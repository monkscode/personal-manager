import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/app_controller.dart';
import '../../data/insights.dart';
import '../../data/scan_controller.dart';
import '../../data/sms_models.dart';
import '../../data/transactions_notifier.dart';
import '../../widgets/ui.dart';
import 'about_sheet.dart';
import 'scan_review_page.dart';
import 'why_log_screen.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final s = ref.watch(appControllerProvider);
    final monthView = s.monthView;
    final i = ref.watch(insightsProvider);
    final ctrl = ref.read(appControllerProvider.notifier);
    final connected = s.gmailEmail.isNotEmpty;
    final name = connected && s.gmailName.isNotEmpty
        ? s.gmailName
        : (connected ? 'Gmail user' : 'Your finances');
    final avatarLabel = initials(name).isEmpty ? '—' : initials(name);
    final liveForecast = i.forecastHeadline.isNotEmpty;
    final hasFinancialData = s.hasFinancialData || liveForecast;

    if (!hasFinancialData) {
      return _emptyHome(context, ref, name, avatarLabel, connected, ctrl);
    }

    return RefreshIndicator(
      onRefresh: () => _refreshFromSms(context, ref),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
        children: [
          // Header
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Welcome back',
                      style: jakarta(
                        size: 12,
                        weight: FontWeight.w600,
                        color: p.textTertiary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      name,
                      style: jakarta(
                        size: 21,
                        weight: FontWeight.w800,
                        color: p.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: () => showAboutSheet(context),
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: p.surface,
                    shape: BoxShape.circle,
                    border: Border.all(color: p.border),
                  ),
                  child: Icon(
                    Icons.info_outline_rounded,
                    size: 16,
                    color: p.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: AppColors.teal.withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  avatarLabel,
                  style: jakarta(
                    size: 14,
                    weight: FontWeight.w700,
                    color: AppColors.teal,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          // Sync chip
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: p.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: p.border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: connected || liveForecast
                          ? AppColors.green
                          : p.textTertiary,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    connected
                        ? 'Connected · Gmail'
                        : (liveForecast
                              ? 'Live · your messages'
                              : (s.manualTx.isNotEmpty
                                    ? 'Live · your entries'
                                    : 'Live · your data')),
                    style: jakarta(
                      size: 12,
                      weight: FontWeight.w600,
                      color: p.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          // Live-mode: embedded forecast explorer replaces old recommendation,
          // hero, and balance-check surfaces; sample/manual path unchanged.
          if (i.forecastExplorer != null) ...[
            _spendSummaryCard(context, i, ctrl),
            const SizedBox(height: 20),
            if (i.recentTx.isNotEmpty) ...[
              _recentTransactions(context, i, ctrl),
              const SizedBox(height: 20),
            ],
          ] else ...[
            // Live-mode forecast recommendation (dated headline + salary strip +
            // anchor provenance + freshness + See why).
            if (liveForecast) ...[
              _recommendationCard(context, i),
              const SizedBox(height: 20),
            ],
            // Hero card
            Surface(
              radius: 22,
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SegmentedToggle(
                    labels: const ['This month', 'Next month'],
                    selectedIndex: monthView == 'current' ? 0 : 1,
                    onChanged: (idx) =>
                        ctrl.setMonthView(idx == 0 ? 'current' : 'next'),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    i.heroLabel,
                    style: jakarta(
                      size: 12,
                      weight: FontWeight.w600,
                      color: p.textTertiary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    i.heroAmount,
                    style: mono(
                      size: 38,
                      weight: FontWeight.w800,
                      color: p.textPrimary,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    i.heroSubText,
                    style: jakarta(
                      size: 13,
                      weight: FontWeight.w600,
                      color: i.heroSubColor,
                    ),
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    height: 82,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      spacing: 6,
                      children: [
                        for (final bar in i.heroTrendBars)
                          ChartBar(
                            height: bar.height,
                            color: bar.color,
                            label: bar.label,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            // Balance check
            _balanceCheck(context, i),
            const SizedBox(height: 20),
          ],
          // Insight cards driven by computed alerts.
          for (final a in i.alerts.take(2)) ...[
            _insightCard(
              context,
              bg: a.bg,
              border: a.border,
              icon: a.isAlert
                  ? Icons.notifications_active_outlined
                  : Icons.trending_up_rounded,
              iconColor: a.iconColor,
              onTap: ctrl.goInsights,
              spans: [_t(context, a.text)],
            ),
            const SizedBox(height: 12),
          ],
          const SizedBox(height: 8),
          // Upcoming bills
          Text(
            'Upcoming bills',
            style: jakarta(
              size: 15,
              weight: FontWeight.w700,
              color: p.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          for (final b in i.upcomingBills)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: p.border)),
              ),
              child: Row(
                children: [
                  _initialBadge(b.initial, b.color, b.bgColor, radius: 11),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          b.name,
                          style: jakarta(
                            size: 13,
                            weight: FontWeight.w600,
                            color: p.textPrimary,
                          ),
                        ),
                        Text(
                          b.due,
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
                    b.amount,
                    style: mono(
                      size: 13,
                      weight: FontWeight.w600,
                      color: p.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          if (i.upcomingBills.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Row(
                children: [
                  Icon(
                    Icons.event_available_outlined,
                    size: 18,
                    color: p.textTertiary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'No bills, card payments, or recurring debits are coming up. New ones appear here as we detect them.',
                      style: jakarta(
                        size: 12,
                        weight: FontWeight.w500,
                        height: 1.5,
                        color: p.textTertiary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _emptyHome(
    BuildContext context,
    WidgetRef ref,
    String name,
    String avatarLabel,
    bool connected,
    AppController ctrl,
  ) {
    final p = context.palette;
    return RefreshIndicator(
      onRefresh: () => _refreshFromSms(context, ref),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Welcome',
                      style: jakarta(
                        size: 12,
                        weight: FontWeight.w600,
                        color: p.textTertiary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      name,
                      style: jakarta(
                        size: 21,
                        weight: FontWeight.w800,
                        color: p.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: AppColors.teal.withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  avatarLabel,
                  style: jakarta(
                    size: 14,
                    weight: FontWeight.w700,
                    color: AppColors.teal,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Surface(
            radius: 20,
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Icon(
                  Icons.account_balance_wallet_outlined,
                  size: 32,
                  color: p.textSecondary,
                ),
                const SizedBox(height: 14),
                Text(
                  'No financial data yet',
                  style: jakarta(
                    size: 17,
                    weight: FontWeight.w800,
                    color: p.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  connected
                      ? 'Sync Gmail or scan messages to build your forecast.'
                      : 'Add your details, connect Gmail, or scan messages to build your forecast.',
                  textAlign: TextAlign.center,
                  style: jakarta(
                    size: 13,
                    weight: FontWeight.w500,
                    height: 1.5,
                    color: p.textSecondary,
                  ),
                ),
                const SizedBox(height: 16),
                PrimaryButton(
                  label: connected ? 'Sync Gmail' : 'Connect Gmail',
                  onTap: ctrl.syncGmail,
                  icon: const Icon(
                    Icons.mail_outline_rounded,
                    size: 18,
                    color: AppColors.ink,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _recommendationCard(BuildContext context, Insights i) {
    final p = context.palette;
    Widget stripCell(String label, String value, Color valueColor) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: jakarta(
            size: 11,
            weight: FontWeight.w600,
            color: p.textTertiary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: mono(size: 15, weight: FontWeight.w800, color: valueColor),
        ),
      ],
    );
    final divider = Container(width: 1, height: 30, color: p.border);
    return Surface(
      radius: 22,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome_rounded, size: 16, color: AppColors.teal),
              const SizedBox(width: 8),
              Text(
                'Your forecast',
                style: jakarta(
                  size: 12,
                  weight: FontWeight.w600,
                  color: p.textTertiary,
                ),
              ),
              const Spacer(),
              _freshnessChip(context, i),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            i.forecastHeadline,
            style: jakarta(
              size: 18,
              weight: FontWeight.w800,
              height: 1.4,
              color: p.textPrimary,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: stripCell('Committed', i.salaryCommitted, p.textPrimary),
              ),
              divider,
              Expanded(
                child: stripCell('Expected', i.salaryExpected, AppColors.green),
              ),
              divider,
              Expanded(child: stripCell('Free', i.salaryFree, AppColors.teal)),
            ],
          ),
          const SizedBox(height: 16),
          Container(height: 1, color: p.border),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(
                Icons.account_balance_wallet_outlined,
                size: 14,
                color: p.textTertiary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  i.anchorAsOfLabel,
                  style: jakarta(
                    size: 12,
                    weight: FontWeight.w500,
                    color: p.textTertiary,
                  ),
                ),
              ),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => WhyLogScreen(
                      lines: i.forecastLines,
                      forwardEarmarks: i.forwardEarmarks,
                      coverageLines: i.coverageLines,
                      monthLabel: i.breakdownMonthLabel,
                    ),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'See why',
                      style: jakarta(
                        size: 12,
                        weight: FontWeight.w700,
                        color: AppColors.teal,
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 16,
                      color: AppColors.teal,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _freshnessChip(BuildContext context, Insights i) {
    final provisional = i.anchorProvisional;
    final color = provisional ? AppColors.amber : AppColors.green;
    final label = provisional
        ? (i.anchorConfirmLabel.isEmpty
              ? 'Confirm balance'
              : i.anchorConfirmLabel)
        : 'Up to date';
    final icon = provisional
        ? Icons.error_outline_rounded
        : Icons.check_circle_outline_rounded;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: jakarta(size: 11, weight: FontWeight.w700, color: color),
          ),
        ],
      ),
    );
  }

  Widget _balanceCheck(BuildContext context, Insights i) {
    final p = context.palette;
    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: jakarta(
              size: 12,
              weight: FontWeight.w500,
              color: p.textSecondary,
            ),
          ),
          Text(
            value,
            style: mono(
              size: 12,
              weight: FontWeight.w600,
              color: p.textPrimary,
            ),
          ),
        ],
      ),
    );
    return Surface(
      radius: 20,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Balance check · ${i.balanceCheckLabel}',
            style: jakarta(
              size: 13,
              weight: FontWeight.w700,
              color: p.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          row('Available by then', i.balanceAvailable),
          row('Required spend', i.balanceRequired),
          const SizedBox(height: 4),
          Container(height: 1, color: p.border),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                i.balanceResultLabel,
                style: jakarta(
                  size: 13,
                  weight: FontWeight.w700,
                  color: i.balanceResultColor,
                ),
              ),
              Text(
                i.balanceResultAmount,
                style: mono(
                  size: 20,
                  weight: FontWeight.w800,
                  color: i.balanceResultColor,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _insightCard(
    BuildContext context, {
    required Color bg,
    required Color border,
    required IconData icon,
    required Color iconColor,
    required VoidCallback onTap,
    required List<InlineSpan> spans,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: border),
        ),
        child: Row(
          children: [
            Icon(icon, size: 22, color: iconColor),
            const SizedBox(width: 12),
            Expanded(child: Text.rich(TextSpan(children: spans))),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right_rounded, size: 18, color: iconColor),
          ],
        ),
      ),
    );
  }

  InlineSpan _t(BuildContext context, String text) => TextSpan(
    text: text,
    style: jakarta(
      size: 13,
      weight: FontWeight.w600,
      height: 1.5,
      color: context.palette.textPrimary,
    ),
  );

  // Spent-this-month (actual) alongside next month's projected need — the two
  // numbers the user most wants at a glance.
  Widget _spendSummaryCard(BuildContext context, Insights i, AppController ctrl) {
    final p = context.palette;
    Widget cell({
      required String label,
      required String value,
      required Color valueColor,
      required String caption,
      double valueSize = 30,
      Color? captionColor,
    }) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: jakarta(
            size: 12,
            weight: FontWeight.w600,
            color: p.textTertiary,
          ),
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: mono(
                size: valueSize,
                weight: FontWeight.w800,
                color: valueColor,
                letterSpacing: -0.5,
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          caption,
          style: jakarta(
            size: 11,
            weight: FontWeight.w600,
            color: captionColor ?? p.textTertiary,
          ),
        ),
      ],
    );
    return Surface(
      radius: 22,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: cell(
                    label: 'Spent this month',
                    value: i.spentThisMonthLabel,
                    valueColor: p.textPrimary,
                    caption:
                        '${i.spentThisMonthCount} payment${i.spentThisMonthCount == 1 ? '' : 's'} tracked',
                  ),
                ),
                const SizedBox(width: 16),
                Container(width: 1, color: p.border),
                const SizedBox(width: 16),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: ctrl.goInsights,
                    child: cell(
                      label: 'Need for ${i.nextMonthLabel}',
                      value: i.nextMonthNeedLabel,
                      valueColor: AppColors.teal,
                      caption: 'Tap to see how \u203a',
                      captionColor: AppColors.teal,
                      valueSize: 24,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (i.spendTrendBars.isNotEmpty) ...[
            const SizedBox(height: 20),
            Divider(color: p.border, height: 1),
            const SizedBox(height: 16),
            Row(
              children: [
                Text(
                  'Monthly spend',
                  style: jakarta(
                    size: 12,
                    weight: FontWeight.w600,
                    color: p.textTertiary,
                  ),
                ),
                const Spacer(),
                _legendDot(AppColors.amber, 'Spent'),
                const SizedBox(width: 12),
                _legendDot(AppColors.teal, 'Projected'),
              ],
            ),
            const SizedBox(height: 14),
            SizedBox(
              height: 108,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                spacing: 10,
                children: [
                  for (final bar in i.spendTrendBars)
                    ChartBar(
                      height: bar.height,
                      color: bar.color,
                      label: bar.label,
                      tag: bar.tag,
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _legendDot(Color color, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 5),
      Builder(
        builder: (context) => Text(
          label,
          style: jakarta(
            size: 10,
            weight: FontWeight.w600,
            color: context.palette.textTertiary,
          ),
        ),
      ),
    ],
  );

  // Finart-style recent transactions with readable names and categories.
  Widget _recentTransactions(
    BuildContext context,
    Insights i,
    AppController ctrl,
  ) {
    final p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Recent transactions',
              style: jakarta(
                size: 15,
                weight: FontWeight.w700,
                color: p.textPrimary,
              ),
            ),
            GestureDetector(
              onTap: () => ctrl.setTab('transactions'),
              child: Text(
                'View all',
                style: jakarta(
                  size: 12,
                  weight: FontWeight.w600,
                  color: AppColors.teal,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        for (final tx in i.recentTx)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 11),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: p.border)),
            ),
            child: Row(
              children: [
                _initialBadge(tx.initial, tx.color, tx.bgColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tx.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: jakarta(
                          size: 13,
                          weight: FontWeight.w600,
                          color: p.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        tx.date.isEmpty
                            ? tx.category
                            : '${tx.category} · ${tx.date}',
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
                  tx.amount,
                  style: mono(
                    size: 13,
                    weight: FontWeight.w700,
                    color: tx.amountColor ?? p.textPrimary,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _initialBadge(
    String initial,
    Color color,
    Color bg, {
    double radius = 11,
  }) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(radius),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: jakarta(size: 12, weight: FontWeight.w700, color: color),
      ),
    );
  }
}

Future<void> _refreshFromSms(BuildContext context, WidgetRef ref) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final navigator = Navigator.of(context);
  // Non-Android platforms cannot read SMS; a pull-to-refresh there simply
  // re-derives the snapshot from already-stored data.
  if (!ref.read(smsScanSupportedProvider)) {
    await ref.read(transactionsNotifierProvider.notifier).reload();
    return;
  }
  final result = await ref.read(scanControllerProvider.notifier).scan();
  if (result == null) {
    messenger?.showSnackBar(
      const SnackBar(content: Text("Scanning isn't available right now.")),
    );
    return;
  }
  if (!result.isSuccess) {
    messenger?.showSnackBar(
      SnackBar(content: Text(_scanStatusMessage(result.status))),
    );
    return;
  }
  // Nothing new to confirm; the snapshot already refreshed inside scan().
  if (result.autoAdded == 0 && result.queuedReview == 0) {
    messenger?.showSnackBar(
      const SnackBar(
        content: Text('You are up to date \u2014 no new messages.'),
      ),
    );
    return;
  }
  if (!context.mounted) return;
  await navigator.push(
    MaterialPageRoute(builder: (_) => const ScanReviewPage()),
  );
}

String _scanStatusMessage(SmsScanStatus status) => switch (status) {
  SmsScanStatus.unsupportedPlatform =>
    'SMS scanning is only available on Android.',
  SmsScanStatus.permissionDenied => 'Grant SMS access to scan your messages.',
  SmsScanStatus.permissionPermanentlyDenied =>
    'Enable SMS access in Settings to scan your messages.',
  SmsScanStatus.failed => "Couldn't read your messages. Please try again.",
  SmsScanStatus.success => 'Scan complete.',
};
