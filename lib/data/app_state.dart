import 'dart:convert';

import 'models.dart';
import 'parsed_bill.dart';

/// The full immutable application state. Mirrors the `state` object of the
/// design prototype's `Component` class. Ephemeral fields (scan progress) are
/// not persisted; everything else round-trips through [toJson]/[fromJson].
class AppState {
  const AppState({
    this.stage = 'onboard',
    this.onboardStep = 0,
    this.tab = 'home',
    this.monthView = 'next',
    this.txFilter = 'all',
    this.scanProgress = 0,
    this.scanCount = 0,
    this.notifOn = true,
    this.manualTx = const [],
    this.manualInvestments = const [],
    this.salary = '85000',
    this.currentBalance = '38000',
    this.nps = const ContribPlan(enabled: true, amount: '5000', frequency: 'monthly', month: 'Feb'),
    this.ppf = const ContribPlan(enabled: true, amount: '100000', frequency: 'lumpsum', month: 'Feb'),
    this.mf = const ContribPlan(enabled: true, amount: '10000', frequency: 'monthly', month: 'Feb'),
    this.fdRoundoffChoice = '',
    this.customPlans = const [],
    this.theme = 'dark',
    this.candidates = const [],
    this.gmailEmail = '',
    this.gmailName = '',
    this.scanError = '',
    this.aiFallbackNote = '',
    this.aiApiKey = '',
    this.aiModel = 'gemini-2.5-flash',
    this.aiEndpoint = 'https://generativelanguage.googleapis.com/v1beta',
    this.aiServiceAccount = '',
    this.aiRegion = 'us-central1',
  });

  final String stage;
  final int onboardStep;
  final String tab;
  final String monthView; // 'current' | 'next'
  final String txFilter;
  final int scanProgress; // 0..100, transient
  final int scanCount; // transient
  final bool notifOn;
  final List<ExpenseEntry> manualTx;
  final List<Investment> manualInvestments;
  final String salary;
  final String currentBalance;
  final ContribPlan nps;
  final ContribPlan ppf;
  final ContribPlan mf;
  final String fdRoundoffChoice; // '' | 'yes' | 'no'
  final List<CustomPlan> customPlans;
  final String theme; // 'dark' | 'light'

  // Gmail scan (transient — not persisted).
  final List<ParsedBill> candidates;
  final String gmailEmail; // '' when not connected via Gmail
  final String gmailName; // '' when not connected via Gmail
  final String scanError; // '' when no error
  final String aiFallbackNote; // '' unless the last scan's AI extraction failed and fell back to rules

  // Optional AI extraction (Gemini/Vertex). Empty key => on-device rules only.
  final String aiApiKey;
  final String aiModel;
  final String aiEndpoint;
  final String aiServiceAccount; // Vertex service-account key JSON (on-device only)
  final String aiRegion; // Vertex region, e.g. us-central1

  bool get isDark => theme != 'light';
  bool get aiEnabled => aiApiKey.trim().isNotEmpty || aiServiceAccount.trim().isNotEmpty;
  bool get isApp => stage == 'app';

  AppState copyWith({
    String? stage,
    int? onboardStep,
    String? tab,
    String? monthView,
    String? txFilter,
    int? scanProgress,
    int? scanCount,
    bool? notifOn,
    List<ExpenseEntry>? manualTx,
    List<Investment>? manualInvestments,
    String? salary,
    String? currentBalance,
    ContribPlan? nps,
    ContribPlan? ppf,
    ContribPlan? mf,
    String? fdRoundoffChoice,
    List<CustomPlan>? customPlans,
    String? theme,
    List<ParsedBill>? candidates,
    String? gmailEmail,
    String? gmailName,
    String? scanError,
    String? aiFallbackNote,
    String? aiApiKey,
    String? aiModel,
    String? aiEndpoint,
    String? aiServiceAccount,
    String? aiRegion,
  }) {
    return AppState(
      stage: stage ?? this.stage,
      onboardStep: onboardStep ?? this.onboardStep,
      tab: tab ?? this.tab,
      monthView: monthView ?? this.monthView,
      txFilter: txFilter ?? this.txFilter,
      scanProgress: scanProgress ?? this.scanProgress,
      scanCount: scanCount ?? this.scanCount,
      notifOn: notifOn ?? this.notifOn,
      manualTx: manualTx ?? this.manualTx,
      manualInvestments: manualInvestments ?? this.manualInvestments,
      salary: salary ?? this.salary,
      currentBalance: currentBalance ?? this.currentBalance,
      nps: nps ?? this.nps,
      ppf: ppf ?? this.ppf,
      mf: mf ?? this.mf,
      fdRoundoffChoice: fdRoundoffChoice ?? this.fdRoundoffChoice,
      customPlans: customPlans ?? this.customPlans,
      theme: theme ?? this.theme,
      candidates: candidates ?? this.candidates,
      gmailEmail: gmailEmail ?? this.gmailEmail,
      gmailName: gmailName ?? this.gmailName,
      scanError: scanError ?? this.scanError,
      aiFallbackNote: aiFallbackNote ?? this.aiFallbackNote,
      aiApiKey: aiApiKey ?? this.aiApiKey,
      aiModel: aiModel ?? this.aiModel,
      aiEndpoint: aiEndpoint ?? this.aiEndpoint,
      aiServiceAccount: aiServiceAccount ?? this.aiServiceAccount,
      aiRegion: aiRegion ?? this.aiRegion,
    );
  }

