import 'dart:typed_data';

/// 兜底实现：拿不到保存位置就返回 null，调用方据此提示「用复制表格内容」。
///
/// 这个文件只在既没有 dart:io 也没有 dart:js_interop 的平台上被选中，
/// 实际上不会被编译进 Android / Web 产物。
Future<String?> saveBytes({
  required String fileName,
  required Uint8List bytes,
}) async =>
    null;
