import 'dart:async';
import 'dart:convert';

import 'package:expense_insight/data/parsed_bill.dart';
import 'package:expense_insight/services/ai_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

RawEmail _e(String id, String from, String subject) =>
    RawEmail(id: id, from: from, subject: subject, date: DateTime(2026, 1, 20));

final class _BatchingClient extends http.BaseClient {
  int requestCount = 0;
  final List<int> emailCounts = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requestCount++;
    final body = request is http.Request ? request.body : '';
    final requestJson = jsonDecode(body) as Map<String, dynamic>;
    final contents = requestJson['contents'] as List;
    final content = contents.single as Map<String, dynamic>;
    final parts = content['parts'] as List;
    final prompt = (parts.single as Map<String, dynamic>)['text'] as String;
    emailCounts.add(RegExp(r'--- EMAIL index=').allMatches(prompt).length);
    final response = jsonEncode({
      'candidates': [
        {
          'content': {
            'parts': [
              {
                'text': jsonEncode([
                  {
                    'index': 0,
                    'isBill': true,
                    'merchant': 'Batch bill',
                    'amount': 100,
                    'category': 'other',
                    'recurrence': 'onetime',
                  },
                ]),
              },
            ],
          },
        },
      ],
    });
    return http.StreamedResponse(Stream.value(utf8.encode(response)), 200);
  }
}

final class _NeverReturningClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Completer<http.StreamedResponse>().future;
}

final class _PartiallyReturningClient extends http.BaseClient {
  final _success = _BatchingClient();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final body = request is http.Request ? request.body : '';
    if (body.contains('Bill 5')) {
      return Completer<http.StreamedResponse>().future;
    }
    return _success.send(request);
  }
}

final class _FailsOnceClient extends http.BaseClient {
  final _success = _BatchingClient();
  int attempts = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    attempts++;
    if (attempts == 1) {
      throw http.ClientException('temporary network error');
    }
    return _success.send(request);
  }
}

