import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;

import '../data/parsed_bill.dart';
import 'email_parser.dart';

class AiException implements Exception {
  const AiException(this.message);
  final String message;
  @override
  String toString() => 'AiException: $message';
}

const int kAiEmailBatchSize = 5;
const int kAiMaxConcurrentBatches = 4;
const int kAiMaxAttempts = 2;
const int kAiMaxBodyChars = 1500;
const Duration kAiRequestTimeout = Duration(seconds: 60);
const Duration kAiResolverOverallTimeout = Duration(seconds: 120);

class AiBatchFallback {
  const AiBatchFallback({required this.emailCount, required this.reason});

  final int emailCount;
  final String reason;
}

Future<List<ParsedBill>> _extractWithPartialFallback({
  required List<RawEmail> emails,
  required Future<List<ParsedBill>> Function(List<RawEmail>) requestBatch,
  required Duration requestTimeout,
  required Duration overallTimeout,
  required int batchSize,
  required int maxConcurrentBatches,
  required int maxAttempts,
  void Function(AiBatchFallback fallback)? onBatchFallback,
  void Function(int emailCount)? onBatchSuccess,
}) async {
  if (batchSize <= 0) {
    throw ArgumentError.value(batchSize, 'batchSize', 'must be positive');
  }
  if (maxConcurrentBatches <= 0) {
    throw ArgumentError.value(
      maxConcurrentBatches,
      'maxConcurrentBatches',
      'must be positive',
    );
  }
  if (maxAttempts <= 0) {
    throw ArgumentError.value(maxAttempts, 'maxAttempts', 'must be positive');
  }
  final batches = <List<RawEmail>>[
    for (var start = 0; start < emails.length; start += batchSize)
      emails.skip(start).take(batchSize).toList(),
  ];
  final results = List<List<ParsedBill>?>.filled(batches.length, null);
  final deadline = DateTime.now().add(overallTimeout);
  var nextBatch = 0;

  List<ParsedBill> fallback(List<RawEmail> batch, String reason) {
    onBatchFallback?.call(
      AiBatchFallback(emailCount: batch.length, reason: reason),
    );
    return const EmailParser().parseAll(batch);
  }

  Future<void> worker() async {
    while (true) {
      // Claimed synchronously before the first await, so workers cannot overlap.
      final batchIndex = nextBatch++;
      if (batchIndex >= batches.length) return;
      final batch = batches[batchIndex];
      Object? lastError;

      for (var attempt = 0; attempt < maxAttempts; attempt++) {
        final remaining = deadline.difference(DateTime.now());
        if (remaining <= Duration.zero) {
          lastError = TimeoutException(
            'AI overall extraction timed out after '
            '${overallTimeout.inSeconds} seconds.',
          );
          break;
        }
        final timeout = remaining < requestTimeout ? remaining : requestTimeout;
        try {
          results[batchIndex] = await requestBatch(batch).timeout(
            timeout,
            onTimeout: () => throw TimeoutException(
              'AI request timed out after ${timeout.inSeconds} seconds.',
            ),
          );
          onBatchSuccess?.call(batch.length);
          lastError = null;
          break;
        } catch (error) {
          lastError = error;
        }
      }

      results[batchIndex] ??= fallback(batch, lastError.toString());
    }
  }

  final workerCount = math.min(maxConcurrentBatches, batches.length);
  await Future.wait(List.generate(workerCount, (_) => worker()));
  if (results.any((result) => result == null)) {
    throw StateError('AI extraction left an unprocessed batch.');
  }
  return [for (final result in results) ...result ?? const []];
}

