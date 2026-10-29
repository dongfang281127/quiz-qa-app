import 'package:flutter/material.dart';

import 'app_colors.dart';

/// 统一主题配置。
/// 注意：只用 `colorScheme` 作为唯一取色来源（M3）。
/// 之前 lightTheme 里 primaryColor 和 colorScheme.primary 是两个不同颜色，
/// 导致部分组件白字配淡绿底几乎不可读。
class AppTheme {
  AppTheme._();

  static ThemeData light() {
    const scheme = ColorScheme.light(
      primary: Color(0xFF2E7D32), // 深祖母绿：白字可读
      onPrimary: Colors.white,
      secondary: Color(0xFF33691E),
      onSecondary: Colors.white,
      surface: Colors.white,
      onSurface: Colors.black87,
      surfaceContainerHighest: Color(0xFFF1F8E9),
    );
    return _base(Brightness.light, scheme, AppColors.light);
  }

  static ThemeData dark() {
    const scheme = ColorScheme.dark(
      primary: Color(0xFF2E8B57), // 提亮：避免暗底上更深一块
      onPrimary: Colors.white,
      secondary: Color(0xFF2A623D),
      onSecondary: Color(0xFFC0C0C0),
      surface: Color(0xFF11221C),
      onSurface: Color(0xFFE0E0E0),
      surfaceContainerHighest: Color(0xFF17352A),
    );
    return _base(Brightness.dark, scheme, AppColors.dark);
  }

  static ThemeData _base(
    Brightness brightness,
    ColorScheme scheme,
    AppColors colors,
  ) {
    final isDark = brightness == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor:
          isDark ? const Color(0xFF0A1612) : const Color(0xFFF7FBF4),
      extensions: [colors],
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 1,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: isDark ? const Color(0xFF142B22) : Colors.white,
        elevation: isDark ? 0 : 1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: isDark ? 0.5 : 0.6),
          ),
        ),
        margin: const EdgeInsets.only(bottom: 12),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark ? const Color(0xFF243B31) : const Color(0xFF1F3D2B),
        contentTextStyle: const TextStyle(color: Colors.white),
        actionTextColor: Colors.white,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.black.withValues(alpha: 0.04),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.primary, width: 1.6),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          minimumSize: const Size(64, 46),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          minimumSize: const Size(64, 46),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.primary,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.6),
      ),
      splashFactory: InkRipple.splashFactory,
    );
  }

  /// 品牌深色渐变（开屏/登录用；浅色模式下用柔和浅色渐变，保持同一套视觉）。
  static LinearGradient brandGradient(Brightness brightness) {
    return brightness == Brightness.dark
        ? const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF0D3A28), Color(0xFF000000)],
          )
        : const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFEAF5E4), Color(0xFFC8E6C0)],
          );
  }
}
