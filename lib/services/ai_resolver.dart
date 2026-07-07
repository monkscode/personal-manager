import 'dart:convert';

import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;

import '../data/parsed_bill.dart';

class AiException implements Exception {
  const AiException(this.message);
  final String message;
  @override
  String toString() => 'AiException: $message';
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
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String apiKey;
  final String model;
  final String endpointBase;
  final http.Client _client;

  static const _allowedCategories = {
    'insurance', 'housing', 'utilities', 'subscriptions', 'transport', 'groceries', 'other'
  };
  static const _allowedRecurrence = {'onetime', 'monthly', 'quarterly', 'annual'};

  bool get isConfigured => apiKey.trim().isNotEmpty;

  Future<List<ParsedBill>> extract(List<RawEmail> emails) async {
    if (!isConfigured) throw const AiException('No API key configured.');
    if (emails.isEmpty) return const [];

    final uri = Uri.parse('$endpointBase/models/$model:generateContent?key=$apiKey');
    final res = await _client.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(buildRequestBody(emails)),
    );
    if (res.statusCode != 200) {
      throw AiException('Gemini request failed (${res.statusCode}): ${_shorten(res.body)}');
    }

    final decoded = jsonDecode(res.body) as Map<String, dynamic>;
    final text = responseText(decoded);
    if (text == null) throw const AiException('Empty AI response.');
    return mapItems(text, emails);
  }

  /// Pulls the model's text out of a `generateContent` response.
  static String? responseText(Map<String, dynamic> decoded) {
    final candidates = decoded['candidates'] as List?;
    if (candidates == null || candidates.isEmpty) return null;
    final parts = (((candidates.first as Map)['content'] as Map?)?['parts'] as List?) ?? const [];
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
    final list = parsed is List ? parsed : (parsed is Map ? (parsed['bills'] as List? ?? const []) : const []);

    final bills = <ParsedBill>[];
    for (final item in list) {
      if (item is! Map) continue;
      final isBill = item['isBill'];
      if (isBill == false) continue;
      final amount = _num(item['amount']);
      if (amount == null || amount < 1) continue;

      final idx = _int(item['index']);
      final email = (idx != null && idx >= 0 && idx < emails.length) ? emails[idx] : null;

      var category = (item['category'] as String?)?.toLowerCase().trim() ?? 'other';
      if (!_allowedCategories.contains(category)) category = 'other';
      var recurrence = (item['recurrence'] as String?)?.toLowerCase().trim() ?? 'onetime';
      if (!_allowedRecurrence.contains(recurrence)) recurrence = 'onetime';

      final merchant = (item['merchant'] as String?)?.trim();
      final dueStr = (item['dueDate'] as String?)?.trim() ?? '';
      final due = dueStr.isEmpty ? null : DateTime.tryParse(dueStr);

      bills.add(ParsedBill(
        sourceId: email?.id ?? 'ai-${bills.length}',
        merchant: (merchant == null || merchant.isEmpty) ? (email?.fromName ?? 'Bill') : merchant,
        amount: amount,
        dueDate: due,
        categoryKey: category,
        recurrence: recurrence,
        confidence: 0.92, // AI-extracted; user still confirms
        sourceSubject: email?.subject ?? '',
        sourceFrom: email?.from ?? '',
      ));
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
      buffer.writeln('Body: ${_clip(body, 1500)}');
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
        'Amounts must be the payable total, not fees or balances. Omit non-bills.';

    return {
      'contents': [
        {
          'role': 'user',
          'parts': [
            {'text': '$instruction\n\nEMAILS:\n${buffer.toString()}'}
          ]
        }
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

  static String _clip(String s, int max) => s.length <= max ? s : s.substring(0, max);
  static String _shorten(String s) => s.length <= 180 ? s : '${s.substring(0, 180)}…';

  static String _stripFences(String s) {
    var t = s.trim();
    if (t.startsWith('```')) {
      t = t.replaceFirst(RegExp(r'^```[a-zA-Z]*\s*'), '').replaceFirst(RegExp(r'\s*```$'), '');
    }
    return t.trim();
  }

  static double? _num(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v.replaceAll(',', '').replaceAll(RegExp(r'[^0-9.]'), ''));
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
    http.Client? baseClient,
  }) : _base = baseClient;

  final String serviceAccountJson;
  final String region;
  final String model;
  final http.Client? _base;

  bool get isConfigured => serviceAccountJson.trim().isNotEmpty;

  Future<List<ParsedBill>> extract(List<RawEmail> emails) async {
    if (!isConfigured) throw const AiException('No service account configured.');
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
          'This does not look like a service-account key (needs type=service_account + project_id).');
    }

    final credentials = ServiceAccountCredentials.fromJson(sa);
    final client = await clientViaServiceAccount(
      credentials,
      const ['https://www.googleapis.com/auth/cloud-platform'],
      baseClient: _base,
    );
    try {
      final uri = Uri.parse(
          'https://$region-aiplatform.googleapis.com/v1/projects/$projectId/locations/$region/publishers/google/models/$model:generateContent');
      final res = await client.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(GeminiResolver.buildRequestBody(emails)),
      );
      if (res.statusCode != 200) {
        throw AiException('Vertex request failed (${res.statusCode}).');
      }
      final decoded = jsonDecode(res.body) as Map<String, dynamic>;
      final text = GeminiResolver.responseText(decoded);
      if (text == null) throw const AiException('Empty Vertex response.');
      return GeminiResolver.mapItems(text, emails);
    } finally {
      client.close();
    }
  }
}