/// Optional AI extractor. Sends candidate emails to Google's Gemini
/// `generateContent` endpoint (using the user's own API key) and asks for a
/// structured list of bills. Used as a higher-accuracy alternative to the
/// on-device rule parser; the caller falls back to rules if this fails.
///
/// The same `?key=` call works for a Google AI Studio / Gemini key and for a
/// Vertex AI *Express* key; [endpointBase] can be pointed at another host for
/// other Vertex configurations.
class GeminiResolver {
  GeminiResolver({
    required this.apiKey,
    this.model = 'gemini-2.5-flash',
    this.endpointBase = 'https://generativelanguage.googleapis.com/v1beta',
    this.requestTimeout = kAiRequestTimeout,
    this.overallTimeout = kAiResolverOverallTimeout,
    this.batchSize = kAiEmailBatchSize,
    this.maxConcurrentBatches = kAiMaxConcurrentBatches,
    this.maxAttempts = kAiMaxAttempts,
    this.onBatchFallback,
    this.onBatchSuccess,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String apiKey;
  final String model;
  final String endpointBase;
  final Duration requestTimeout;
  final Duration overallTimeout;
  final int batchSize;
  final int maxConcurrentBatches;
  final int maxAttempts;
  final void Function(AiBatchFallback fallback)? onBatchFallback;
  final void Function(int emailCount)? onBatchSuccess;
  final http.Client _client;

  static const _allowedCategories = {
    'insurance',
    'housing',
    'utilities',
    'subscriptions',
    'transport',
    'groceries',
    'other',
  };
  static const _allowedRecurrence = {
    'onetime',
    'monthly',
    'quarterly',
    'annual',
  };

  bool get isConfigured => apiKey.trim().isNotEmpty;

  Future<List<ParsedBill>> extract(List<RawEmail> emails) async {
    if (!isConfigured) throw const AiException('No API key configured.');
    if (emails.isEmpty) return const [];

    final uri = Uri.parse(
      '$endpointBase/models/$model:generateContent?key=$apiKey',
    );
    return _extractWithPartialFallback(
      emails: emails,
      requestTimeout: requestTimeout,
      overallTimeout: overallTimeout,
      batchSize: batchSize,
      maxConcurrentBatches: maxConcurrentBatches,
      maxAttempts: maxAttempts,
      onBatchFallback: onBatchFallback,
      onBatchSuccess: onBatchSuccess,
      requestBatch: (batch) async {
        final res = await _client.post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(buildRequestBody(batch)),
        );
        if (res.statusCode != 200) {
          throw AiException(
            'Gemini request failed (${res.statusCode}): ${_shorten(res.body)}',
          );
        }
        final decoded = jsonDecode(res.body) as Map<String, dynamic>;
        final text = responseText(decoded);
        if (text == null) throw const AiException('Empty AI response.');
        return mapItems(text, batch);
      },
    );
  }

  /// Pulls the model's text out of a `generateContent` response.
  static String? responseText(Map<String, dynamic> decoded) {
    final candidates = decoded['candidates'] as List?;
    if (candidates == null || candidates.isEmpty) return null;
    final parts =
        (((candidates.first as Map)['content'] as Map?)?['parts'] as List?) ??
        const [];
    final buffer = StringBuffer();
    for (final p in parts) {
      final t = (p as Map)['text'];
      if (t is String) buffer.write(t);
    }
    final s = buffer.toString().trim();
    return s.isEmpty ? null : s;
  }

  /// Parses the model's JSON text into bills, mapping each item back to its
  /// source email by index. Pure and unit-tested — no network.
  static List<ParsedBill> mapItems(String jsonText, List<RawEmail> emails) {
    final cleaned = _stripFences(jsonText);
    final dynamic parsed;
    try {
      parsed = jsonDecode(cleaned);
    } catch (_) {
      throw AiException('AI returned non-JSON output: ${_shorten(cleaned)}');
    }
    final list = parsed is List
        ? parsed
        : (parsed is Map ? (parsed['bills'] as List? ?? const []) : const []);

    final bills = <ParsedBill>[];
    for (final item in list) {
      if (item is! Map) continue;
      final isBill = item['isBill'];
      if (isBill == false) continue;
      // Keep bills even when the model couldn't find an amount (many Indian bill
      // *reminder* emails omit the figure). Amount 0 means "not detected"; the
      // caller runs a rule-based backstop and, failing that, the user sets it in
      // review. Dropping amountless bills here is what made real bills vanish.
      final amount = _num(item['amount']) ?? 0;

      final idx = _int(item['index']);
      final email = (idx != null && idx >= 0 && idx < emails.length)
          ? emails[idx]
          : null;

      var category =
          (item['category'] as String?)?.toLowerCase().trim() ?? 'other';
      if (!_allowedCategories.contains(category)) category = 'other';
      var recurrence =
          (item['recurrence'] as String?)?.toLowerCase().trim() ?? 'onetime';
      if (!_allowedRecurrence.contains(recurrence)) recurrence = 'onetime';

      final merchant = (item['merchant'] as String?)?.trim();
      final dueStr = (item['dueDate'] as String?)?.trim() ?? '';
      final due = dueStr.isEmpty ? null : DateTime.tryParse(dueStr);

      bills.add(
        ParsedBill(
          sourceId: email?.id ?? 'ai-${bills.length}',
          merchant: (merchant == null || merchant.isEmpty)
              ? (email?.fromName ?? 'Bill')
              : merchant,
          amount: amount,
          dueDate: due,
          categoryKey: category,
          recurrence: recurrence,
          confidence: 0.92, // AI-extracted; user still confirms
          sourceSubject: email?.subject ?? '',
          sourceFrom: email?.from ?? '',
        ),
      );
    }
    return bills;
  }

  static Map<String, dynamic> buildRequestBody(List<RawEmail> emails) {
    final buffer = StringBuffer();
    for (var i = 0; i < emails.length; i++) {
      final e = emails[i];
      final body = e.body.isEmpty ? e.snippet : e.body;
      buffer.writeln('--- EMAIL index=$i ---');
      buffer.writeln('From: ${e.from}');
      buffer.writeln('Subject: ${e.subject}');
      buffer.writeln('Date: ${e.date.toIso8601String()}');
      buffer.writeln('Body: ${_clip(body, kAiMaxBodyChars)}');
    }

    const instruction =
        'You extract upcoming bills/payments from a user\'s emails so they can plan next month\'s cash. '
        'For EACH email decide if it represents a real bill, invoice, premium, EMI, subscription charge or payment the user must pay. '
        'Ignore marketing, offers, OTPs and receipts for already-completed one-off purchases. '
        'Return a JSON array; one object per email you judged a bill. Fields: '
        'index (the email index), isBill (bool), merchant (short payee name), amount (number in INR, no symbols/commas), '
        'dueDate (YYYY-MM-DD, or "" if unknown), '
        'category (one of: insurance, housing, utilities, subscriptions, transport, groceries, other), '
        'recurrence (one of: onetime, monthly, quarterly, annual). '
        'For amount: read the whole email (subject + body) and return the exact numeric payable total if it appears ANYWHERE '
        '(e.g. "Rs. 543", "INR 1,168.20", "₹2,100"); strip symbols and commas. '
        'Use 0 ONLY if the email truly states no amount (e.g. a reminder that says "your bill is ready, log in to pay"). '
        'Never guess or fabricate an amount, and never treat a fee, balance, reward-points or promotional figure as the amount. '
        'Still return the bill object (with amount 0) when it is clearly a bill but the amount is absent. Omit non-bills.';

    return {
      'contents': [
        {
          'role': 'user',
          'parts': [
            {'text': '$instruction\n\nEMAILS:\n${buffer.toString()}'},
          ],
        },
      ],
      'generationConfig': {
        'temperature': 0,
        'responseMimeType': 'application/json',
        'responseSchema': {
          'type': 'ARRAY',
          'items': {
            'type': 'OBJECT',
            'properties': {
              'index': {'type': 'INTEGER'},
              'isBill': {'type': 'BOOLEAN'},
              'merchant': {'type': 'STRING'},
              'amount': {'type': 'NUMBER'},
              'dueDate': {'type': 'STRING'},
              'category': {'type': 'STRING'},
              'recurrence': {'type': 'STRING'},
            },
            'required': ['index', 'isBill', 'amount'],
          },
        },
      },
    };
  }

  static String _clip(String s, int max) =>
      s.length <= max ? s : s.substring(0, max);
  static String _shorten(String s) =>
      s.length <= 180 ? s : '${s.substring(0, 180)}…';

  static String _stripFences(String s) {
    var t = s.trim();
    if (t.startsWith('```')) {
      t = t
          .replaceFirst(RegExp(r'^```[a-zA-Z]*\s*'), '')
          .replaceFirst(RegExp(r'\s*```$'), '');
    }
    return t.trim();
  }

  static double? _num(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) {
      return double.tryParse(
        v.replaceAll(',', '').replaceAll(RegExp(r'[^0-9.]'), ''),
      );
    }
    return null;
  }

