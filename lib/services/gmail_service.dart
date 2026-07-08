import 'dart:convert';

import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;

import '../data/parsed_bill.dart';
import 'email_parser.dart';

/// Why a Gmail scan couldn't complete — lets the UI show the right message and
/// always fall back to sample data.
enum GmailFailure { cancelled, notConfigured, unsupported, network, unknown }

class GmailScanException implements Exception {
  const GmailScanException(this.failure, this.message);
  final GmailFailure failure;
  final String message;
  @override
  String toString() => 'GmailScanException($failure): $message';
}

class GmailAccount {
  const GmailAccount({required this.email, this.name});
  final String email;
  final String? name;
}

class GmailScanResult {
  const GmailScanResult({required this.account, required this.candidates, required this.scanned});
  final GmailAccount account;
  final List<ParsedBill> candidates;
  final int scanned;
}

/// Reads the user's Gmail entirely on-device (no backend), extracts upcoming
/// bills with [EmailParser], and returns them as candidates to confirm.
///
/// Requires a Google Cloud OAuth client configured for this app (see
/// `SETUP.md`). Everything runs on the phone; nothing is uploaded.
class GmailService {
  GmailService({this.parser = const EmailParser(), http.Client? client})
      : _client = client ?? http.Client();

  final EmailParser parser;
  final http.Client _client;

  static const scope = 'https://www.googleapis.com/auth/gmail.readonly';
  static const _maxMessages = 40;
  static bool _initialized = false;

  // Google **Web** OAuth client ID, tied to the committed debug keystore's
  // SHA-1 (see SETUP.md, Part C). Fixed because that SHA-1 never changes.
  static const _webClientId =
      '45204952204-5102jul2h2ad87v3o5bbssv1cn2r8s1e.apps.googleusercontent.com';

  // Gmail search: recent, transactional mail only.
  static const _query =
      'newer_than:6m (due OR premium OR invoice OR bill OR payment OR emi OR statement OR subscription OR renewal OR recharge OR policy)';

  /// Runs the full flow: sign in → authorize → fetch → parse.
  ///
  /// When [aiExtract] is supplied (the user configured an AI key), it is used to
  /// extract bills; if it throws, we fall back to the on-device rule parser.
  Future<GmailScanResult> scan({
    void Function(int done, int total)? onProgress,
    Future<List<ParsedBill>> Function(List<RawEmail>)? aiExtract,
  }) async {
    final signIn = GoogleSignIn.instance;
    if (!signIn.supportsAuthenticate()) {
      throw const GmailScanException(
          GmailFailure.unsupported, 'Gmail sign-in isn\'t available on this device.');
    }

    if (!_initialized) {
      try {
        await signIn.initialize(serverClientId: _webClientId);
        _initialized = true;
      } catch (e) {
        throw GmailScanException(GmailFailure.notConfigured,
            'Google Sign-In could not initialize. Check the OAuth setup in SETUP.md. ($e)');
      }
    }

    final GoogleSignInAccount account;
    try {
      account = await signIn.authenticate(scopeHint: const [scope]);
    } on GoogleSignInException catch (e) {
      final cancelled = e.code == GoogleSignInExceptionCode.canceled;
      throw GmailScanException(
        cancelled ? GmailFailure.cancelled : GmailFailure.notConfigured,
        cancelled ? 'Sign-in was cancelled.' : 'Google sign-in failed: ${e.description ?? e.code.name}.',
      );
    }

    final headers = await account.authorizationClient
        .authorizationHeaders(const [scope], promptIfNecessary: true);
    if (headers == null) {
      throw const GmailScanException(
          GmailFailure.cancelled, 'Gmail read permission was not granted.');
    }

    try {
      final ids = (await _listMessageIds(headers)).take(_maxMessages).toList();
      final total = ids.length;
      final emails = <RawEmail>[];
      // Fetch message bodies in parallel batches — far faster than serial.
      const batchSize = 8;
      var done = 0;
      for (var start = 0; start < ids.length; start += batchSize) {
        final batch = ids.skip(start).take(batchSize);
        final results = await Future.wait(batch.map((id) => _getMessage(headers, id)));
        for (final r in results) {
          if (r != null) emails.add(r);
        }
        done += results.length;
        onProgress?.call(done, total);
      }
      List<ParsedBill> candidates;
      if (aiExtract != null) {
        try {
          candidates = await aiExtract(emails);
        } catch (_) {
          // AI failed (bad key, quota, offline) — fall back to on-device rules.
          candidates = parser.parseAll(emails);
        }
      } else {
        candidates = parser.parseAll(emails);
      }
      return GmailScanResult(
        account: GmailAccount(email: account.email, name: account.displayName),
        candidates: candidates,
        scanned: emails.length,
      );
    } on GmailScanException {
      rethrow;
    } catch (e) {
      throw GmailScanException(GmailFailure.network, 'Could not read Gmail: $e');
    }
  }

