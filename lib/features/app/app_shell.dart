import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/app_controller.dart';
import 'add_modal.dart';
import 'home_screen.dart';
import 'insights_screen.dart';
import 'investments_screen.dart';
import 'profile_screen.dart';
import 'transactions_screen.dart';

const _tabs = ['home', 'transactions', 'insights', 'investments', 'profile'];

class AppShell extends ConsumerWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final tab = ref.watch(appControllerProvider.select((s) => s.tab));
    final ctrl = ref.read(appControllerProvider.notifier);
    final index = _tabs.indexOf(tab).clamp(0, _tabs.length - 1);

    // Home is deliberately absent. Since TASK-34 wired up the forecast surface
    // it is a read-and-decide dashboard, and the FAB floated over it: on a
    // 1080-wide screen it covered the tail of the "Free" value at the resting
    // scroll position, and a risk row's "Dismiss" control once scrolled. The
    // second is why this is a removal rather than a nudge — an interactive
    // control the user cannot reach is not a cosmetic problem, and every other
    // remedy (hide-on-scroll, re-laying the strip) fixes one collision while
    // leaving the rest. Adding an expense still lives one tab away, on
    // Activity, which is where transactions are (TASK-38 F4).
    final fabVisible = tab == 'transactions' || tab == 'investments';

    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        bottom: false,
        child: IndexedStack(
          index: index,
          children: const [
            HomeScreen(),
            TransactionsScreen(),
            InsightsScreen(),
            InvestmentsScreen(),
            ProfileScreen(),
          ],
        ),
      ),
      floatingActionButton: fabVisible
          ? FloatingActionButton(
              onPressed: () => showAddSheet(context, ref, type: tab == 'investments' ? 'investment' : 'expense'),
              backgroundColor: AppColors.teal,
              elevation: 6,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              child: const Icon(Icons.add_rounded, color: AppColors.ink, size: 26),
            )
          : null,
      bottomNavigationBar: _BottomBar(index: index, onTap: (i) => ctrl.setTab(_tabs[i])),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.index, required this.onTap});
  final int index;
  final ValueChanged<int> onTap;

  static const _items = [
    (Icons.home_outlined, 'Home'),
    (Icons.receipt_long_outlined, 'Activity'),
    (Icons.bar_chart_rounded, 'Insights'),
    (Icons.trending_up_rounded, 'Invest'),
    (Icons.person_outline_rounded, 'Profile'),
  ];

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      decoration: BoxDecoration(
        color: p.bg,
        border: Border(top: BorderSide(color: p.border)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              for (var i = 0; i < _items.length; i++)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onTap(i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(_items[i].$1, size: 21, color: i == index ? AppColors.teal : const Color(0xFF5C6579)),
                        const SizedBox(height: 4),
                        Text(_items[i].$2,
                            style: jakarta(size: 9.5, weight: FontWeight.w600, color: i == index ? AppColors.teal : const Color(0xFF5C6579))),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
