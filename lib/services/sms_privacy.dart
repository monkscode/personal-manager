import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../data/sms_models.dart';

class SmsPrivacy {
  const SmsPrivacy._();

  static final RegExp _amount = RegExp(
    r'(?:₹|rs\.?|inr)\s*[0-9][0-9,]*(?:\.[0-9]+)?',
    caseSensitive: false,
  );
  static final RegExp _account = RegExp(
    // "Card ending 1234" / "A/c ending 4321"
    r'\b(?:card|a/c|ac|acct|account)\s+ending\s+\d{2,}'
    // "A/c XX1234" / "account no. 1234"
    r'|\b(?:a/c|ac|acct|account)\s*(?:no\.?\s*)?[*xX]*\d{2,}'
    // Standalone masked tail like "XX1234" / "**1234"
    r'|(?<![A-Za-z0-9])[*xX]{2,}\d{2,4}\b',
    caseSensitive: false,
  );
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
        .replaceAll(_account, '[account]')
        .replaceAll(_amount, '[amount]');
  }

  static String bodyHash(String body, {required String salt}) =>
      _sha256Hex('$salt|${_normalize(body)}');

  static String stableSmsId(RawSms sms) {
    final providerId = sms.providerId?.trim();
    if (providerId != null && providerId.isNotEmpty) {
      return 'provider:$providerId';
    }

    final identity = [
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
