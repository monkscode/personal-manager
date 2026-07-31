import 'dart:async';
import 'dart:convert';

import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;

import '../data/parsed_bill.dart';
import 'email_parser.dart';

/// Why a Gmail scan couldn't complete so the UI can show the right recovery.
enum GmailFailure { cancelled, notConfigured, unsupported, network, unknown }

const Duration kAiOverallExtractionTimeout = Duration(seconds: 150);

class GmailScanException implements Exception {
  const GmailScanException(this.failure, this.message);
  final GmailFailure failure;
  final String message;
  @override
  String toString() => 'GmailScanException($failure): $message';
}

typedef GmailAuthorizationHeaders =
    Future<Map<String, String>?> Function(
      List<String> scopes, {
      required bool promptIfNecessary,
    });

class GmailAuthAccount {
  const GmailAuthAccount({
    required this.email,
    required this.authorizationHeaders,
    this.name,
  });

  final String email;
  final String? name;
  final GmailAuthorizationHeaders authorizationHeaders;
}

abstract interface class GmailAuthClient {
  bool supportsAuthenticate();
  Future<GmailAuthAccount?> restore();
  Future<GmailAuthAccount> authenticate({required List<String> scopeHint});
  Future<void> disconnect();
}

final class GoogleGmailAuthClient implements GmailAuthClient {
  static Future<void>? _initialization;

  Future<void> _initialize() => _initialization ??= GoogleSignIn.instance
      .initialize(serverClientId: GmailService.webClientId);

  GmailAuthAccount _wrap(GoogleSignInAccount account) => GmailAuthAccount(
    email: account.email,
    name: account.displayName,
    authorizationHeaders: (scopes, {required promptIfNecessary}) => account
        .authorizationClient
        .authorizationHeaders(scopes, promptIfNecessary: promptIfNecessary),
  );

  @override
  bool supportsAuthenticate() => GoogleSignIn.instance.supportsAuthenticate();

  @override
  Future<GmailAuthAccount?> restore() async {
    await _initialize();
    final attempt = GoogleSignIn.instance.attemptLightweightAuthentication();
    final account = attempt == null ? null : await attempt;
    return account == null ? null : _wrap(account);
  }

  @override
  Future<GmailAuthAccount> authenticate({
    required List<String> scopeHint,
  }) async {
    await _initialize();
    return _wrap(
      await GoogleSignIn.instance.authenticate(scopeHint: scopeHint),
    );
  }

  @override
  Future<void> disconnect() async {
    await _initialize();
    await GoogleSignIn.instance.disconnect();
  }
}

class GmailAccount {
  const GmailAccount({required this.email, this.name});
  final String email;
  final String? name;
}

class GmailScanResult {
  const GmailScanResult({
    required this.account,
    required this.candidates,
    required this.scanned,
  });
  final GmailAccount account;
  final List<ParsedBill> candidates;
  final int scanned;
}

abstract interface class GmailScanClient {
  Future<GmailScanResult> scan({
    void Function(int done, int total)? onProgress,
    Future<List<ParsedBill>> Function(List<RawEmail>)? aiExtract,
    void Function(String message)? onAiFallback,
  });

  Future<void> disconnect();
}

/// Reads the user's Gmail entirely on-device (no backend), extracts upcoming
/// bills with [EmailParser], and returns them as candidates to confirm.
///
/// Requires a Google Cloud OAuth client configured for this app (see
/// `SETUP.md`). Everything runs on the phone; nothing is uploaded.
class GmailService implements GmailScanClient {
  GmailService({
    this.parser = const EmailParser(),
    this.aiExtractionTimeout = kAiOverallExtractionTimeout,
    http.Client? client,
    GmailAuthClient? auth,
  }) : _client = client ?? http.Client(),
       _auth = auth ?? GoogleGmailAuthClient();

  final EmailParser parser;
  final Duration aiExtractionTimeout;
  final http.Client _client;
  final GmailAuthClient _auth;

  static const scope = 'https://www.googleapis.com/auth/gmail.readonly';

  // Google **Web** OAuth client ID, tied to the committed debug keystore's
  // SHA-1 (see SETUP.md, Part C). Fixed because that SHA-1 never changes.
  static const webClientId =
      '45204952204-5102jul2h2ad87v3o5bbssv1cn2r8s1e.apps.googleusercontent.com';

  // Gmail search: recent, transactional mail only. Narrowed per Decision D13 —
  // phrase anchors ("payment reminder", "amount due") keep the observed real
  // Gas/Postpaid reminders while the noisiest broad terms (payment,
  // subscription, recharge) are dropped. The pre-AI prefilter below is the main
  // precision/cost lever, so the query stays fairly inclusive to protect recall.
  static const kGmailQueryTerms = <String>[
    '"payment reminder"',
    '"amount due"',
    'due',
    'premium',
    'invoice',
    'bill',
    'emi',
    'statement',
    'renewal',
    'policy',
  ];

  static const int kGmailLookbackMonths = 1;

