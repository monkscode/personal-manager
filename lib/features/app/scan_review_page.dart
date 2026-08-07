import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/self_transfer_decision_store.dart';
import '../../data/sms_analysis_snapshot.dart';
import '../../data/sms_models.dart';
import '../../data/transaction_repository.dart';
import '../../data/transactions_notifier.dart';
import '../../services/self_transfer_detector.dart';
import '../../services/sms_live_normalizer.dart';
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
    final transfers = await _loadTransferCandidates(repo);
    if (!mounted) return;
    setState(() {
      _review = review;
      _autoAdded = auto;
      _transferCandidates = transfers;
      _loading = false;
    });
  }

  /// Pairs the user has not answered yet.
  ///
  /// Detection runs over the same lookback the snapshot uses, not over the rows
  /// this scan happened to touch: a transfer's two legs can arrive in different
  /// scans, and a pair with only one leg present is invisible.
  Future<List<SelfTransferCandidate>> _loadTransferCandidates(
    TransactionRepository repo,
  ) async {
    final db = ref.read(smsDatabaseProvider);
    if (db == null) return const [];
    final now = ref.read(analysisClockProvider)();
    final history = await repo.allSince(
      DateTime(now.year, now.month - kAnalysisLookbackMonths, 1),
    );
    final decided = await SelfTransferDecisionStore(db).all();
    return [
      for (final candidate in const SelfTransferDetector().candidates(
        const SmsLiveNormalizer().normalize(history),
      ))
        if (!decided.isDecided(candidate.debit.smsId)) candidate,
    ];
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
    return DefaultTabController(
      length: hasTransfers ? 3 : 2,
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
                ],
              ),
      ),
    );
  }
}
