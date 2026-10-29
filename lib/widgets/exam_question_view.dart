import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/question.dart';
import '../theme/app_colors.dart';
import 'comment_section.dart';
import 'question_options.dart';

class ExamQuestionView extends StatelessWidget {
  final Question question;
  final List<String> currentOptions;
  final Set<int> selectedIndices;
  final bool isAnswerRevealed;
  final bool showSubmitBtn;
  final int currentIndex;
  final VoidCallback onNextQuestion;
  final VoidCallback onPrevQuestion;
  final VoidCallback onSubmitAnswer;
  final Function(int) onOptionTap;
  final bool isFavorite;
  final bool isFavoriteBusy;
  final VoidCallback onToggleFavorite;

  const ExamQuestionView({
    super.key,
    required this.question,
    required this.currentOptions,
    required this.selectedIndices,
    required this.isAnswerRevealed,
    required this.showSubmitBtn,
    required this.currentIndex,
    required this.onNextQuestion,
    required this.onPrevQuestion,
    required this.onSubmitAnswer,
    required this.onOptionTap,
    required this.isFavorite,
    required this.isFavoriteBusy,
    required this.onToggleFavorite,
  });

  String _letters(List<int> indices) =>
      indices.map((i) => String.fromCharCode(65 + i)).join('、');

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final correct =
        selectedIndices.length == question.answerIndices.length &&
        selectedIndices.every(question.answerIndices.contains);
    return GestureDetector(
      onHorizontalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (v < -350) {
          onNextQuestion();
        } else if (v > 350) {
          onPrevQuestion();
        }
      },
      child: KeyedSubtree(
        key: ValueKey('question_view_$currentIndex'),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    margin: const EdgeInsets.only(top: 4, right: 8),
                    decoration: BoxDecoration(
                      color: question.isMultiSelect
                          ? colors.warning
                          : colors.info,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      question.isMultiSelect ? '多选' : '单选',
                      style: TextStyle(fontSize: 12, color: colors.onWarning),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      question.text,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: isFavorite ? '取消收藏' : '收藏题目',
                    onPressed: isFavoriteBusy ? null : onToggleFavorite,
                    icon: isFavoriteBusy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            isFavorite ? Icons.star : Icons.star_border,
                            // 点亮必须是黄的：灰星星看不出收没收
                            color: isFavorite ? colors.favorite : null,
                            size: 26,
                          ),
                  ),
                ],
              ),
              const SizedBox(height: 30),
              QuestionOptions(
                options: currentOptions,
                selectedIndices: selectedIndices,
                isMultiSelect: question.isMultiSelect,
                isAnswerRevealed: isAnswerRevealed,
                correctIndices: question.answerIndices,
                onOptionTap: onOptionTap,
              ),
              if (isAnswerRevealed && question.hasValidAnswer)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(top: 16),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: (correct ? colors.success : colors.danger)
                        .withValues(alpha: .08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        correct ? '回答正确' : '回答错误',
                        style: TextStyle(
                          color: correct ? colors.success : colors.danger,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        selectedIndices.isEmpty
                            ? '你的答案：未作答'
                            : '你的答案：${_letters(selectedIndices.toList()..sort())}',
                      ),
                      Text('正确答案：${_letters(question.answerIndices)}'),
                    ],
                  ),
                ),
              if (!question.hasValidAnswer && isAnswerRevealed)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    '⚠️ 这道题的答案数据不完整，无法判分',
                    style: TextStyle(color: colors.warning, fontSize: 12),
                  ),
                ),
              if (showSubmitBtn)
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: selectedIndices.isEmpty
                          ? null
                          : onSubmitAnswer,
                      child: Text(question.isMultiSelect ? '提交多选答案' : '确认'),
                    ),
                  ),
                ),
              if (isAnswerRevealed)
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: onPrevQuestion,
                          icon: const Icon(Icons.arrow_back),
                          label: const Text('上一题'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () {
                            HapticFeedback.selectionClick();
                            onNextQuestion();
                          },
                          icon: const Icon(Icons.arrow_forward),
                          label: const Text('下一题'),
                        ),
                      ),
                    ],
                  ),
                ),
              const Divider(height: 40),
              CommentSection(
                questionId: question.id,
                isAnswerRevealed: isAnswerRevealed,
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}
