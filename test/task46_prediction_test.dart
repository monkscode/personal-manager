// TASK-46 — offline prediction for the v6 `merchant` sanitising migration.
//
// Predicts the sweep against a real device export *before* the migration is
// allowed to write anything, per the TASK-43/44/45 precedent. This one matters
// more than those three did: they were read-time changes that wrote nothing and
// were verified byte-identical, whereas v6 rewrites a stored column.
//
// It answers the question §3a of the design leaves open — what the sanitising
// sweep does to the identity chain:
//
//   transactions.merchant
//     -> SmsLiveNormalizer.enrich  (substitutes a body-derived name only when
//        the stored merchant is missing or *opaque*)
//     -> _ownerNorm = merchant ?? upiVpaNorm ?? sender
//     -> recurring grouping key + commitment.merchantNorm
//     -> ownerKey 'commitment:<merchantNorm>'
//     -> forecast_risk_decisions.owner_key, which TASK-40's Undo matches on
//
// The direction of that effect is genuinely uncertain. Nulling a junk merchant
// lets `enrich` substitute the good body-derived name, which is TASK-39's win;
// it can equally collapse several rows onto one `sender` key and mint a
// commitment that does not exist today. Hence: measure, then choose the rule.
//
// Runs the production path — load -> normalize -> reduce — because `enrich` and
// the TASK-43 suppression both live in `normalize`, and a prediction that skips
// them is not predicting what the app does.
//
// USAGE
//   1. Pull the device database to `.private/transactions.db` (gitignored —
//      this repository is public and the export is real SMS data).
//   2. flutter test test/task46_prediction_test.dart
//   3. Delete the export when done.
//
// Opens the export READ-ONLY and with no version, so no migration can fire and
// mutate the very file being measured.
//
// Skips silently when no export is present, so the suite stays green.
import 'dart:io';

import 'package:expense_insight/data/forecast_risk_decision_store.dart';
import 'package:expense_insight/data/obligation_repository.dart';
import 'package:expense_insight/data/sms_analysis_snapshot.dart';
import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/data/transaction_repository.dart';
import 'package:expense_insight/services/payee_text.dart';
import 'package:expense_insight/services/sms_live_normalizer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Values that look like an identifier but are public, so counting them as a
/// leak inflates the severity. TASK-45's first pass reported 393 rows; 157 held
/// nothing but the bank helpline, and the honest figure was 236.
const _publicValues = <String>['18605005555', '18004253800', '18001030'];

/// A digit run or masked tail the redactor would have removed from a body.
/// Deliberately a copy of `PayeeText`'s rule rather than a call into it: this
/// measures what is *there*, and must not silently agree with the code it is
/// auditing.
final _identifier = RegExp(
  r'(?<![a-z0-9])\d{4,}(?![a-z0-9])'
  r'|(?<![a-z])[*x]{2,}\d{2,}\b',
  caseSensitive: false,
);

bool _leaks(String? merchant) {
  if (merchant == null) return false;
  var value = merchant.toLowerCase();
  for (final public in _publicValues) {
    value = value.replaceAll(public, ' ');
  }
  return _identifier.hasMatch(value);
}

/// Rebuilds [t] with [merchant]. `copyWith` cannot express this: its
/// `merchant ?? this.merchant` means it can never *clear* a merchant, which is
/// the case this whole prediction is about.
ParsedTxn _withMerchant(ParsedTxn t, String? merchant) => ParsedTxn(
  smsId: t.smsId,
  sender: t.sender,
  direction: t.direction,
  instrument: t.instrument,
  type: t.type,
  amountPaise: t.amountPaise,
  txnDate: t.txnDate,
  payeeType: t.payeeType,
  categoryKey: t.categoryKey,
  confidence: t.confidence,
  reviewStatus: t.reviewStatus,
  source: t.source,
  coverageBucket: t.coverageBucket,
  rawBodyRedacted: t.rawBodyRedacted,
  bodyHash: t.bodyHash,
  scanBatchId: t.scanBatchId,
  effectiveMonth: t.effectiveMonth,
  accountLast4: t.accountLast4,
  merchant: merchant,
  upiVpaNorm: t.upiVpaNorm,
  reviewReason: t.reviewReason,
  autoAddedAt: t.autoAddedAt,
  collisionSetId: t.collisionSetId,
  refNumber: t.refNumber,
  balancePaise: t.balancePaise,
  ownerKey: t.ownerKey,
  supersededBySmsId: t.supersededBySmsId,
);

