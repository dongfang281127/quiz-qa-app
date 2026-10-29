import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/auth_service.dart';
import 'login_page.dart';
import 'main_screen.dart';

/// 开屏页。
/// 之前：固定 1.5s 延迟 + 5s Timer，总共约 6.5 秒才进入 App；
/// 现在：动画照常播，但会话检查并行做，最短展示 1.4s 即进入；
/// Timer 在 dispose 时取消，不再泄漏。
class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> with TickerProviderStateMixin {
  late AnimationController _breathingController;
  late AnimationController _textController;
  late Animation<double> _breathingAnimation;
  late Animation<double> _textOpacityAnimation;
  late Animation<Offset> _textSlideAnimation;
  Timer? _goTimer;
  Future<bool>? _sessionFuture;
  bool _navigated = false;

  static const _minShow = Duration(milliseconds: 1400);

  @override
  void initState() {
    super.initState();

    _breathingController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat(reverse: true);

    _breathingAnimation = Tween<double>(begin: 0.9, end: 1.15).animate(
      CurvedAnimation(parent: _breathingController, curve: Curves.easeInOutCubic),
    );

    _textController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );

    _textOpacityAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _textController, curve: Curves.easeInSine),
    );

    _textSlideAnimation = Tween<Offset>(begin: const Offset(0, 0.3), end: Offset.zero)
        .animate(CurvedAnimation(parent: _textController, curve: Curves.easeOutQuart));

    _startSequence();
  }

  void _startSequence() {
    _textController.forward();
    // 恢复登录态要联网，和开屏动画并行跑，不额外耗时。
    _sessionFuture = AuthService.instance.restoreSession();
    _goTimer = Timer(_minShow, _go);
  }

  Future<void> _go() async {
    if (_navigated || !mounted) return;
    _navigated = true;

    var loggedIn = AuthService.instance.isLoggedIn;
    try {
      loggedIn = await (_sessionFuture ?? Future<bool>.value(loggedIn))
          .timeout(
        const Duration(seconds: 3),
        onTimeout: () => AuthService.instance.isLoggedIn,
      );
    } catch (_) {
      // 恢复会话失败就按本地 token 判断，别把用户卡在开屏页。
      loggedIn = AuthService.instance.isLoggedIn;
    }
    if (!mounted) return;

    final Widget nextPage =
        loggedIn ? const MainScreen() : const LoginPage();

    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 600),
        pageBuilder: (_, __, ___) => nextPage, // ignore: unnecessary_underscores
        transitionsBuilder: (_, animation, __, child) => // ignore: unnecessary_underscores
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  @override
  void dispose() {
    _goTimer?.cancel();
    _breathingController.dispose();
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final silver = isDark ? const Color(0xFFC0C0C0) : const Color(0xFF33502F);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
        body: SizedBox.expand(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.center,
                radius: 1.4,
                colors: isDark
                    ? const [Color(0xFF0D3A28), Color(0xFF000000)]
                    : const [Color(0xFFDFF0D8), Color(0xFFF7FBF4)],
                stops: const [0.1, 1.0],
              ),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                AnimatedBuilder(
                  animation: _breathingAnimation,
                  builder: (context, child) {
                    return Transform.scale(
                      scale: _breathingAnimation.value,
                      child: Container(
                        width: 90,
                        height: 90,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: const RadialGradient(
                            center: Alignment(-0.3, -0.3),
                            colors: [Colors.white, Color(0xFFE0E0E0), Color(0xFF909090)],
                            stops: [0.1, 0.4, 1.0],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF2E8B57)
                                  .withValues(alpha: isDark ? 0.5 : 0.25),
                              blurRadius: 30,
                              spreadRadius: 6,
                            ),
                          ],
                        ),
                        child: const Center(
                          child: Icon(Icons.all_inclusive, color: Color(0xFF145235), size: 45),
                        ),
                      ),
                    );
                  },
                ),
                Positioned(
                  top: MediaQuery.of(context).size.height * 0.5 + 110,
                  child: SlideTransition(
                    position: _textSlideAnimation,
                    child: FadeTransition(
                      opacity: _textOpacityAnimation,
                      child: Column(
                        children: [
                          Text('问 道',
                              style: TextStyle(
                                  color: silver,
                                  fontSize: 28,
                                  letterSpacing: 14,
                                  fontWeight: FontWeight.w300)),
                          const SizedBox(height: 16),
                          Text('万籁俱寂 · 唯思不止',
                              style: TextStyle(
                                  color: silver.withValues(alpha: 0.5),
                                  fontSize: 13,
                                  letterSpacing: 4)),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
