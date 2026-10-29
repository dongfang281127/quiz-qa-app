import 'package:flutter/material.dart';

import '../models/bank.dart';
import '../models/bank_taxonomy.dart';
import '../models/question.dart';
import '../services/bank_service.dart';
import '../theme/app_colors.dart';
import '../utils/error_text.dart';
import '../utils/question_filter.dart';
import '../widgets/async_view.dart';
import '../widgets/rename_bank_dialog.dart';
import 'bank_taxonomy_page.dart';
import 'edit_question_page.dart';

/// 管理自己上传的题库：改题库名 + 逐题改题干/选项/答案。
/// 题库动辄几百上千题，所以顶上有搜索框和章节筛选，不用一条条翻。
/// 后端还有一道 403 校验，非作者进来什么也改不动。
class ManageBankPage extends StatefulWidget {
  const ManageBankPage({super.key, required this.bank});

  final Bank bank;

  @override
  State<ManageBankPage> createState() => _ManageBankPageState();
}

class _ManageBankPageState extends State<ManageBankPage> {
  final BankService _service = BankService();
  final TextEditingController _searchCtrl = TextEditingController();

  late Bank _bank = widget.bank;
  List<Question> _questions = [];
  BankTaxonomies _taxonomies = BankTaxonomies.empty;
  AsyncStatus _status = AsyncStatus.loading;
  String? _errorText;

  /// 题干/选项/答案/章节/学科 里的任意片段都能搜到
  String _keyword = '';

