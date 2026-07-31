import 'package:flutter/material.dart';

import '../core/theme.dart';

/// A rounded card using the theme surface + hairline border. The building
/// block for almost every panel in the design.
class Surface extends StatelessWidget {
  const Surface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.radius = 20,
    this.color,
    this.border,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? color;
  final Color? border;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? p.surface,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: border ?? p.border),
      ),
      child: child,
    );
  }
}

/// A segmented pill control (e.g. This month / Next month).
class SegmentedToggle extends StatelessWidget {
  const SegmentedToggle({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onChanged,
    this.height = 38,
    this.radius = 14,
    this.fontSize = 13,
  });

  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onChanged;
  final double height;
  final double radius;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: p.surfaceAlt,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Expanded(
              child: Semantics(
                button: true,
                selected: i == selectedIndex,
                label: labels[i],
                excludeSemantics: true,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onChanged(i),
                  child: Container(
                    height: height - 8,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: i == selectedIndex
                          ? AppColors.teal
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(radius - 3),
                    ),
                    child: Text(
                      labels[i],
                      style: jakarta(
                        size: fontSize,
                        weight: FontWeight.w700,
                        color: i == selectedIndex
                            ? AppColors.ink
                            : p.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A 42×24 iOS-style switch matching the design's toggles.
class SwitchToggle extends StatelessWidget {
  const SwitchToggle({super.key, required this.value, required this.onTap});

  final bool value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: 42,
        height: 24,
        decoration: BoxDecoration(
          color: value ? AppColors.teal : const Color(0xFF242A36),
          borderRadius: BorderRadius.circular(12),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 150),
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: Container(
              width: 18,
              height: 18,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The full-width teal primary CTA.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onTap,
    this.height = 56,
    this.radius = 18,
    this.icon,
  });

  final String label;
  final VoidCallback onTap;
  final double height;
  final double radius;
  final Widget? icon;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: double.infinity,
        height: height,
        decoration: BoxDecoration(
          color: AppColors.teal,
          borderRadius: BorderRadius.circular(radius),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[icon!, const SizedBox(width: 10)],
            Text(
              label,
              style: jakarta(
                size: 16,
                weight: FontWeight.w700,
                color: AppColors.ink,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A small selectable pill (month chips, category chips, filters).
class SelectableChip extends StatelessWidget {
  const SelectableChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.selectedColor = AppColors.teal,
    this.fontSize = 12,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color selectedColor;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? selectedColor : p.surfaceAlt,
          borderRadius: BorderRadius.circular(11),
        ),
        child: Text(
          label,
          style: jakarta(
            size: fontSize,
            weight: FontWeight.w600,
            color: selected ? AppColors.ink : p.textSecondary,
          ),
        ),
      ),
    );
  }
}

/// A styled text input matching the design's fields.
class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    required this.controller,
    required this.hint,
    this.onChanged,
    this.mono = false,
    this.number = false,
    this.height = 50,
    this.fillAlt = false,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String>? onChanged;
  final bool mono;
  final bool number;
  final double height;
  final bool fillAlt;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return SizedBox(
      height: height,
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        keyboardType: number
            ? const TextInputType.numberWithOptions(decimal: true)
            : TextInputType.text,
        style: mono
            ? mono4(p.textPrimary)
            : jakarta(size: 14, weight: FontWeight.w500, color: p.textPrimary),
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          hintStyle: mono
              ? mono4(p.textTertiary)
              : jakarta(
                  size: 14,
                  weight: FontWeight.w500,
                  color: p.textTertiary,
                ),
          filled: true,
          fillColor: fillAlt ? p.surfaceAlt : p.surface,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 14,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: p.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: AppColors.teal),
          ),
        ),
      ),
    );
  }
}

TextStyle mono4(Color color) =>
    mono(size: 16, weight: FontWeight.w600, color: color);

/// Small field label above an input.
class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: jakarta(
          size: 12,
          weight: FontWeight.w600,
          color: context.palette.textTertiary,
        ),
      ),
    );
  }
}

/// A vertical bar (used by the trend / forecast charts) with an optional label
/// underneath and tag above.
class ChartBar extends StatelessWidget {
  const ChartBar({
    super.key,
    required this.height,
    required this.color,
    this.label,
    this.tag,
    this.minWidth,
    this.radius = 3,
  });

  final double height;
  final Color color;
  final String? label;
  final String? tag;
  final double? minWidth;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Expanded(
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: minWidth ?? 0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (tag != null && tag!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  tag!,
                  style: mono(size: 9, weight: FontWeight.w600, color: color),
                ),
              ),
            Container(
              width: double.infinity,
              height: height,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(radius),
              ),
            ),
            if (label != null) ...[
              const SizedBox(height: 4),
              Text(
                label!,
                style: jakarta(
                  size: 9.5,
                  weight: FontWeight.w600,
                  color: p.textTertiary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A category progress row (dot + name + amount + bar).
class CategoryProgress extends StatelessWidget {
  const CategoryProgress({
    super.key,
    required this.name,
    required this.color,
    required this.amount,
    required this.pct,
  });

  final String name;
  final Color color;
  final String amount;
  final double pct;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  name,
                  style: jakarta(
                    size: 13,
                    weight: FontWeight.w600,
                    color: p.textPrimary,
                  ),
                ),
              ],
            ),
            Text(
              amount,
              style: mono(
                size: 13,
                weight: FontWeight.w600,
                color: p.textSecondary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: (pct / 100).clamp(0, 1),
            minHeight: 6,
            backgroundColor: p.surfaceAlt,
            valueColor: AlwaysStoppedAnimation(color),
          ),
        ),
      ],
    );
  }
}
