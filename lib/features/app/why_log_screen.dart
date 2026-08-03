import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/forecast_models.dart';
import '../../services/reserve_planner.dart';

/// The itemised why-log for the forecast month: every dated event, estimate,
/// paid/unpaid obligation, already-in-anchor item and quantified coverage line
/// that shapes the headline, grouped and each tappable to its source. Forward
/// earmarks — material lumps beyond the target month — render as a visually
/// distinct "coming up later" section (spec §7 / §13, Decision D10).
class WhyLogScreen extends StatelessWidget {
  const WhyLogScreen({
    super.key,
    required this.lines,
    required this.forwardEarmarks,
    this.coverageLines = const [],
    this.reserveSchedules = const [],
    this.riskLines = const [],
    this.monthLabel = '',
    this.onTapLine,
  });

  final List<ForecastLine> lines;
  final List<ForecastLine> forwardEarmarks;
  final List<ForecastCoverageLine> coverageLines;
  final List<ReserveSchedule> reserveSchedules;
  final List<ForecastLine> riskLines;
  final String monthLabel;
  final void Function(ForecastLine line)? onTapLine;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final groups = _groupLines(lines);

    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.bg,
        elevation: 0,
        iconTheme: IconThemeData(color: p.textPrimary),
        title: Text(
          monthLabel.isEmpty
              ? 'Why this forecast'
              : 'Why $monthLabel looks like this',
          style: jakarta(
            size: 16,
            weight: FontWeight.w800,
            color: p.textPrimary,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        children: [
          for (final group in groups) ...[
            _sectionHeader(context, group.title),
            const SizedBox(height: 8),
            for (final line in group.lines) _lineTile(context, line),
            const SizedBox(height: 20),
          ],
          if (reserveSchedules.isNotEmpty) ...[
            _sectionHeader(context, 'Set aside'),
            const SizedBox(height: 8),
            for (final s in reserveSchedules) _reserveTile(context, s),
            const SizedBox(height: 20),
          ],
          if (riskLines.isNotEmpty) ...[
            _sectionHeader(context, 'Unconfirmed risk'),
            const SizedBox(height: 8),
            for (final r in riskLines) _riskTile(context, r),
            const SizedBox(height: 20),
          ],
          if (coverageLines.isNotEmpty) ...[
            _sectionHeader(context, 'Needs your attention'),
            const SizedBox(height: 8),
            for (final c in coverageLines) _coverageTile(context, c),
            const SizedBox(height: 20),
          ],
          if (forwardEarmarks.isNotEmpty) ...[
            _sectionHeader(context, 'Coming up later'),
            const SizedBox(height: 8),
            for (final line in forwardEarmarks) _earmarkTile(context, line),
          ],
        ],
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String title) => Text(
    title.toUpperCase(),
    style: jakarta(
      size: 12,
      weight: FontWeight.w700,
      letterSpacing: 0.6,
      color: context.palette.textTertiary,
    ),
  );

  Widget _lineTile(BuildContext context, ForecastLine line) {
    final p = context.palette;
    final (statusText, statusColor) = _status(line);
    final subtitleParts = <String>[
      if (line.date != null) DateFormat('d MMM').format(line.date!),
      if (line.source == ForecastEventSource.seasonal)
        'est · ${(line.confidence * 100).round()}%',
      statusText,
    ];
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      key: ValueKey('why-line-${line.ownerKey}'),
      onTap: onTapLine == null ? null : () => onTapLine!(line),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: p.border)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    line.label,
                    style: jakarta(
                      size: 13,
                      weight: FontWeight.w600,
                      color: p.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitleParts.join(' · '),
                    style: jakarta(
                      size: 12,
                      weight: FontWeight.w500,
                      color: statusColor,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              inr(line.amountPaise / 100.0),
              style: mono(
                size: 13,
                weight: FontWeight.w600,
                color: p.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _coverageTile(BuildContext context, ForecastCoverageLine c) {
    final p = context.palette;
    final action = _actionLabel(c.action);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.amber.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.amber.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  c.label,
                  style: jakarta(
                    size: 13,
                    weight: FontWeight.w600,
                    color: p.textPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  action.isEmpty
                      ? _reasonLabel(c.reason)
                      : '${_reasonLabel(c.reason)} · $action',
                  style: jakarta(
                    size: 12,
                    weight: FontWeight.w500,
                    color: p.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (c.amountPaise != null) ...[
            const SizedBox(width: 10),
            Text(
              inr(c.amountPaise! / 100.0),
              style: mono(
                size: 13,
                weight: FontWeight.w600,
                color: AppColors.amber,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _earmarkTile(BuildContext context, ForecastLine line) {
    final p = context.palette;
    final due = line.date == null
        ? ''
        : 'Due ${DateFormat('MMMM').format(line.date!)}';
    return Container(
      key: ValueKey('why-earmark-${line.ownerKey}'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.violet.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.violet.withValues(alpha: 0.30)),
      ),
      child: Row(
        children: [
          Icon(Icons.event_outlined, size: 20, color: AppColors.violet),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  line.label,
                  style: jakarta(
                    size: 13,
                    weight: FontWeight.w600,
                    color: p.textPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '$due · set aside ahead of time',
                  style: jakarta(
                    size: 12,
                    weight: FontWeight.w500,
                    color: AppColors.violet,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            inr(line.amountPaise / 100.0),
            style: mono(
              size: 13,
              weight: FontWeight.w700,
              color: AppColors.violet,
            ),
          ),
        ],
      ),
    );
  }

  // ---- reserve / risk tiles ------------------------------------------------

  Widget _reserveTile(BuildContext context, ReserveSchedule s) {
    final p = context.palette;
    final dueLabel = DateFormat('MMMM').format(s.dueDate);
    final dueDate = DateFormat('d MMM yyyy').format(s.dueDate);
    return Container(
      key: ValueKey('why-reserve-${s.dedupeKey}'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.teal.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.teal.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s.label,
            style: jakarta(
              size: 13,
              weight: FontWeight.w600,
              color: p.textPrimary,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            'Due $dueLabel · $dueDate',
            style: jakarta(
              size: 12,
              weight: FontWeight.w500,
              color: p.textSecondary,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              Text(
                'Target ${inr(s.targetPaise / 100.0)}',
                style: mono(
                  size: 12,
                  weight: FontWeight.w600,
                  color: p.textPrimary,
                ),
              ),
              Text(
                'Funded ${inr(s.fundedPaise / 100.0)}',
                style: mono(
                  size: 12,
                  weight: FontWeight.w600,
                  color: AppColors.green,
                ),
              ),
              Text(
                'Remaining ${inr(s.remainingPaise / 100.0)}',
                style: mono(
                  size: 12,
                  weight: FontWeight.w600,
                  color: AppColors.amber,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _riskTile(BuildContext context, ForecastLine line) {
    final p = context.palette;
    final confPercent = '${(line.confidence * 100).round()}%';
    final (statusText, _) = _status(line);
    final dateLabel = line.date != null
        ? DateFormat('d MMM').format(line.date!)
        : '';
    return Container(
      key: ValueKey('why-risk-${line.ownerKey}'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.amber.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.amber.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  line.label,
                  style: jakarta(
                    size: 13,
                    weight: FontWeight.w600,
                    color: p.textPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  [
                    if (dateLabel.isNotEmpty) dateLabel,
                    '$confPercent confidence',
                    statusText,
                    _sourceLabel(line.source),
                  ].join(' · '),
                  style: jakarta(
                    size: 12,
                    weight: FontWeight.w500,
                    color: p.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            inr(line.amountPaise / 100.0),
            style: mono(
              size: 13,
              weight: FontWeight.w600,
              color: AppColors.amber,
            ),
          ),
        ],
      ),
    );
  }

  String _sourceLabel(ForecastEventSource source) => switch (source) {
    ForecastEventSource.seasonal => 'Seasonal',
    ForecastEventSource.recurring => 'Recurring',
    ForecastEventSource.gmailBill => 'Gmail bill',
    ForecastEventSource.cardStatement => 'Card',
    _ => 'Other',
  };

  // ---- grouping -------------------------------------------------------------

  List<_LineGroup> _groupLines(List<ForecastLine> lines) {
    final buckets = <String, List<ForecastLine>>{};
    for (final line in lines) {
      buckets.putIfAbsent(_bucketOf(line), () => []).add(line);
    }
    // Deterministic, reader-friendly order.
    const order = [
      'Recurring',
      'Bills',
      'Cards',
      'Seasonal estimates',
      'Income & credits',
      'Already in your balance',
      'Other dated items',
    ];
    final groups = <_LineGroup>[];
    for (final title in order) {
      final items = buckets.remove(title);
      if (items != null && items.isNotEmpty) {
        items.sort(_byDate);
        groups.add(_LineGroup(title, items));
      }
    }
    // Any unexpected bucket falls through last, still shown (no silent drop).
    for (final entry in buckets.entries) {
      final items = [...entry.value]..sort(_byDate);
      groups.add(_LineGroup(entry.key, items));
    }
    return groups;
  }

  static int _byDate(ForecastLine a, ForecastLine b) {
    final da = a.date, db = b.date;
    if (da == null && db == null) return 0;
    if (da == null) return 1;
    if (db == null) return -1;
    return da.compareTo(db);
  }

  String _bucketOf(ForecastLine line) {
    if (line.status == ForecastLineStatus.alreadyInAnchor) {
      return 'Already in your balance';
    }
    return switch (line.source) {
      ForecastEventSource.recurring ||
      ForecastEventSource.configuredContribution => 'Recurring',
      ForecastEventSource.gmailBill => 'Bills',
      ForecastEventSource.cardStatement ||
      ForecastEventSource.cardPayment ||
      ForecastEventSource.cardOutstanding => 'Cards',
      ForecastEventSource.seasonal ||
      ForecastEventSource.untrackedCash => 'Seasonal estimates',
      ForecastEventSource.salary ||
      ForecastEventSource.otherIncome ||
      ForecastEventSource.refund ||
      ForecastEventSource.currentActual => 'Income & credits',
      _ => 'Other dated items',
    };
  }

  (String, Color) _status(ForecastLine line) => switch (line.status) {
    ForecastLineStatus.paid => ('Paid', AppColors.green),
    ForecastLineStatus.reconciled => ('Reconciled', AppColors.green),
    ForecastLineStatus.unpaid => ('Unpaid', AppColors.amber),
    ForecastLineStatus.overdue => ('Overdue', AppColors.pink),
    ForecastLineStatus.exceeded => ('Over budget', AppColors.pink),
    ForecastLineStatus.alreadyInAnchor => (
      'Already in balance',
      AppColors.slate,
    ),
    ForecastLineStatus.projected => ('Projected', AppColors.slate),
    ForecastLineStatus.estimated => ('Estimated', AppColors.slate),
    ForecastLineStatus.review => ('Review', AppColors.amber),
    ForecastLineStatus.coverage => ('Heads-up', AppColors.amber),
    ForecastLineStatus.opening => ('Opening balance', AppColors.slate),
  };

  String _reasonLabel(CoverageReason r) => switch (r) {
    CoverageReason.untrackedCash => "Cash spending we can't see",
    CoverageReason.staleAnchor => 'Your balance may be out of date',
    CoverageReason.noBalanceEvidence => "We haven't seen your balance yet",
    CoverageReason.outOfPrimaryScope => 'On another account',
    CoverageReason.unscheduledObligation => 'No due date yet',
    CoverageReason.reviewNeeded => 'Needs review',
    CoverageReason.possiblyAlreadyPaid => 'May already be paid',
    CoverageReason.p2pConfirmationRequired => 'Confirm this person',
    CoverageReason.setCardCycle => 'Set your card cycle',
    CoverageReason.transferBridgeReview => 'Transfer to confirm',
    CoverageReason.partialCardOutstanding => 'Card balance carried over',
    CoverageReason.accountHintUncertain => 'Account unclear',
    CoverageReason.overBudgetDiscretionary => 'Over your usual',
    CoverageReason.cardCycleOnly => 'Card cycle only',
    CoverageReason.futureEarmark => 'Coming up later',
    CoverageReason.duplicateSuppressed => 'Counted once, under another name',
    CoverageReason.discretionaryNotModelled => 'Everyday spending not included',
  };

  String _actionLabel(CoverageAction a) => switch (a) {
    CoverageAction.confirmBalance => 'Confirm balance',
    CoverageAction.setDueMonth => 'Set due month',
    CoverageAction.dismiss => 'Dismiss',
    CoverageAction.markUnpaid => 'Mark unpaid',
    CoverageAction.linkAccount => 'Link account',
    CoverageAction.review => 'Review',
    CoverageAction.confirmIncome => 'Confirm income',
    CoverageAction.setCardCycle => 'Set card cycle',
    CoverageAction.none => '',
  };
}

class _LineGroup {
  const _LineGroup(this.title, this.lines);
  final String title;
  final List<ForecastLine> lines;
}
