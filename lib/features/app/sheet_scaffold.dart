import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Shows a bottom sheet styled like the design's modals (rounded top, surface
/// background, up to 82% of the screen height, scrollable).
Future<T?> showAppSheet<T>(BuildContext context, WidgetBuilder builder) {
  final p = context.palette;
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.6),
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.82),
        child: Container(
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border(top: BorderSide(color: p.border)),
          ),
          child: builder(ctx),
        ),
      ),
    ),
  );
}

/// A titled sheet body with a close button and a scrolling content column.
class SheetScaffold extends StatelessWidget {
  const SheetScaffold({super.key, required this.title, required this.children, this.subtitle});

  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(title, style: jakarta(size: 17, weight: FontWeight.w800, color: p.textPrimary)),
              GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(color: p.surfaceAlt, shape: BoxShape.circle),
                  child: Icon(Icons.close_rounded, size: 14, color: p.textSecondary),
                ),
              ),
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 8),
            Text(subtitle!, style: jakarta(size: 12, weight: FontWeight.w500, height: 1.5, color: p.textTertiary)),
          ],
          const SizedBox(height: 18),
          ...children,
        ],
      ),
    );
  }
}
