import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../services/exam_service.dart';
import '../theme/app_colors.dart';
import '../utils/error_text.dart';
import '../utils/time_text.dart';
import '../widgets/async_view.dart';

/// 信箱（收到他人的留言）。
/// 修复：
/// - 之前 created_at 为空时 substring 直接崩溃；
/// - 滑动删除不再立即永久删（先确认，再提供撤销）；
/// - 未登录不再永远转圈；支持下拉刷新；
/// - 删除按 id 定位，不再依赖可能错位的 index。
class MyMessagesPage extends StatefulWidget {
  const MyMessagesPage({super.key});

  @override
  State<MyMessagesPage> createState() => _MyMessagesPageState();
}

class _MyMessagesPageState extends State<MyMessagesPage> {
  final ExamService _examService = ExamService();
  List<Map<String, dynamic>> _messages = [];
  AsyncStatus _status = AsyncStatus.loading;
  String _errorText = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _status = AsyncStatus.loading;
      _errorText = '';
    });
    if (!AuthService.instance.isLoggedIn) {
      if (!mounted) return;
      setState(() => _status = AsyncStatus.empty);
      return;
    }
    try {
      final rows = await _examService.fetchMessages();
      if (!mounted) return;
      setState(() {
        _messages = rows;
        _status = _messages.isEmpty ? AsyncStatus.empty : AsyncStatus.data;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorText = friendlyError(e);
        _status = AsyncStatus.error;
      });
    }
  }

  Future<void> _deleteMessage(Map<String, dynamic> msg) async {
    final id = (msg['id'] as num?)?.toInt();
    if (id == null) return;

    final backup = Map<String, dynamic>.from(msg);
    final idx = _messages.indexWhere((m) => m['id'] == id);
    setState(() => _messages.removeAt(idx));

    try {
      await _examService.deleteOwlMessage(id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('留言已删除'),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () async {
            try {
              await _examService.restoreOwlMessage(backup);
              if (!mounted) return;
              setState(() {
                _messages.insert(idx.clamp(0, _messages.length), backup);
                if (_status == AsyncStatus.empty) _status = AsyncStatus.data;
              });
            } catch (e) {
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('恢复失败：${friendlyError(e)}')));
            }
          },
        ),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (idx >= 0 && idx <= _messages.length) _messages.insert(idx, backup);
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('删除失败：${friendlyError(e)}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('信箱')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: AsyncView(
          status: _status,
          onRetry: _load,
          emptyIcon: Icons.mark_email_unread_outlined,
          emptyText: '还没有收到留言\n当有人对你的题目留言时会出现在这里',
          errorText: _errorText,
          dataBuilder: (context) => ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            itemCount: _messages.length,
            itemBuilder: (context, index) {
              final msg = _messages[index];
              final time = formatRelative(msg['created_at']);
              return Dismissible(
                key: ValueKey('msg_${msg['id']}'),
                direction: DismissDirection.endToStart,
                confirmDismiss: (_) async {
                  // 滑动不再直接删，弹确认
                  return await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('删除留言'),
                          content: const Text('确定删除这条留言吗？'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              style: TextButton.styleFrom(foregroundColor: context.appColors.danger),
                              child: const Text('删除'),
                            ),
                          ],
                        ),
                      ) ??
                      false;
                },
                onDismissed: (_) => _deleteMessage(msg),
                background: Container(
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 20),
                  decoration: BoxDecoration(
                    color: context.appColors.danger,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(Icons.delete, color: context.appColors.onDanger),
                ),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.account_circle, size: 20, color: context.appColors.info),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(msg['sender_nickname']?.toString() ?? '匿名',
                                  style: const TextStyle(fontWeight: FontWeight.bold)),
                            ),
                            Text(time,
                                style: TextStyle(
                                    fontSize: 12, color: theme.colorScheme.outline)),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.outline.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '来源: 《${msg['group_name'] ?? ''}》\n题目: ${msg['question_preview'] ?? ''}',
                            style: TextStyle(
                                fontSize: 12, color: theme.colorScheme.outline),
                          ),
                        ),
                        const SizedBox(height: 10),
                        SelectableText(msg['message_content']?.toString() ?? '',
                            style: const TextStyle(fontSize: 16)),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
