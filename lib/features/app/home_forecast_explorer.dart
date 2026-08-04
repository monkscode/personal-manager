import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/forecast_models.dart';
import '../../data/forecast_risk_models.dart';
import '../../services/forecast_explorer.dart';
import '../../services/reserve_planner.dart';
import '../../widgets/ui.dart';

/// Interactive 12-month forecast component for the Home screen.
///
/// Pure local selection — no DB/IO on taps. All persistence is delegated to
/// typed callbacks that the parent wires to the real stores.
class HomeForecastExplorer extends StatefulWidget {
  const HomeForecastExplorer({
    super.key,
    required this.explorer,
    required this.onUpdateReserve,
    required this.onSaveRiskDecision,
    required this.onSeeWhy,
    this.initialOffset = 0,
    this.embedded = false,
    this.anchorLabel = '',
    this.committedLabel = '',
    this.expectedLabel = '',
    this.freeLabel = '',
  });

  final ForecastExplorer explorer;
  final int initialOffset;

  /// Provenance of the balance the whole forecast opens on, e.g.
  /// `as of 1 Aug · 1234`. Empty hides the line. A plan the user cannot trace
  /// to a reading is not explainable, so this belongs beside the number
  /// (TASK-34).
  final String anchorLabel;

  /// This month's salary split — already committed, still expected, and free
  /// to spend. Empty hides the strip.
  final String committedLabel;
  final String expectedLabel;
  final String freeLabel;

  /// Persist a reserve schedule change. The parent reloads the snapshot after
  /// this future completes.
  final Future<void> Function({
    required String dedupeKey,
    required bool enabled,
    required int fundedPaise,
  })
  onUpdateReserve;

  /// Persist a risk decision. Same reload contract as [onUpdateReserve].
  final Future<void> Function(ForecastRiskDecision) onSaveRiskDecision;

  /// Navigate to the why-log for the selected plan/month.
  final void Function(ForecastMonthPlan plan, int offset) onSeeWhy;

  /// When true, renders in shrink-wrap mode for embedding in an outer
  /// scrollable (e.g. Home's ListView). Default false = standalone scrollable.
  final bool embedded;

  @override
  State<HomeForecastExplorer> createState() => _HomeForecastExplorerState();
}

class _HomeForecastExplorerState extends State<HomeForecastExplorer> {
  late int _selectedOffset;
  final Set<String> _pendingActions = {};

  @override
  void initState() {
    super.initState();
    _selectedOffset = widget.initialOffset.clamp(0, 11);
  }

  ForecastMonthPlan get _selectedPlan =>
      widget.explorer.planAt(_selectedOffset);

  void _selectOffset(int offset) {
    if (offset == _selectedOffset) return;
    setState(() => _selectedOffset = offset.clamp(0, 11));
  }

  bool get _hasEvidence {
    for (final plan in widget.explorer.plans) {
      if (plan.hardLines.isNotEmpty ||
          plan.riskLines.isNotEmpty ||
          plan.coverageLines.isNotEmpty ||
          plan.committedOutflowPaise > 0 ||
          plan.expectedInflowPaise > 0 ||
          plan.reserveContributionPaise > 0 ||
          plan.riskBufferPaise > 0 ||
          plan.requiredInBankPaise != 0 ||
          plan.reserveSchedules.isNotEmpty) {
        return true;
      }
    }
    return widget.explorer.availableToEnable.isNotEmpty;
  }

