import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/sms_models.dart';
import '../../services/sms_ingestion_policy.dart';

/// Whether [txn] is part of a same amount/day/account collision set. Collision
/// rows are always reviewed individually and can never be bulk-confirmed
/// (spec §4 no-ref collision rule).
bool _isCollision(ParsedTxn txn) =>
    txn.collisionSetId != null &&
    txn.reviewReason == ReviewReason.dedupCollision;

/// Whether [txn] should be pre-checked in the review-all list: a non-collision,
/// non-uncertain row whose confidence clears the auto-add threshold.
bool _preChecked(ParsedTxn txn) =>
    !_isCollision(txn) &&
    txn.reviewReason != ReviewReason.parserUncertain &&
    txn.confidence >= kAutoAddConfidenceThreshold;

String _label(ParsedTxn txn) =>
    txn.merchant ?? txn.upiVpaNorm ?? txn.categoryKey;

/// Review queue for a completed scan. Standalone rows carry a selection
/// checkbox (high-confidence pre-checked); collision sets render grouped and
/// without checkboxes so they can be confirmed only one at a time, never
/// bulk-auto-added.
class SmsReviewScreen extends StatefulWidget {
  const SmsReviewScreen({
    super.key,
    required this.items,
    required this.onConfirmSelected,
    required this.onDismiss,
    this.title = 'Review transactions',
  });

  final List<ParsedTxn> items;
  final void Function(List<ParsedTxn> confirmed) onConfirmSelected;
  final void Function(ParsedTxn item) onDismiss;
  final String title;

  @override
  State<SmsReviewScreen> createState() => _SmsReviewScreenState();
}

class _SmsReviewScreenState extends State<SmsReviewScreen> {
  late final Set<String> _selected = {
    for (final txn in widget.items)
      if (_preChecked(txn)) txn.smsId,
  };

  List<ParsedTxn> get _selectable =>
      widget.items.where((t) => !_isCollision(t)).toList(growable: false);

  Map<String, List<ParsedTxn>> get _collisionGroups {
    final groups = <String, List<ParsedTxn>>{};
    for (final txn in widget.items) {
      if (_isCollision(txn)) {
        groups.putIfAbsent(txn.collisionSetId!, () => []).add(txn);
      }
    }
    return groups;
  }

  void _toggle(String smsId, bool? value) {
    setState(() {
      if (value ?? false) {
        _selected.add(smsId);
      } else {
        _selected.remove(smsId);
      }
    });
  }

  void _selectAll() {
    setState(() => _selected
      ..clear()
      ..addAll(_selectable.map((t) => t.smsId)));
  }

  void _confirm() {
    final confirmed = widget.items
        .where((t) => _selected.contains(t.smsId))
        .toList(growable: false);
    widget.onConfirmSelected(confirmed);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final collisionGroups = _collisionGroups;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
            children: [
              Text(
                widget.title,
                style: jakarta(
                  size: 21,
                  weight: FontWeight.w800,
                  color: p.textPrimary,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  TextButton(
                    onPressed: _selectAll,
                    child: Text(
                      'Select all',
                      style: jakarta(
                        size: 13,
                        weight: FontWeight.w600,
                        color: AppColors.teal,
                      ),
                    ),
                  ),
                ],
              ),
              for (final txn in _selectable)
                _ReviewRow(
                  txn: txn,
                  selected: _selected.contains(txn.smsId),
                  onChanged: (v) => _toggle(txn.smsId, v),
                  onDismiss: () => widget.onDismiss(txn),
                ),
              for (final entry in collisionGroups.entries)
                _CollisionGroup(
                  rows: entry.value,
                  onConfirmOne: (t) => widget.onConfirmSelected([t]),
                  onDismiss: widget.onDismiss,
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: FilledButton(
            onPressed: _confirm,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.teal,
              foregroundColor: AppColors.ink,
              minimumSize: const Size.fromHeight(48),
            ),
            child: Text(
              'Confirm selected',
              style: jakarta(size: 14, weight: FontWeight.w700),
            ),
          ),
        ),
      ],
    );
  }
}

class _ReviewRow extends StatelessWidget {
  const _ReviewRow({
    required this.txn,
    required this.selected,
    required this.onChanged,
    required this.onDismiss,
  });

