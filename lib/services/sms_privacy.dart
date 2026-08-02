import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../data/sms_models.dart';

class SmsPrivacy {
  const SmsPrivacy._();

  /// Currency-tagged money. `rs` and `inr` carry a leading word boundary: the
  /// `hrs.` in "valid for 24 hrs. 5000 points" would otherwise supply the
  /// currency token, and the redactor would eat the tail of the word and leave
  /// `24 h[amount]` in the body a human reviews. `₹` is punctuation and needs
  /// no boundary. Kept in step with `SmsTransactionParser._amount`.
  static final RegExp _amount = RegExp(
    r'(?:₹|\b(?:rs\.?|inr))\s*[0-9][0-9,]*(?:\.[0-9]+)?',
    caseSensitive: false,
  );

  /// Card and account tails. Each branch captures the leading noun so only the
  /// identifying digits are consumed — `HDFC Credit Card ending 4321` becomes
  /// `HDFC Credit Card ending [account]`, which keeps the review screen
  /// readable while removing the tail.
  static final RegExp _account = RegExp(
    // "Card ending 1234" / "A/c ending 4321"
    r'\b((?:card|a/c|ac|acct|account)\s+ending\s+)[*xX]*\d{2,}'
    // "A/c XX1234" / "account no. 1234" / "Card x1111" / "Card 5555"
    r'|\b((?:card|a/c|ac|acct|account)\s*(?:no\.?\s*)?)[*xX]*\d{2,}'
    // Standalone masked tail like "XX1234" / "**1234" / "x1111"
    r'|()(?<![A-Za-z0-9])[*xX]+\d{2,4}\b',
    caseSensitive: false,
  );

  /// Balances and bare transaction amounts written without a currency token.
  /// Anchored to the surrounding keyword rather than to `₹|rs|inr`, because
  /// running balances are routinely printed as bare numbers.
  static final RegExp _balance = RegExp(
    r'\b((?:avl|available|closing|current)?\s*bal(?:ance)?\s*[:\-]?\s*)'
    r'(?:₹|rs\.?|inr)?\s*\d[\d,]*(?:\.\d+)?'
    r'|\b((?:debited|credited)\s+(?:by|with)\s+)'
    r'(?:₹|rs\.?|inr)?\s*\d[\d,]*(?:\.\d+)?'
    r'|\b((?:available\s+)?limit\s*[:\-]?\s*)'
    r'(?:₹|rs\.?|inr)?\s*\d[\d,]*(?:\.\d+)?',
    caseSensitive: false,
  );

  /// Whatever numeric text survived the labelled passes above.
  ///
  /// A privacy floor cannot depend on having enumerated every bank's phrasing,
  /// so this is default-deny: any money-shaped token or run of four or more
  /// digits still present — an unrecognised balance, an OTP, a helpline number,
  /// an account number with no keyword near it — is removed. The labelled
  /// patterns run first so the common cases keep their `[amount]`/`[account]`
  /// context; this only catches the rest.
  static final RegExp _residualNumber = RegExp(r'\d[\d,]*\.\d{1,2}\b|\d{4,}');
  static final RegExp _reference = RegExp(
    r'\b(?:upi\s*)?(?:ref(?:erence)?|rrn|txn(?:\s*id)?|transaction\s*id)\s*[:#-]?\s*[A-Za-z0-9]{6,}',
    caseSensitive: false,
  );
  static final RegExp _vpa = RegExp(
    r'\b[A-Za-z0-9._-]+@[A-Za-z][A-Za-z0-9._-]+\b',
  );

  static String redactBody(String body) {
    return body
        .replaceAll(_reference, '[ref]')
        .replaceAll(_vpa, '[vpa]')
        .replaceAllMapped(_account, (m) => '${_keptPrefix(m)}[account]')
        .replaceAllMapped(_balance, (m) => '${_keptPrefix(m)}[amount]')
        .replaceAll(_amount, '[amount]')
        .replaceAll(_residualNumber, '[number]');
  }

  /// The noun captured by whichever branch of an alternation matched, so the
  /// replacement removes only the digits.
  static String _keptPrefix(Match match) {
    for (var group = 1; group <= match.groupCount; group++) {
      final value = match.group(group);
      if (value != null) return value;
    }
    return '';
  }

  static String bodyHash(String body, {required String salt}) =>
      _sha256Hex('$salt|${_normalize(body)}');

  static String stableSmsId(RawSms sms, {required String salt}) {
    final providerId = sms.providerId?.trim();
    if (providerId != null && providerId.isNotEmpty) {
      return 'provider:$providerId';
    }

    // Salted with the same per-install secret as [bodyHash]. The row this id
    // lands on stores `sender` and `txn_date` in plaintext, so an unsalted
    // digest over (sender|timestamp|body) lets anyone holding the database
    // brute-force the redacted body back out of a template — which would
    // defeat the salted body hash. The salt is per-install and stable, which
    // is all dedupe needs.
    final identity = [
      salt,
      sms.sender.trim().toLowerCase(),
      sms.receivedAt.millisecondsSinceEpoch.toString(),
      _normalize(sms.body),
    ].join('|');
    return 'synthetic:${_sha256Hex(identity)}';
  }

  static String _normalize(String text) {
    return text.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  static String _sha256Hex(String text) {
    return sha256.convert(utf8.encode(text)).toString();
  }
}
