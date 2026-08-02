import '../data/sms_models.dart';
import 'merchant_display.dart';
import 'sms_ingestion_policy.dart';

/// Cleans the **live** SMS transaction history just before it is reduced into
/// the analysis snapshot. Two jobs, both pure and both no-ops on already-clean
/// data (so unit-test fixtures are unaffected):
///
///  1. **Dedup** identical bank events that were delivered more than once —
///     the classic Indian-bank case where the same alert arrives under several
///     DLT sender headers (`VM-HDFCBK-S`, `AD-HDFCBK-S`, …). Rows collapse only
///     when something proves they name the same event, so genuine same-day
///     repeats survive: mutual-fund SIPs (different UPI ref/payee in the body)
///     and sequential ATM withdrawals (different balance/timestamp). Repeats
///     that nothing tells apart are **flagged, never dropped**.
///
///  2. **Enrich** the merchant + category the on-device parser left blank or
///     opaque, using [MerchantDisplay]. A *genuine* payee token is written
///     (never the bank-name fallback), giving recurring-detection a stable
///     owner key instead of the volatile DLT sender — the fix that lets monthly
///     commitments actually lock and populate the forecast.
class SmsLiveNormalizer {
  const SmsLiveNormalizer({this.display = const MerchantDisplay()});

  final MerchantDisplay display;

  /// Dedup, then enrich. Order matters: dedup first so enrichment does not run
  /// on rows that are about to be dropped.
  List<ParsedTxn> normalize(List<ParsedTxn> txns) {
    final deduped = dedup(txns);
    return [for (final t in deduped) enrich(t)];
  }

  /// The two passes in order: drop re-deliveries of one message, then flag
  /// what is left over as a collision rather than dropping it.
  ///
  /// The distinction matters and the passes are deliberately not merged.
  /// [collapseRedeliveries] removes *the same message* seen more than once —
  /// no money disappears, because there was only ever one payment.
  /// [flagCollisions] handles *two payments* that happen to look alike; those
  /// are surfaced, never collapsed, because collapsing one would delete real
  /// spend from the forecast.
  List<ParsedTxn> dedup(List<ParsedTxn> txns) =>
      flagCollisions(collapseRedeliveries(txns));

  /// Drop rows that are one bank event delivered more than once — the classic
  /// case where an alert arrives under several DLT sender headers.
  ///
  /// A row is only ever collapsed against another when something proves they
  /// describe the same event:
  ///
  ///  * an identical `smsId` — literally the same message, or
  ///  * an identical reference number, the reliable discriminator when the
  ///    bank supplies one, or
  ///  * a byte-identical body that is *self-identifying* (see
  ///    [_selfIdentifying]) — a UPI RRN or an intra-body timestamp.
  ///
  /// A row whose redacted body carries none of these proves nothing by matching
  /// another, so it survives this pass untouched and is left to
  /// [flagCollisions].
  List<ParsedTxn> collapseRedeliveries(List<ParsedTxn> txns) {
    final sorted = [...txns]..sort((a, b) {
      final byDate = a.txnDate.compareTo(b.txnDate);
      if (byDate != 0) return byDate;
      return a.smsId.compareTo(b.smsId);
    });
    final seenMessages = <String>{};
    final seenEvents = <String>{};
    final out = <ParsedTxn>[];
    for (final t in sorted) {
      if (!seenMessages.add(t.smsId)) continue;
      final event = _sameEventKey(t);
      if (event != null && !seenEvents.add(event)) continue;
      out.add(t);
    }
    return out;
  }