  final ParsedTxn txn;
  final bool selected;
  final ValueChanged<bool?> onChanged;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: p.border)),
      ),
      child: Row(
        children: [
          Checkbox(
            key: ValueKey('review-check-${txn.smsId}'),
            value: selected,
            onChanged: onChanged,
            activeColor: AppColors.teal,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _label(txn),
                  style: jakarta(
                    size: 13,
                    weight: FontWeight.w600,
                    color: p.textPrimary,
                  ),
                ),
                Text(
                  txn.categoryKey,
                  style: jakarta(
                    size: 12,
                    weight: FontWeight.w500,
                    color: p.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          Text(
            inr(txn.amountPaise / 100),
            style: mono(size: 13, weight: FontWeight.w600, color: p.textPrimary),
          ),
          IconButton(
            key: ValueKey('dismiss-${txn.smsId}'),
            onPressed: onDismiss,
            icon: Icon(Icons.close_rounded, size: 18, color: p.textTertiary),
            tooltip: 'Dismiss',
          ),
        ],
      ),
    );
  }
}

class _CollisionGroup extends StatelessWidget {
  const _CollisionGroup({
    required this.rows,
    required this.onConfirmOne,
    required this.onDismiss,
  });

  final List<ParsedTxn> rows;
  final void Function(ParsedTxn item) onConfirmOne;
  final void Function(ParsedTxn item) onDismiss;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: p.surfaceAlt,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: p.borderStrong),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded, size: 16, color: AppColors.amber),
              const SizedBox(width: 6),
              Text(
                'Possible duplicate',
                style: jakarta(
                  size: 12,
                  weight: FontWeight.w700,
                  color: AppColors.amber,
                ),
              ),
            ],
          ),
          Text(
            'Review each one — same amount, day and account.',
            style: jakarta(
              size: 12,
              weight: FontWeight.w500,
              color: p.textTertiary,
            ),
          ),
          const SizedBox(height: 6),
          for (final txn in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${_label(txn)} · ${inr(txn.amountPaise / 100)}',
                      style: jakarta(
                        size: 13,
                        weight: FontWeight.w600,
                        color: p.textPrimary,
                      ),
                    ),
                  ),
                  TextButton(
                    key: ValueKey('keep-${txn.smsId}'),
                    onPressed: () => onConfirmOne(txn),
                    child: Text(
                      'Keep',
                      style: jakarta(
                        size: 13,
                        weight: FontWeight.w600,
                        color: AppColors.teal,
                      ),
                    ),
                  ),
                  IconButton(
                    key: ValueKey('dismiss-${txn.smsId}'),
                    onPressed: () => onDismiss(txn),
                    icon: Icon(
                      Icons.close_rounded,
                      size: 18,
                      color: p.textTertiary,
                    ),
                    tooltip: 'Dismiss',
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Correction view for auto-added rows (spec §5): a mis-parsed auto-add would
/// silently inflate the seasonal signal for up to a year, so every auto-add is
/// surfaced here with a one-tap correction that routes it back to review.
class RecentlyAutoAddedView extends StatelessWidget {
  const RecentlyAutoAddedView({
    super.key,
    required this.items,
    required this.onCorrect,
    this.title = 'Recently auto-added',
  });

  final List<ParsedTxn> items;
  final void Function(ParsedTxn item) onCorrect;
  final String title;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      children: [
        Text(
          title,
          style: jakarta(size: 21, weight: FontWeight.w800, color: p.textPrimary),
        ),
        const SizedBox(height: 12),
        if (items.isEmpty)
          Text(
            'No auto-added transactions yet',
            style: jakarta(
              size: 13,
              weight: FontWeight.w500,
              color: p.textTertiary,
            ),
          ),
        for (final txn in items)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
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
                        _label(txn),
                        style: jakarta(
                          size: 13,
                          weight: FontWeight.w600,
                          color: p.textPrimary,
                        ),
                      ),
                      Text(
                        txn.categoryKey,
                        style: jakarta(
                          size: 12,
                          weight: FontWeight.w500,
                          color: p.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  inr(txn.amountPaise / 100),
                  style: mono(
                    size: 13,
                    weight: FontWeight.w600,
                    color: p.textPrimary,
                  ),
                ),
                TextButton(
                  key: ValueKey('correct-${txn.smsId}'),
                  onPressed: () => onCorrect(txn),
                  child: Text(
                    'Not mine',
                    style: jakarta(
                      size: 13,
                      weight: FontWeight.w600,
                      color: AppColors.pink,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