  Map<String, dynamic> toJson() => {
        'stage': stage,
        'tab': tab,
        'monthView': monthView,
        'notifOn': notifOn,
        'manualTx': manualTx.map((e) => e.toJson()).toList(),
        'manualInvestments': manualInvestments.map((e) => e.toJson()).toList(),
        'salary': salary,
        'currentBalance': currentBalance,
        'nps': nps.toJson(),
        'ppf': ppf.toJson(),
        'mf': mf.toJson(),
        'fdRoundoffChoice': fdRoundoffChoice,
        'customPlans': customPlans.map((e) => e.toJson()).toList(),
        'theme': theme,
        'aiApiKey': aiApiKey,
        'aiModel': aiModel,
        'aiEndpoint': aiEndpoint,
        'aiServiceAccount': aiServiceAccount,
        'aiRegion': aiRegion,
      };

  factory AppState.fromJson(Map<String, dynamic> j) {
    List<T> parseList<T>(String key, T Function(Map<String, dynamic>) f) =>
        ((j[key] as List?) ?? const [])
            .map((e) => f(e as Map<String, dynamic>))
            .toList();
    // A returning user with saved data resumes straight into the app.
    final savedStage = j['stage'] as String? ?? 'onboard';
    return AppState(
      stage: savedStage == 'scanning' ? 'app' : savedStage,
      tab: j['tab'] as String? ?? 'home',
      monthView: j['monthView'] as String? ?? 'next',
      notifOn: j['notifOn'] as bool? ?? true,
      manualTx: parseList('manualTx', ExpenseEntry.fromJson),
      manualInvestments: parseList('manualInvestments', Investment.fromJson),
      salary: j['salary'] as String? ?? '85000',
      currentBalance: j['currentBalance'] as String? ?? '38000',
      nps: j['nps'] != null ? ContribPlan.fromJson(j['nps'] as Map<String, dynamic>) : const ContribPlan(enabled: true, amount: '5000', frequency: 'monthly', month: 'Feb'),
      ppf: j['ppf'] != null ? ContribPlan.fromJson(j['ppf'] as Map<String, dynamic>) : const ContribPlan(enabled: true, amount: '100000', frequency: 'lumpsum', month: 'Feb'),
      mf: j['mf'] != null ? ContribPlan.fromJson(j['mf'] as Map<String, dynamic>) : const ContribPlan(enabled: true, amount: '10000', frequency: 'monthly', month: 'Feb'),
      fdRoundoffChoice: j['fdRoundoffChoice'] as String? ?? '',
      customPlans: parseList('customPlans', CustomPlan.fromJson),
      theme: j['theme'] as String? ?? 'dark',
      aiApiKey: j['aiApiKey'] as String? ?? '',
      aiModel: j['aiModel'] as String? ?? 'gemini-2.5-flash',
      aiEndpoint: j['aiEndpoint'] as String? ?? 'https://generativelanguage.googleapis.com/v1beta',
      aiServiceAccount: j['aiServiceAccount'] as String? ?? '',
      aiRegion: j['aiRegion'] as String? ?? 'us-central1',
    );
  }

  String encode() => jsonEncode(toJson());

  static AppState decode(String source) =>
      AppState.fromJson(jsonDecode(source) as Map<String, dynamic>);
}
