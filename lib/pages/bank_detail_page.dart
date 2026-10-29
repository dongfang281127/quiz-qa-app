import 'package:flutter/material.dart';

import '../models/bank.dart';
import '../models/bank_chapter.dart';
import '../services/bank_service.dart';
import '../theme/app_colors.dart';
import '../utils/error_text.dart';
import '../widgets/async_view.dart';
import '../widgets/segmented_progress_bar.dart';
import 'exam_page.dart';

/// 题库详情：题库 → 章节列表 → 只练某一章。
/// 之前点题库直接进考场（一次性几百题），现在中间加了这一层，
/// 章节统计由后端一条聚合 SQL 算好，进来就能看到每章练了多少。
class BankDetailPage extends StatefulWidget {
  const BankDetailPage({super.key, required this.bank});

  final Bank bank;

  @override
  State<BankDetailPage> createState() => _BankDetailPageState();
}

class _BankDetailPageState extends State<BankDetailPage> {
  final BankService _bankService = BankService();

  BankSummary? _summary;
  AsyncStatus _status = AsyncStatus.loading;
  String? _errorText;
  bool _isOpening = false;

  /// 当前选中的学科；null 表示还没选过（默认落第一个）。
  String? _selectedSubject;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _status = AsyncStatus.loading;
      _errorText = null;
    });
    try {
      final summary = await _bankService.fetchBankSummary(widget.bank.id);
      if (!mounted) return;
      setState(() {
        _summary = summary;
        _status = summary.total == 0 ? AsyncStatus.empty : AsyncStatus.data;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = AsyncStatus.error;
        _errorText = friendlyError(e);
      });
    }
  }

  /// 打开考场。chapter 为 null 表示整个题库。
  Future<void> _openExam({
    String? chapter,
    String? chapterName,
    String? subject,
  }) async {
    if (_isOpening) return;
    setState(() => _isOpening = true);
    try {
      final questions = await _bankService.fetchQuestionsOfBank(
        widget.bank.id,
        chapter: chapter,
        subject: subject,
      );
      if (!mounted) return;
      if (questions.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('这一章还没有题目')));
        return;
      }
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ExamPage(
            bank: widget.bank,
            questionsRaw: questions,
            chapter: chapter,
            chapterName: chapterName,
            subject: subject,
          ),
        ),
      );
      // 从考场回来刷新统计（做题/重置都会改变进度）
      if (mounted) await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('加载题目失败：${friendlyError(e)}')));
    } finally {
      if (mounted) setState(() => _isOpening = false);
    }
  }

  /// 只重置这一章的进度。
  Future<void> _resetChapter(BankChapter chapter) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重刷这一章？'),
        content: Text('将清除「${chapter.label}」的 ${chapter.done} 条做题记录，其他章节不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
              foregroundColor: context.appColors.danger,
            ),
            child: const Text('重刷'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      await _bankService.resetChapterProgress(
        widget.bank.id,
        chapter.chapter,
        subject: chapter.subject.trim(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已重刷「${chapter.label}」')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('重置失败：${friendlyError(e)}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.bank.name, style: const TextStyle(fontSize: 17)),
            Text(
              widget.bank.authorName,
              style: TextStyle(fontSize: 11, color: theme.colorScheme.outline),
            ),
          ],
        ),
        // 取题中的进度条放在 AppBar 底部：高度固定 2，不挤占列表，列表因此不会整体位移
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: SizedBox(
            height: 2,
            child: _isOpening
                ? const LinearProgressIndicator(minHeight: 2)
                : null,
          ),
        ),
      ),
      body: AsyncView(
        status: _status,
        onRetry: _load,
        errorText: _errorText,
        loadingText: '正在读取章节…',
        emptyIcon: Icons.menu_book_outlined,
        emptyText: '这个题库还没有题目',
        dataBuilder: (_) => _buildBody(context),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final summary = _summary!;
    final theme = Theme.of(context);
    final appColors = context.appColors;

    // 学科列表（按出现顺序去重）；真的分了多个学科才显示「选择学科」这一行
    final subjects = <String>[];
    for (final c in summary.chapters) {
      final s = c.subject.trim();
      if (s.isEmpty || subjects.contains(s)) continue;
      subjects.add(s);
    }
    final hasUnassigned = summary.chapters.any((c) => c.subject.trim().isEmpty);
    if (subjects.length > 1 && hasUnassigned) subjects.insert(0, '未分学科');
    final showSubjects =
        subjects.length > 1 || (subjects.length == 1 && hasUnassigned);
    final selected = !showSubjects
        ? null
        : (subjects.contains(_selectedSubject)
              ? _selectedSubject!
              : subjects.first);
    final visibleChapters = selected == null
        ? summary.chapters
        : summary.chapters
              .where(
                (c) => (selected == '未分学科'
                    ? c.subject.trim().isEmpty
                    : c.subject.trim() == selected),
              )
              .toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        _SummaryCard(summary: summary),
        const SizedBox(height: 16),
        // 有多个学科时：先选学科，再看这个学科下面的章节
        if (showSubjects) ...[
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Text('选择学科', style: theme.textTheme.titleSmall),
          ),
          SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: subjects.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final subject = subjects[i];
                final isOn = subject == selected;
                return ChoiceChip(
                  key: ValueKey('subject:$subject'),
                  label: Text(subject),
                  selected: isOn,
                  showCheckmark: false,
                  selectedColor: theme.colorScheme.primary.withValues(
                    alpha: 0.16,
                  ),
                  labelStyle: TextStyle(
                    fontSize: 13,
                    fontWeight: isOn ? FontWeight.w600 : FontWeight.normal,
                    color: isOn
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurface,
                  ),
                  onSelected: (_) => setState(() => _selectedSubject = subject),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
        ],
        // 多章节时才给「整库练」入口，单章节没必要多一步
        if (summary.hasMultipleChapters)
          Card(
            key: const ValueKey('all-questions'),
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              leading: Icon(
                Icons.playlist_play,
                color: theme.colorScheme.primary,
              ),
              title: const Text('全部题目'),
              subtitle: Text('共 ${summary.total} 题 · 已练 ${summary.done}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _openExam(),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          child: Row(
            children: [
              Text(
                selected == null ? '章节' : '$selected · 章节',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(width: 6),
              Text(
                '(${visibleChapters.length})',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
              const Spacer(),
              if (visibleChapters.isNotEmpty)
                Text(
                  '正确率',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: appColors.success,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        ),
        for (final chapter in visibleChapters)
          _ChapterTile(
            // 稳定 key：列表项按身份而不是下标复用。
            // 没有它时，列表里插入/移除任何一个兄弟节点（例如取题进度条）都会让
            // Flutter 按 index 重新绑定元素，点击水波纹会画到相邻的那一张卡片上。
            key: ValueKey('chapter:${chapter.subject}|${chapter.chapter}'),
            chapter: chapter,
            onTap: () => _openExam(
              chapter: chapter.filterValue,
              chapterName: chapter.label,
              subject: chapter.subject.trim(),
            ),
            onReset: () => _resetChapter(chapter),
          ),
      ],
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary});
  final BankSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appColors = context.appColors;
    final progress = summary.total == 0 ? 0.0 : summary.done / summary.total;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _Stat(
                  label: '总题数',
                  value: '${summary.total}',
                  color: theme.colorScheme.onSurface,
                ),
                _Stat(
                  label: '已练',
                  value: '${summary.done}',
                  color: theme.colorScheme.primary,
                ),
                _Stat(
                  label: '正确率',
                  value: summary.accuracyText,
                  color: appColors.success,
                ),
                _Stat(
                  label: '剩余',
                  value: '${summary.remaining}',
                  color: theme.colorScheme.outline,
                ),
              ],
            ),
            const SizedBox(height: 14),
            // 三段进度：绿=做对、红=做错、灰=还没做
            SegmentedProgressBar(
              correct: summary.correct,
              wrong: summary.done - summary.correct,
              remaining: summary.remaining,
              height: 8,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                LegendDot(
                  color: appColors.success,
                  label: '做对 ${summary.correct}',
                ),
                const SizedBox(width: 14),
                LegendDot(
                  color: appColors.danger,
                  label: '做错 ${summary.done - summary.correct}',
                ),
                const SizedBox(width: 14),
                LegendDot(
                  color: theme.colorScheme.outline.withValues(alpha: 0.35),
                  label: '未做 ${summary.remaining}',
                ),
                const Spacer(),
                Text(
                  '${(progress * 100).round()}%',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, required this.color});
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        const SizedBox(height: 2),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

/// 正确率配色：≥80% 绿、60–79% 橙、<60% 红；没练过用灰（outline）。
Color _accuracyColor(BuildContext context, BankChapter chapter) {
  if (chapter.done <= 0) return Theme.of(context).colorScheme.outline;
  final accuracy = chapter.accuracy;
  if (accuracy >= 0.8) return context.appColors.success;
  if (accuracy >= 0.6) return context.appColors.warning;
  return context.appColors.danger;
}

class _ChapterTile extends StatelessWidget {
  const _ChapterTile({
    super.key,
    required this.chapter,
    required this.onTap,
    required this.onReset,
  });

  final BankChapter chapter;
  final VoidCallback onTap;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appColors = context.appColors;
    final accuracyColor = _accuracyColor(context, chapter);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      chapter.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (chapter.allDone)
                    Icon(
                      Icons.check_circle,
                      size: 16,
                      color: appColors.success,
                    ),
                  const SizedBox(width: 4),
                  // 重刷按钮固定占住右上角这一格。
                  // 以前它是「做过题才出现」的条件节点，一出现就把左边的进度条挤短，
                  // 于是同一个列表里每行的进度条长度都不一样（未开始的看起来特别长）。
                  SizedBox(
                    width: 52,
                    height: 32,
                    child: chapter.done > 0
                        ? TextButton(
                            onPressed: onReset,
                            style: TextButton.styleFrom(
                              foregroundColor: theme.colorScheme.outline,
                              padding: EdgeInsets.zero,
                              minimumSize: const Size(52, 32),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: const Text(
                              '重刷',
                              style: TextStyle(fontSize: 12),
                            ),
                          )
                        : null,
                  ),
                  Icon(Icons.chevron_right, color: theme.colorScheme.outline),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  // 正确率用色块突出：绿=稳、橙=一般、红=要补
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: accuracyColor.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      chapter.done == 0 ? '未开始' : '正确率 ${chapter.accuracyText}',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: accuracyColor,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '共 ${chapter.total} 题 · 已练 ${chapter.done}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // 章内进度条：绿=对、红=错、灰=未做，按真实题数比例切分。
              // 它占满整行宽度，右边的重刷按钮不会再压到它。
              SegmentedProgressBar(
                correct: chapter.correct,
                wrong: chapter.done - chapter.correct,
                remaining: chapter.total - chapter.done,
                height: 6,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