  /// The composed Gmail search query. Public so it is unit-testable (D13).
  static final String searchQuery =
      'newer_than:${kGmailLookbackMonths}m (${kGmailQueryTerms.join(' OR ')})';

  // Sender fragments that are almost never bills — job boards, newsletters,
  // investment / mutual-fund (SIP) confirmations, and social. Dropped pre-AI
  // unless the sender is a known biller (Decision D13). Ambiguous common words
  // are anchored with `.com` to avoid matching legitimate biller domains.
  static const kNonBillSenderFragments = <String>[
    // Job boards
    'naukri',
    'linkedin',
    'indeed.com',
    'monster.com',
    'shine.com',
    'glassdoor',
    'instahyre',
    // Newsletters / content platforms
    'newsletter',
    'digest',
    'substack',
    'medium.com',
    'mailchimp',
    'alphasignal',
    // Investment / mutual-fund / SIP confirmations
    'cams', 'kfintech', 'mfcentral', 'zerodha', 'groww', 'kuvera', 'indmoney',
    // Social
    'facebook', 'twitter', 'instagram', 'quora', 'pinterest', 'reddit',
  ];

  // Bill-signal keywords that keep an *unknown* sender's mail in the pre-AI set.
  static const kPrefilterBillSignals = <String>[
    'payment reminder',
    'amount due',
    'due date',
    'bill',
    'invoice',
    'premium',
    'emi',
    'statement',
    'outstanding',
    'payable',
    'e-mandate',
    'autopay',
    'auto-debit',
    'last date to pay',
    'upcoming payment',
    'standing instruction',
    'renewal',
    'membership',
    'subscription',
    'charge',
  ];

  /// Pure, testable pre-AI prefilter (Decision D13): decide whether an email is
  /// worth sending to the (paid) AI classifier. Keeps every known biller and any
  /// unknown sender carrying a real bill signal; drops obvious non-bill senders
  /// (job alerts, newsletters, SIP confirmations) so they never cost a token.
  static bool isLikelyBillEmail(RawEmail e) {
    final domain = e.fromDomain;
    final from = e.from.toLowerCase();

    if (EmailParser.isCompletedOrInformationalSubject(e.subject)) return false;

    // Obvious non-bill sender → drop before considering bill-like copy.
    if (kNonBillSenderFragments.any(
      (f) => domain.contains(f) || from.contains(f),
    )) {
      return false;
    }

    // Body footers contain broad words such as "bill", "statement", and
    // "insurance". Gate on subject/snippet so newsletters and legal notices do
    // not become AI candidates merely because of footer text.
    final summary = '${e.subject}\n${e.snippet}'.toLowerCase();
    return kPrefilterBillSignals.any(summary.contains);
  }

  /// Runs the full flow: sign in → authorize → fetch → parse.
  ///
  /// When [aiExtract] is supplied (the user configured an AI key), it is used to
  /// extract bills; if it throws, we fall back to the on-device rule parser.
  @override
  Future<GmailScanResult> scan({
    void Function(int done, int total)? onProgress,
    Future<List<ParsedBill>> Function(List<RawEmail>)? aiExtract,
    void Function(String message)? onAiFallback,
  }) async {
    if (!_auth.supportsAuthenticate()) {
      throw const GmailScanException(
        GmailFailure.unsupported,
        'Gmail sign-in isn\'t available on this device.',
      );
    }

    final GmailAuthAccount account;
    try {
      account =
          await _auth.restore() ??
          await _auth.authenticate(scopeHint: const [scope]);
    } on GoogleSignInException catch (e) {
      final cancelled = e.code == GoogleSignInExceptionCode.canceled;
      throw GmailScanException(
        cancelled ? GmailFailure.cancelled : GmailFailure.notConfigured,
        cancelled
            ? 'Sign-in was cancelled.'
            : 'Google sign-in failed: ${e.description ?? e.code.name}.',
      );
    } catch (e) {
      throw GmailScanException(
        GmailFailure.notConfigured,
        'Google Sign-In could not initialize. Check the OAuth setup in SETUP.md. ($e)',
      );
    }

    final headers =
        await account.authorizationHeaders(const [
          scope,
        ], promptIfNecessary: false) ??
        await account.authorizationHeaders(const [
          scope,
        ], promptIfNecessary: true);
    if (headers == null) {
      throw const GmailScanException(
        GmailFailure.cancelled,
        'Gmail read permission was not granted.',
      );
    }

    try {
      final ids = await _listMessageIds(headers);
      final total = ids.length;
      final emails = <RawEmail>[];
      // Fetch message bodies in parallel batches — far faster than serial.
      const batchSize = 8;
      var done = 0;
      for (var start = 0; start < ids.length; start += batchSize) {
        final batch = ids.skip(start).take(batchSize);
        final results = await Future.wait(
          batch.map((id) => _getMessage(headers, id)),
        );
        for (final r in results) {
          if (r != null) emails.add(r);
        }
        done += results.length;
        onProgress?.call(done, total);
      }
      final candidates = await extractCandidates(
        emails,
        aiExtract: aiExtract,
        onAiFallback: onAiFallback,
      );
      return GmailScanResult(
        account: GmailAccount(email: account.email, name: account.name),
        candidates: candidates,
        scanned: emails.length,
      );
    } on GmailScanException {
      rethrow;
    } catch (e) {
      throw GmailScanException(
        GmailFailure.network,
        'Could not read Gmail: $e',
      );
    }
  }