void main() {
  final emails = [
    _e('m0', 'LIC <no-reply@licindia.com>', 'Premium reminder'),
    _e('m1', 'Amazon <deals@amazon.in>', 'Sale'),
    _e('m2', 'Netflix <info@netflix.com>', 'Your bill'),
  ];

  group('GeminiResolver.mapItems', () {
    test('maps AI JSON to bills, mapping index back to the source email', () {
      const json = '''
      [
        {"index":0,"isBill":true,"merchant":"LIC of India","amount":47000,"dueDate":"2026-02-14","category":"insurance","recurrence":"annual"},
        {"index":2,"isBill":true,"merchant":"Netflix","amount":649,"dueDate":"","category":"subscriptions","recurrence":"monthly"}
      ]''';
      final bills = GeminiResolver.mapItems(json, emails);
      expect(bills.length, 2);
      expect(bills[0].sourceId, 'm0');
      expect(bills[0].merchant, 'LIC of India');
      expect(bills[0].amount, 47000);
      expect(bills[0].dueDate, DateTime(2026, 2, 14));
      expect(bills[0].categoryKey, 'insurance');
      expect(bills[0].recurrence, 'annual');
      expect(bills[1].sourceId, 'm2');
      expect(bills[1].dueDate, isNull);
      expect(bills.every((b) => b.confidence > 0.8), isTrue);
    });

    test('drops non-bills but keeps genuine bills that have no amount', () {
      const json = '''
      [
        {"index":1,"isBill":false,"amount":0},
        {"index":0,"isBill":true,"merchant":"X","amount":0,"category":"other","recurrence":"onetime"}
      ]''';
      // isBill:false is dropped; the amountless bill is kept with amount 0
      // ("not detected") so the rule-based backstop / review can supply the
      // figure — dropping it here is what made real reminder bills vanish.
      final bills = GeminiResolver.mapItems(json, emails);
      expect(bills.single.merchant, 'X');
      expect(bills.single.amount, 0);
      expect(bills.single.sourceId, 'm0');
    });

    test('normalizes unknown category/recurrence to safe defaults', () {
      const json =
          '[{"index":0,"isBill":true,"merchant":"X","amount":100,"category":"weird","recurrence":"nonsense"}]';
      final bills = GeminiResolver.mapItems(json, emails);
      expect(bills.single.categoryKey, 'other');
      expect(bills.single.recurrence, 'onetime');
    });

    test('tolerates markdown code fences and stringified amounts', () {
      const json =
          '```json\n[{"index":2,"isBill":true,"merchant":"Netflix","amount":"₹649","category":"subscriptions","recurrence":"monthly"}]\n```';
      final bills = GeminiResolver.mapItems(json, emails);
      expect(bills.single.amount, 649);
      expect(bills.single.merchant, 'Netflix');
    });

    test('throws AiException on non-JSON output', () {
      expect(
        () => GeminiResolver.mapItems('sorry, I could not help', emails),
        throwsA(isA<AiException>()),
      );
    });
  });

  group('GeminiResolver.extract', () {
    test('limits each email body excerpt to 1500 characters', () {
      final body = List.filled(2000, 'x').join();
      final request = GeminiResolver.buildRequestBody([
        RawEmail(
          id: 'long',
          from: 'Biller <bills@example.com>',
          subject: 'Bill',
          body: body,
          date: DateTime(2026, 7, 20),
        ),
      ]);
      final contents = request['contents'] as List;
      final content = contents.single as Map<String, dynamic>;
      final parts = content['parts'] as List;
      final prompt = (parts.single as Map<String, dynamic>)['text'] as String;

      expect(kAiMaxBodyChars, 1500);
      expect(prompt, contains(List.filled(1500, 'x').join()));
      expect(prompt, isNot(contains(List.filled(1501, 'x').join())));
    });

    test(
      'batches at 5 emails and preserves each batch source mapping',
      () async {
        final client = _BatchingClient();
        var aiProcessedEmails = 0;
        final resolver = GeminiResolver(
          apiKey: 'test',
          client: client,
          onBatchSuccess: (emailCount) => aiProcessedEmails += emailCount,
        );
        final input = [
          for (var index = 0; index < 21; index++)
            _e('m$index', 'Biller <bills@example.com>', 'Bill $index'),
        ];

        final bills = await resolver.extract(input);

        expect(client.requestCount, 5);
        expect(client.emailCounts, unorderedEquals([5, 5, 5, 5, 1]));
        expect(bills.map((bill) => bill.sourceId), [
          'm0',
          'm5',
          'm10',
          'm15',
          'm20',
        ]);
        expect(aiProcessedEmails, 21);
      },
    );

    test('uses local extraction when an AI batch cannot return', () async {
      final fallbacks = <AiBatchFallback>[];
      var aiProcessedEmails = 0;
      final resolver = GeminiResolver(
        apiKey: 'test',
        client: _NeverReturningClient(),
        requestTimeout: const Duration(milliseconds: 10),
        overallTimeout: const Duration(milliseconds: 30),
        maxAttempts: 1,
        onBatchFallback: fallbacks.add,
        onBatchSuccess: (emailCount) => aiProcessedEmails += emailCount,
      );

      final bills = await resolver.extract([emails.first]);

      expect(bills.map((bill) => bill.sourceId), ['m0']);
      expect(fallbacks, hasLength(1));
      expect(fallbacks.single.emailCount, 1);
      expect(fallbacks.single.reason, contains('timed out'));
      expect(aiProcessedEmails, 0);
    });

    test(
      'retries a transient batch failure before using local extraction',
      () async {
        final client = _FailsOnceClient();
        final fallbacks = <AiBatchFallback>[];
        var aiProcessedEmails = 0;
        final resolver = GeminiResolver(
          apiKey: 'test',
          client: client,
          onBatchFallback: fallbacks.add,
          onBatchSuccess: (emailCount) => aiProcessedEmails += emailCount,
        );

        final bills = await resolver.extract([emails.first]);

        expect(client.attempts, 2);
        expect(bills.map((bill) => bill.sourceId), ['m0']);
        expect(aiProcessedEmails, 1);
        expect(fallbacks, isEmpty);
      },
    );

    test(
      'retains successful AI batches when another batch falls back',
      () async {
        final fallbacks = <AiBatchFallback>[];
        var aiProcessedEmails = 0;
        final resolver = GeminiResolver(
          apiKey: 'test',
          client: _PartiallyReturningClient(),
          requestTimeout: const Duration(milliseconds: 10),
          overallTimeout: const Duration(milliseconds: 30),
          maxAttempts: 1,
          onBatchFallback: fallbacks.add,
          onBatchSuccess: (emailCount) => aiProcessedEmails += emailCount,
        );
        final input = [
          for (var index = 0; index < 6; index++)
            RawEmail(
              id: 'm$index',
              from: 'Biller <bills@example.com>',
              subject: 'Bill $index',
              body: 'Amount due ₹100 on 10 Aug 2026.',
              date: DateTime(2026, 7, 20),
            ),
        ];

        final bills = await resolver.extract(input);

        expect(bills.map((bill) => bill.sourceId), ['m0', 'm5']);
        expect(fallbacks, hasLength(1));
        expect(fallbacks.single.emailCount, 1);
        expect(aiProcessedEmails, 5);
      },
    );
  });
}
