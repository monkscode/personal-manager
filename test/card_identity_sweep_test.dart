// Spec A Part 2 — the corpus sweep for the widened card-identity regex.
//
// TASK-43/44/45 all established the same precedent: predict what a rule change
// does to every body you have before you put the build on a phone. TASK-45's
// offline pass is the argument for it — it caught a `\d{4,}` that mangled the
// real UPI handle `priyalpatel1910`, which no amount of reading would have.
//
// The spec's own figure did not survive being checked: it claimed "the 332 SMS
// bodies in `test/golden/*.json`", and the golden corpus holds **38**. So this
// measures the real universe rather than inheriting a number — the same failure
// mode as the r2 revision's seventh table row, which existed nowhere in the
// repo.
//
// The universe is every labelled golden body plus every amount-bearing string
// literal under `test/`. That is what this repository actually holds; it is not
// a device export, and it cannot be — `raw_body_redacted` has already had its
// card tails removed by `SmsPrivacy._account`, so a stored body can never
// answer what the parser reads from a live one.
//
// The old and new patterns are copied here on purpose rather than reached for
// in the parser. A measurement that imports the code it is auditing agrees with
// that code by construction, which is the one thing it must not do.
import 'dart:convert';
import 'dart:io';

import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/services/sms_transaction_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// `_account` and `_cardEnding` as they stood before Spec A Part 2.
final _oldAccount = RegExp(
  r'\b(?:a/c|ac|acct|account|ending)\s*(?:no\.?\s*)?[*xX]*(\d{4})\b',
  caseSensitive: false,
);
final _oldCardEnding = RegExp(r'\bcard\s+ending\s+(\d{4})\b', caseSensitive: false);

/// `_account` after it, with `card` in the keyword set and `with` allowed to
/// sit between the keyword and the digits.
final _newAccount = RegExp(
  r'\b(?:a/c|ac|acct|account|card|ending)\s*(?:no\.?\s*|with\s+)?[*xX]*(\d{4})\b',
  caseSensitive: false,
);

/// `SmsTransactionParser._cardMarker`, copied for the same reason. This is what
/// decides whether a row is a card row, and the claim under test is that only
/// card rows move.
final _cardMarker = RegExp(
  r'\bcredit card\b|\bcard ending\b|\bbank card\b|\bcard\s+[*x]*\d{4}\b'
  r'|\bavailable credit\b|\bavailable limit\b|\bavl lmt\b|\bcredit limit\b'
  r'|\bcard limit\b',
);

final _amount = RegExp(
  r'(?:₹|\b(?:rs\.?|inr))\s*[0-9][0-9,]*(?:\.[0-9]+)?',
  caseSensitive: false,
);

String? _oldLast4(String body) =>
    _oldAccount.firstMatch(body)?.group(1) ??
    _oldCardEnding.firstMatch(body)?.group(1);

String? _newLast4(String body) => _newAccount.firstMatch(body)?.group(1);

/// Single- and double-quoted Dart literals, with adjacent literals joined the
/// way the compiler joins them (`'a' 'b'` is one string). Multi-line and raw
/// strings are not read; the corpus is reported as what it is rather than
/// claimed to be exhaustive.
final _literal = RegExp("'((?:[^'\\\\\\n]|\\\\.)*)'" r'|"((?:[^"\\\n]|\\.)*)"');
final _gap = RegExp(r'\s*');

List<String> _literalsIn(String source) {
  final out = <String>[];
  var cursor = 0;
  while (cursor < source.length) {
    final match = _literal.firstMatch(source.substring(cursor));
    if (match == null) break;
    final start = cursor + match.start;
    var end = cursor + match.end;
    final parts = <String>[match.group(1) ?? match.group(2) ?? ''];
    while (true) {
      final gap = _gap.matchAsPrefix(source, end);
      final next = _literal.matchAsPrefix(source, gap?.end ?? end);
      if (next == null) break;
      parts.add(next.group(1) ?? next.group(2) ?? '');
      end = next.end;
    }
    out.add(parts.join());
    cursor = end > start ? end : start + 1;
  }
  return out;
}

/// Body -> where it came from, deduplicated.
Map<String, String> _universe() {
  final universe = <String, String>{};
  for (final file in Directory('test/golden').listSync().whereType<File>()) {
    for (final sample in jsonDecode(file.readAsStringSync()) as List) {
      final body = (sample as Map)['body'] as String?;
      if (body != null) {
        universe.putIfAbsent(body, () => 'golden/${file.uri.pathSegments.last}');
      }
    }
  }
  for (final file
      in Directory('test').listSync(recursive: true).whereType<File>()) {
    if (!file.path.endsWith('.dart')) continue;
    for (final literal in _literalsIn(file.readAsStringSync())) {
      if (_amount.hasMatch(literal)) {
        universe.putIfAbsent(literal, () => file.path);
      }
    }
  }
  return universe;
}