  /// Post-fetch extraction pipeline, split out so the pre-AI prefilter and AI
  /// gating are unit-testable without any network/device.
  ///
  /// Applies the [isLikelyBillEmail] prefilter (Decision D13) so obvious
  /// non-bill senders never reach the (paid) AI, then extracts with [aiExtract]
  /// — recovering amounts the AI missed via the rule backstop — falling back to
  /// the on-device rule parser if the AI is absent or throws.
  Future<List<ParsedBill>> extractCandidates(
    List<RawEmail> emails, {
    Future<List<ParsedBill>> Function(List<RawEmail>)? aiExtract,
    void Function(String message)? onAiFallback,
  }) async {
    final likely = emails.where(isLikelyBillEmail).toList();
    if (aiExtract != null) {
      try {
        final ai = await aiExtract(likely).timeout(
          aiExtractionTimeout,
          onTimeout: () => throw TimeoutException(
            'AI extraction timed out after '
            '${aiExtractionTimeout.inSeconds} seconds.',
          ),
        );
        // Recover amounts the AI missed via the rule-based backstop.
        return _dedupeCandidates(_recoverAmounts(ai, likely));
      } catch (e) {
        // AI failed (bad key, quota, offline) — fall back to on-device rules,
        // but tell the caller why so the user isn't left guessing.
        onAiFallback?.call(e.toString());
        return parser.parseAll(likely);
      }
    }
    return parser.parseAll(likely);
  }

  @override
  Future<void> disconnect() async {
    try {
      await _auth.disconnect();
    } catch (_) {}
  }

  /// Backstop for AI candidates that came back without an amount: try to recover
  /// it from the source email with the rule-based extractor. Bills that still
  /// have no amount are kept (the user sets the amount in review) rather than
  /// silently dropped.
  List<ParsedBill> _recoverAmounts(
    List<ParsedBill> candidates,
    List<RawEmail> emails,
  ) {
    final byId = {for (final e in emails) e.id: e};
    return candidates.map((b) {
      if (b.amount >= 1) return b;
      final e = byId[b.sourceId];
      final amt = e == null ? null : parser.extractAmount(e.haystack);
      return (amt != null && amt >= 1) ? b.copyWith(amount: amt) : b;
    }).toList();
  }

  List<ParsedBill> _dedupeCandidates(List<ParsedBill> candidates) {
    final byKey = <String, ParsedBill>{};
    for (final candidate in candidates) {
      final existing = byKey[candidate.dedupeKey];
      if (existing == null || candidate.confidence > existing.confidence) {
        byKey[candidate.dedupeKey] = candidate;
      }
    }
    return byKey.values.toList();
  }

  Future<List<String>> _listMessageIds(Map<String, String> headers) async {
    final ids = <String>[];
    String? pageToken;
    do {
      final uri = Uri.https(
        'gmail.googleapis.com',
        '/gmail/v1/users/me/messages',
        {'q': searchQuery, 'maxResults': '500', 'pageToken': ?pageToken},
      );
      final res = await _client.get(uri, headers: headers);
      if (res.statusCode != 200) {
        throw GmailScanException(
          GmailFailure.network,
          'Gmail list failed (${res.statusCode}).',
        );
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final messages = (body['messages'] as List?) ?? const [];
      ids.addAll(
        messages.map(
          (message) => (message as Map<String, dynamic>)['id'] as String,
        ),
      );
      pageToken = body['nextPageToken'] as String?;
    } while (pageToken != null && pageToken.isNotEmpty);
    return ids;
  }

  Future<RawEmail?> _getMessage(Map<String, String> headers, String id) async {
    final uri = Uri.https(
      'gmail.googleapis.com',
      '/gmail/v1/users/me/messages/$id',
      {'format': 'full'},
    );
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

  /// Walks the MIME tree for text and returns whichever of the plain-text and
  /// tag-stripped HTML parts carries more content. Some billers send a tiny
  /// text/plain stub ("view this email in a browser") while the real content —
  /// including the amount — lives only in the HTML part, so preferring plain
  /// unconditionally (as before) silently dropped the useful text.
  String _extractBody(Map<String, dynamic> payload) {
    final plain = _findPart(payload, 'text/plain') ?? '';
    final htmlRaw = _findPart(payload, 'text/html');
    final html = htmlRaw == null ? '' : _stripHtml(htmlRaw);
    return html.length > plain.length ? html : plain;
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
      return utf8.decode(
        base64Url.decode(base64Url.normalize(data)),
        allowMalformed: true,
      );
    } catch (_) {
      return '';
    }
  }

  String _stripHtml(String html) => html
      .replaceAll(
        RegExp(r'<(script|style)[^>]*>[\s\S]*?</\1>', caseSensitive: false),
        ' ',
      )
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAll(RegExp(r'&nbsp;', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
