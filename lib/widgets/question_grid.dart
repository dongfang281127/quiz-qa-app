import 'package:flutter/material.dart';

import '../models/question.dart';
import '../theme/app_colors.dart';

/// 题目卡底部弹层。
/// 修复：
/// - 加了颜色图例，绿/红/灰不再靠猜；
/// - “重置进度”等待服务端完成再关弹层，失败会提示（之前静默）；
/// - 文字颜色跟随主题（之前暗色模式白底黑字/黑底黑字混乱）。
class QuestionGrid extends StatelessWidget {
  final List<Question> questions;
  final Map<int, Map<String, dynamic>> historyMap;
  final int currentIndex;
  final Function(int) onJumpToQuestion;
  final Future<void> Function() onResetProgress;

  /// 重置确认框的说明文案（整库 / 单章不同）。
  final String resetHint;

  const QuestionGrid({
    super.key,
    required this.questions,
    required this.historyMap,
    required this.currentIndex,
    required this.onJumpToQuestion,
    required this.onResetProgress,
    this.resetHint = '这将清除本套题目的所有做题记录。',
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appColors = context.appColors;
    final maxHeight = MediaQuery.of(context).size.height * 0.8;

    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('题目列表 (${questions.length})',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              TextButton.icon(
                onPressed: () async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('确定重置？'),
                      content: Text(resetHint),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          style: TextButton.styleFrom(foregroundColor: appColors.danger),
                          child: const Text('重置'),
                        ),
                      ],
                    ),
                  );
                  if (confirmed == true) {
                    if (!context.mounted) return;
                    Navigator.pop(context); // 关掉题卡
                    await onResetProgress(); // 失败会在外层提示
                  }
                },
                icon: Icon(Icons.refresh, size: 16, color: theme.colorScheme.outline),
                label: Text('重置进度',
                    style: TextStyle(color: theme.colorScheme.outline)),
              ),
            ],
          ),
          const Divider(),
          // 图例
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _legend(context, appColors.success, '答对'),
              const SizedBox(width: 16),
              _legend(context, appColors.danger, '答错'),
              const SizedBox(width: 16),
              _legend(context, theme.colorScheme.outline, '未做'),
              const SizedBox(width: 16),
              _legend(context, theme.colorScheme.primary, '当前'),
            ],
          ),
          const SizedBox(height: 8),
          Flexible(
            child: GridView.builder(
              padding: const EdgeInsets.symmetric(vertical: 10),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 5,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
              ),
              itemCount: questions.length,
              itemBuilder: (context, index) {
                final q = questions[index];
                final isAnswered = historyMap.containsKey(q.id);
                final isCorrect =
                    isAnswered ? (historyMap[q.id]?['isCorrect'] ?? false) : false;
                final isCurrent = index == currentIndex;

                Color bgColor = theme.colorScheme.outline.withValues(alpha: 0.1);
                Color textColor = theme.colorScheme.onSurface;
                Color borderColor = Colors.transparent;

                if (isAnswered) {
                  if (isCorrect) {
                    bgColor = appColors.success.withValues(alpha: 0.18);
                    textColor = appColors.success;
                    borderColor = appColors.success;
                  } else {
                    bgColor = appColors.danger.withValues(alpha: 0.18);
                    textColor = appColors.danger;
                    borderColor = appColors.danger;
                  }
                }
                if (isCurrent) {
                  borderColor = theme.colorScheme.primary;
                  if (!isAnswered) {
                    bgColor = theme.colorScheme.primary.withValues(alpha: 0.1);
                  }
                }

                return InkWell(
                  onTap: () => onJumpToQuestion(index),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    decoration: BoxDecoration(
                      color: bgColor,
                      border: Border.all(color: borderColor, width: isCurrent ? 2 : 1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    alignment: Alignment.center,
                    child: Text('${index + 1}',
                        style: TextStyle(
                            color: textColor,
                            fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal)),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _legend(BuildContext context, Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.2),
            border: Border.all(color: color),
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