  /// Surface rows that share amount, direction, day and account and that
  /// nothing tells apart, as a collision set for the user to resolve.
  ///
  /// Two ₹100 payments to the same payee on the same day are ordinary, and
  /// their redacted bodies can be identical — `[amount] debited [account] Axis
  /// Bank` carries no distinguishing content at all. Dropping one would delete
  /// a real rupee, so both are kept and marked instead. The rows stay in the
  /// snapshot (only `dismissed` rows are excluded from the reduction), so the
  /// money is still counted while the ambiguity is visible.
  ///
  /// Rows the user has already confirmed or dismissed are left alone — that
  /// decision is theirs and must survive a reload.
  List<ParsedTxn> flagCollisions(List<ParsedTxn> txns) {
    final byTuple = <String, List<int>>{};
    for (var i = 0; i < txns.length; i++) {
      byTuple.putIfAbsent(_tuple(txns[i]), () => []).add(i);
    }

    final collided = <int>{};
    for (final members in byTuple.values) {
      if (members.length < 2) continue;
      for (var i = 0; i < members.length; i++) {
        for (var j = i + 1; j < members.length; j++) {
          if (_distinguishable(txns[members[i]], txns[members[j]])) continue;
          collided
            ..add(members[i])
            ..add(members[j]);
        }
      }
    }
    if (collided.isEmpty) return txns;

    return [
      for (var i = 0; i < txns.length; i++)
        if (collided.contains(i) && _undecided(txns[i]))
          txns[i].copyWith(
            reviewStatus: ReviewStatus.needsReview,
            reviewReason: ReviewReason.dedupCollision,
            collisionSetId: SmsIngestionPolicy.collisionSetIdFor(txns[i]),
            coverageBucket: CoverageBucket.reviewPending,
          )
        else
          txns[i],
    ];
  }

  bool _undecided(ParsedTxn t) =>
      t.reviewStatus != ReviewStatus.confirmed &&
      t.reviewStatus != ReviewStatus.dismissed;

  String _tuple(ParsedTxn t) => [
    t.amountPaise,
    t.direction.storageValue,
    t.txnLocalDate,
    t.accountLast4 ?? '',
  ].join('§');

  /// Whether anything separates two rows that share a tuple. A self-identifying
  /// row is distinguishable by construction: [collapseRedeliveries] has already
  /// merged any row carrying the *same* identifying token, so a survivor of
  /// that pass necessarily names a different event.
  bool _distinguishable(ParsedTxn a, ParsedTxn b) =>
      SmsIngestionPolicy.hasDistinguishingSignal(a, b) ||
      _sameEventKey(a) != null ||
      _sameEventKey(b) != null;

  /// A key naming the underlying bank event, or `null` when the row carries
  /// nothing that identifies one.
  String? _sameEventKey(ParsedTxn t) {
    final ref = t.refNumber?.trim();
    final String discriminator;
    if (ref != null && ref.isNotEmpty) {
      discriminator = 'ref§$ref';
    } else {
      final content = _content(t.rawBodyRedacted);
      if (!_selfIdentifying(content)) return null;
      discriminator = 'body§$content';
    }
    return [
      t.amountPaise,
      t.direction.storageValue,
      t.txnLocalDate,
      discriminator,
    ].join('§');
  }

  static final RegExp _label = RegExp(r'^\s*\[[^\]]*\]\s*\w+\s+\d+p\s*::\s*');
  static final RegExp _ws = RegExp(r'\s+');

  /// A redacted body that pins down one specific event: a clock time
  /// (`10:57:27`) or a long digit run such as a UPI RRN (`549148394747`).
  /// A bare calendar date is not enough — two payments on the same day share
  /// it, so it discriminates nothing.
  static final RegExp _identifyingToken = RegExp(r'\d{1,2}:\d{2}|\d{8,}');

  bool _selfIdentifying(String content) => _identifyingToken.hasMatch(content);

  String _content(String raw) =>
      raw.replaceFirst(_label, '').toLowerCase().trim().replaceAll(_ws, ' ');

  /// Fill a readable merchant/category for rows the parser left blank or
  /// opaque. Only writes a genuinely-resolved merchant (never the bank-name
  /// fallback) so unrelated bank debits are not merged into a false recurring
  /// group.
  ParsedTxn enrich(ParsedTxn t) {
    final display = this.display.resolve(t);
    final hasGoodMerchant = t.merchant != null &&
        t.merchant!.trim().isNotEmpty &&
        !_opaque(t.merchant!.trim());
    final merchant = (!hasGoodMerchant && display.merchantResolved)
        ? display.name.toLowerCase()
        : null;
    final category = (t.categoryKey.isEmpty || t.categoryKey == 'other') &&
            display.categoryKey != 'other'
        ? display.categoryKey
        : null;
    if (merchant == null && category == null) return t;
    return t.copyWith(merchant: merchant, categoryKey: category);
  }

  bool _opaque(String s) {
    final compact = s.replaceAll(' ', '');
    if (compact.length >= 12 &&
        RegExp(r'^[0-9a-f]+$', caseSensitive: false).hasMatch(compact)) {
      return true;
    }
    return RegExp(r'^\d{6,}$').hasMatch(compact);
  }
}
