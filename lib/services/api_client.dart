import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/error_text.dart';

/// 服务端返回的业务错误：message 已经是中文，status 是 HTTP 状态码。
/// 继承 AppException 是为了让 friendlyError() 原样透出 message。
class ApiException extends AppException {
  final int status;
  ApiException(super.message, this.status);
}

/// 问道后端（Cloudflare Worker `wenda-api` + D1）的唯一出口。
/// 迁移前这里是 supabase_flutter，所有页面都直接调 Supabase.instance；
/// 现在统一走这里：拼 URL、带 Bearer token、把 {error:"中文"} 转成异常。
class ApiClient {
  ApiClient._();
  static final ApiClient instance = ApiClient._();

  static const _tokenKey = 'wenda_api_token';
  static const _timeout = Duration(seconds: 20);

  String _baseUrl = '';
  String? _token;

  /// 收到 401 时回调（由 AuthService 注册），用于把用户请回登录页。
  void Function()? onUnauthorized;

  String get baseUrl => _baseUrl;
  String? get token => _token;
  bool get hasToken => (_token ?? '').isNotEmpty;

  /// main() 里调一次：写入服务器地址 + 读取上次保存的 token。
  Future<void> init({required String baseUrl}) async {
    var url = baseUrl.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    _baseUrl = url;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_tokenKey);
      _token = (saved == null || saved.isEmpty) ? null : saved;
    } catch (_) {
      _token = null;
    }
  }

  Future<void> setToken(String? value) async {
    _token = (value == null || value.isEmpty) ? null : value;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_token == null) {
        await prefs.remove(_tokenKey);
      } else {
        await prefs.setString(_tokenKey, _token!);
      }
    } catch (_) {
      // 本地存不下不影响当前会话，只是下次启动要重新登录。
    }
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    if (_baseUrl.isEmpty) {
      throw AppException('还没有配置服务器地址（.env 里的 API_BASE_URL）');
    }
    final normalized = path.startsWith('/') ? path : '/$path';
    final uri = Uri.parse('$_baseUrl$normalized');
    if (query == null || query.isEmpty) return uri;
    return uri.replace(queryParameters: {...uri.queryParameters, ...query});
  }

  Map<String, String> _headers({bool withBody = false}) {
    final headers = <String, String>{'accept': 'application/json'};
    if (withBody) headers['content-type'] = 'application/json; charset=utf-8';
    final t = _token;
    if (t != null && t.isNotEmpty) headers['authorization'] = 'Bearer $t';
    return headers;
  }

  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) =>
      _send(() => http.get(_uri(path, query), headers: _headers()).timeout(_timeout));

  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, String>? query,
  }) =>
      _send(() => http
          .post(
            _uri(path, query),
            headers: _headers(withBody: true),
            body: jsonEncode(body ?? const <String, dynamic>{}),
          )
          .timeout(_timeout));

  Future<Map<String, dynamic>> put(String path, {Object? body}) => _send(() => http
      .put(
        _uri(path),
        headers: _headers(withBody: true),
        body: jsonEncode(body ?? const <String, dynamic>{}),
      )
      .timeout(_timeout));

  Future<Map<String, dynamic>> delete(String path, {Object? body}) => _send(() => http
      .delete(
        _uri(path),
        headers: _headers(withBody: body != null),
        body: body == null ? null : jsonEncode(body),
      )
      .timeout(_timeout));

  Future<Map<String, dynamic>> _send(Future<http.Response> Function() run) async {
    http.Response res;
    try {
      res = await run();
    } on TimeoutException {
      throw AppException('网络连接超时，请检查网络后重试');
    } catch (e) {
      // http 的 ClientException / SocketException 都在这里被翻译成中文。
      throw AppException(friendlyError(e));
    }

    Map<String, dynamic>? decoded;
    if (res.bodyBytes.isNotEmpty) {
      try {
        final raw = jsonDecode(utf8.decode(res.bodyBytes));
        if (raw is Map<String, dynamic>) decoded = raw;
      } catch (_) {
        decoded = null;
      }
    }

    if (res.statusCode >= 200 && res.statusCode < 300) {
      return decoded ?? const <String, dynamic>{};
    }

    final serverMessage = decoded?['error']?.toString() ?? '';
    final message =
        serverMessage.isNotEmpty ? serverMessage : _fallbackMessage(res.statusCode);

    if (res.statusCode == 401) onUnauthorized?.call();
    throw ApiException(message, res.statusCode);
  }

  String _fallbackMessage(int status) {
    if (status == 400) return '请求内容不完整';
    if (status == 401) return '登录已过期，请重新登录';
    if (status == 403) return '没有权限执行这个操作';
    if (status == 404) return '请求的内容不存在';
    if (status == 429) return '操作太频繁了，请稍后再试';
    if (status >= 500) return '服务器出错了，请稍后再试';
    return '请求失败（$status）';
  }
}