void main() {
  // Absolute, deliberately. `sqflite_common_ffi` resolves a *relative* path
  // against its own `.dart_tool/sqflite_common_ffi/databases/` directory, not
  // the working directory — so a relative path would silently look somewhere
  // other than where the export was pulled to, and openDatabase would create an
  // empty database there rather than failing.
  final exportPath = File(
    Platform.environment['TASK46_DB'] ?? '.private/transactions.db',
  ).absolute.path;

  test('TASK-46 — predict the v6 merchant sweep against a device export', () async {
    if (!File(exportPath).existsSync()) {
      markTestSkipped(
        'No device export at $exportPath — see the header of this file. '
        'Skipping so the suite stays green.',
      );
      return;
    }

    sqfliteFfiInit();
    // Read-only and version-less: opening with a version would run onUpgrade
    // and mutate the export this test exists to measure.
    final db = await databaseFactoryFfi.openDatabase(
      exportPath,
      options: OpenDatabaseOptions(readOnly: true),
    );
    addTearDown(db.close);

    final before = await TransactionRepository(db).allSince(DateTime(2000));
    final obligations = await ObligationRepository(db).allActive();
    final riskDecisions = await ForecastRiskDecisionStore(db).all();

    expect(before, isNotEmpty, reason: 'export holds no transactions');

    // Deterministic clock: the newest stored transaction, not DateTime.now(),
    // so two runs of this prediction agree with each other.
    final now = before
        .map((t) => t.txnDate)
        .reduce((a, b) => a.isAfter(b) ? a : b);

    // ---- the sweep itself ---------------------------------------------------
    final after = <ParsedTxn>[];
    final changed = <(String before, String? after)>[];
    var nulled = 0;
    for (final t in before) {
      final original = t.merchant;
      if (original == null) {
        after.add(t);
        continue;
      }
      final sanitized = PayeeText.sanitize(original);
      if (sanitized == original) {
        after.add(t);
        continue;
      }
      if (sanitized == null) nulled++;
      changed.add((original, sanitized));
      after.add(_withMerchant(t, sanitized));
    }

    final leakedBefore = before.where((t) => _leaks(t.merchant)).length;
    final leakedAfter = after.where((t) => _leaks(t.merchant)).length;

    // ---- run the real pipeline both ways ------------------------------------
    const normalizer = SmsLiveNormalizer();
    SmsAnalysisSnapshot run(List<ParsedTxn> history) =>
        SmsAnalysisSnapshot.reduce(
          history: normalizer.normalize(history),
          obligations: obligations,
          riskDecisions: riskDecisions,
          configuredPlans: const [],
          now: now,
        );

    final snapBefore = run(before);
    final snapAfter = run(after);

    final commitsBefore = {for (final c in snapBefore.commitments) c.merchantNorm};
    final commitsAfter = {for (final c in snapAfter.commitments) c.merchantNorm};
    final ownerBefore = {for (final n in commitsBefore) 'commitment:$n'};
    final ownerAfter = {for (final n in commitsAfter) 'commitment:$n'};

    // A stored decision whose ownerKey no longer exists renders nothing — the
    // user's confirmation silently disappears. This is the number that decides
    // whether the null rule is safe.
    final decisionKeys = {for (final d in riskDecisions) d.ownerKey};
    final orphanedNow = decisionKeys.difference(ownerBefore);
    final orphanedAfter = decisionKeys.difference(ownerAfter);
    final newlyOrphaned = orphanedAfter.difference(orphanedNow);

    // ---- report -------------------------------------------------------------
    final out = StringBuffer()
      ..writeln('\n=== TASK-46 prediction — $exportPath ===')
      ..writeln('rows                       ${before.length}')
      ..writeln('merchants changed          ${changed.length}')
      ..writeln('  of which cleared to NULL $nulled')
      ..writeln('rows leaking an identifier $leakedBefore -> $leakedAfter')
      ..writeln('commitments                ${commitsBefore.length} -> ${commitsAfter.length}')
      ..writeln('  disappeared              ${commitsBefore.difference(commitsAfter)}')
      ..writeln('  newly minted             ${commitsAfter.difference(commitsBefore)}')
      ..writeln('stored risk decisions      ${decisionKeys.length}')
      ..writeln('  already orphaned         ${orphanedNow.length}')
      ..writeln('  NEWLY orphaned by v6     ${newlyOrphaned.length}  $newlyOrphaned')
      ..writeln('\n--- every changed merchant ---');
    for (final (was, now_) in changed) {
      out.writeln('  "$was"  ->  ${now_ == null ? 'NULL' : '"$now_"'}');
    }
    // ignore: avoid_print
    print(out);

    // ---- the gates ----------------------------------------------------------
    // The sweep must actually close the leak.
    expect(leakedAfter, 0, reason: 'the sweep left an identifier behind');

    // The two §3a gates. A failure here is not a bug in this test — it is the
    // measurement saying the null rule needs redesigning before v6 ships.
    expect(
      commitsAfter.difference(commitsBefore),
      isEmpty,
      reason: 'the sweep minted a commitment that does not exist today (§3a.1)',
    );
    expect(
      newlyOrphaned,
      isEmpty,
      reason: "the sweep orphans a user's stored risk decision (§3a.2)",
    );
  });
}
