/// 业务侧主动抛出的、已经是人类可读的错误。
class AppException implements Exception {
  final String message;
  AppException(this.message);
  @override
  String toString() => message;
}

/// 把 Supabase / 网络错误映射成用户能看懂的中文。
/// 之前登录失败直接把英文原文弹给用户（如 "Invalid login credentials"）。
String friendlyError(Object error) {
  if (error is AppException) return error.message;
  final raw = error.toString();
  final lower = raw.toLowerCase();

  bool has(List<String> keys) => keys.any(lower.contains);

  if (has(['invalid login credentials', 'invalid_credentials'])) {
    return '邮箱或密码不正确';
  }
  if (has(['email not confirmed', 'email_not_confirmed'])) {
    return '邮箱还未验证，请先到邮箱点击确认链接';
  }
  if (has(['user already registered', 'already been registered'])) {
    return '该邮箱已注册过，请直接登录';
  }
  if (has(['password should be at least', 'password_too_short'])) {
    return '密码太短，至少需要 6 位';
  }
  if (has(['rate limit', 'too many requests', 'over_request_rate_limit'])) {
    return '操作太频繁了，请稍后再试';
  }
  if (has(['unable to validate email', 'invalid_email', 'invalid format'])) {
    return '邮箱格式看起来不太对';
  }
  if (has(['failed host lookup', 'socketexception', 'connection',
      'timeout', 'timed out', 'network'])) {
    return '网络连接失败，请检查网络后重试';
  }
  if (has(['duplicate key', 'unique constraint', '23505'])) {
    return '内容重复了，可能已经收藏过或已存在';
  }
  if (has(['jwt', '401', 'unauthorized', 'row-level security', 'rls', '42501'])) {
    return '登录状态已失效，请重新登录';
  }
  if (has(['permission denied', 'forbidden', '403'])) {
    return '没有权限执行这个操作';
  }
  if (has(['violation of foreign key', '23503'])) {
    return '关联的数据不存在或已被删除';
  }
  if (raw.trim().isEmpty) return '未知错误';
  return '出错了：$raw';
}
