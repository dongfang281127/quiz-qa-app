import 'package:flutter/material.dart';
import 'package:flutter_first/theme/app_colors.dart';
import 'package:flutter_first/widgets/segmented_progress_bar.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(
      theme: ThemeData(extensions: const [AppColors.light]),
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 200, child: child),
        ),
      ),
    );

/// Material/Scaffold 自己也会插 ColoredBox，所以只看进度条内部的。
Finder get _bars => find.descendant(
      of: find.byType(SegmentedProgressBar),
      matching: find.byType(ColoredBox),
    );

List<ColoredBox> _boxes(WidgetTester tester) =>
    tester.widgetList<ColoredBox>(_bars).toList();

void main() {
  testWidgets('一正一错：绿红各占半条，且高度撑满（回归：曾经全是灰）', (tester) async {
    await tester.pumpWidget(_wrap(
      const SegmentedProgressBar(
          correct: 1, wrong: 1, remaining: 0, height: 6),
    ));

    final boxes = _boxes(tester);
    expect(boxes.length, 3, reason: '外层底条 + 绿色段 + 红色段');
    expect(boxes[1].color, AppColors.light.success);
    expect(boxes[2].color, AppColors.light.danger);

    final green = tester.getSize(find.byWidget(boxes[1]));
    final red = tester.getSize(find.byWidget(boxes[2]));
    // 之前 Row 默认 center 对齐，ColoredBox 没子节点 → 高度塌成 0，整条只剩灰色底色
    expect(green.height, 6);
    expect(red.height, 6);
    expect(green.width, closeTo(100, 1));
    expect(red.width, closeTo(100, 1));
  });

  testWidgets('两题全错：只有红色段', (tester) async {
    await tester.pumpWidget(_wrap(
      const SegmentedProgressBar(correct: 0, wrong: 2, remaining: 0),
    ));

    final boxes = _boxes(tester);
    expect(boxes.length, 2, reason: '外层底条 + 红色段');
    expect(boxes[1].color, AppColors.light.danger);
    expect(tester.getSize(find.byWidget(boxes[1])).height, 6);
    expect(tester.getSize(find.byWidget(boxes[1])).width, 200);
  });

  testWidgets('有未做题目：灰色段按剩余题数占位', (tester) async {
    await tester.pumpWidget(_wrap(
      const SegmentedProgressBar(correct: 1, wrong: 1, remaining: 2),
    ));

    final boxes = _boxes(tester);
    expect(boxes.length, 4, reason: '外层底条 + 绿 + 红 + 灰');
    expect(tester.getSize(find.byWidget(boxes[1])).width, closeTo(50, 1));
    expect(tester.getSize(find.byWidget(boxes[2])).width, closeTo(50, 1));
    expect(tester.getSize(find.byWidget(boxes[3])).width, closeTo(100, 1));
  });

  testWidgets('一道题都没有：只显示灰色底条，不崩', (tester) async {
    await tester.pumpWidget(_wrap(
      const SegmentedProgressBar(correct: 0, wrong: 0, remaining: 0),
    ));

    expect(_bars, findsOneWidget);
    expect(tester.getSize(find.byType(SegmentedProgressBar)).height, 6);
  });
}
