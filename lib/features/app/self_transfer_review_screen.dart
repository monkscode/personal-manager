import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../services/self_transfer_detector.dart';

/// Asks the user whether a detected pair is money moving between their own
/// accounts, or a real payment that happens to look like one.
///
/// The question cannot be answered from the SMS. The bank prints the payee's
/// name and nothing else, and the owner's own name appears on both genuine
/// transfers and genuine payments; one detected pair is a coincidence between
/// a card purchase and an unrelated reimbursement of the same amount. So the
/// screen states the evidence it has — the amount, the day, and which account
/// each leg touched — and lets the user decide.
///
/// The UPI note the user wrote when paying is deliberately not shown: banks do
/// not forward it. Measured over the owner's 2,071 messages, no body carries a
/// remark field, and `Info:` holds the bank's own rail description.
class SelfTransferReviewScreen extends StatelessWidget {
  const SelfTransferReviewScreen({
    super.key,
    required this.candidates,
    required this.onDecide,
  });

  final List<SelfTransferCandidate> candidates;

  /// Called with the pair and the user's verdict. A `false` is recorded just as
  /// durably as a `true` — it is what stops the pair being asked about again.
  final void Function(SelfTransferCandidate candidate, bool confirmed) onDecide;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    if (candidates.isEmpty) {
      return Center(
        key: const ValueKey('self-transfer-empty'),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'Nothing to check. No payment this scan looked like a transfer '
            'between your own accounts.',
            textAlign: TextAlign.center,
            style: jakarta(
              size: 13,
              weight: FontWeight.w500,
              color: p.textTertiary,
            ),
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      children: [
        Text(
          'Was this your own account?',
          style: jakarta(
            size: 21,
            weight: FontWeight.w800,
            color: p.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Each of these left one account and the same amount arrived in '
          'another the same day. If it was your own money moving, it should '
          'not count as spending.',
          style: jakarta(
            size: 13,
            weight: FontWeight.w500,
            color: p.textTertiary,
          ),
        ),
        const SizedBox(height: 16),
        for (final candidate in candidates)
          _CandidateCard(candidate: candidate, onDecide: onDecide),
      ],
    );
  }
}

class _CandidateCard extends StatelessWidget {
  const _CandidateCard({required this.candidate, required this.onDecide});

  final SelfTransferCandidate candidate;
  final void Function(SelfTransferCandidate candidate, bool confirmed) onDecide;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final debit = candidate.debit;
    final payee = debit.merchant?.trim();

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: p.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  inr(debit.amountPaise / 100),
                  style: mono(
                    size: 18,
                    weight: FontWeight.w700,
                    color: p.textPrimary,
                  ),
                ),
              ),
              Text(
                debit.txnLocalDate,
                style: jakarta(
                  size: 12,
                  weight: FontWeight.w500,
                  color: p.textTertiary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'A/c ${debit.accountLast4 ?? "?"}  →  '
            'A/c ${candidate.credit.accountLast4 ?? "?"}',
            style: mono(
              size: 13,
              weight: FontWeight.w600,
              color: p.textPrimary,
            ),
          ),
          if (payee != null && payee.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'Paid to $payee',
              style: jakarta(
                size: 12,
                weight: FontWeight.w500,
                color: p.textTertiary,
              ),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  key: ValueKey('self-transfer-yes-${debit.smsId}'),
                  onPressed: () => onDecide(candidate, true),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.teal,
                    foregroundColor: AppColors.ink,
                    minimumSize: const Size.fromHeight(44),
                  ),
                  child: Text(
                    'My own account',
                    style: jakarta(size: 13, weight: FontWeight.w700),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  key: ValueKey('self-transfer-no-${debit.smsId}'),
                  onPressed: () => onDecide(candidate, false),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: p.textPrimary,
                    side: BorderSide(color: p.border),
                    minimumSize: const Size.fromHeight(44),
                  ),
                  child: Text(
                    'A real payment',
                    style: jakarta(size: 13, weight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
