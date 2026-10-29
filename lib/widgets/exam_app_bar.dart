import 'package:flutter/material.dart';

/// 顶部导航栏。
/// 修复：
/// - 题库名显示进副标题（之前不知道自己在做哪套题）；
/// - 当前模式显示为角标文字，不再只靠一个换向箭头图标去猜；
/// - 动作收纳：排序/留言进 overflow 菜单，避免小屏溢出。
enum ExamMode { rapid, practice, memorize }

class ExamAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String bankName;
  final int currentIndex;
  final int totalCount;
  final bool isShuffleOn;
  final ExamMode currentMode;
  final VoidCallback onToggleSort;
  final VoidCallback onSendMessage;
  final VoidCallback onShowGrid;
  final Function(ExamMode) onModeChanged;

  /// 只有题库作者才会拿到：右上角菜单里的「修改该题」，就排在「给出题人留言」下面。
  final VoidCallback? onEditQuestion;

  const ExamAppBar({
    super.key,
    required this.bankName,
    required this.currentIndex,
    required this.totalCount,
    required this.isShuffleOn,
    required this.currentMode,
    required this.onToggleSort,
    required this.onSendMessage,
    required this.onShowGrid,
    required this.onModeChanged,
    this.onEditQuestion,
  });

  String get _modeLabel => switch (currentMode) {
    ExamMode.rapid => '快速',
    ExamMode.practice => '练习',
    ExamMode.memorize => '背题',
  };

  @override
  Widget build(BuildContext context) {
    return AppBar(
      titleSpacing: 0,
      title: GestureDetector(
        // 自主跳转入口：点标题直接打开题目卡（之前图标收进菜单后用户找不到了）
        behavior: HitTestBehavior.opaque,
        onTap: onShowGrid,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '第 ${currentIndex + 1}/$totalCount 题',
                  style: const TextStyle(fontSize: 17),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.expand_more,
                  size: 18,
                  color: Theme.of(context).colorScheme.outline,
                ),
              ],
            ),
            if (bankName.isNotEmpty)
              Text(
                bankName,
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
          ],
        ),
      ),
      actions: [
        // 自主跳转的显式按钮：随时点开题目卡，点任意题号即可跳过去
        IconButton(
          icon: const Icon(Icons.grid_view),
          tooltip: '题目卡（跳转到任意题）',
          onPressed: onShowGrid,
        ),
        Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                _modeLabel,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          ),
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.tune),
          tooltip: '练习选项',
          onSelected: (key) {
            switch (key) {
              case 'sort':
                onToggleSort();
                break;
              case 'mode_rapid':
                onModeChanged(ExamMode.rapid);
                break;
              case 'mode_practice':
                onModeChanged(ExamMode.practice);
                break;
              case 'mode_memorize':
                onModeChanged(ExamMode.memorize);
                break;
              case 'mail':
                onSendMessage();
                break;
              case 'edit':
                onEditQuestion?.call();
                break;
              case 'grid':
                onShowGrid();
                break;
            }
          },
          itemBuilder: (context) => [
            CheckedPopupMenuItem(
              value: 'mode_rapid',
              checked: currentMode == ExamMode.rapid,
              child: const Text('⚡ 快速模式 — 点选项即判题'),
            ),
            CheckedPopupMenuItem(
              value: 'mode_practice',
              checked: currentMode == ExamMode.practice,
              child: const Text('🛡️ 练习模式 — 选完点确认'),
            ),
            CheckedPopupMenuItem(
              value: 'mode_memorize',
              checked: currentMode == ExamMode.memorize,
              child: const Text('📖 背题模式 — 直接看答案'),
            ),
            const PopupMenuDivider(),
            PopupMenuItem(
              value: 'sort',
              child: Row(
                children: [
                  Icon(isShuffleOn ? Icons.sort : Icons.shuffle, size: 18),
                  const SizedBox(width: 10),
                  Text(isShuffleOn ? '切换为顺序' : '切换为乱序'),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'grid',
              child: Row(
                children: [
                  Icon(Icons.grid_view, size: 18),
                  SizedBox(width: 10),
                  Text('题目卡 / 重置进度'),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'mail',
              child: Row(
                children: [
                  Icon(Icons.mail_outline, size: 18),
                  SizedBox(width: 10),
                  Text('给出题人留言'),
                ],
              ),
            ),
            // 紧跟在留言下面：改题是作者才会用到的动作，收在同一个菜单里就够了
            if (onEditQuestion != null)
              const PopupMenuItem(
                value: 'edit',
                child: Row(
                  children: [
                    Icon(Icons.edit_outlined, size: 18),
                    SizedBox(width: 10),
                    Text('修改该题'),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
}
