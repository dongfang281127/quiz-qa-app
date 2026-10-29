import 'package:flutter/material.dart';

/// 语义色板：通过 `context.appColors` / `theme.appColors` 取用，
/// 避免到处硬编码 Colors.green / Colors.red（深色主题下绿色和主色几乎分不清）。
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.success,
    required this.onSuccess,
    required this.danger,
    required this.onDanger,
    required this.warning,
    required this.onWarning,
    required this.info,
    required this.onInfo,
    required this.favorite,
  });

  final Color success;
  final Color onSuccess;
  final Color danger;
  final Color onDanger;
  final Color warning;
  final Color onWarning;
  final Color info;
  final Color onInfo;

  /// 收藏星标点亮后的黄色。灰星星看不住「到底收没收藏」，所以单独给它一个色。
  final Color favorite;

  static const light = AppColors(
    success: Color(0xFF2E7D32),
    onSuccess: Colors.white,
    danger: Color(0xFFC62828),
    onDanger: Colors.white,
    warning: Color(0xFFEF6C00),
    onWarning: Colors.white,
    info: Color(0xFF1565C0),
    onInfo: Colors.white,
    favorite: Color(0xFFFFC107),
  );

  static const dark = AppColors(
    success: Color(0xFF66BB6A),
    onSuccess: Color(0xFF0A1612),
    danger: Color(0xFFEF5350),
    onDanger: Color(0xFF0A1612),
    warning: Color(0xFFFFB74D),
    onWarning: Color(0xFF0A1612),
    info: Color(0xFF64B5F6),
    onInfo: Color(0xFF0A1612),
    favorite: Color(0xFFFFD54F),
  );

  @override
  AppColors copyWith({
    Color? success,
    Color? onSuccess,
    Color? danger,
    Color? onDanger,
    Color? warning,
    Color? onWarning,
    Color? info,
    Color? onInfo,
    Color? favorite,
  }) {
    return AppColors(
      success: success ?? this.success,
      onSuccess: onSuccess ?? this.onSuccess,
      danger: danger ?? this.danger,
      onDanger: onDanger ?? this.onDanger,
      warning: warning ?? this.warning,
      onWarning: onWarning ?? this.onWarning,
      info: info ?? this.info,
      onInfo: onInfo ?? this.onInfo,
      favorite: favorite ?? this.favorite,
    );
  }

  @override
  AppColors lerp(AppColors? other, double t) {
    if (other == null) return this;
    return AppColors(
      success: Color.lerp(success, other.success, t)!,
      onSuccess: Color.lerp(onSuccess, other.onSuccess, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      onDanger: Color.lerp(onDanger, other.onDanger, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      onWarning: Color.lerp(onWarning, other.onWarning, t)!,
      info: Color.lerp(info, other.info, t)!,
      onInfo: Color.lerp(onInfo, other.onInfo, t)!,
      favorite: Color.lerp(favorite, other.favorite, t)!,
    );
  }
}

extension AppColorsContext on BuildContext {
  AppColors get appColors => Theme.of(this).extension<AppColors>()!;
}

extension AppColorsTheme on ThemeData {
  AppColors get appColors => extension<AppColors>()!;
}

/// 统一兜底文案（之前“未命名巫师 / 神秘巫师 / 神秘智者”三种叫法混用）。
class AppDefaults {
  static const nickname = '无名智者';
}
