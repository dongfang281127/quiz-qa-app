import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/auth_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../utils/error_text.dart';
import 'main_screen.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, this.kickedOut = false});

  /// true = 被动登出（登录过期），页面顶部给一句提示。
  final bool kickedOut;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nicknameController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = false;
  bool _isLoginMode = true;
  bool _showPassword = false;

  /// 邮箱框只吃 ASCII 里跟邮箱有关的字符：中文/全角/emoji 直接进不来，
  /// 避免中文输入法把「＠」或全角字母打进邮箱。
  static final _emailFormatters = <TextInputFormatter>[
    FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9@._%+\-]')),
  ];

  /// 密码框只吃 ASCII 可见字符（0x21–0x7E，不含空格），
  /// 配合 keyboardType: visiblePassword 让系统键盘切到英文布局。
  static final _passwordFormatters = <TextInputFormatter>[
    FilteringTextInputFormatter.allow(RegExp(r'[\x21-\x7E]')),
  ];

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _nicknameController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final email = _emailController.text.trim();
    final password = _passwordController.text; // 密码不做 trim，首尾空格可能是有效的
    final nickname = _nicknameController.text.trim();

    setState(() => _isLoading = true);
    try {
      if (_isLoginMode) {
        await AuthService.instance.login(email: email, password: password);
      } else {
        // 自建后端注册即登录，不再需要去邮箱点确认链接。
        // 昵称注册时就填，省得所有人默认成邮箱前缀。
        await AuthService.instance.register(
          email: email,
          password: password,
          nickname: nickname,
        );
      }

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const MainScreen()),
      );
    } catch (e) {
      if (mounted) _showMsg(friendlyError(e), isError: true);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showMsg(String msg, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: isError ? context.appColors.danger : context.appColors.success,
      behavior: SnackBarBehavior.floating,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textColor = theme.colorScheme.onSurface;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
        body: DecoratedBox(
          decoration: BoxDecoration(
              gradient: AppTheme.brandGradient(theme.brightness)),
          child: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(30),
                child: Form(
                  key: _formKey,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  child: AutofillGroup(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.lock_outline, size: 60, color: textColor),
                        const SizedBox(height: 20),
                        Text(
                          _isLoginMode ? '登录账号' : '注册新账号',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w600,
                            color: textColor,
                            letterSpacing: 1,
                          ),
                        ),
                        if (widget.kickedOut) ...[
                          const SizedBox(height: 12),
                          Text('登录已过期，请重新登录',
                              style: TextStyle(
                                  color: context.appColors.warning, fontSize: 13)),
                        ],
                        const SizedBox(height: 40),
                        // 注册时先填昵称：以前默认拿邮箱前缀当昵称，很难看。
                        if (!_isLoginMode) ...[
                          _buildTextField(
                            controller: _nicknameController,
                            label: '昵称',
                            icon: Icons.badge_outlined,
                            keyboardType: TextInputType.text,
                            autofillHints: const [AutofillHints.nickname],
                            textInputAction: TextInputAction.next,
                            validator: (v) {
                              final s = v?.trim() ?? '';
                              if (s.isEmpty) return '请输入昵称';
                              if (s.length > 20) return '昵称最多 20 个字';
                              return null;
                            },
                          ),
                          const SizedBox(height: 20),
                        ],
                        _buildTextField(
                          controller: _emailController,
                          label: '邮箱',
                          icon: Icons.email_outlined,
                          keyboardType: TextInputType.emailAddress,
                          inputFormatters: _emailFormatters,
                          autofillHints: const [AutofillHints.email],
                          textInputAction: TextInputAction.next,
                          validator: (v) {
                            final s = v?.trim() ?? '';
                            if (s.isEmpty) return '请输入邮箱';
                            if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(s)) {
                              return '邮箱格式不正确';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 20),
                        _buildTextField(
                          controller: _passwordController,
                          label: '密码',
                          icon: Icons.key_outlined,
                          isObscure: !_showPassword,
                          keyboardType: TextInputType.visiblePassword,
                          inputFormatters: _passwordFormatters,
                          suffix: IconButton(
                            // 密码可见切换：手机上打错密码很难发现
                            icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility,
                                color: textColor.withValues(alpha: 0.6)),
                            onPressed: () => setState(() => _showPassword = !_showPassword),
                          ),
                          autofillHints: [
                            _isLoginMode
                                ? AutofillHints.password
                                : AutofillHints.newPassword
                          ],
                          // 密码框是最后一个输入框（注册时昵称在最上面），所以始终按“完成”提交
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _submit(),
                          validator: (v) {
                            final s = v ?? '';
                            if (s.isEmpty) return '请输入密码';
                            if (!_isLoginMode && s.length < 6) return '密码至少 6 位';
                            return null;
                          },
                        ),
                        const SizedBox(height: 36),
                        SizedBox(
                          width: double.infinity,
                          height: 50,
                          child: ElevatedButton(
                            onPressed: _isLoading ? null : _submit,
                            child: _isLoading
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(strokeWidth: 2))
                                : Text(_isLoginMode ? '登录' : '注册',
                                    style: const TextStyle(fontSize: 16)),
                          ),
                        ),
                        const SizedBox(height: 20),
                        TextButton(
                          onPressed: _isLoading
                              ? null
                              : () => setState(() => _isLoginMode = !_isLoginMode),
                          child: Text(
                            _isLoginMode ? '没有账号？去注册' : '已有账号？去登录',
                            style: TextStyle(color: textColor.withValues(alpha: 0.6), fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    bool isObscure = false,
    Widget? suffix,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
    List<String>? autofillHints,
    TextInputAction? textInputAction,
    ValueChanged<String>? onSubmitted,
    String? Function(String?)? validator,
  }) {
    final theme = Theme.of(context);
    final textColor = theme.colorScheme.onSurface;
    return TextFormField(
      controller: controller,
      obscureText: isObscure,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      enableIMEPersonalizedLearning: false,
      autofillHints: autofillHints,
      textInputAction: textInputAction,
      onFieldSubmitted: onSubmitted,
      validator: validator,
      style: TextStyle(color: textColor),
      cursorColor: theme.colorScheme.primary,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: textColor.withValues(alpha: 0.5)),
        prefixIcon: Icon(icon, color: theme.colorScheme.primary),
        suffixIcon: suffix,
      ),
    );
  }
}
