import 'package:expense_insight/core/theme.dart';
import 'package:expense_insight/data/app_controller.dart';
import 'package:expense_insight/data/app_state.dart';
import 'package:expense_insight/data/models.dart';
import 'package:expense_insight/data/parsed_bill.dart';
import 'package:expense_insight/data/transactions_notifier.dart';
import 'package:expense_insight/services/gmail_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class _FakeGmailScanClient implements GmailScanClient {
  _FakeGmailScanClient({this.result, this.error});

  final GmailScanResult? result;
  final GmailScanException? error;
  int disconnectCalls = 0;

  @override
  Future<GmailScanResult> scan({
    void Function(int done, int total)? onProgress,
    Future<List<ParsedBill>> Function(List<RawEmail>)? aiExtract,
    void Function(String message)? onAiFallback,
  }) async {
    if (error case final error?) throw error;
    onProgress?.call(result!.scanned, result!.scanned);
    return result!;
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
  }
}

const _expense = ExpenseEntry(
  name: 'Rent',
  category: 'Housing',
  categoryKey: 'housing',
  amount: 18000,
  initial: 'RE',
  color: AppColors.blue,
  recurrence: 'monthly',
);

Future<(ProviderContainer, SharedPreferences)> _container(
  _FakeGmailScanClient gmail,
) async {
  final original = const AppState().copyWith(
    stage: 'app',
    tab: 'profile',
    salary: '123456',
    currentBalance: '654321',
    manualTx: const [_expense],
  );
  SharedPreferences.setMockInitialValues({
    'expense_insight_state_v1': original.encode(),
  });
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      sharedPrefsProvider.overrideWithValue(prefs),
      gmailScanClientProvider.overrideWithValue(gmail),
      analysisClockProvider.overrideWithValue(
        () => DateTime.utc(2026, 7, 21, 12, 30),
      ),
    ],
  );
  addTearDown(container.dispose);
  return (container, prefs);
}

void main() {
  group('formatAiUsageNote', () {
    test('reports full AI utilization', () {
      expect(
        formatAiUsageNote(aiProcessedEmails: 20, localFallbackEmails: 0),
        'AI analyzed 20 emails for this sync.',
      );
    });

    test('reports hybrid AI and local utilization', () {
      expect(
        formatAiUsageNote(aiProcessedEmails: 15, localFallbackEmails: 5),
        'AI analyzed 15 emails; on-device extraction completed 5 emails that AI could not process.',
      );
    });

    test('reports all-local completion without failure wording', () {
      final note = formatAiUsageNote(
        aiProcessedEmails: 0,
        localFallbackEmails: 20,
      );
      expect(
        note,
        'AI was unavailable for 20 emails; on-device extraction completed them.',
      );
      expect(note.toLowerCase(), isNot(contains('failed')));
    });
  });

  test(
    'Profile resync persists Gmail metadata without losing financial data',
    () async {
      final gmail = _FakeGmailScanClient(
        result: const GmailScanResult(
          account: GmailAccount(email: 'person@example.com', name: 'Person'),
          candidates: [],
          scanned: 42,
        ),
      );
      final (container, prefs) = await _container(gmail);

      await container.read(appControllerProvider.notifier).syncGmail();

      final synced = container.read(appControllerProvider);
      expect(synced.stage, 'review');
      expect(synced.tab, 'profile');
      expect(synced.gmailEmail, 'person@example.com');
      expect(synced.gmailName, 'Person');
      expect(synced.gmailLastFetchedCount, 42);
      expect(synced.gmailLastSyncedAt, DateTime.utc(2026, 7, 21, 12, 30));
      expect(synced.salary, '123456');
      expect(synced.currentBalance, '654321');
      expect(synced.manualTx, hasLength(1));
      expect(synced.manualTx.single.name, _expense.name);
      expect(synced.manualTx.single.amount, _expense.amount);

      final persisted = AppState.decode(
        prefs.getString('expense_insight_state_v1')!,
      );
      expect(persisted.gmailEmail, 'person@example.com');
      expect(persisted.gmailLastFetchedCount, 42);
      expect(persisted.manualTx, hasLength(1));
    },
  );

  test(
    'failed Profile resync returns to Profile with financial data intact',
    () async {
      final gmail = _FakeGmailScanClient(
        error: const GmailScanException(
          GmailFailure.network,
          'Could not read Gmail.',
        ),
      );
      final (container, _) = await _container(gmail);

      await container.read(appControllerProvider.notifier).syncGmail();

      final failed = container.read(appControllerProvider);
      expect(failed.stage, 'app');
      expect(failed.tab, 'profile');
      expect(failed.scanError, 'Could not read Gmail.');
      expect(failed.salary, '123456');
      expect(failed.currentBalance, '654321');
      expect(failed.manualTx, hasLength(1));
      expect(failed.manualTx.single.name, _expense.name);
      expect(failed.manualTx.single.amount, _expense.amount);
    },
  );
}