  static int? _int(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }
}

/// Vertex AI extractor authenticated with a **service-account key**
/// (`credentials.json` with `type: service_account`). Signs a token via
/// [googleapis_auth] and calls the regional Vertex `generateContent` endpoint.
/// Shares request/response handling with [GeminiResolver].
///
/// SECURITY: this embeds a broad-scope credential on the device — fine for a
/// personal build you don't distribute, but never ship it in a public app.
class VertexResolver {
  VertexResolver({
    required this.serviceAccountJson,
    this.region = 'us-central1',
    this.model = 'gemini-2.5-flash',
    this.requestTimeout = kAiRequestTimeout,
    this.overallTimeout = kAiResolverOverallTimeout,
    this.batchSize = kAiEmailBatchSize,
    this.maxConcurrentBatches = kAiMaxConcurrentBatches,
    this.maxAttempts = kAiMaxAttempts,
    this.onBatchFallback,
    this.onBatchSuccess,
    http.Client? baseClient,
  }) : _base = baseClient;

  final String serviceAccountJson;
  final String region;
  final String model;
  final Duration requestTimeout;
  final Duration overallTimeout;
  final int batchSize;
  final int maxConcurrentBatches;
  final int maxAttempts;
  final void Function(AiBatchFallback fallback)? onBatchFallback;
  final void Function(int emailCount)? onBatchSuccess;
  final http.Client? _base;

