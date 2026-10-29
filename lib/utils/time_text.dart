import 'package:intl/intl.dart';

/// 相对/绝对时间显示。
/// 之前 my_messages 直接 `substring(0, 10)`，字段为空时会 RangeError 崩溃。
String formatTime(dynamic raw, {bool withTime = true}) {
  final DateTime? dt = _parse(raw);
  if (dt == null) return '';
  final local = dt.toLocal();
  final pattern = withTime ? 'yyyy-MM-dd HH:mm' : 'yyyy-MM-dd';
  return DateFormat(pattern).format(local);
}

/// “3 分钟前 / 昨天 / 2026-01-02” 风格。
String formatRelative(dynamic raw, {DateTime? now}) {
  final DateTime? dt = _parse(raw);
  if (dt == null) return '';
  final local = dt.toLocal();
  final ref = now ?? DateTime.now();
  final diff = ref.difference(local);

  if (diff.inSeconds < 60) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  if (diff.inDays == 1) return '昨天';
  if (diff.inDays < 7) return '${diff.inDays} 天前';
  final pattern =
      local.year == ref.year ? 'MM-dd' : 'yyyy-MM-dd';
  return DateFormat(pattern).format(local);
}

DateTime? _parse(dynamic raw) {
  if (raw == null) return null;
  if (raw is DateTime) return raw;
  final s = raw.toString();
  if (s.isEmpty) return null;
  return DateTime.tryParse(s);
}
