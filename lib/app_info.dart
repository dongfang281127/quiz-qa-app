/// 版本信息：跟 pubspec.yaml 的 `version:` 手动保持一致
/// （改版本时两处一起改，pubspec 里的数字决定 APK 的实际版本号）。
class AppInfo {
  const AppInfo._();

  static const String appName = 'Q&A';
  static const String version = '2.0.0';
  static const int build = 11;

  /// 例如「Q&A v2.0.0 (11)」
  static const String display = '$appName v$version ($build)';
}
