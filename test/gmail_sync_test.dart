import 'dart:convert';

import 'package:expense_insight/services/gmail_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

final class _FakeAuthClient implements GmailAuthClient {
  _FakeAuthClient(this.restored);

  final GmailAuthAccount? restored;
  int restoreCalls = 0;
  int authenticateCalls = 0;

  @override
  bool supportsAuthenticate() => true;

  @override
  Future<GmailAuthAccount?> restore() async {
    restoreCalls++;
    return restored;
  }

  @override
  Future<GmailAuthAccount> authenticate({
    required List<String> scopeHint,
  }) async {
    authenticateCalls++;
    return restored!;
  }

  @override
  Future<void> disconnect() async {}
}

final class _GmailHttpClient extends http.BaseClient {
  _GmailHttpClient({required this.pages});

  final Map<String?, List<String>> pages;
  final List<String?> listPageTokens = [];
  int messageRequestCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final uri = request.url;
    late final Map<String, dynamic> body;
    if (uri.path == '/gmail/v1/users/me/messages') {
      final token = uri.queryParameters['pageToken'];
      listPageTokens.add(token);
      final ids = pages[token] ?? const [];
      body = {
        'messages': [
          for (final id in ids) {'id': id},
        ],
        if (token == null && pages.containsKey('page-2'))
          'nextPageToken': 'page-2',
      };
    } else {
      messageRequestCount++;
      final id = uri.pathSegments.last;
      body = {
        'id': id,
        'internalDate': '1767225600000',
        'snippet': 'Amount due Rs 100 on 10 Jan 2026',
        'payload': {
          'mimeType': 'text/plain',
          'headers': [
            {'name': 'From', 'value': 'Biller <bills@example.com>'},
            {'name': 'Subject', 'value': 'Payment reminder'},
          ],
          'body': {
            'data': base64Url.encode(
              utf8.encode('Your bill amount due is Rs 100 on 10 Jan 2026.'),
            ),
          },
        },
      };
    }
    final bytes = utf8.encode(jsonEncode(body));
    return http.StreamedResponse(
      Stream.value(bytes),
      200,
      request: request,
      headers: const {'content-type': 'application/json'},
    );
  }
}

GmailAuthAccount _account(List<bool> authorizationPrompts) => GmailAuthAccount(
  email: 'person@example.com',
  name: 'Person',
  authorizationHeaders: (scopes, {required promptIfNecessary}) async {
    authorizationPrompts.add(promptIfNecessary);
    return {'Authorization': 'Bearer local-test'};
  },
);

void main() {
  test(
    'restored account is reused without interactive authentication',
    () async {
      final prompts = <bool>[];
      final auth = _FakeAuthClient(_account(prompts));
      final service = GmailService(
        auth: auth,
        client: _GmailHttpClient(pages: const {null: []}),
      );

      await service.scan();

      expect(auth.restoreCalls, 1);
      expect(auth.authenticateCalls, 0);
      expect(prompts, [false]);
    },
  );

  test(
    'follows page tokens and fetches more than 40 matching messages',
    () async {
      final prompts = <bool>[];
      final auth = _FakeAuthClient(_account(prompts));
      final client = _GmailHttpClient(
        pages: {
          null: [for (var i = 0; i < 40; i++) 'm$i'],
          'page-2': ['m40', 'm41'],
        },
      );
      final service = GmailService(auth: auth, client: client);

      final result = await service.scan();

      expect(result.scanned, 42);
      expect(client.listPageTokens, [null, 'page-2']);
      expect(client.messageRequestCount, 42);
    },
  );
}
