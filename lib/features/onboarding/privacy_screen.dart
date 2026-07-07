import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/app_controller.dart';
import '../../widgets/ui.dart';

class PrivacyScreen extends ConsumerWidget {
  const PrivacyScreen({super.key});

  static const _points = [
    ('Only transaction emails', 'We scan for receipts, invoices & payment alerts — nothing else is read.'),
    ('Numbers stay on your device', 'Amounts & categories are processed locally, never uploaded to a server.'),
    ('Revoke anytime', 'Disconnect from Profile in one tap — we delete cached data immediately.'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final ctrl = ref.read(appControllerProvider.notifier);
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 28, 28, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(color: AppColors.teal.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
            child: const Icon(Icons.shield_outlined, size: 30, color: AppColors.teal),
          ),
          const SizedBox(height: 24),
          Text('Private by design', style: jakarta(size: 24, weight: FontWeight.w800, height: 1.3, color: p.textPrimary)),
          const SizedBox(height: 8),
          Text("Here's exactly what happens when you connect Gmail.",
              style: jakarta(size: 14, weight: FontWeight.w500, height: 1.6, color: p.textSecondary)),
          const SizedBox(height: 28),
          Expanded(
            child: ListView.separated(
              padding: EdgeInsets.zero,
              itemCount: _points.length,
              separatorBuilder: (_, _) => const SizedBox(height: 14),
              itemBuilder: (_, i) {
                final (title, body) = _points[i];
                return Surface(
                  radius: 16,
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: Icon(Icons.check_rounded, size: 22, color: AppColors.green),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title, style: jakarta(size: 14, weight: FontWeight.w700, color: p.textPrimary)),
                            const SizedBox(height: 3),
                            Text(body, style: jakarta(size: 13, weight: FontWeight.w500, height: 1.5, color: p.textSecondary)),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 20),
          PrimaryButton(label: 'Continue', onTap: ctrl.goIncome),
        ],
      ),
    );
  }
}
