import 'package:flutter/material.dart';

/// 给出题人留言弹窗。
/// 修复：空内容时禁用发送按钮（之前点了才弹“不能为空”的 SnackBar，
/// 而且那句话在 Dialog 之上基本看不见）。
class OwlMessageDialog extends StatefulWidget {
  const OwlMessageDialog({super.key});

  @override
  State<OwlMessageDialog> createState() => _OwlMessageDialogState();
}

class _OwlMessageDialogState extends State<OwlMessageDialog> {
  final TextEditingController _msgCtrl = TextEditingController();
  int _length = 0;

  @override
  void initState() {
    super.initState();
    _msgCtrl.addListener(() {
      if (mounted) setState(() => _length = _msgCtrl.text.trim().length);
    });
  }

  @override
  void dispose() {
    _msgCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('给作者留言'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('不吝赐教\n有什么思绪或建议，请在此落笔...',
              style: TextStyle(fontSize: 12)),
          const SizedBox(height: 10),
          TextField(
            controller: _msgCtrl,
            maxLines: 3,
            maxLength: 200,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: '在此输入内容...',
              counterText: '',
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.all(12),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Text('$_length/200',
                style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('取消'),
        ),
        ElevatedButton.icon(
          onPressed: _length == 0 || _length > 200
              ? null
              : () => Navigator.of(context).pop(_msgCtrl.text.trim()),
          icon: const Icon(Icons.send, size: 16),
          label: const Text('发送'),
        ),
      ],
    );
  }
}