  bool get isConfigured => serviceAccountJson.trim().isNotEmpty;

  Future<List<ParsedBill>> extract(List<RawEmail> emails) async {
    if (!isConfigured) {
      throw const AiException('No service account configured.');
    }
    if (emails.isEmpty) return const [];

    final Map<String, dynamic> sa;
    try {
      sa = jsonDecode(serviceAccountJson) as Map<String, dynamic>;
    } catch (_) {
      throw const AiException('Service account JSON is not valid JSON.');
    }
    final projectId = sa['project_id'] as String?;
    if (sa['type'] != 'service_account' || projectId == null) {
      throw const AiException(
        'This does not look like a service-account key (needs type=service_account + project_id).',
      );
    }

    final credentials = ServiceAccountCredentials.fromJson(sa);
    final client = await clientViaServiceAccount(credentials, const [
      'https://www.googleapis.com/auth/cloud-platform',
    ], baseClient: _base);
    try {
      final uri = Uri.parse(
        'https://$region-aiplatform.googleapis.com/v1/projects/$projectId/locations/$region/publishers/google/models/$model:generateContent',
      );
      return await _extractWithPartialFallback(
        emails: emails,
        requestTimeout: requestTimeout,
        overallTimeout: overallTimeout,
        batchSize: batchSize,
        maxConcurrentBatches: maxConcurrentBatches,
        maxAttempts: maxAttempts,
        onBatchFallback: onBatchFallback,
        onBatchSuccess: onBatchSuccess,
        requestBatch: (batch) async {
          final res = await client.post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(GeminiResolver.buildRequestBody(batch)),
          );
          if (res.statusCode != 200) {
            throw AiException('Vertex request failed (${res.statusCode}).');
          }
          final decoded = jsonDecode(res.body) as Map<String, dynamic>;
          final text = GeminiResolver.responseText(decoded);
          if (text == null) throw const AiException('Empty Vertex response.');
          return GeminiResolver.mapItems(text, batch);
        },
      );
    } finally {
      client.close();
    }
  }
}
