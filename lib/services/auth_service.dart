import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/bank.dart';
import '../utils/error_text.dart';
import 'api_client.dart';

/// 登录用户（对应后端 users 表对外暴露的字段）。
class AuthUser {
  final int id;
  final String email;
  final String nickname;

  const AuthUser({
    required this.id,
    required this.email,
    required this.nickname,
  });

  factory AuthUser.fromMap(Map<String, dynamic> map) {
    return AuthUser(
      id: (map['id'] as num?)?.toInt() ?? 0,
      email: map['email']?.toString() ?? '',
      nickname: map['nickname']?.toString() ?? AppDefaults.nickname,
    );
  }

  AuthUser copyWith({String? nickname}) => AuthUser(
        id: id,
        email: email,
        nickname: nickname ?? this.nickname,
      );
}

/// 账号：注册 / 登录 / 改昵称 / 注销 / 退出。
/// 之前全部直连 Supabase Auth，现在走自建 Worker（Bearer token + PBKDF2 密码）。
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  /// 当前用户。为 null 表示未登录，所有页面都读这里，不再有第二份状态。
  final ValueNotifier<AuthUser?> currentUser = ValueNotifier<AuthUser?>(null);

  final StreamController<void> _signedOutController =
      StreamController<void>.broadcast();

  /// 被动登出（token 失效）时发事件，main 里监听后回登录页。
  Stream<void> get onSignedOut => _signedOutController.stream;

  AuthUser? get user => currentUser.value;
  int? get userId => currentUser.value?.id;
  bool get isLoggedIn => currentUser.value != null;

  /// 展示用昵称：未登录/未设置时给默认值。
  String get nickname => currentUser.value?.nickname ?? AppDefaults.nickname;

  /// main() 里调一次：让 401 能把用户请回登录页。
  void bindUnauthorizedHandler() {
    ApiClient.instance.onUnauthorized = () {
      // 只有“本来以为已登录”才需要提示；启动时恢复会话的 401 不算。
      if (currentUser.value == null) return;
      unawaited(_handleUnauthorized());
    };
  }

  Future<void> _handleUnauthorized() async {
    await ApiClient.instance.setToken(null);
    currentUser.value = null;
    if (!_signedOutController.isClosed) _signedOutController.add(null);
  }

  Future<AuthUser> login({required String email, required String password}) async {
    final res = await ApiClient.instance.post(
      '/api/auth/login',
      body: {'email': email.trim(), 'password': password},
    );
    return _consumeAuth(res);
  }

  Future<AuthUser> register({
    required String email,
    required String password,
    String? nickname,
  }) async {
    final res = await ApiClient.instance.post(
      '/api/auth/register',
      body: {
        'email': email.trim(),
        'password': password,
        if (nickname != null && nickname.trim().isNotEmpty)
          'nickname': nickname.trim(),
      },
    );
    return _consumeAuth(res);
  }

  Future<AuthUser> _consumeAuth(Map<String, dynamic> res) async {
    final token = res['token']?.toString() ?? '';
    if (token.isEmpty) throw AppException('服务器没有返回登录凭证，请重试');
    final rawUser = res['user'];
    final map = rawUser is Map ? Map<String, dynamic>.from(rawUser) : <String, dynamic>{};
    final user = AuthUser.fromMap(map);
    await ApiClient.instance.setToken(token);
    currentUser.value = user;
    return user;
  }

  /// 启动时用本地 token 换用户信息，同时验证 token 还有没有效。
  /// 返回 true 表示可以进主页（网络异常也先进去，让各页面自己报错）。
  Future<bool> restoreSession() async {
    if (!ApiClient.instance.hasToken) return false;
    try {
      final res = await ApiClient.instance.get('/api/auth/me');
      final raw = res['user'];
      if (raw is Map) {
        currentUser.value = AuthUser.fromMap(Map<String, dynamic>.from(raw));
      }
      return true;
    } on ApiException catch (e) {
      if (e.status == 401) {
        await ApiClient.instance.setToken(null);
        return false;
      }
      return true;
    } catch (_) {
      return true;
    }
  }

  /// 我的页/加题页需要最新昵称时调一次。
  Future<AuthUser?> loadMe() async {
    if (!ApiClient.instance.hasToken) return null;
    try {
      final res = await ApiClient.instance.get('/api/auth/me');
      final raw = res['user'];
      if (raw is Map) {
        final user = AuthUser.fromMap(Map<String, dynamic>.from(raw));
        currentUser.value = user;
        return user;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<AuthUser> updateNickname(String newName) async {
    final res = await ApiClient.instance.put('/api/auth/me', body: {'nickname': newName});
    final raw = res['user'];
    final map = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    final user = AuthUser.fromMap(map);
    currentUser.value = user;
    return user;
  }

  /// 永久注销：服务端会连带删掉自己的题库、记录、评论和信箱留言。
  Future<void> deleteAccount() async {
    await ApiClient.instance.delete('/api/auth/me');
    await signOut();
  }

  Future<void> signOut() async {
    await ApiClient.instance.setToken(null);
    currentUser.value = null;
  }
}
