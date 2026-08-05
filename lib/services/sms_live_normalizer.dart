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
    // Enrich before marking: the re-delivery rule joins on the payee name, and
    // enrichment is what fills a payee the on-device parser left blank.
    final enriched = [for (final t in deduped) enrich(t)];
    return markSupersededRedeliveries(enriched);
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

  /// Mark the later of two alerts that report **one** bank debit, so the rupee
  /// is counted once (TASK-43).
  ///
  /// [collapseRedeliveries] handles the case where the *same message* arrives
  /// twice. This handles the harder one: two different messages, from two
  /// systems inside one bank, about one event — on the device, an HDFC Ltd
  /// home-loan EMI collected by ACH, announced both as
  /// `UPDATE: … ACH D- HDFC BANK LTD-…` (payee `hdfc bank ltd`) and as
  /// `PAYMENT ALERT! … towards HDFC LTD UMRN: …` (payee `hdfc ltd`). Nothing
  /// in either redacted body names the other, so no shared token can join them.
  ///
  /// The join is therefore the payee name — which [_hasDistinguishingSignal]
  /// reads the other way round, treating two spellings as proof of two
  /// payments. A name join is only safe with independent evidence beside it
  /// (TASK-42), so it is the *last* clause here: amount, direction, day,
  /// account, reference, balance and issuing bank must already agree, and
  /// neither body may identify its own event.
  ///
  /// The issuing-bank clause is what keeps TASK-42's counterexample safe.
  /// `google` and `google asia pacific pte.ltd` are token-subset related and
  /// are two genuinely different subscriptions; they are billed by different
  /// banks, and two alerts about one event come from one bank.
  ///
  /// The loser is **marked, not dropped**: `active` in `SmsAnalysisSnapshot`
  /// stops counting it and a `duplicateSuppressed` coverage line names it, so a
  /// suppressed duplicate never looks like money that vanished.
  List<ParsedTxn> markSupersededRedeliveries(List<ParsedTxn> txns) {
    final order = [...txns]..sort((a, b) {
      final byDate = a.txnDate.compareTo(b.txnDate);
      if (byDate != 0) return byDate;
      return a.smsId.compareTo(b.smsId);
    });
    // Earliest (date, smsId) wins, the same ordering collapseRedeliveries uses.
    final supersededBy = <String, String>{};
    for (var i = 0; i < order.length; i++) {
      final winner = order[i];
      if (supersededBy.containsKey(winner.smsId)) continue;
      for (var j = i + 1; j < order.length; j++) {
        final loser = order[j];
        if (supersededBy.containsKey(loser.smsId)) continue;
        if (_isRedelivery(winner, loser)) {
          supersededBy[loser.smsId] = winner.smsId;
        }
      }
    }
    if (supersededBy.isEmpty) return txns;
    return [
      for (final t in txns)
        if (supersededBy.containsKey(t.smsId))
          t.copyWith(supersededBySmsId: supersededBy[t.smsId])
        else
          t,
    ];
  }

  bool _isRedelivery(ParsedTxn a, ParsedTxn b) {
    if (a.amountPaise != b.amountPaise) return false;
    if (a.direction != b.direction) return false;
    if (a.txnLocalDate != b.txnLocalDate) return false;
    // Absent is not different. An alert that drops the a/c tail (or the
    // running balance) contradicts nothing — the same reading
    // `_strongReferenceDuplicate` already applies to the account.
    if (_conflicts(_blankToNull(a.accountLast4), _blankToNull(b.accountLast4))) {
      return false;
    }
    if (_conflicts(_blankToNull(a.refNumber), _blankToNull(b.refNumber))) {
      return false;
    }
    // Two debits cannot leave the same account at the same balance, so a
    // balance that differs is proof of two payments — this is what keeps the
    // five same-day `indian clearing corp` SIP debits apart.
    if (_conflicts(a.balancePaise, b.balancePaise)) return false;
    // A row that pins down its own event has already met any twin in
    // collapseRedeliveries, so a survivor names a different event.
    if (_sameEventKey(a) != null || _sameEventKey(b) != null) return false;
    if (_institution(a.sender) != _institution(b.sender)) return false;
    return _namesOnePayee(a.merchant, b.merchant);
  }

  bool _conflicts(Object? a, Object? b) => a != null && b != null && a != b;

  String? _blankToNull(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  /// Whether two *different* payee strings are two spellings of one payee.
  ///
  /// Equal strings are deliberately excluded: identically-worded alerts are the
  /// shape of a genuine repeat (sequential ATM withdrawals, a SIP debited twice
  /// in a day), and the design already refuses to collapse those.
  bool _namesOnePayee(String? left, String? right) {
    final a = left?.trim().toLowerCase() ?? '';
    final b = right?.trim().toLowerCase() ?? '';
    if (a.isEmpty || b.isEmpty || a == b) return false;
    final tokensA = _payeeTokens(a);
    final tokensB = _payeeTokens(b);
    if (tokensA.isEmpty || tokensB.isEmpty) return false;
    return tokensA.containsAll(tokensB) || tokensB.containsAll(tokensA);
  }

  static final RegExp _tokenSplit = RegExp(r'[^a-z0-9]+');

  Set<String> _payeeTokens(String value) =>
      value.split(_tokenSplit).where((t) => t.isNotEmpty).toSet();

  /// The bank behind a DLT sender header: `VM-HDFCBK-S` and `JD-HDFCBK-S` are
  /// both `HDFCBK`. Older headers carry no separators (`VMHDFCBN`), so the
  /// two-character operator prefix is dropped instead. An imperfect reading
  /// only ever fails to match, which is the safe direction.
  String _institution(String sender) {
    final upper = sender.toUpperCase().trim();
    final parts = upper.split('-').where((p) => p.isNotEmpty).toList();
    if (parts.length >= 2) return parts[1];
    return upper.length > 2 ? upper.substring(2) : upper;
  }

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
