import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'app_info.dart';
import 'pages/login_page.dart';
import 'pages/splash_page.dart';
import 'services/api_client.dart';
import 'services/auth_service.dart';
import 'theme/app_theme.dart';
import 'theme/theme_controller.dart';
import 'utils/error_text.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  String? initError;
  try {
    // Web 版可能拿不到 .env（静态托管会把点开头的文件过滤掉），
    // 所以 .env 允许缺席，缺了就用构建时注入的 --dart-define=API_BASE_URL。
    await dotenv.load(fileName: ".env", isOptional: true);
    final baseUrl = dotenv.env['API_BASE_URL'] ??
        const String.fromEnvironment('API_BASE_URL');
    if (baseUrl.trim().isEmpty) {
      initError = '配置文件缺少 API_BASE_URL';
    } else {
      // 服务器地址 + 上次登录留下的 token，都在这里一次性就位。
      await ApiClient.instance.init(baseUrl: baseUrl);
      AuthService.instance.bindUnauthorizedHandler();
    }
  } catch (e) {
    initError = friendlyError(e);
  }

  // 主题持久化：启动即读，避免“每次打开都变回深色”。
  await ThemeController.instance.load();

  runApp(MyApp(initError: initError));
}

class MyApp extends StatefulWidget {
  const MyApp({super.key, this.initError});

  /// 初始化失败时给出可读的错误页，而不是白屏。
  final String? initError;

  /// 全局导航钥匙：登录失效时在任何位置都能把栈清空并回到登录页。
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  /// 主动 signOut 前置位，用于区分“用户自己退出”和“被动登出”。
  static bool _signOutRequested = false;
  static void markSignOutRequested() => _signOutRequested = true;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  StreamSubscription<void>? _authSub;

  @override
  void initState() {
    super.initState();
    _listenAuth();
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  /// 只关心“被动登出”：token 失效 / 服务端 401。
  void _listenAuth() {
    _authSub = AuthService.instance.onSignedOut.listen((_) {
      // 等一帧再导航，避免事件恰好落在 build 期间。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final nav = MyApp.navigatorKey.currentState;
        final ctx = MyApp.navigatorKey.currentContext;
        if (nav == null || ctx == null) return;

        // 主动退出（个人页按钮）自己会提示；这里只兜底“被动登出”。
        final wasSignedOutByUser = MyApp._signOutRequested;
        if (!wasSignedOutByUser && ctx.mounted) {
          ScaffoldMessenger.of(ctx).showSnackBar(
            const SnackBar(content: Text('登录已失效，请重新登录')),
          );
        }
        MyApp._signOutRequested = false;

        nav.pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const LoginPage(kickedOut: false)),
          (route) => false,
        );
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.initError != null) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark(),
        home: _InitErrorPage(message: widget.initError!),
      );
    }

    return ValueListenableBuilder<AppThemeMode>(
      valueListenable: ThemeController.instance.mode,
      builder: (context, mode, _) {
        return MaterialApp(
          navigatorKey: MyApp.navigatorKey,
          title: AppInfo.appName,
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: switch (mode) {
            AppThemeMode.light => ThemeMode.light,
            AppThemeMode.dark => ThemeMode.dark,
            AppThemeMode.system => ThemeMode.system,
          },
          home: const SplashPage(),
        );
      },
    );
  }
}

class _InitErrorPage extends StatelessWidget {
  const _InitErrorPage({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: const Color(0xFF0A1612),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, color: Colors.white54, size: 56),
                const SizedBox(height: 16),
                const Text('应用初始化失败',
                    style: TextStyle(color: Colors.white70, fontSize: 18)),
                const SizedBox(height: 8),
                Text(message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white38, fontSize: 13)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
