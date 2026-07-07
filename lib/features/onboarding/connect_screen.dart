import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/app_controller.dart';
import '../../widgets/ui.dart';

class ConnectScreen extends ConsumerWidget {
  const ConnectScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final ctrl = ref.read(appControllerProvider.notifier);
    final scanError = ref.watch(appControllerProvider.select((s) => s.scanError));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: p.border),
            ),
            child: Icon(Icons.mail_outline_rounded, size: 40, color: p.textPrimary),
          ),
          const SizedBox(height: 24),
          Text('Connect your Gmail',
              textAlign: TextAlign.center,
              style: jakarta(size: 22, weight: FontWeight.w800, height: 1.3, color: p.textPrimary)),
          const SizedBox(height: 10),
          Text("We'll ask Google for read-only access to scan for transaction emails.",
              textAlign: TextAlign.center,
              style: jakarta(size: 14, weight: FontWeight.w500, height: 1.6, color: p.textSecondary)),
          const SizedBox(height: 24),
          PrimaryButton(
            label: 'Continue with Gmail',
            onTap: ctrl.connectGmail,
            icon: Icon(Icons.mail_outline_rounded, size: 18, color: AppColors.ink),
          ),
          if (scanError.isNotEmpty) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.pink.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.pink.withValues(alpha: 0.3)),
              ),
              child: Text(scanError,
                  textAlign: TextAlign.center,
                  style: jakarta(size: 12, weight: FontWeight.w500, height: 1.5, color: p.textSecondary)),
            ),
          ],
          const SizedBox(height: 24),
          GestureDetector(
            onTap: ctrl.skipToApp,
            child: Text('Use sample data instead',
                style: jakarta(size: 13, weight: FontWeight.w600, color: p.textTertiary)),
          ),
        ],
      ),
    );
  }
}
