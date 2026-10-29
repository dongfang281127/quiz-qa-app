import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Web 端保存字节流：造 Blob → 生成 object URL → 触发隐藏 <a download> 的点击。
///
/// 浏览器没有「另存为」对话框（除非用户自己开了「下载前询问」），
/// 所以直接落到默认下载目录，返回文件名表示已开始下载。
Future<String?> saveBytes({
  required String fileName,
  required Uint8List bytes,
}) async {
  final blob = web.Blob(
    <JSAny>[bytes.toJS].toJS,
    web.BlobPropertyBag(
      type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    ),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.document.createElement('a') as web.HTMLAnchorElement
    ..href = url
    ..download = fileName
    ..style.display = 'none';
  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
  return fileName;
}
