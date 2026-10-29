import 'package:flutter/material.dart';

import '../models/bank_taxonomy.dart';
import '../models/question.dart';
import '../services/app_events.dart';
import '../services/bank_service.dart';
import '../theme/app_colors.dart';
import '../utils/error_text.dart';
import 'bank_taxonomy_page.dart';

/// 题目编辑页，两种模式共用一套表单：
/// - 编辑模式（传了 [question]）：改题干 / 选项 / 答案 / 章节 / 学科，底部还能删掉这题；
/// - 新增模式（不传 question）：往这个题库里加一道新题，章节和学科可以直接填新的。
///
/// 保存成功或删除成功都 pop(true)，让上一页刷新列表。
class EditQuestionPage extends StatefulWidget {
  const EditQuestionPage({
    super.key,
    required this.bankId,
    required this.bankName,
    this.question,
    this.chapters = const [],
    this.subjects = const [],
    this.chapterSubjects = const {},
    this.initialChapter = '',
    this.initialSubject = '',
  });

  final int bankId;
  final String bankName;

  /// null 表示新增
  final Question? question;

  /// 题库里已有的章节/学科，做成快捷 chip，省得每次手打（也避免打错字分裂出两个章节）
  final List<String> chapters;
  final List<String> subjects;

  /// 章节 -> 学科 的归属表。有了它，编辑页才能「先选学科，只列这个学科下的章节」。
  /// 调用方给了就用，没给的话页面自己拉 /taxonomies 补齐。
  final Map<String, String> chapterSubjects;

  /// 新增模式下预填的章节/学科
  final String initialChapter;
  final String initialSubject;

  @override
  State<EditQuestionPage> createState() => _EditQuestionPageState();
}

class _EditQuestionPageState extends State<EditQuestionPage> {
  static const _letters = ['A', 'B', 'C', 'D', 'E'];
  static const _minOptions = 2;
  static const _maxOptions = 5;

  final BankService _service = BankService();
  final TextEditingController _textCtrl = TextEditingController();
  final TextEditingController _chapterCtrl = TextEditingController();
  final TextEditingController _subjectCtrl = TextEditingController();
  final List<TextEditingController> _optionCtrls = [];

  /// 被删掉的那一行 controller 先攒起来，等页面销毁时统一 disposal，
  /// 免得在当前帧还挂在 TextField 上就被释放。
  final List<TextEditingController> _orphans = [];

  /// 答案对应的选项下标（0 基）。多选就是多个。
  Set<int> _answerIndices = {};

  bool _saving = false;

  bool get _isCreate => widget.question == null;

  Question? get _question => widget.question;

  @override
  void initState() {
    super.initState();
    final q = _question;
    _textCtrl.text = q?.text ?? '';
    _chapterCtrl.text = q?.chapter.trim() ?? widget.initialChapter;
    _subjectCtrl.text = q?.subject.trim() ?? widget.initialSubject;

    final existing = q?.optionsList
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList() ??
        const <String>[];
    for (final text in existing.isEmpty ? ['', ''] : existing) {
      _optionCtrls.add(TextEditingController(text: text));
    }
    _answerIndices = (q?.answerIndices ?? const <int>[])
        .where((i) => i >= 0 && i < _optionCtrls.length)
        .toSet();
    _loadTaxonomies();
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    _chapterCtrl.dispose();
    _subjectCtrl.dispose();
    for (final c in _optionCtrls) {
      c.dispose();
    }
    for (final c in _orphans) {
      c.dispose();
    }
    super.dispose();
  }

  String get _answerLetters {
    final sorted = _answerIndices.toList()..sort();
    return sorted.map((i) => _letters[i]).join();
  }

  void _addOption() {
    if (_optionCtrls.length >= _maxOptions) return;
    setState(() => _optionCtrls.add(TextEditingController()));
  }

