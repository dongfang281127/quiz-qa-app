import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

/// 原生端（Android / iOS / Windows / macOS / Linux）保存字节流。
///
/// 先试系统「另存为」（Android 走 SAF、桌面走原生对话框），
/// 拿不到路径就退回 App 自己的目录，两种都能用。
Future<String?> saveBytes({
  required String fileName,
  required Uint8List bytes,
}) async {
  try {
    final path = await FilePicker.platform.saveFile(
      dialogTitle: '保存$fileName',
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: ['xlsx'],
      bytes: bytes,
    );
    if (path != null && path.isNotEmpty) return path;
  } on UnimplementedError {
    // 平台没实现这个方法，往下走兜底
  } catch (_) {
    // 用户取消或插件异常，同样往下走兜底
  }

  Directory? dir;
  if (Platform.isAndroid) {
    try {
      dir = await getExternalStorageDirectory();
    } catch (_) {
      dir = null;
    }
  }
  if (dir == null) {
    try {
      dir = await getDownloadsDirectory();
    } catch (_) {
      dir = null;
    }
  }
  dir ??= await getApplicationDocumentsDirectory();

  final file = File('${dir.path}${Platform.pathSeparator}$fileName');
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}
