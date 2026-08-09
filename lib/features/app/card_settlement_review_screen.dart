import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../services/card_settlement_candidates.dart';

/// Asks the user whether payments to a merchant settle a credit-card bill.
///
/// The app used to answer this itself, from a list of names in the source —
/// `cred`, `billdesk`, `cc payment`, `card bill`. That list was wrong in both
/// directions on the owner's device: it had never heard of Cheq Digital and
/// counted Rs.5,35,438 of card payments as ordinary shopping, while `cred`
/// matched `CRED Store` and erased Rs.599 of real purchases.
///
/// Deriving the list instead of hardcoding it was measured too, and is worse: a
/// stationery shop paired with a card acknowledgement once, by coincidence, and
/// became a permanent payment front — taking four real purchases with it.
/// `amazon` is a proper prefix of `amazon pay credit c`. No rule separates
/// these, which is why the question reaches the user.
///
/// The design spec estimated thirteen answers for seven years of the owner's
/// history, four of them "no". Measured against the real corpus, round 1
/// alone proposes 12, not 8, and three further merchants remain open even
/// after the owner's real answers are applied — see
/// `test/card_settlement_corpus_test.dart` and
/// `.superpowers/sdd/2026-08-09-card-settlement-pairing/task-8-report.md`
/// (gitignored, owner-local) for the corpus measurement this correction is
/// based on. The number of questions moved; the point the original sentence
/// existed to make has not — every "no" the owner gives is what stops that
/// merchant being asked about again and is the reason this screen exists at
/// all, not a hardcoded list.
class CardSettlementReviewScreen extends StatelessWidget {
  const CardSettlementReviewScreen({
    super.key,
    required this.candidates,
    required this.onDecide,
  });

  final List<CardSettlementCandidate> candidates;

  /// Called with the merchant and the user's verdict. A `false` is recorded
  /// just as durably as a `true` — it is what stops the merchant being asked
  /// about after every scan, and what keeps its payments counted as spend.
  final void Function(CardSettlementCandidate candidate, bool confirmed)
  onDecide;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    if (candidates.isEmpty) {
      return Center(
        key: const ValueKey('card-settlement-empty'),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'Nothing to review. Every payment app in your history is already '
            'decided.',
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
          'Is this how you pay card bills?',
          style: jakarta(
            size: 21,
            weight: FontWeight.w800,
            color: p.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'A card bill you pay is not new spending — you already counted it '
          'when you made the purchases. Tell us which apps you pay bills '
          'through and those payments stop being counted twice.',
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

  final CardSettlementCandidate candidate;
  final void Function(CardSettlementCandidate candidate, bool confirmed)
  onDecide;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final debit = candidate.debit;

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
                  candidate.displayMerchant,
                  style: jakarta(
                    size: 16,
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
            _evidence(candidate),
            style: jakarta(
              size: 13,
              weight: FontWeight.w500,
              color: p.textSecondary,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  key: ValueKey('card-settlement-yes-${candidate.merchantNorm}'),
                  onPressed: () => onDecide(candidate, true),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.teal,
                    foregroundColor: AppColors.ink,
                    minimumSize: const Size.fromHeight(44),
                  ),
                  child: Text(
                    'Yes, a card bill',
                    style: jakarta(size: 13, weight: FontWeight.w700),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  key: ValueKey('card-settlement-no-${candidate.merchantNorm}'),
                  onPressed: () => onDecide(candidate, false),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: p.textPrimary,
                    side: BorderSide(color: p.border),
                    minimumSize: const Size.fromHeight(44),
                  ),
                  child: Text(
                    'No, a purchase',
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

  /// The evidence behind the question, in the user's own numbers.
  ///
  /// Branches on [CardSettlementCandidate.source], not on whether a card
  /// number is present. `cardLast4` is `ack?.accountLast4`, and the parser
  /// admits a transaction on any 2 of its 5 signals, so a genuinely *paired*
  /// candidate can carry an acknowledgement that never named a card. Branching
  /// on `cardLast4 == null` put those candidates through the adjacent path
  /// instead — discarding the acknowledgement, the strongest evidence this
  /// screen has, and rendering the literal string "null" where `adjacentTo`
  /// would have gone, since a paired candidate has none. A paired candidate
  /// always has a real acknowledgement worth showing, even on the rare case
  /// it cannot say which card; only an adjacent candidate has nothing but a
  /// resemblance to a merchant already confirmed.
  String _evidence(CardSettlementCandidate candidate) {
    final amount = inr(candidate.debit.amountPaise / 100);
    if (candidate.source == CardSettlementCandidateSource.adjacent) {
      return 'You sent $amount to ${candidate.displayMerchant}. You already '
          'pay card bills through "${candidate.adjacentTo}" — is this the '
          'same app?';
    }
    final points = candidate.pointsPaise ?? 0;
    final acknowledged = inr(candidate.ack!.amountPaise / 100);
    final tail = points > 0
        ? ' ${inr(points / 100)} of it came from points.'
        : '';
    final card = candidate.cardLast4;
    return card == null
        ? 'You sent $amount to ${candidate.displayMerchant}. A card confirmed '
              '$acknowledged the same day.$tail'
        : 'You sent $amount to ${candidate.displayMerchant}. Card $card '
              'confirmed $acknowledged the same day.$tail';
  }
}
