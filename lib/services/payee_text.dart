import 'sms_privacy.dart';

/// What disqualifies a captured string from being a payee (TASK-45).
///
/// The capture patterns in `SmsTransactionParser` and `MerchantDisplay` each
/// have terminators, and a terminator is not the same thing as knowing what a
/// payee *is*. A pattern can stop in exactly the right place and still return
/// the bank's own noun phrase (`your ICICI Bank Credit Card XX7117`), a rail
/// string carrying a transaction reference (`ECS/RAZORPAY SOFTW/1111202...`),
/// or the whole dispute footer that follows the name on a single-line body.
///
/// Both readers funnel every capture through this one object rather than
/// restating the rule in each pattern's terminator list — TASK-41's lesson,
/// that a predicate applied at call sites is not a rule. They differ only in
/// vocabulary: the parser sees raw digits, the display sees the redaction
/// tokens standing where those digits were, and [SmsPrivacy.placeholderPattern]
/// is the single definition of the latter.
///
/// Referenced by: `sms_transaction_parser.dart`, `merchant_display.dart`.
/// Depends on: `sms_privacy.dart`.
class PayeeText {
  const PayeeText._();

  /// Where the payee ends and the bank's boilerplate begins.
  ///
  /// A sentence end counts, but only when a space follows it: `google asia
  /// pacific pte.ltd` is one real payee (TASK-42) and must not be cut at its
  /// internal period.
  static final RegExp _footer = RegExp(
    r'\.\s'
    r'|\bcall\b'
    r'|\bif\s+not\s+you\b'
    r'|\bnot\s+you\b'
    r'|\bdispute\b'
    r'|\bhas\s+been\s+received\b'
    r'|\bif\s+you\s+have\s+not\b'
    r'|\bsms\s+block\b'
    r'|\bto\s+report\b'
    r'|\bavl\b|\bavbl\b|\bavailable\b',
    caseSensitive: false,
  );

  /// The user's own instrument, which is never an external payee. A payment
  /// *towards your own credit card* has no payee at all, and capturing the
  /// card carries its tail — which the redactor strips from the body — into a
  /// display column.
  static final RegExp _ownInstrument = RegExp(
    r'\b(?:credit|debit)\s+card\b'
    r'|\bcard\s+ending\b'
    r'|\baccount\s+ending\b'
    r'|^a/c\b'
    r'|\ba/c\s*[*x]*\d',
    caseSensitive: false,
  );

  /// A digit run the redactor would have removed from a body, or a masked
  /// tail. Four digits is the same threshold `SmsPrivacy` uses, so a name that
  /// survives here carries nothing the body would have hidden.
  ///
  /// The run must stand as its own field. A bank prints a reference in a slot
  /// of its own (`ECS/RAZORPAY SOFTW/111120218042703`), whereas digits glued
  /// to letters are part of the word — `samplepayee1910` is a UPI handle and
  /// `1mg` is a pharmacy, and neither survives a blunt `\d{4,}`.
  static final RegExp _identifier = RegExp(
    r'(?<![a-z0-9])\d{4,}(?![a-z0-9])'
    r'|(?<![a-z])[*x]{2,}\d{2,}\b',
    caseSensitive: false,
  );

  /// An address the redactor turns into `[vpa]` inside a body. One that
  /// reached a *stored* merchant instead never passed through it, and must not
  /// render as a payee name.
  static final RegExp _address = RegExp(
    r'[a-z0-9._*+-]+@[a-z][a-z0-9.-]*',
    caseSensitive: false,
  );

  static final RegExp _whitespaceRun = RegExp(r'\s+');
  static final RegExp _edgeJunk = RegExp(r'^[\s/*_,.+\-]+|[\s/*_,.+\-]+$');
  static final RegExp _hasLetters = RegExp(r'[a-z]{2,}', caseSensitive: false);

  /// Separators left stranded once what sat between them was removed —
  /// `rd//dhruvil` after the reference went. A *single* separator still joining
  /// two words is untouched, which is what keeps `ecs/razorpay softw`,
  /// `science city-ii` and `cash-atm` intact.
  static final RegExp _strandedSeparator = RegExp(r'(?:[/*_,+\-]\s*){2,}');

  /// A trailing noun that brackets a payee rather than naming one. The parser
  /// already stripped this before its own captures; keeping it here covers the
  /// display path too.
  static final RegExp _trailingNoun = RegExp(
    r'\s+(?:no|a/c|ac)\.?\s*$',
    caseSensitive: false,
  );

  /// Trims [raw] back to the payee, or returns null when nothing of a name is
  /// left. Pure; safe on both raw and redacted text.
  static String? sanitize(String raw) {
    // 1. Redaction tokens are never part of a name. Removing them rather than
    //    rejecting the whole capture keeps a payee that sits beside one —
    //    `ECS/RAZORPAY SOFTW/[number]` is still Razorpay.
    var value = raw.replaceAll(SmsPrivacy.placeholderPattern, ' ');

    // 2. Cut at the bank's boilerplate.
    final footer = _footer.firstMatch(value);
    if (footer != null) value = value.substring(0, footer.start);

    // 3. Reject the user's own instrument. Checked before separators are
    //    collapsed, because `a/c` is only recognisable while the slash is
    //    still there.
    if (_ownInstrument.hasMatch(value.trim())) return null;

    // 4. Drop identifiers and addresses, closing the gap rather than leaving a
    //    space. Rail and aggregator separators are deliberately left alone:
    //    each caller already collapses them, and `MerchantDisplay` strips a
    //    `RAZ*` prefix by matching the asterisk this used to eat.
    value = value
        .replaceAll(_identifier, '')
        .replaceAll(_address, '')
        .replaceAll(_strandedSeparator, ' ')
        .replaceAll(_whitespaceRun, ' ')
        .replaceAll(_trailingNoun, '')
        .replaceAll(_edgeJunk, '')
        .trim();

    // A name needs letters. This also rejects what step 4 reduced to
    // punctuation or a stray short number.
    if (!_hasLetters.hasMatch(value)) return null;

    return value;
  }
}
