import 'package:flutter/material.dart';

import 'text_input_dialog.dart';

/// 改题库名的小弹窗。「我的题库」和「搜索结果里我自己的题库」两处共用，
/// 省得两套文案对不上。
Future<String?> showRenameBankDialog(
  BuildContext context, {
  required String currentName,
}) {
  return showTextInputDialog(
    context,
    title: '修改题库名称',
    hint: '输入新的题库名称（最多 50 字）',
    initialValue: currentName,
    maxLength: 50,
  );
}
