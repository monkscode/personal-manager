import 'package:flutter/material.dart';

const String kSansFamily = 'Plus Jakarta Sans';
const String kMonoFamily = 'IBM Plex Mono';

/// Brand accent colors — identical across light and dark themes.
/// Ported from the Expense Insight design (`design/project/Expense Insight.dc.html`).
class AppColors {
  static const teal = Color(0xFF2DD4BF);
  static const tealLight = Color(0xFF5EEAD4);
  static const amber = Color(0xFFF5A623);
  static const green = Color(0xFF4ADE80);
  static const pink = Color(0xFFFB7185);
  static const blue = Color(0xFF38BDF8);
  static const purple = Color(0xFFC084FC);
  static const violet = Color(0xFF8B7CF6);
  static const cyan = Color(0xFF22D3EE);
  static const orange = Color(0xFFFB923C);
  static const slate = Color(0xFF94A3B8);
  static const lime = Color(0xFFA3E635);

  /// Text color that sits on top of a teal button.
  static const ink = Color(0xFF0B0E16);
}

/// Theme-dependent surface & text palette, exposed as a [ThemeExtension] so
/// widgets read it via `context.palette` and it swaps automatically with the
/// active [ThemeData].
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.bg,
    required this.surface,
    required this.surfaceAlt,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.border,
    required this.borderStrong,
    required this.isDark,
  });

  final Color bg;
  final Color surface;
  final Color surfaceAlt;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color border;
  final Color borderStrong;
  final bool isDark;

  static const dark = AppPalette(
    bg: Color(0xFF0B0E16),
    surface: Color(0xFF12161F),
    surfaceAlt: Color(0xFF171C27),
    textPrimary: Color(0xFFF3F5F8),
    textSecondary: Color(0xFF96A0B2),
    textTertiary: Color(0xFF5C6579),
    border: Color(0x12FFFFFF), // rgba(255,255,255,0.07)
    borderStrong: Color(0x21FFFFFF), // rgba(255,255,255,0.13)
    isDark: true,
  );

  static const light = AppPalette(
    bg: Color(0xFFF5F6F8),
    surface: Color(0xFFFFFFFF),
    surfaceAlt: Color(0xFFEEF0F4),
    textPrimary: Color(0xFF0B0E16),
    textSecondary: Color(0xFF5B6472),
    textTertiary: Color(0xFF8A93A3),
    border: Color(0x14000000), // rgba(0,0,0,0.08)
    borderStrong: Color(0x26000000), // rgba(0,0,0,0.15)
    isDark: false,
  );

  @override
  AppPalette copyWith({
    Color? bg,
    Color? surface,
    Color? surfaceAlt,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? border,
    Color? borderStrong,
    bool? isDark,
  }) {
    return AppPalette(
      bg: bg ?? this.bg,
      surface: surface ?? this.surface,
      surfaceAlt: surfaceAlt ?? this.surfaceAlt,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textTertiary: textTertiary ?? this.textTertiary,
      border: border ?? this.border,
      borderStrong: borderStrong ?? this.borderStrong,
      isDark: isDark ?? this.isDark,
    );
  }

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    return AppPalette(
      bg: Color.lerp(bg, other.bg, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceAlt: Color.lerp(surfaceAlt, other.surfaceAlt, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!,
      border: Color.lerp(border, other.border, t)!,
      borderStrong: Color.lerp(borderStrong, other.borderStrong, t)!,
      isDark: t < 0.5 ? isDark : other.isDark,
    );
  }
}

extension PaletteX on BuildContext {
  AppPalette get palette => Theme.of(this).extension<AppPalette>()!;
}

/// Plus Jakarta Sans — the primary UI typeface. It ships as a single variable
/// font, so the requested weight is applied both as a [FontWeight] and along the
/// `wght` variation axis for crisp rendering at every weight.
TextStyle jakarta({
  required double size,
  FontWeight weight = FontWeight.w600,
  Color? color,
  double? height,
  double? letterSpacing,
}) {
  return TextStyle(
    fontFamily: kSansFamily,
    fontSize: size,
    fontWeight: weight,
    fontVariations: [FontVariation('wght', weight.value.toDouble())],
    color: color,
    height: height,
    letterSpacing: letterSpacing,
  );
}

/// IBM Plex Mono — used for all monetary figures.
TextStyle mono({
  required double size,
  FontWeight weight = FontWeight.w600,
  Color? color,
  double? letterSpacing,
}) {
  return TextStyle(
    fontFamily: kMonoFamily,
    fontSize: size,
    fontWeight: weight,
    color: color,
    letterSpacing: letterSpacing,
  );
}

ThemeData buildTheme(AppPalette p) {
  final base = ThemeData(brightness: p.isDark ? Brightness.dark : Brightness.light);
  return base.copyWith(
    scaffoldBackgroundColor: p.bg,
    canvasColor: p.bg,
    colorScheme: base.colorScheme.copyWith(
      primary: AppColors.teal,
      surface: p.surface,
    ),
    textTheme: base.textTheme.apply(
      fontFamily: kSansFamily,
      bodyColor: p.textPrimary,
      displayColor: p.textPrimary,
    ),
    extensions: [p],
  );
}
