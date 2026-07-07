import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_state.dart';
import 'insights.dart';
import 'models.dart';

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
  Timer? _scanTimer;

  @override
  AppState build() {
    ref.onDispose(() => _scanTimer?.cancel());
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

  // ---- Gmail "scan" simulation ---------------------------------------------
  // A later phase replaces this with a real Gmail read-only scan; for now it
  // animates progress and then reveals the seeded dataset.

  void connectGmail() {
    _scanTimer?.cancel();
    state = state.copyWith(stage: 'scanning', scanProgress: 0, scanCount: 0);
    _scanTimer = Timer.periodic(const Duration(milliseconds: 130), (timer) {
      final p = (state.scanProgress + 5).clamp(0, 100);
      final c = (p / 100 * 247).round();
      state = state.copyWith(scanProgress: p, scanCount: c);
      if (p >= 100) {
        timer.cancel();
        Timer(const Duration(milliseconds: 500), () {
          _update(state.copyWith(stage: 'app'));
        });
      }
    });
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
