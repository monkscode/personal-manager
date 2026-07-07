import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/app_controller.dart';
import '../../widgets/ui.dart';
import 'about_sheet.dart';
import 'ai_settings_sheet.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final s = ref.watch(appControllerProvider);
    final ctrl = ref.read(appControllerProvider.notifier);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
      children: [
        // Identity
        Column(
          children: [
            Container(
              width: 68,
              height: 68,
              decoration: BoxDecoration(color: AppColors.teal.withValues(alpha: 0.14), shape: BoxShape.circle),
              alignment: Alignment.center,
              child: Text('AM', style: jakarta(size: 20, weight: FontWeight.w700, color: AppColors.teal)),
            ),
            const SizedBox(height: 10),
            Text('Aarav Mehta', style: jakarta(size: 18, weight: FontWeight.w800, color: p.textPrimary)),
            const SizedBox(height: 2),
            Text(s.gmailEmail.isEmpty ? 'aarav.mehta@gmail.com' : s.gmailEmail,
                style: jakarta(size: 13, weight: FontWeight.w500, color: p.textTertiary)),
          ],
        ),
        const SizedBox(height: 22),
        // Gmail connected
        Surface(
          radius: 16,
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(Icons.mail_outline_rounded, size: 26, color: p.textPrimary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Gmail connected', style: jakarta(size: 13, weight: FontWeight.w700, color: p.textPrimary)),
                    Text('● Active · last synced 2 min ago', style: jakarta(size: 12, weight: FontWeight.w500, color: AppColors.green)),
                  ],
                ),
              ),
              GestureDetector(
                onTap: ctrl.signOut,
                child: Text('Disconnect', style: jakarta(size: 12, weight: FontWeight.w700, color: AppColors.pink)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        // Settings list
        Container(
          decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: p.border)),
          child: Column(
            children: [
              _row(context, Icons.notifications_none_rounded, 'Notifications',
                  trailing: SwitchToggle(value: s.notifOn, onTap: ctrl.toggleNotif)),
              _divider(p),
              _row(context, Icons.account_balance_wallet_outlined, 'Currency',
                  trailing: Text('₹ INR', style: jakarta(size: 13, weight: FontWeight.w500, color: p.textTertiary))),
              _divider(p),
              _row(context, Icons.schedule_rounded, 'Scan frequency',
                  trailing: Text('Every 6 hrs', style: jakarta(size: 13, weight: FontWeight.w500, color: p.textTertiary))),
              _divider(p),
              _row(context, Icons.auto_awesome_outlined, 'AI extraction',
                  onTap: () => showAiSettingsSheet(context, ref),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(s.aiEnabled ? 'On' : 'Off',
                          style: jakarta(size: 13, weight: FontWeight.w600, color: s.aiEnabled ? AppColors.teal : p.textTertiary)),
                      const SizedBox(width: 6),
                      Icon(Icons.chevron_right_rounded, size: 18, color: p.textTertiary),
                    ],
                  )),
              _divider(p),
              _row(context, Icons.wb_sunny_outlined, 'Theme', trailing: _themeToggle(context, s.isDark, ctrl)),
              _divider(p),
              _row(context, Icons.info_outline_rounded, 'About this app',
                  trailing: Icon(Icons.chevron_right_rounded, size: 18, color: p.textTertiary),
                  onTap: () => showAboutSheet(context)),
              _divider(p),
              _row(context, Icons.shield_outlined, 'Data & privacy',
                  trailing: Icon(Icons.chevron_right_rounded, size: 18, color: p.textTertiary)),
            ],
          ),
        ),
        const SizedBox(height: 22),
        // Sign out
        GestureDetector(
          onTap: ctrl.signOut,
          child: Container(
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.pink.withValues(alpha: 0.35)),
            ),
            child: Text('Sign out', style: jakarta(size: 14, weight: FontWeight.w700, color: AppColors.pink)),
          ),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, IconData icon, String label, {required Widget trailing, VoidCallback? onTap}) {
    final p = context.palette;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        child: Row(
          children: [
            Icon(icon, size: 19, color: p.textSecondary),
            const SizedBox(width: 12),
            Expanded(child: Text(label, style: jakarta(size: 13, weight: FontWeight.w600, color: p.textPrimary))),
            trailing,
          ],
        ),
      ),
    );
  }

  Widget _divider(AppPalette p) => Container(height: 1, color: p.border);

  Widget _themeToggle(BuildContext context, bool isDark, AppController ctrl) {
    final p = context.palette;
    Widget seg(String label, bool selected, VoidCallback onTap) => GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: selected ? AppColors.teal : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(label,
                style: jakarta(size: 11, weight: FontWeight.w700, color: selected ? AppColors.ink : p.textSecondary)),
          ),
        );
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: p.surfaceAlt, borderRadius: BorderRadius.circular(10)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          seg('Dark', isDark, () => ctrl.setTheme('dark')),
          seg('Light', !isDark, () => ctrl.setTheme('light')),
        ],
      ),
    );
  }
}
