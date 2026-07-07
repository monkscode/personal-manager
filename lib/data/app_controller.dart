import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/ai_resolver.dart';
import '../services/gmail_service.dart';
import 'app_state.dart';
import 'insights.dart';
import 'models.dart';
import 'parsed_bill.dart';
import 'seed_data.dart';

const _prefsKey = 'expense_insight_state_v1';

/// Overridden in `main()` with the resolved [SharedPreferences] instance.
final sharedPrefsProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('sharedPrefsProvider must be overridden'),
);

final appControllerProvider =
    NotifierProvider<AppController, AppState>(AppController.new);

/// Derived forecast/insights, recomputed whenever [AppState] changes.
final insightsProvider = Provider<Insights>(
  (ref) => Insights.compute(ref.watch(appControllerProvider)),
);

class AppController extends Notifier<AppState> {
  final GmailService _gmail = GmailService();

  @override
  AppState build() {
    final prefs = ref.read(sharedPrefsProvider);
    final saved = prefs.getString(_prefsKey);
    if (saved != null) {
      try {
        return AppState.decode(saved);
      } catch (_) {
        // Corrupt/legacy payload — fall through to a fresh state.
      }
    }
    return const AppState();
  }

  /// Update state and persist the durable fields.
  void _update(AppState next) {
    state = next;
    ref.read(sharedPrefsProvider).setString(_prefsKey, next.encode());
  }

  // ---- Onboarding & navigation ---------------------------------------------

  void nextOnboard() {
    if (state.onboardStep < 2) {
      _update(state.copyWith(onboardStep: state.onboardStep + 1));
    } else {
      _update(state.copyWith(stage: 'privacy'));
    }
  }

  void skipToApp() => _update(state.copyWith(stage: 'app', tab: 'home'));
  void goIncome() => _update(state.copyWith(stage: 'income'));
  void goInvestPlan() => _update(state.copyWith(stage: 'investPlan'));
  void goConnect() => _update(state.copyWith(stage: 'connect'));
  void goInsights() => _update(state.copyWith(stage: 'app', tab: 'insights'));
  void goInvestments() => _update(state.copyWith(stage: 'app', tab: 'investments'));

  void setTab(String tab) => _update(state.copyWith(tab: tab));
  void setMonthView(String view) => _update(state.copyWith(monthView: view));
  void setTxFilter(String filter) => _update(state.copyWith(txFilter: filter));
  void toggleNotif() => _update(state.copyWith(notifOn: !state.notifOn));
  void setTheme(String theme) => _update(state.copyWith(theme: theme));

  // ---- Optional AI extraction settings -------------------------------------
  void setAiApiKey(String v) => _update(state.copyWith(aiApiKey: v));
  void setAiModel(String v) => _update(state.copyWith(aiModel: v));
  void setAiEndpoint(String v) => _update(state.copyWith(aiEndpoint: v));
  void setAiServiceAccount(String v) => _update(state.copyWith(aiServiceAccount: v));
  void setAiRegion(String v) => _update(state.copyWith(aiRegion: v));
  void setGmailServerClientId(String v) => _update(state.copyWith(gmailServerClientId: v));

  // ---- Real on-device Gmail scan -------------------------------------------
  // Reads Gmail read-only on the device, parses bills locally, and moves to the
  // review stage. Nothing leaves the phone. Errors fall back to the connect
  // screen with a message; "Use sample data" remains available.

