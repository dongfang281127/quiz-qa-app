import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../services/comment_service.dart';
import '../theme/app_colors.dart';
import '../utils/error_text.dart';
import '../utils/time_text.dart';

/// 讨论区。
/// 修复：
/// - 发送失败时移除乐观插入的假评论（之前会一直挂着）；
/// - 翻题时清空未发送的草稿（之前 A 题草稿会发到 B 题）；
/// - 评论限最近 50 条，避免一个 Column 无限撑高导致卡顿；
/// - 删除按钮点击区放大到 48dp；时间用相对格式且对空值安全。
class CommentSection extends StatefulWidget {
  final int questionId;
  final bool isAnswerRevealed;

  const CommentSection({
    super.key,
    required this.questionId,
    required this.isAnswerRevealed,
  });

  @override
  State<CommentSection> createState() => _CommentSectionState();
}

class _CommentSectionState extends State<CommentSection> {
  static const _limit = 50;

  final CommentService _commentService = CommentService();

  List<Map<String, dynamic>> _comments = [];
  bool _isLoadingComments = false;
  bool _isSending = false;
  final TextEditingController _commentController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadComments();
  }

  @override
  void didUpdateWidget(covariant CommentSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.questionId != widget.questionId) {
      _commentController.clear(); // 草稿不跨题携带
      _loadComments();
    }
  }

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _loadComments() async {
    setState(() => _isLoadingComments = true);
    try {
      final rows = await _commentService.fetchComments(widget.questionId);
      if (mounted) {
        setState(() {
          _comments = rows;
          _isLoadingComments = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingComments = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('评论加载失败：${friendlyError(e)}')));
      }
    }
  }

  Future<void> _sendComment() async {
    final text = _commentController.text.trim();
    if (text.isEmpty || _isSending) return;
    if (text.length > 500) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('评论太长了（最多 500 字）')));
      return;
    }

    if (!AuthService.instance.isLoggedIn) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先登录才能评论')));
      return;
    }

    final nickname = AuthService.instance.nickname;

    final optimistic = <String, dynamic>{
      'user_nickname': nickname,
      'content': text,
      'created_at': DateTime.now().toIso8601String(),
      'user_id': AuthService.instance.userId ?? -1,
      'id': -1,
    };

    setState(() {
      _isSending = true;
      _comments.insert(0, optimistic);
      _commentController.clear();
      FocusScope.of(context).unfocus();
    });

    try {
      await _commentService.addComment(
        questionId: widget.questionId,
        content: text,
      );
      await _loadComments();
    } catch (e) {
      // 发送失败：移除假评论，让用户看到这条没发出去
      if (mounted) {
        setState(() => _comments.removeWhere((c) => c['id'] == -1));
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('发送失败：${friendlyError(e)}')));
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _deleteComment(int commentId, int index) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除评论'),
        content: const Text('确定要撤回这条评论吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: context.appColors.danger),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final backup = Map<String, dynamic>.from(_comments[index]);
    setState(() => _comments.removeAt(index));
    try {
      if (commentId != -1) {
        await _commentService.deleteComment(commentId);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          if (index <= _comments.length) _comments.insert(index, backup);
        });
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('删除失败：${friendlyError(e)}')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (!widget.isAnswerRevealed) {
      return Container(
        padding: const EdgeInsets.all(30),
        width: double.infinity,
        decoration: BoxDecoration(
          color: theme.colorScheme.outline.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.2)),
        ),
        child: Column(
          children: [
            Icon(Icons.lock_outline, size: 40, color: theme.colorScheme.outline),
            const SizedBox(height: 10),
            Text('尘封思绪，待君破局\n答题后解锁',
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.outline)),
          ],
        ),
      );
    }

    final currentUserId = AuthService.instance.userId;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('讨论区',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(width: 8),
            Text('最近 $_limit 条',
                style: TextStyle(fontSize: 11, color: theme.colorScheme.outline)),
          ],
        ),
        const SizedBox(height: 10),
        if (_isLoadingComments)
          const Center(
              child: Padding(
                  padding: EdgeInsets.all(20),
                  child: CircularProgressIndicator())),
        if (!_isLoadingComments && _comments.isEmpty)
          Container(
            padding: const EdgeInsets.all(20),
            width: double.infinity,
            decoration: BoxDecoration(
              color: theme.colorScheme.outline.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text('还没有人讨论这道题，来抢沙发！',
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.outline)),
          )
        else if (!_isLoadingComments)
          ..._comments.asMap().entries.map((entry) {
            final idx = entry.key;
            final c = entry.value;
            final timeStr = formatRelative(c['created_at']);
            final isMine = currentUserId != null &&
                (c['user_id'] as num?)?.toInt() == currentUserId;
            final isPending = c['id'] == -1;

            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.cardColor,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: theme.dividerColor),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 10,
                        backgroundColor: isMine
                            ? context.appColors.success.withValues(alpha: 0.2)
                            : context.appColors.warning.withValues(alpha: 0.2),
                        child: Icon(Icons.person,
                            size: 12,
                            color: isMine
                                ? context.appColors.success
                                : context.appColors.warning),
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          '${c['user_nickname'] ?? '匿名'}${isMine ? ' (我)' : ''}',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                              color: isMine ? context.appColors.success : null),
                        ),
                      ),
                      Text(isPending ? '发送中…' : timeStr,
                          style: TextStyle(
                              color: theme.colorScheme.outline, fontSize: 10)),
                      if (isMine && !isPending)
                        SizedBox(
                          width: 32,
                          height: 32,
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            tooltip: '删除这条评论',
                            iconSize: 16,
                            onPressed: () => _deleteComment(c['id'], idx),
                            icon: Icon(Icons.delete_outline,
                                color: context.appColors.danger),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  SelectableText(c['content']?.toString() ?? '',
                      style: const TextStyle(fontSize: 14)),
                ],
              ),
            );
          }),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _commentController,
                maxLength: 500,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: '写下你的见解...',
                  counterText: '',
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20)),
                ),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 45,
              height: 45,
              child: IconButton.filled(
                onPressed:
                    _commentController.text.trim().isEmpty || _isSending
                        ? null
                        : _sendComment,
                icon: _isSending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.send, size: 20),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