  Future<void> _showEditFundedDialog(ReserveSchedule schedule) async {
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => _EditFundedDialog(schedule: schedule),
    );
    if (!mounted) return;
    if (result != null) {
      await _handleReserveAction(schedule.dedupeKey, true, result);
    }
  }

  Future<void> _showEditRiskDialog(
    ForecastLine line,
    DateTime monthStart,
  ) async {
    final result = await showDialog<ForecastRiskDecision>(
      context: context,
      builder: (ctx) => _EditRiskDialog(line: line, monthStart: monthStart),
    );
    if (!mounted) return;
    if (result != null) {
      await _handleRiskAction(result);
    }
  }

  Future<void> _handleReserveAction(
    String dedupeKey,
    bool enabled,
    int fundedPaise,
  ) async {
    final actionKey = 'reserve:$dedupeKey';
    if (_pendingActions.contains(actionKey)) return;
    if (!mounted) return;
    setState(() => _pendingActions.add(actionKey));
    try {
      await widget.onUpdateReserve(
        dedupeKey: dedupeKey,
        enabled: enabled,
        fundedPaise: fundedPaise,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not update reserve: $e')));
      }
    } finally {
      if (mounted) setState(() => _pendingActions.remove(actionKey));
    }
  }

  Future<void> _handleRiskAction(ForecastRiskDecision decision) async {
    final actionKey = 'risk:${decision.ownerKey}';
    if (_pendingActions.contains(actionKey)) return;
    if (!mounted) return;
    setState(() => _pendingActions.add(actionKey));
    try {
      await widget.onSaveRiskDecision(decision);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save risk decision: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _pendingActions.remove(actionKey));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasEvidence) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'Not enough data yet',
            style: jakarta(
              size: 16,
              weight: FontWeight.w600,
              color: context.palette.textSecondary,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final plan = _selectedPlan;
    final action = widget.explorer.currentAction;

    return ListView(
      shrinkWrap: widget.embedded,
      physics: widget.embedded ? const NeverScrollableScrollPhysics() : null,
      primary: widget.embedded ? false : null,
      padding: widget.embedded
          ? EdgeInsets.zero
          : const EdgeInsets.fromLTRB(20, 16, 20, 28),
      children: [
        // ── Action-first header ──────────────────────────────────────────
        _ActionHeader(
          requiredPaise: action.requiredInBankPaise,
          keepAvailableUntil: action.keepAvailableUntil,
          reserveContributionPaise: action.reserveContributionPaise,
          isProvisional: action.isProvisional,
          anchorLabel: widget.anchorLabel,
          committedLabel: widget.committedLabel,
          expectedLabel: widget.expectedLabel,
          freeLabel: widget.freeLabel,
        ),
        const SizedBox(height: 16),

        // ── This month / Next month toggle ──────────────────────────────
        SegmentedToggle(
          key: const ValueKey('month-toggle'),
          labels: const ['This month', 'Next month'],
          selectedIndex: _selectedOffset <= 1 ? _selectedOffset : -1,
          onChanged: (i) => _selectOffset(i),
        ),
        const SizedBox(height: 16),

        // ── 12-month chart ──────────────────────────────────────────────
        _MonthChart(
          plans: widget.explorer.plans,
          selectedOffset: _selectedOffset,
          onSelect: _selectOffset,
        ),
        const SizedBox(height: 16),

        // ── Selected month detail ───────────────────────────────────────
        _SelectedDetail(
          plan: plan,
          offset: _selectedOffset,
          onSeeWhy: () => widget.onSeeWhy(plan, _selectedOffset),
        ),
        const SizedBox(height: 12),

        // ── Hard drivers (ranked by amount) ─────────────────────────────
        if (plan.hardLines.isNotEmpty) ...[
          _SectionLabel('Drivers'),
          const SizedBox(height: 8),
          ..._rankedDrivers(plan.hardLines),
          const SizedBox(height: 12),
        ],

        // ── Risk lines ──────────────────────────────────────────────────
        if (plan.riskLines.isNotEmpty) ...[
          _SectionLabel('Unconfirmed risk'),
          const SizedBox(height: 8),
          ...plan.riskLines.map(
            (r) => _RiskRow(
              line: r,
              monthStart: plan.monthStart,
              isPending: _pendingActions.contains('risk:${r.ownerKey}'),
              onConfirm: () => _handleRiskAction(
                ForecastRiskDecision(
                  ownerKey: r.ownerKey,
                  targetMonth: _targetMonthKey(plan.monthStart),
                  status: ForecastRiskDecisionStatus.confirmed,
                  amountOverridePaise: r.amountPaise,
                  dueDateOverride: r.date,
                ),
              ),
              onEdit: () => _showEditRiskDialog(r, plan.monthStart),
              onDismiss: () => _handleRiskAction(
                ForecastRiskDecision(
                  ownerKey: r.ownerKey,
                  targetMonth: _targetMonthKey(plan.monthStart),
                  status: ForecastRiskDecisionStatus.dismissed,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],

        // ── Reserve schedules ───────────────────────────────────────────
        if (plan.reserveSchedules.isNotEmpty) ...[
          _SectionLabel('Set-aside reserves'),
          const SizedBox(height: 8),
          ...plan.reserveSchedules.map(
            (s) => _ReserveRow(
              schedule: s,
              isPending: _pendingActions.contains('reserve:${s.dedupeKey}'),
              onEditFunded: () => _showEditFundedDialog(s),
            ),
          ),
          const SizedBox(height: 12),
        ],

        // ── Available to enable (candidates) ────────────────────────────
        if (widget.explorer.availableToEnable.isNotEmpty) ...[
          _SectionLabel('Available reserves'),
          const SizedBox(height: 8),
          ...widget.explorer.availableToEnable.map(
            (c) => _CandidateRow(
              candidate: c,
              isPending: _pendingActions.contains('reserve:${c.dedupeKey}'),
              onStart: () => _handleReserveAction(c.dedupeKey, true, 0),
            ),
          ),
        ],
      ],
    );
  }

  List<Widget> _rankedDrivers(List<ForecastLine> lines) {
    final sorted = [...lines]
      ..sort((a, b) => b.amountPaise.compareTo(a.amountPaise));
    return sorted.map((line) => _DriverRow(line: line)).toList();
  }
}

String _targetMonthKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}';

// ---------------------------------------------------------------------------
// Action-first header
// ---------------------------------------------------------------------------

class _ActionHeader extends StatelessWidget {
  const _ActionHeader({
    required this.requiredPaise,
    required this.keepAvailableUntil,
    required this.reserveContributionPaise,
    required this.isProvisional,
    this.anchorLabel = '',
    this.committedLabel = '',
    this.expectedLabel = '',
    this.freeLabel = '',
  });

  final int requiredPaise;
  final DateTime keepAvailableUntil;
  final int reserveContributionPaise;
  final bool isProvisional;
  final String anchorLabel;
  final String committedLabel;
  final String expectedLabel;
  final String freeLabel;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final dateLabel = DateFormat('d MMM').format(keepAvailableUntil);
    final hasStrip =
        committedLabel.isNotEmpty ||
        expectedLabel.isNotEmpty ||
        freeLabel.isNotEmpty;
    Widget stripCell(String label, String value, Color valueColor) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: jakarta(
            size: 11,
            weight: FontWeight.w600,
            color: p.textTertiary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: mono(size: 15, weight: FontWeight.w800, color: valueColor),
        ),
      ],
    );
    return Surface(
      radius: 16,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Your plan now',
            style: jakarta(
              size: 12,
              weight: FontWeight.w600,
              color: p.textTertiary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            inr(requiredPaise ~/ 100),
            style: mono(
              size: 24,
              weight: FontWeight.w700,
              color: p.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'until $dateLabel',
            style: jakarta(
              size: 12,
              weight: FontWeight.w500,
              color: p.textSecondary,
            ),
          ),
          if (anchorLabel.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  Icons.account_balance_wallet_outlined,
                  size: 14,
                  color: p.textTertiary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    anchorLabel,
                    style: jakarta(
                      size: 12,
                      weight: FontWeight.w500,
                      color: p.textTertiary,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (hasStrip) ...[
            const SizedBox(height: 14),
            Container(height: 1, color: p.border),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: stripCell('Committed', committedLabel, p.textPrimary),
                ),
                Container(width: 1, height: 30, color: p.border),
                Expanded(
                  child: stripCell('Expected', expectedLabel, AppColors.green),
                ),
                Container(width: 1, height: 30, color: p.border),
                Expanded(child: stripCell('Free', freeLabel, AppColors.teal)),
              ],
            ),
          ],
          if (reserveContributionPaise > 0) ...[
            const SizedBox(height: 8),
            Text(
              'Set aside now: ${inr(reserveContributionPaise ~/ 100)}',
              style: jakarta(
                size: 12,
                weight: FontWeight.w600,
                color: AppColors.teal,
              ),
            ),
          ],
          if (isProvisional) ...[
            const SizedBox(height: 8),
            Text(
              'Provisional \u2014 confirm your balance',
              style: jakarta(
                size: 12,
                weight: FontWeight.w600,
                color: AppColors.amber,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 12-month chart
// ---------------------------------------------------------------------------

class _MonthChart extends StatelessWidget {
  const _MonthChart({
    required this.plans,
    required this.selectedOffset,
    required this.onSelect,
  });

  final List<ForecastMonthPlan> plans;
  final int selectedOffset;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final maxRequired = plans.fold<int>(
      0,
      (m, p) => p.requiredInBankPaise > m ? p.requiredInBankPaise : m,
    );

    return SizedBox(
      height: 140,
      child: SingleChildScrollView(
        key: const ValueKey('forecast-month-chart'),
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var i = 0; i < plans.length; i++)
              _ChartBar(
                index: i,
                plan: plans[i],
                isSelected: i == selectedOffset,
                maxRequired: maxRequired,
                onTap: () => onSelect(i),
              ),
          ],
        ),
      ),
    );
  }
}

class _ChartBar extends StatelessWidget {
  const _ChartBar({
    required this.index,
    required this.plan,
    required this.isSelected,
    required this.maxRequired,
    required this.onTap,
  });

  final int index;
  final ForecastMonthPlan plan;
  final bool isSelected;
  final int maxRequired;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final barMaxHeight = 90.0;
    final fraction = maxRequired > 0
        ? (plan.requiredInBankPaise / maxRequired).clamp(0.0, 1.0)
        : 0.0;
    final barHeight = fraction == 0
        ? 2.0
        : (fraction * barMaxHeight).clamp(4.0, barMaxHeight);
    final monthLabel = DateFormat('MMM').format(plan.monthStart);
    final yearLabel = DateFormat('yy').format(plan.monthStart);
    final fullMonthYear = DateFormat('MMMM yyyy').format(plan.monthStart);
    final amountLabel = inr(plan.requiredInBankPaise ~/ 100);
    final confPercent = '${(plan.confidence * 100).round()}%';
    final provisionalSuffix = plan.isProvisional ? ', provisional' : '';

    return Semantics(
      button: true,
      selected: isSelected,
      label:
          '$fullMonthYear, $amountLabel required in bank, $confPercent confidence$provisionalSuffix',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          key: ValueKey('forecast-month-$index'),
          width: 52,
          height: 140,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              SizedBox(
                height: 14,
                child: isSelected
                    ? FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          amountLabel,
                          key: const ValueKey('selected-bar-amount'),
                          style: mono(
                            size: 10,
                            weight: FontWeight.w700,
                            color: AppColors.teal,
                          ),
                        ),
                      )
                    : null,
              ),
              Container(
                key: ValueKey('bar-fill-$index'),
                width: 28,
                height: barHeight,
                decoration: BoxDecoration(
                  color: isSelected ? AppColors.teal : p.surfaceAlt,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(4),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                monthLabel,
                style: jakarta(
                  size: 10,
                  weight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  color: isSelected ? AppColors.teal : p.textTertiary,
                ),
              ),
              if (index == 0 || plan.monthStart.month == 1)
                Text(
                  "'$yearLabel",
                  style: jakarta(
                    size: 9,
                    weight: FontWeight.w500,
                    color: p.textTertiary,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Selected month detail
// ---------------------------------------------------------------------------

class _SelectedDetail extends StatelessWidget {
  const _SelectedDetail({
    required this.plan,
    required this.offset,
    required this.onSeeWhy,
  });

  final ForecastMonthPlan plan;
  final int offset;
  final VoidCallback onSeeWhy;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final monthName = DateFormat('MMMM').format(plan.monthStart);
    final lowestDate = DateFormat('d MMM').format(plan.minimumBalanceDate);
    final confPercent = '${(plan.confidence * 100).round()}%';

    return Surface(
      radius: 16,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$monthName plan',
            style: jakarta(
              size: 14,
              weight: FontWeight.w800,
              color: p.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          _DetailRow(
            'Required in bank',
            inr(plan.requiredInBankPaise ~/ 100),
            p,
          ),
          _DetailRow(
            'Lowest balance',
            '${inr(plan.minimumBalancePaise ~/ 100)} on $lowestDate',
            p,
          ),
          _DetailRow('Reserve', inr(plan.reserveContributionPaise ~/ 100), p),
          _DetailRow('Unconfirmed risk', inr(plan.riskBufferPaise ~/ 100), p),
          _DetailRow(
            'Confidence',
            plan.isProvisional ? '$confPercent (provisional)' : confPercent,
            p,
          ),
          const SizedBox(height: 4),
          Semantics(
            button: true,
            label:
                'See why $monthName requires ${inr(plan.requiredInBankPaise ~/ 100)}',
            excludeSemantics: true,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onSeeWhy,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'See why $monthName requires ${inr(plan.requiredInBankPaise ~/ 100)}',
                        style: jakarta(
                          size: 13,
                          weight: FontWeight.w700,
                          color: AppColors.teal,
                        ),
                        maxLines: 2,
                        softWrap: true,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: AppColors.teal,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow(this.label, this.value, this.palette);

  final String label;
  final String value;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: jakarta(
                size: 12,
                weight: FontWeight.w500,
                color: palette.textSecondary,
              ),
            ),
          ),
          Flexible(
            child: Text(
              value,
              style: mono(
                size: 12,
                weight: FontWeight.w600,
                color: palette.textPrimary,
              ),
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Driver row (hard lines ranked by amount)
// ---------------------------------------------------------------------------

class _DriverRow extends StatelessWidget {
  const _DriverRow({required this.line});

  final ForecastLine line;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              line.label,
              style: jakarta(
                size: 12,
                weight: FontWeight.w600,
                color: p.textPrimary,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            inr(line.amountPaise ~/ 100),
            style: mono(
              size: 12,
              weight: FontWeight.w600,
              color: p.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Risk row
// ---------------------------------------------------------------------------

class _RiskRow extends StatelessWidget {
  const _RiskRow({
    required this.line,
    required this.monthStart,
    required this.isPending,
    required this.onConfirm,
    required this.onEdit,
    required this.onDismiss,
  });

  final ForecastLine line;
  final DateTime monthStart;
  final bool isPending;
  final VoidCallback onConfirm;
  final VoidCallback onEdit;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  line.label,
                  style: jakarta(
                    size: 12,
                    weight: FontWeight.w600,
                    color: p.textPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  inr(line.amountPaise ~/ 100),
                  style: mono(
                    size: 11,
                    weight: FontWeight.w500,
                    color: p.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (isPending)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else ...[
            _SmallAction(label: 'Confirm', onTap: onConfirm),
            const SizedBox(width: 8),
            _SmallAction(label: 'Edit', onTap: onEdit),
            const SizedBox(width: 8),
            _SmallAction(label: 'Dismiss', onTap: onDismiss, muted: true),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Reserve schedule row
// ---------------------------------------------------------------------------

class _ReserveRow extends StatelessWidget {
  const _ReserveRow({
    required this.schedule,
    required this.isPending,
    required this.onEditFunded,
  });

  final ReserveSchedule schedule;
  final bool isPending;
  final VoidCallback onEditFunded;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final dueLabel = DateFormat('d MMM yyyy').format(schedule.dueDate);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  schedule.label,
                  style: jakarta(
                    size: 12,
                    weight: FontWeight.w600,
                    color: p.textPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '${inr(schedule.fundedPaise ~/ 100)} / ${inr(schedule.targetPaise ~/ 100)} · Due $dueLabel',
                  style: jakarta(
                    size: 11,
                    weight: FontWeight.w500,
                    color: p.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (isPending)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            _SmallAction(label: 'Edit funded amount', onTap: onEditFunded),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Reserve candidate row
// ---------------------------------------------------------------------------

class _CandidateRow extends StatelessWidget {
  const _CandidateRow({
    required this.candidate,
    required this.isPending,
    required this.onStart,
  });

  final ReserveCandidate candidate;
  final bool isPending;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final dueLabel = DateFormat('d MMM yyyy').format(candidate.dueDate);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  candidate.label,
                  style: jakarta(
                    size: 12,
                    weight: FontWeight.w600,
                    color: p.textPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '${inr(candidate.targetPaise ~/ 100)} · Due $dueLabel',
                  style: jakarta(
                    size: 11,
                    weight: FontWeight.w500,
                    color: p.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (isPending)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            _SmallAction(label: 'Start reserve', onTap: onStart),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared small widgets
// ---------------------------------------------------------------------------

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Text(
      text,
      style: jakarta(size: 12, weight: FontWeight.w700, color: p.textTertiary),
    );
  }
}

class _SmallAction extends StatelessWidget {
  const _SmallAction({
    required this.label,
    required this.onTap,
    this.muted = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: muted
              ? Colors.transparent
              : AppColors.teal.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
          border: muted ? Border.all(color: context.palette.border) : null,
        ),
        child: Text(
          label,
          style: jakarta(
            size: 12,
            weight: FontWeight.w700,
            color: muted ? context.palette.textSecondary : AppColors.teal,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Edit funded amount dialog
// ---------------------------------------------------------------------------

class _EditFundedDialog extends StatefulWidget {
  const _EditFundedDialog({required this.schedule});
  final ReserveSchedule schedule;

  @override
  State<_EditFundedDialog> createState() => _EditFundedDialogState();
}

class _EditFundedDialogState extends State<_EditFundedDialog> {
  late TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: (widget.schedule.fundedPaise ~/ 100).toString(),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final parsed = int.tryParse(_controller.text);
    if (parsed == null || parsed < 0) {
      setState(() => _error = 'Enter a valid non-negative amount');
      return;
    }
    final paise = parsed * 100;
    if (paise > widget.schedule.targetPaise) {
      setState(
        () => _error =
            'Amount exceeds target of ${inr(widget.schedule.targetPaise ~/ 100)}',
      );
      return;
    }
    Navigator.of(context).pop(paise);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit funded amount'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const ValueKey('reserve-funded-input'),
            controller: _controller,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              prefixText: '\u20b9',
              errorText: _error,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Edit risk dialog
// ---------------------------------------------------------------------------

class _EditRiskDialog extends StatefulWidget {
  const _EditRiskDialog({required this.line, required this.monthStart});
  final ForecastLine line;
  final DateTime monthStart;

  @override
  State<_EditRiskDialog> createState() => _EditRiskDialogState();
}

class _EditRiskDialogState extends State<_EditRiskDialog> {
  late TextEditingController _amountController;
  DateTime? _selectedDate;
  String? _error;

  @override
  void initState() {
    super.initState();
    _amountController = TextEditingController(
      text: (widget.line.amountPaise ~/ 100).toString(),
    );
    _selectedDate = widget.line.date ?? widget.monthStart;
  }

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate ?? widget.monthStart,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
    );
    if (!mounted) return;
    if (picked != null) {
      setState(() => _selectedDate = picked);
    }
  }

  void _save() {
    final parsed = int.tryParse(_amountController.text);
    if (parsed == null || parsed < 0) {
      setState(() => _error = 'Enter a valid non-negative amount');
      return;
    }
    if (_selectedDate == null) {
      setState(() => _error = 'Select a date');
      return;
    }
    Navigator.of(context).pop(
      ForecastRiskDecision(
        ownerKey: widget.line.ownerKey,
        targetMonth: _targetMonthKey(widget.monthStart),
        status: ForecastRiskDecisionStatus.confirmed,
        amountOverridePaise: parsed * 100,
        dueDateOverride: _selectedDate,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dateLabel = _selectedDate != null
        ? DateFormat('d MMM yyyy').format(_selectedDate!)
        : 'No date selected';
    return AlertDialog(
      title: const Text('Edit risk'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const ValueKey('risk-amount-input'),
            controller: _amountController,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              prefixText: '\u20b9',
              labelText: 'Amount',
              errorText: _error,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: Text(dateLabel)),
              TextButton(
                onPressed: _pickDate,
                child: const Text('Select date'),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
