import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 主题模式：跟随系统 / 浅色 / 深色。
enum AppThemeMode { system, light, dark }

/// 全局主题控制器。
/// 之前主题状态靠构造函数层层透传（main → splash → login → main → profile），
/// 切换后路由里缓存的是旧值，导致个人页开关和实际主题不同步。
/// 现在改成单一数据源 + 通知，任何页面直接读 [instance.mode]。
class ThemeController {
  ThemeController._();
  static final ThemeController instance = ThemeController._();

  static const _prefKey = 'app_theme_mode';

  final ValueNotifier<AppThemeMode> mode =
      ValueNotifier<AppThemeMode>(AppThemeMode.dark);

  bool get isDarkEffective {
    switch (mode.value) {
      case AppThemeMode.dark:
        return true;
      case AppThemeMode.light:
        return false;
      case AppThemeMode.system:
        return WidgetsBinding
                .instance.platformDispatcher.platformBrightness ==
            Brightness.dark;
    }
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefKey);
      if (saved != null) {
        mode.value = AppThemeMode.values
            .firstWhere((e) => e.name == saved, orElse: () => AppThemeMode.dark);
      }
    } catch (_) {
      // 读取失败就用默认深色，不影响启动。
    }
  }

  Future<void> set(AppThemeMode next) async {
    mode.value = next;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, next.name);
    } catch (_) {
      // 持久化失败不阻塞切换。
    }
  }

  /// 供 SwitchListTile 一类的控件使用：设置为一个确定值，而不是“取反”。
  void setDark(bool dark) =>
      set(dark ? AppThemeMode.dark : AppThemeMode.light);
}
