// 「改题库名」弹窗的行为测试。
// 原来的 widget_test.dart 是 flutter create 留下的计数器样例（Counter increments），
// 计数器早就不存在了，留着只会一直报错，这里换成对真实功能的测试。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_first/widgets/rename_bank_dialog.dart';

void main() {
  Future<void> openDialog(
    WidgetTester tester,
    void Function(String? value) onResult, {
    String currentName = '旧题库名',
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              final value =
                  await showRenameBankDialog(context, currentName: currentName);
              onResult(value);
            },
            child: const Text('打开弹窗'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开弹窗'));
    await tester.pumpAndSettle();
  }

  testWidgets('弹窗预填原名，保存时去掉首尾空格', (tester) async {
    String? result;
    await openDialog(tester, (v) => result = v);

    expect(find.text('修改题库名称'), findsOneWidget);
    expect(find.text('旧题库名'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '  新题库名  ');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(result, '新题库名');
    expect(find.text('修改题库名称'), findsNothing);
  });

  testWidgets('点取消返回 null，不误改名字', (tester) async {
    String? result = '哨兵';
    await openDialog(tester, (v) => result = v);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(result, isNull);
  });
}