void main() {
  const parser = SmsTransactionParser();
  final universe = _universe();

  ParsedTxn? parse(String body, String sender) => parser.parseOne(
    RawSms(sender: sender, body: body, receivedAt: DateTime(2026, 8, 1)),
    scanBatchId: 'sweep',
    bodyHashSalt: 'sweep',
  );

  test('the corpus is large enough for the sweep to mean anything', () {
    // A guard, not a headline. Every gate below is vacuously true over an empty
    // universe, and a scraper that silently stopped matching would report a
    // clean sweep.
    expect(universe.length, greaterThan(200));
  });

  test('only card rows move, and no row loses a tail it already had', () {
    final changed = <String>[];
    final overwritten = <String>[];
    final lost = <String>[];
    final notACardRow = <String>[];

    for (final body in universe.keys) {
      final before = _oldLast4(body);
      final after = _newLast4(body);
      if (before == after) continue;
      changed.add(body);
      if (after == null) lost.add(body);
      if (before != null && after != null) {
        overwritten.add(body);
        // An overwrite is only defensible on a row the app files under a card.
        // "Payment of Rs.45,000 towards your HDFC Credit Card ending with 7110
        // debited from A/c XX1234" used to read **1234** — the bank account —
        // and `_cardEstimates` then opened a card bucket named after a bank
        // account. Reading 7110 files it under the card that was actually paid.
        // On a bank row the same flip would move a real account tail, which
        // dedupe, collision sets and normalizer grouping all key on.
        if (parse(body, 'VM-HDFCBK')?.instrument != PaymentInstrument.card) {
          notACardRow.add(body);
        }
      }
      if (!_cardMarker.hasMatch(body.toLowerCase())) notACardRow.add(body);
    }

    // ignore: avoid_print
    print(
      '\n=== Spec A Part 2 — card identity sweep ===\n'
      'bodies            ${universe.length}\n'
      'last-4 changed    ${changed.length}\n'
      'unchanged         ${universe.length - changed.length}\n'
      'lost a tail       ${lost.length}\n'
      'tail overwritten  ${overwritten.length}  (all on card rows)\n'
      'non-card rows hit ${notACardRow.length}\n'
      '${overwritten.map((b) => '  overwrote: $b\n').join()}',
    );

    expect(lost, isEmpty, reason: 'the widening dropped a tail it used to read');
    expect(
      notACardRow,
      isEmpty,
      reason: 'a body with no card marker gained a card tail, or a bank row had '
          'its account tail replaced — dedupe, collision sets and normalizer '
          'grouping all key on this field, so that is not a cosmetic change',
    );
    expect(changed, isNotEmpty, reason: 'the sweep measured nothing at all');
  });

  test('the shipped parser reads exactly what the sweep predicted', () {
    // Closes the loop the copied patterns above open. If the parser and the
    // measurement ever disagree, the sweep is auditing something that is not
    // shipping.
    for (final body in universe.keys) {
      for (final sender in ['VM-HDFCBK', 'AD-762211']) {
        final txn = parse(body, sender);
        if (txn == null) continue;
        expect(
          txn.accountLast4,
          _newLast4(body),
          reason: 'parser and sweep disagree on: $body',
        );
      }
    }
  });

  test('the admission floor moves only for senders with no bank in the name', () {
    // The measured consequence of fact 13. Every body that crosses `signals < 2`
    // because its card tail became readable is a card row, and none of them
    // crosses it when the sender already carries a bank fragment.
    var newlyAdmittedUnknownSender = 0;
    for (final body in universe.keys) {
      final known = parse(body, 'VM-HDFCBK');
      final unknown = parse(body, 'AD-762211');
      if (unknown == null) continue;
      // A row the unknown sender admits whose only second signal is the tail.
      if (unknown.accountLast4 != null &&
          _oldLast4(body) == null &&
          unknown.balancePaise == null &&
          unknown.refNumber == null) {
        newlyAdmittedUnknownSender++;
        expect(
          unknown.instrument,
          PaymentInstrument.card,
          reason: 'a non-card row crossed the admission floor: $body',
        );
        expect(
          known,
          isNotNull,
          reason: 'a known-bank sender would have admitted this row anyway',
        );
      }
    }
    expect(newlyAdmittedUnknownSender, greaterThan(0));
  });
}
