import 'package:flutter/material.dart';

/// 一个「输入一行文字然后确认」的通用弹窗。
/// 取消返回 null，确认返回去掉首尾空格的字符串（可能为空串，由调用方校验）。
///
/// 为什么是 StatefulWidget 而不是在调用处 new 一个 controller 再 dispose：
/// showDialog 返回后路由还在播放退场动画，TextField 仍然持有 controller，
/// 那时立刻 dispose 会抛 “A TextEditingController was used after being disposed”。
/// 让弹窗自己持有并在 dispose 里释放，生命周期才对得上。
Future<String?> showTextInputDialog(
  BuildContext context, {
  required String title,
  required String hint,
  String initialValue = '',
  int maxLength = 50,
  String confirmText = '保存',
  String cancelText = '取消',
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _TextInputDialog(
      title: title,
      hint: hint,
      initialValue: initialValue,
      maxLength: maxLength,
      confirmText: confirmText,
      cancelText: cancelText,
    ),
  );
}

class _TextInputDialog extends StatefulWidget {
  const _TextInputDialog({
    required this.title,
    required this.hint,
    required this.initialValue,
    required this.maxLength,
    required this.confirmText,
    required this.cancelText,
  });

  final String title;
  final String hint;
  final String initialValue;
  final int maxLength;
  final String confirmText;
  final String cancelText;

  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialValue);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: widget.maxLength,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(hintText: widget.hint, counterText: ''),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.cancelText),
        ),
        TextButton(
          onPressed: _submit,
          child: Text(widget.confirmText),
        ),
      ],
    );
  }
}
