import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/app_controller.dart';

class ScanningScreen extends ConsumerWidget {
  const ScanningScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final s = ref.watch(appControllerProvider);
    final pct = s.scanProgress;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 96,
            height: 96,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 96,
                  height: 96,
                  child: CircularProgressIndicator(
                    value: pct / 100,
                    strokeWidth: 3,
                    backgroundColor: AppColors.teal.withValues(alpha: 0.15),
                    valueColor: const AlwaysStoppedAnimation(AppColors.teal),
                  ),
                ),
                Text('$pct%', style: mono(size: 20, weight: FontWeight.w700, color: p.textPrimary)),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text('Scanning your inbox…',
              style: jakarta(size: 20, weight: FontWeight.w800, height: 1.3, color: p.textPrimary)),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('${s.scanCount}',
                  style: mono(size: 14, weight: FontWeight.w600, color: AppColors.teal)),
              Text(' transactions found so far',
                  style: jakarta(size: 14, weight: FontWeight.w500, color: p.textSecondary)),
            ],
          ),
          const SizedBox(height: 24),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: pct / 100,
              minHeight: 6,
              backgroundColor: p.surfaceAlt,
              valueColor: const AlwaysStoppedAnimation(AppColors.teal),
            ),
          ),
        ],
      ),
    );
  }
}
