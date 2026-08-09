import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/self_transfer_decision_store.dart';
import '../../data/sms_models.dart';
import '../../data/transaction_repository.dart';
import '../../data/transactions_notifier.dart';
import '../../services/card_settlement_candidates.dart';
import '../../services/self_transfer_detector.dart';
import 'card_settlement_review_screen.dart';
import 'self_transfer_review_screen.dart';
import 'sms_review_screen.dart';

/// The post-scan destination: a two-tab page hosting the review queue
/// ([SmsReviewScreen]) and the recently-auto-added audit
/// ([RecentlyAutoAddedView]). Reads the just-persisted rows from the database
/// and writes review decisions back, reloading the snapshot on confirm.
class ScanReviewPage extends ConsumerStatefulWidget {
  const ScanReviewPage({super.key});

  @override
  ConsumerState<ScanReviewPage> createState() => _ScanReviewPageState();
}

class _ScanReviewPageState extends ConsumerState<ScanReviewPage> {
  List<ParsedTxn> _review = const [];
  List<ParsedTxn> _autoAdded = const [];
  List<SelfTransferCandidate> _transferCandidates = const [];
  List<CardSettlementCandidate> _settlementCandidates = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  TransactionRepository? get _repo {
    final db = ref.read(smsDatabaseProvider);
    return db == null ? null : TransactionRepository(db);
  }

  Future<void> _load() async {
    final repo = _repo;
    if (repo == null) {
      setState(() => _loading = false);
      return;
    }
    final review = await repo.queryByReviewStatus(ReviewStatus.needsReview);
    final auto = await repo.recentlyAutoAdded();
    // Candidates come off the cached snapshot, which already detected them over
    // the normalized history. Re-reading deep history here would be a second
    // pass over the same rows for the same answer.
    final snapshot = await ref.read(transactionsNotifierProvider.future);
    final transfers = snapshot.selfTransferCandidates;
    final settlements = snapshot.settlementCandidates;
    if (!mounted) return;
    setState(() {
      _review = review;
      _autoAdded = auto;
      _transferCandidates = transfers;
      _settlementCandidates = settlements;
      _loading = false;
    });
  }

  Future<void> _decideTransfer(
    SelfTransferCandidate candidate,
    bool confirmed,
  ) async {
    final db = ref.read(smsDatabaseProvider);
    if (db == null) return;
    await SelfTransferDecisionStore(db).record(
      debitSmsId: candidate.debit.smsId,
      creditSmsId: candidate.credit.smsId,
      confirmed: confirmed,
    );
    await ref.read(transactionsNotifierProvider.notifier).reload();
    await _load();
  }

  Future<void> _decideSettlement(
    CardSettlementCandidate candidate,
    bool confirmed,
  ) async {
    await ref
        .read(transactionsNotifierProvider.notifier)
        .recordSettlementFront(
          merchantNorm: candidate.merchantNorm,
          confirmed: confirmed,
          exampleDebitSmsId: candidate.debit.smsId,
          exampleAckSmsId: candidate.ack?.smsId,
        );
    await _load();
  }

  Future<void> _confirm(List<ParsedTxn> confirmed) async {
    final repo = _repo;
    if (repo != null) {
      for (final txn in confirmed) {
        // The reason the row needed review no longer applies once the user has
        // confirmed it. Passed explicitly, because omitting it now preserves
        // the stored reason (TASK-27 M5).
        await repo.updateReviewStatus(
          txn.smsId,
          ReviewStatus.confirmed,
          reviewReason: null,
        );
      }
      await ref.read(transactionsNotifierProvider.notifier).reload();
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _dismiss(ParsedTxn txn) async {
    final repo = _repo;
    if (repo != null) {
      await repo.updateReviewStatus(
        txn.smsId,
        ReviewStatus.dismissed,
        reviewReason: null,
      );
      await ref.read(transactionsNotifierProvider.notifier).reload();
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    // The transfers tab appears only when there is something to ask. Candidates
    // are rare — four in six years of the owner's messages — so a permanently
    // empty third tab would be noise on every scan.
    final hasTransfers = _transferCandidates.isNotEmpty;
    final hasSettlements = _settlementCandidates.isNotEmpty;
    final tabCount = 2 + (hasTransfers ? 1 : 0) + (hasSettlements ? 1 : 0);
    return DefaultTabController(
      length: tabCount,
      child: Scaffold(
        backgroundColor: p.bg,
        appBar: AppBar(
          backgroundColor: p.bg,
          elevation: 0,
          iconTheme: IconThemeData(color: p.textPrimary),
          title: Text('Scan results',
              style: jakarta(size: 16, weight: FontWeight.w800, color: p.textPrimary)),
          bottom: TabBar(
            labelColor: AppColors.teal,
            unselectedLabelColor: p.textTertiary,
            indicatorColor: AppColors.teal,
            labelStyle: jakarta(size: 13, weight: FontWeight.w700),
            tabs: [
              const Tab(text: 'Review'),
              const Tab(text: 'Auto-added'),
              if (hasTransfers) const Tab(text: 'Transfers'),
              if (hasSettlements) const Tab(text: 'Card bills'),
            ],
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                children: [
                  SmsReviewScreen(
                    items: _review,
                    onConfirmSelected: _confirm,
                    onDismiss: _dismiss,
                  ),
                  RecentlyAutoAddedView(
                    items: _autoAdded,
                    onCorrect: _dismiss,
                  ),
                  if (hasTransfers)
                    SelfTransferReviewScreen(
                      candidates: _transferCandidates,
                      onDecide: _decideTransfer,
                    ),
                  if (hasSettlements)
                    CardSettlementReviewScreen(
                      candidates: _settlementCandidates,
                      onDecide: _decideSettlement,
                    ),
                ],
              ),
      ),
    );
  }
}
