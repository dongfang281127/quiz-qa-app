import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// 三段式进度条：做对=绿、做错=红、没做=灰。
///
/// 之前用单色 [LinearProgressIndicator] 只按「做了多少」上色，做对做错看不出区别；
/// 现在按题数真实切分（flex = 题数），一眼能看出这一章/这一库里对错分布。
class SegmentedProgressBar extends StatelessWidget {
  const SegmentedProgressBar({
    super.key,
    required this.correct,
    required this.wrong,
    required this.remaining,
    this.height = 6,
  });

  /// 做对的题数（绿色段）。
  final int correct;

  /// 做错的题数（红色段）。
  final int wrong;

  /// 还没做的题数（灰色段）。
  final int remaining;

  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appColors = context.appColors;
    final emptyColor = theme.colorScheme.outline.withValues(alpha: 0.15);

    final segments = <Widget>[
      if (correct > 0)
        Expanded(flex: correct, child: ColoredBox(color: appColors.success)),
      if (wrong > 0)
        Expanded(flex: wrong, child: ColoredBox(color: appColors.danger)),
      if (remaining > 0)
        Expanded(flex: remaining, child: ColoredBox(color: emptyColor)),
    ];

    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: SizedBox(
        height: height,
        child: ColoredBox(
          color: emptyColor, // 全 0 时的兜底底色
          // 关键：Row 默认 center 对齐，没有子节点的 ColoredBox 高度会塌成 0，
          // 整条就只剩底色（全是灰的）。必须 stretch 让它撑满条高。
          child: segments.isEmpty
              ? const SizedBox.shrink()
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: segments,
                ),
        ),
      ),
    );
  }
}

/// 图例小圆点 + 文字（配合 [SegmentedProgressBar] 用）。
class LegendDot extends StatelessWidget {
  const LegendDot({super.key, required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