  /// 章节筛选；null 表示不筛
  String? _chapterFilter;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _status = AsyncStatus.loading;
      _errorText = null;
    });
    try {
      final rows = await _service.fetchQuestionsOfBank(_bank.id);
      if (!mounted) return;
      final list = rows.map(Question.fromMap).toList();
      setState(() {
        _questions = list;
        _status = list.isEmpty ? AsyncStatus.empty : AsyncStatus.data;
        // 章节被改没了就退回「全部」
        if (_chapterFilter != null &&
            !list.any((q) => q.chapterLabel == _chapterFilter)) {
          _chapterFilter = null;
        }
      });
      await _loadTaxonomies();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = AsyncStatus.error;
        _errorText = friendlyError(e);
      });
    }
  }

  List<String> get _chapters {
    final set = <String>{};
    for (final q in _questions) {
      set.add(q.chapterLabel);
    }
    final list = set.toList()..sort();
    return list;
  }

  List<Question> get _visible => filterQuestions(
        _questions,
        keyword: _keyword,
        chapter: _chapterFilter,
      );

  bool get _isFiltering => _keyword.trim().isNotEmpty || _chapterFilter != null;

  Future<void> _rename() async {
    final name = await showRenameBankDialog(context, currentName: _bank.name);
    if (name == null) return;
    if (!mounted) return;
    if (name.isEmpty) {
      _msg('题库名称不能为空');
      return;
    }
    if (name == _bank.name) return;
    try {
      final saved = await _service.renameBank(_bank.id, name);
      if (!mounted) return;
      setState(() => _bank = _bank.copyWith(name: saved));
      _msg('题库已改名为《$saved》');
    } catch (e) {
      if (mounted) _msg(friendlyError(e), isError: true);
    }
  }

  /// 题库里已出现的章节名（去空）+ 后台登记的标题（可能还没有题），
  /// 一起交给编辑页做快捷 chip。
  List<String> get _chapterNames => [
        ..._taxonomies.titlesOf(TaxonomyKind.chapter),
        for (final q in _questions)
          if (q.chapter.trim().isNotEmpty) q.chapter.trim(),
      ];

  List<String> get _subjectNames => [
        ..._taxonomies.titlesOf(TaxonomyKind.subject),
        for (final q in _questions)
          if (q.subject.trim().isNotEmpty) q.subject.trim(),
      ];

  /// 章节 -> 学科。编辑页靠它把「章节」列表收窄到当前学科下，
  /// 不然一进去所有章节摊一屏，找不到想改的那个。
  Map<String, String> get _chapterSubjects => {
        for (final c in _taxonomies.chapters)
          if (c.title.trim().isNotEmpty) c.title.trim(): c.subject.trim(),
        // 后台没登记过的章节：用题目上带的学科兜底
        for (final q in _questions)
          if (q.chapter.trim().isNotEmpty)
            if (!_taxonomies.chapters
                .any((c) => c.title.trim() == q.chapter.trim()))
              q.chapter.trim(): q.subject.trim(),
      };

  /// 标题清单单独拉：拿不到就用题目里出现过的名字凑合，不影响编辑题目本身。
  Future<void> _loadTaxonomies() async {
    try {
      final data = await _service.fetchTaxonomies(_bank.id);
      if (!mounted) return;
      setState(() => _taxonomies = data);
    } catch (_) {
      // 静默失败：chip 少几个不影响改题
    }
  }

  Future<void> _openTaxonomies({String initialKind = TaxonomyKind.chapter}) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BankTaxonomyPage(
          bankId: _bank.id,
          initialKind: initialKind,
        ),
      ),
    );
    if (!mounted) return;
    await _load();
  }

  /// 打开题目编辑页：传 [question] 就是改，不传就是加一道新的。
  /// [chapter]/[subject] 只在新增时作为预填，方便连续录同一章的题。
  Future<void> _openEditor({
    Question? question,
    String chapter = '',
    String subject = '',
  }) async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => EditQuestionPage(
          bankId: _bank.id,
          bankName: _bank.name,
          question: question,
          chapters: _chapterNames,
          subjects: _subjectNames,
          chapterSubjects: _chapterSubjects,
          initialChapter: chapter,
          initialSubject: subject,
        ),
      ),
    );
    if (result == null || !mounted) return;

    final text = switch (result) {
      'created' => '新题已加入题库',
      'deleted' => '这道题已删除',
      _ => '这道题已更新',
    };
    _msg(text);
    await _load();
  }

  void _msg(String text, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(text),
      backgroundColor:
          isError ? context.appColors.danger : context.appColors.success,
    ));
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
            Text(_bank.name, style: const TextStyle(fontSize: 17)),
            Text(
                '共 ${_questions.isEmpty ? _bank.questionCount : _questions.length} 题',
                style: TextStyle(
                    fontSize: 11, color: theme.colorScheme.outline)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '章节与学科',
            icon: const Icon(Icons.category_outlined),
            onPressed: () => _openTaxonomies(),
          ),
          IconButton(
            tooltip: '加一道题',
            icon: const Icon(Icons.add),
            onPressed: () => _openEditor(
              chapter: (_chapterFilter == null || _chapterFilter == '未分类')
                  ? ''
                  : _chapterFilter!,
            ),
          ),
          IconButton(
            tooltip: '改题库名',
            icon: const Icon(Icons.drive_file_rename_outline),
            onPressed: _rename,
          ),
        ],
      ),
      body: Column(
        children: [
          _buildSearchBar(theme),
          if (_chapters.length > 1) _buildChapterChips(theme),
          if (_isFiltering && _status == AsyncStatus.data) _buildCountBar(theme),
          Expanded(
            child: AsyncView(
              status: _status,
              onRetry: _load,
              errorText: _errorText,
              loadingText: '正在读取题目…',
              emptyIcon: Icons.inbox_outlined,
              emptyText: '这个题库里还没有题目',
              dataBuilder: (_) => _buildList(theme),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: TextField(
        controller: _searchCtrl,
        textInputAction: TextInputAction.search,
        onChanged: (v) => setState(() => _keyword = v),
        decoration: InputDecoration(
          isDense: true,
          hintText: '搜题干、答案、章节或学科…',
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: _keyword.isEmpty
              ? null
              : IconButton(
                  tooltip: '清空',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () {
                    _searchCtrl.clear();
                    setState(() => _keyword = '');
                  },
                ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
        ),
      ),
    );
  }

  Widget _buildChapterChips(ThemeData theme) {
    return SizedBox(
      height: 38,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: const Text('全部章节'),
              selected: _chapterFilter == null,
              showCheckmark: false,
              visualDensity: VisualDensity.compact,
              onSelected: (_) => setState(() => _chapterFilter = null),
            ),
          ),
          for (final chapter in _chapters)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                key: ValueKey('chapter-chip:$chapter'),
                label: Text(chapter),
                selected: _chapterFilter == chapter,
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                selectedColor:
                    theme.colorScheme.primary.withValues(alpha: 0.16),
                labelStyle: TextStyle(
                  fontSize: 12.5,
                  fontWeight: _chapterFilter == chapter
                      ? FontWeight.w600
                      : FontWeight.normal,
                  color: _chapterFilter == chapter
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurface,
                ),
                onSelected: (on) => setState(
                    () => _chapterFilter = on ? chapter : null),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCountBar(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 2),
      child: Row(
        children: [
          Text('匹配 ${_visible.length} / 共 ${_questions.length} 题',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline)),
          const Spacer(),
          TextButton(
            onPressed: () {
              _searchCtrl.clear();
              setState(() {
                _keyword = '';
                _chapterFilter = null;
              });
            },
            style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8)),
            child: const Text('清除筛选', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _buildList(ThemeData theme) {
    final visible = _visible;
    if (visible.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.search_off,
                  size: 44, color: theme.colorScheme.outline),
              const SizedBox(height: 12),
              Text('没有匹配的题目', style: theme.textTheme.bodyMedium),
              const SizedBox(height: 6),
              Text('换个关键词，或者点上面的「清除筛选」',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline)),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: visible.length + (_isFiltering ? 0 : 1),
        itemBuilder: (context, index) {
          if (!_isFiltering && index == 0) return _buildHint(theme);
          final question = visible[index - (_isFiltering ? 0 : 1)];
          return _buildQuestionTile(question);
        },
      ),
    );
  }

  Widget _buildHint(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, left: 4, right: 4),
      child: Text(
        '顶上是搜索和章节筛选；点任意一题能改题干、选项、答案、章节和学科，页面底部还能删掉这题。右上角＋随时加一道新题。',
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.outline),
      ),
    );
  }

  Widget _buildQuestionTile(Question question) {
    final theme = Theme.of(context);
    return Card(
      key: ValueKey('manage-question:${question.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        title: Text(
          question.text,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, height: 1.35),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            children: [
              _Tag(
                text: question.chapterLabel,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 6),
              _Tag(
                text: '答案 ${question.answer.isEmpty ? '空' : question.answer}',
                color: question.hasValidAnswer
                    ? context.appColors.success
                    : context.appColors.danger,
              ),
              if (question.subject.trim().isNotEmpty) ...[
                const SizedBox(width: 6),
                _Tag(
                  text: question.subject.trim(),
                  color: theme.colorScheme.outline,
                ),
              ],
            ],
          ),
        ),
        trailing: Icon(Icons.edit_outlined, color: theme.colorScheme.primary),
        onTap: () => _openEditor(question: question),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}
