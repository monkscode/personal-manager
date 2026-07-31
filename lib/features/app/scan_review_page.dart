import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/sms_models.dart';
import '../../data/transaction_repository.dart';
import '../../data/transactions_notifier.dart';
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
    if (!mounted) return;
    setState(() {
      _review = review;
      _autoAdded = auto;
      _loading = false;
    });
  }

  Future<void> _confirm(List<ParsedTxn> confirmed) async {
    final repo = _repo;
    if (repo != null) {
      for (final txn in confirmed) {
        await repo.updateReviewStatus(txn.smsId, ReviewStatus.confirmed);
      }
      await ref.read(transactionsNotifierProvider.notifier).reload();
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _dismiss(ParsedTxn txn) async {
    final repo = _repo;
    if (repo != null) {
      await repo.updateReviewStatus(txn.smsId, ReviewStatus.dismissed);
      await ref.read(transactionsNotifierProvider.notifier).reload();
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return DefaultTabController(
      length: 2,
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
            tabs: const [
              Tab(text: 'Review'),
              Tab(text: 'Auto-added'),
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
                ],
              ),
      ),
    );
  }
}
