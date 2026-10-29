import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// 底部统计条。
/// 修复：颜色改语义色；正确率标注清楚是“全部记录”而不是“本次”。
class ExamStatsBar extends StatelessWidget {
  final int completedCount;
  final int totalCount;
  final int remainingCount;
  final String accuracy;

  const ExamStatsBar({
    super.key,
    required this.completedCount,
    required this.totalCount,
    required this.remainingCount,
    required this.accuracy,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final appColors = context.appColors;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 20),
      decoration: BoxDecoration(
        color: isDark
            ? Theme.of(context).colorScheme.surface
            : Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(
            top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _buildStatItem(context, '已完成', '$completedCount / $totalCount', appColors.info),
          _buildStatItem(context, '剩余', '$remainingCount', appColors.warning),
          _buildStatItem(context, '总正确率', accuracy, appColors.success),
        ],
      ),
    );
  }

  Widget _buildStatItem(BuildContext context, String label, String value, Color color) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value,
            style: TextStyle(color: color, fontSize: 16, fontWeight: FontWeight.bold)),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