  Future<void> connectGmail() async {
    state = state.copyWith(stage: 'scanning', scanProgress: 0, scanCount: 0, scanError: '');

    // If the user configured an AI key, use Gemini for extraction; otherwise the
    // service falls back to the on-device rule parser.
    final model = state.aiModel.trim().isEmpty ? 'gemini-2.5-flash' : state.aiModel.trim();
    Future<List<ParsedBill>> Function(List<RawEmail>)? aiExtract;
    if (state.aiServiceAccount.trim().isNotEmpty) {
      // Vertex AI via a service-account key (credentials.json).
      aiExtract = VertexResolver(
        serviceAccountJson: state.aiServiceAccount.trim(),
        region: state.aiRegion.trim().isEmpty ? 'us-central1' : state.aiRegion.trim(),
        model: model,
      ).extract;
    } else if (state.aiApiKey.trim().isNotEmpty) {
      // Gemini / Vertex Express via an API key.
      aiExtract = GeminiResolver(
        apiKey: state.aiApiKey.trim(),
        model: model,
        endpointBase: state.aiEndpoint.trim().isEmpty
            ? 'https://generativelanguage.googleapis.com/v1beta'
            : state.aiEndpoint.trim(),
      ).extract;
    }

    try {
      final result = await _gmail.scan(
        aiExtract: aiExtract,
        serverClientId: state.gmailServerClientId,
        onProgress: (done, total) {
          final pct = total == 0 ? 100 : (done / total * 100).round();
          state = state.copyWith(scanProgress: pct.clamp(0, 100), scanCount: done);
        },
      );
      _update(state.copyWith(
        stage: 'review',
        candidates: result.candidates,
        gmailEmail: result.account.email,
        scanProgress: 100,
        scanCount: result.scanned,
      ));
    } on GmailScanException catch (e) {
      // Cancellation returns quietly; real failures surface a message.
      state = state.copyWith(
        stage: 'connect',
        scanError: e.failure == GmailFailure.cancelled ? '' : e.message,
      );
    } catch (e) {
      state = state.copyWith(stage: 'connect', scanError: 'Something went wrong: $e');
    }
  }

  /// Turn the confirmed candidates into obligations and enter the app.
  void confirmCandidates(List<ParsedBill> selected) {
    final entries = selected.map(_toExpense).toList();
    _update(state.copyWith(
      manualTx: [...entries, ...state.manualTx],
      candidates: const [],
      stage: 'app',
      tab: 'home',
    ));
  }

  void skipReview() =>
      _update(state.copyWith(stage: 'app', tab: 'home', candidates: const []));

  /// Disconnects Gmail and returns to onboarding so the user can start over.
  void signOut() {
    _gmail.disconnect();
    _update(state.copyWith(
      stage: 'onboard',
      onboardStep: 0,
      gmailEmail: '',
      candidates: const [],
      scanError: '',
    ));
  }

  ExpenseEntry _toExpense(ParsedBill b) {
    final cat = kCatsNext.firstWhere((c) => c.key == b.categoryKey,
        orElse: () => kCatsNext.firstWhere((c) => c.key == 'other'));
    final name = b.merchant.trim().isEmpty ? 'Bill' : b.merchant.trim();
    return ExpenseEntry(
      name: name,
      category: cat.name,
      categoryKey: cat.key,
      amount: b.amount,
      initial: name.substring(0, name.length >= 2 ? 2 : name.length).toUpperCase(),
      color: cat.color,
      recurring: b.isRecurring,
    );
  }

  // ---- Income & investment plan --------------------------------------------

  void setSalary(String v) => _update(state.copyWith(salary: v));
  void setCurrentBalance(String v) => _update(state.copyWith(currentBalance: v));

  void setNps(ContribPlan plan) => _update(state.copyWith(nps: plan));
  void setPpf(ContribPlan plan) => _update(state.copyWith(ppf: plan));
  void setMf(ContribPlan plan) => _update(state.copyWith(mf: plan));

  void setFdRoundoff(String choice) => _update(state.copyWith(fdRoundoffChoice: choice));

  void addCustomPlan(CustomPlan plan) =>
      _update(state.copyWith(customPlans: [...state.customPlans, plan]));

  void removeCustomPlan(String id) => _update(
      state.copyWith(customPlans: state.customPlans.where((p) => p.id != id).toList()));

  // ---- Manual entries -------------------------------------------------------

  void addExpense(ExpenseEntry entry) =>
      _update(state.copyWith(manualTx: [entry, ...state.manualTx], stage: 'app'));

  void addInvestment(Investment inv) => _update(
      state.copyWith(manualInvestments: [inv, ...state.manualInvestments], stage: 'app'));
}
