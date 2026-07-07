import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/app_controller.dart';
import '../../widgets/ui.dart';

class _Slide {
  const _Slide(this.icon, this.accent, this.title, this.body);
  final IconData icon;
  final Color accent;
  final String title;
  final String body;
}

const _slides = [
  _Slide(Icons.mark_email_read_outlined, AppColors.teal, 'Your inbox already knows your expenses',
      'We read the receipts, bills & payment emails already sitting in Gmail — no manual entry.'),
  _Slide(Icons.notifications_active_outlined, AppColors.amber, 'See next month before it arrives',
      'Annual premiums, renewals & one-off bills get flagged early, so nothing surprises your balance.'),
  _Slide(Icons.check_rounded, AppColors.green, 'Always know what to keep in the bank',
      "One number, updated automatically: what you need set aside before it's due."),
];

class OnboardingScreen extends ConsumerWidget {
  const OnboardingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final step = ref.watch(appControllerProvider.select((s) => s.onboardStep));
    final ctrl = ref.read(appControllerProvider.notifier);
    final slide = _slides[step];

    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 28, 28, 40),
      child: Column(
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: GestureDetector(
              onTap: ctrl.skipToApp,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Text('Skip', style: jakarta(size: 13, weight: FontWeight.w600, color: p.textTertiary)),
              ),
            ),
          ),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    color: slide.accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(32),
                  ),
                  child: Icon(slide.icon, size: 56, color: slide.accent),
                ),
                const SizedBox(height: 28),
                Text(slide.title,
                    textAlign: TextAlign.center,
                    style: jakarta(size: 26, weight: FontWeight.w800, height: 1.3, color: p.textPrimary)),
                const SizedBox(height: 12),
                Text(slide.body,
                    textAlign: TextAlign.center,
                    style: jakarta(size: 15, weight: FontWeight.w500, height: 1.6, color: p.textSecondary)),
              ],
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < 3; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: i == step ? 24 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: i == step ? AppColors.teal : const Color(0xFF242A36),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),
          PrimaryButton(label: step == 2 ? 'Get started' : 'Next', onTap: ctrl.nextOnboard),
        ],
      ),
    );
  }
}
