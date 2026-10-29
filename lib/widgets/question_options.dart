import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// 选项列表。
/// 修复：
/// - 浅色模式下“选中 = 白字配淡绿底”几乎不可读 → 用 colorScheme.primary/onPrimary；
/// - BoxDecoration 同时给了 BoxShape.circle 和 borderRadius（语义冲突）→ 分开处理；
/// - 揭晓答案后用语义色（success/danger），深色主题下不再和主色混在一起。
class QuestionOptions extends StatelessWidget {
  final List<String> options;
  final Set<int> selectedIndices;
  final bool isMultiSelect;
  final bool isAnswerRevealed;
  final List<int> correctIndices;
  final Function(int) onOptionTap;

  const QuestionOptions({
    super.key,
    required this.options,
    required this.selectedIndices,
    this.isMultiSelect = false,
    required this.isAnswerRevealed,
    required this.correctIndices,
    required this.onOptionTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final appColors = context.appColors;

    return Column(
      children: List.generate(options.length, (index) {
        final letter = String.fromCharCode(65 + index);
        final isSelected = selectedIndices.contains(index);
        final isCorrect = correctIndices.contains(index);

        Color bgColor = Colors.transparent;
        Color borderColor =
            isDark ? Colors.white24 : theme.colorScheme.outlineVariant;
        Color textColor = theme.colorScheme.onSurface;

        if (isAnswerRevealed) {
          if (isCorrect) {
            bgColor = appColors.success.withValues(alpha: 0.16);
            borderColor = appColors.success;
            textColor = appColors.success;
          } else if (isSelected && !isCorrect) {
            bgColor = appColors.danger.withValues(alpha: 0.16);
            borderColor = appColors.danger;
            textColor = appColors.danger;
          }
        } else if (isSelected) {
          bgColor = theme.colorScheme.primary;
          borderColor = theme.colorScheme.primary;
          textColor = theme.colorScheme.onPrimary;
        }

        // 判定小方块/圆圈里的前景色
        Color markBg;
        Color markBorder;
        Color markText;
        if (isAnswerRevealed) {
          if (isCorrect) {
            markBg = appColors.success;
            markBorder = appColors.success;
            markText = appColors.onSuccess;
          } else if (isSelected) {
            markBg = appColors.danger;
            markBorder = appColors.danger;
            markText = appColors.onDanger;
          } else {
            markBg = Colors.transparent;
            markBorder = theme.colorScheme.outline;
            markText = theme.colorScheme.outline;
          }
        } else if (isSelected) {
          markBg = theme.colorScheme.onPrimary;
          markBorder = theme.colorScheme.onPrimary;
          markText = theme.colorScheme.primary;
        } else {
          markBg = Colors.transparent;
          markBorder = theme.colorScheme.outline;
          markText = theme.colorScheme.outline;
        }

        return GestureDetector(
          onTap: () => onOptionTap(index),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: bgColor,
              border: Border.all(
                color: borderColor,
                width: isSelected || (isAnswerRevealed && isCorrect) ? 2 : 1,
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: markBg,
                    shape: isMultiSelect ? BoxShape.rectangle : BoxShape.circle,
                    borderRadius:
                        isMultiSelect ? BorderRadius.circular(5) : null,
                    border: Border.all(color: markBorder, width: 1.5),
                  ),
                  child: Text(letter,
                      style: TextStyle(
                          color: markText,
                          fontWeight: FontWeight.bold,
                          fontSize: 12)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(options[index],
                      style: TextStyle(
                          fontSize: 16,
                          color: textColor,
                          fontWeight:
                              isSelected ? FontWeight.bold : FontWeight.normal)),
                ),
                if (isAnswerRevealed)
                  if (isCorrect)
                    Icon(Icons.check_circle, color: appColors.success, size: 20)
                  else if (isSelected)
                    Icon(Icons.cancel, color: appColors.danger, size: 20),
              ],
            ),
          ),
        );
      }),
    );
  }
}