  Future<void> disconnect() async {
    try {
      await GoogleSignIn.instance.disconnect();
    } catch (_) {}
  }

  Future<List<String>> _listMessageIds(Map<String, String> headers) async {
    final uri = Uri.https('gmail.googleapis.com', '/gmail/v1/users/me/messages', {
      'q': _query,
      'maxResults': '$_maxMessages',
    });
    final res = await _client.get(uri, headers: headers);
    if (res.statusCode != 200) {
      throw GmailScanException(GmailFailure.network, 'Gmail list failed (${res.statusCode}).');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final messages = (body['messages'] as List?) ?? const [];
    return messages.map((m) => (m as Map<String, dynamic>)['id'] as String).toList();
  }

  Future<RawEmail?> _getMessage(Map<String, String> headers, String id) async {
    final uri = Uri.https('gmail.googleapis.com', '/gmail/v1/users/me/messages/$id',
        {'format': 'full'});
    final res = await _client.get(uri, headers: headers);
    if (res.statusCode != 200) return null;
    final msg = jsonDecode(res.body) as Map<String, dynamic>;
    final payload = (msg['payload'] as Map<String, dynamic>?) ?? const {};
    final hdrs = (payload['headers'] as List?) ?? const [];

    String header(String name) {
      for (final h in hdrs) {
        final map = h as Map<String, dynamic>;
        if ((map['name'] as String).toLowerCase() == name.toLowerCase()) {
          return map['value'] as String? ?? '';
        }
      }
      return '';
    }

    final internalMs = int.tryParse(msg['internalDate'] as String? ?? '') ?? 0;
    return RawEmail(
      id: id,
      from: header('From'),
      subject: header('Subject'),
      date: DateTime.fromMillisecondsSinceEpoch(internalMs),
      snippet: msg['snippet'] as String? ?? '',
      body: _extractBody(payload),
    );
  }

  /// Walks the MIME tree for text, preferring text/plain, falling back to a
  /// tag-stripped text/html part.
  String _extractBody(Map<String, dynamic> payload) {
    final plain = _findPart(payload, 'text/plain');
    if (plain != null) return plain;
    final html = _findPart(payload, 'text/html');
    if (html != null) return _stripHtml(html);
    return '';
  }

  String? _findPart(Map<String, dynamic> node, String mime) {
    final nodeMime = (node['mimeType'] as String? ?? '').toLowerCase();
    final data = (node['body'] as Map<String, dynamic>?)?['data'] as String?;
    if (nodeMime == mime && data != null) return _decodeB64(data);
    for (final part in (node['parts'] as List?) ?? const []) {
      final found = _findPart(part as Map<String, dynamic>, mime);
      if (found != null) return found;
    }
    return null;
  }

  String _decodeB64(String data) {
    try {
      return utf8.decode(base64Url.decode(base64Url.normalize(data)), allowMalformed: true);
    } catch (_) {
      return '';
    }
  }

  String _stripHtml(String html) => html
      .replaceAll(RegExp(r'<(script|style)[^>]*>[\s\S]*?</\1>', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAll(RegExp(r'&nbsp;', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