  void _removeOption(int index) {
    if (_optionCtrls.length <= _minOptions) {
      _msg('至少要留两个选项');
      return;
    }
    setState(() {
      _orphans.add(_optionCtrls.removeAt(index));
      // 删掉一行后，答案下标要跟着往前挪
      _answerIndices = {
        for (final i in _answerIndices)
          if (i < index) i else if (i > index) i - 1,
      };
    });
  }

  Future<void> _save() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) {
      _msg('题干不能为空');
      return;
    }

    final options = _optionCtrls.map((c) => c.text.trim()).toList();
    if (options.length < _minOptions) {
      _msg('至少要两个选项');
      return;
    }
    if (options.any((o) => o.isEmpty)) {
      _msg('选项不能留空，多余的可以点右侧删除');
      return;
    }
    if (_answerIndices.isEmpty) {
      _msg('请把正确答案选上');
      return;
    }

    final chapter = _chapterCtrl.text.trim();
    final subject = _subjectCtrl.text.trim();

    setState(() => _saving = true);
    try {
      if (_isCreate) {
        await _service.addQuestion(
          widget.bankId,
          question: text,
          options: options,
          answer: _answerLetters,
          chapter: chapter,
          subject: subject,
        );
      } else {
        await _service.updateQuestion(
          _question!.id,
          question: text,
          options: options,
          answer: _answerLetters,
          chapter: chapter,
          subject: subject,
        );
      }
      if (!mounted) return;
      // 新增/改题都会改动题库的题数或章节统计，喊一声让列表页跟上。
      AppEvents.banksChanged();
      Navigator.pop(context, _isCreate ? 'created' : 'saved');
    } catch (e) {
      if (mounted) _msg(friendlyError(e), isError: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final q = _question;
    if (q == null) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删掉这道题？'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _textCtrl.text.trim().isEmpty ? q.text : _textCtrl.text.trim(),
                style: Theme.of(dialogContext).textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              Text(
                '这题的所有做题记录和评论会一起删掉，删除后没法恢复。',
                style: Theme.of(dialogContext)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: dialogContext.appColors.danger),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('算了'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(
                foregroundColor: dialogContext.appColors.danger),
            child: const Text('删掉'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _saving = true);
    try {
      await _service.deleteQuestion(q.id);
      if (!mounted) return;
      AppEvents.banksChanged();
      Navigator.pop(context, 'deleted');
    } catch (e) {
      if (mounted) _msg(friendlyError(e), isError: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _msg(String text, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(text),
      backgroundColor:
          isError ? context.appColors.danger : context.appColors.warning,
    ));
  }

  /// 已有章节（去掉空值、去重），点一下就填进输入框。
  /// 用 state 字段而不是直接读 widget.chapters：从这里进「管理章节」改完标题回来，
  /// 快捷 chip 要立刻跟着变。
  late List<String> _chapters = _cleanList(widget.chapters);
  late List<String> _subjects = _cleanList(widget.subjects);

  /// 章节 -> 学科。没登记的章节算「未分学科」（空串）。
  late Map<String, String> _chapterSubject = {
    for (final entry in widget.chapterSubjects.entries)
      if (entry.key.trim().isNotEmpty) entry.key.trim(): entry.value.trim(),
  };

  /// 题库的标题清单（含还没挂题的章节/学科）。拉不到就退回 widget 里的名字。
  Future<void> _loadTaxonomies() async {
    try {
      final data = await _service.fetchTaxonomies(widget.bankId);
      if (!mounted) return;
      setState(() {
        _chapters = _cleanList([
          ...data.titlesOf(TaxonomyKind.chapter),
          ...widget.chapters,
        ]);
        _subjects = _cleanList([
          ...data.subjectNames,
          ...data.titlesOf(TaxonomyKind.subject),
          ...widget.subjects,
        ]);
        _chapterSubject = {
          for (final c in data.chapters)
            if (c.title.trim().isNotEmpty) c.title.trim(): c.subject.trim(),
          for (final entry in widget.chapterSubjects.entries)
            if (entry.key.trim().isNotEmpty)
              entry.key.trim(): entry.value.trim(),
        };
      });
    } catch (_) {
      // 拉不到就保持调用方给的名字，别打断正在填的内容
    }
  }

  static List<String> _cleanList(List<String> raw) {
    final out = <String>[];
    for (final item in raw) {
      final t = item.trim();
      if (t.isNotEmpty && !out.contains(t)) out.add(t);
    }
    return out;
  }

  /// 当前输入框里的学科（空串 = 不分学科）。
  String get _selectedSubject => _subjectCtrl.text.trim();

  /// 兜底开关：有的老题库章节根本没登记学科，按学科过滤会一个都不剩，
  /// 给一个「看全部章节」的入口，免得人卡在空列表上。
  bool _showAllChapters = false;

  /// 只列当前学科下的章节：先选学科，章节列表跟着收窄，不再一股脑全摊开。
  /// 归属表为空（老题库没登记过）时才退回「全列」，否则选了学科就一片空白。
  List<String> get _chapterSuggestions {
    if (_chapterSubject.isEmpty || _showAllChapters) return _chapters;
    final subject = _selectedSubject;
    return [
      for (final name in _chapters)
        if ((_chapterSubject[name] ?? '') == subject) name,
    ];
  }

  List<String> get _subjectSuggestions => _subjects;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(_isCreate ? '新增题目' : '编辑题目'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('保存'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Text(
            _isCreate
                ? '《${widget.bankName}》· 新加一道题'
                : '《${widget.bankName}》· 第 ${_question!.id} 号题',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _textCtrl,
            minLines: 2,
            maxLines: 6,
            textInputAction: TextInputAction.newline,
            decoration: const InputDecoration(
              labelText: '题干',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Text('选项', style: theme.textTheme.titleSmall),
              const SizedBox(width: 8),
              Text('${_optionCtrls.length}/$_maxOptions',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline)),
              const Spacer(),
              if (_optionCtrls.length < _maxOptions)
                TextButton.icon(
                  onPressed: _addOption,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('加一个'),
                  style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact),
                ),
            ],
          ),
          const SizedBox(height: 4),
          for (int i = 0; i < _optionCtrls.length; i++) ...[
            _buildOptionRow(i),
            const SizedBox(height: 10),
          ],
          const SizedBox(height: 8),
          Text('正确答案', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (int i = 0; i < _optionCtrls.length; i++)
                FilterChip(
                  key: ValueKey('answer-${_letters[i]}'),
                  label: Text(_letters[i]),
                  selected: _answerIndices.contains(i),
                  onSelected: (on) => setState(() {
                    on ? _answerIndices.add(i) : _answerIndices.remove(i);
                  }),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '多选题就多选几个字母。当前答案：${_answerLetters.isEmpty ? '未选' : _answerLetters}',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
          const SizedBox(height: 22),
          Row(
            children: [
              Text('第一步：选学科', style: theme.textTheme.titleSmall),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  '决定下面章节列表的范围',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _subjectCtrl,
            textInputAction: TextInputAction.next,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              isDense: true,
              hintText: '比如 生理学 / 解剖学，留空就不分学科',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.school_outlined, size: 20),
            ),
          ),
          if (_subjectSuggestions.isNotEmpty) ...[
            const SizedBox(height: 8),
            _buildSuggestionChips(
              values: ['', ..._subjectSuggestions],
              controller: _subjectCtrl,
              keyPrefix: 'subject',
              labelOf: (v) => v.isEmpty ? '不分学科' : v,
            ),
          ],
          const SizedBox(height: 18),
          Row(
            children: [
              Text('第二步：选章节', style: theme.textTheme.titleSmall),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  _selectedSubject.isEmpty
                      ? '只列「未分学科」的章节'
                      : '只列「$_selectedSubject」下的章节',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.primary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _chapterCtrl,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              isDense: true,
              hintText: '章节名，留空就是「未分类」',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.menu_book_outlined, size: 20),
            ),
          ),
          if (_chapterSuggestions.isNotEmpty) ...[
            const SizedBox(height: 8),
            _buildSuggestionChips(
              values: _chapterSuggestions,
              controller: _chapterCtrl,
              keyPrefix: 'chapter',
            ),
          ] else ...[
            const SizedBox(height: 8),
            Text(
              _chapterSubject.isEmpty
                  ? '题库里还没有章节，直接在上面输入新的章节名就行。'
                  : '「${_selectedSubject.isEmpty ? '未分学科' : _selectedSubject}」下还没有章节，'
                      '直接输入新章节名，或者点下面的「管理章节」去建一个。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ],
          if (_chapterSubject.isNotEmpty) ...[
            const SizedBox(height: 2),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () =>
                    setState(() => _showAllChapters = !_showAllChapters),
                icon: Icon(
                  _showAllChapters
                      ? Icons.filter_alt_off_outlined
                      : Icons.filter_alt_outlined,
                  size: 16,
                ),
                label: Text(
                  _showAllChapters
                      ? '只看本学科的章节'
                      : '章节不全？显示全部 ${_chapters.length} 个',
                ),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 12),
                ),
              ),
            ),
          ],
          const SizedBox(height: 10),
          _buildManageRow(),
          const SizedBox(height: 22),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton(
              onPressed: _saving ? null : _save,
              child: Text(_isCreate ? '加到题库里' : '保存这道题'),
            ),
          ),
          if (!_isCreate) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: OutlinedButton.icon(
                onPressed: _saving ? null : _delete,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('删除这道题'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: context.appColors.danger,
                  side: BorderSide(
                      color: context.appColors.danger.withValues(alpha: 0.5)),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 「管理章节 / 管理学科」入口：进标题管理页，回来时刷新快捷 chip。
  Widget _buildManageRow() {
    return Row(
      children: [
        TextButton.icon(
          onPressed:
              _saving ? null : () => _openTaxonomy(TaxonomyKind.chapter),
          icon: const Icon(Icons.playlist_add, size: 18),
          label: const Text('管理章节'),
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
        ),
        const SizedBox(width: 4),
        TextButton.icon(
          onPressed:
              _saving ? null : () => _openTaxonomy(TaxonomyKind.subject),
          icon: const Icon(Icons.school_outlined, size: 18),
          label: const Text('管理学科'),
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
        ),
      ],
    );
  }

  Future<void> _openTaxonomy(String kind) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BankTaxonomyPage(
          bankId: widget.bankId,
          initialKind: kind,
          initialSubject: _selectedSubject,
        ),
      ),
    );
    if (!mounted) return;
    // 管理页可能改了章节的学科归属，整份重拉，chip 和过滤同时跟上
    await _loadTaxonomies();
  }

  Widget _buildSuggestionChips({
    required List<String> values,
    required TextEditingController controller,
    required String keyPrefix,
    String Function(String value)? labelOf,
  }) {
    final theme = Theme.of(context);
    final current = controller.text.trim();
    return SizedBox(
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: values.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final value = values[i];
          final selected = value == current;
          final label = labelOf == null ? value : labelOf(value);
          return ActionChip(
            key: ValueKey('$keyPrefix-chip:$value'),
            label: Text(label),
            labelStyle: TextStyle(
              fontSize: 12,
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurface,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            ),
            backgroundColor: selected
                ? theme.colorScheme.primary.withValues(alpha: 0.14)
                : null,
            side: BorderSide(
              color: theme.colorScheme.outline.withValues(alpha: 0.4),
            ),
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() => controller.text = value),
          );
        },
      ),
    );
  }

  Widget _buildOptionRow(int index) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 22,
          child: Text(_letters[index],
              style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary)),
        ),
        Expanded(
          child: TextField(
            controller: _optionCtrls[index],
            decoration: InputDecoration(
              isDense: true,
              hintText: '选项 ${_letters[index]} 的内容',
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        IconButton(
          tooltip: '删掉这个选项',
          onPressed:
              _optionCtrls.length > _minOptions ? () => _removeOption(index) : null,
          icon: const Icon(Icons.remove_circle_outline),
          color: context.appColors.danger,
        ),
      ],
    );
  }
}
