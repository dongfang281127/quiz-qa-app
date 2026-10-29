import 'package:flutter/material.dart';

import '../models/bank_taxonomy.dart';
import '../services/bank_service.dart';
import '../utils/error_text.dart';
import '../widgets/text_input_dialog.dart';

/// 章节 / 学科标题的管理页：题库作者可以新建标题、改名、改学科、删标题。
///
/// 章节按学科分组显示：先选学科，再看这个学科下的章节——和做题时的路径一致。
/// 删标题不等于删题：那个标题下的题会变成「未分类」，题干选项答案都还在。
class BankTaxonomyPage extends StatefulWidget {
  const BankTaxonomyPage({
    super.key,
    required this.bankId,
    this.initialKind = TaxonomyKind.chapter,
    this.initialSubject = '',
  });

  final int bankId;
  final String initialKind;

  /// 进来就锁定在这个学科上（从编辑题目的「管理章节」进来时，用户刚选完学科）
  final String initialSubject;

  @override
  State<BankTaxonomyPage> createState() => _BankTaxonomyPageState();
}

class _BankTaxonomyPageState extends State<BankTaxonomyPage> {
  final BankService _service = BankService();

  late String _kind = TaxonomyKind.of(widget.initialKind);
  BankTaxonomies _data = BankTaxonomies.empty;
  bool _loading = true;
  String? _error;
  bool _busy = false;

  /// 章节视图的学科过滤：null = 全部，'' = 未分学科，其它 = 学科名。
  late String? _subjectFilter = widget.initialSubject.trim();

  @override
  void initState() {
    super.initState();
    _load();
  }

  String get _label => TaxonomyKind.label(_kind);

  bool get _grouped => _kind == TaxonomyKind.chapter;

  List<TaxonomyTitle> get _items {
    if (!_grouped || _subjectFilter == null) return _data.of(_kind);
    return _data.chaptersOfSubject(_subjectFilter!);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await _service.fetchTaxonomies(widget.bankId);
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
        // 过滤的学科被删干净了就退回「全部」，免得停在空白页
        if (_subjectFilter != null &&
            _subjectFilter!.isNotEmpty &&
            !data.subjectNames.contains(_subjectFilter)) {
          _subjectFilter = null;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = friendlyError(e);
        _loading = false;
      });
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// 选一个学科：返回 null 表示放弃，返回 '' 表示「不分学科」。
  Future<String?> _pickSubject({
    required String current,
    required String title,
  }) {
    final options = <String>['', ..._data.subjectNames];
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(title),
        children: [
          for (final option in options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, option),
              child: Row(
                children: [
                  Icon(
                    option == current
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(option.isEmpty ? '不分学科' : option),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _add() async {
    final title = await showTextInputDialog(
      context,
      title: '新增$_label',
      hint: _kind == TaxonomyKind.subject ? '例如：内科学' : '例如：循环系统疾病',
      maxLength: 30,
      confirmText: '建好',
    );
    if (title == null || !mounted) return;
    if (title.isEmpty) {
      _snack('$_label标题不能为空');
      return;
    }

    var subject = '';
    if (_grouped) {
      // 已经在某个学科视角下，就直接归到它；在「全部」视角则问一下
      subject = _subjectFilter ?? '';
      if (_subjectFilter == null) {
        final picked = await _pickSubject(
          current: '',
          title: '把「$title」归到哪个学科？',
        );
        if (picked == null || !mounted) return;
        subject = picked;
      }
    }

    await _run(
      () => _service.addTaxonomy(
        widget.bankId,
        _kind,
        title,
        subject: subject,
      ),
      success: subject.isEmpty
          ? '已新建$_label「$title」'
          : '已在「$subject」下新建章节「$title」',
    );
  }

  Future<void> _rename(TaxonomyTitle item) async {
    final to = await showTextInputDialog(
      context,
      title: '重命名$_label',
      hint: '改成什么名字',
      initialValue: item.title,
      maxLength: 30,
    );
    if (to == null || !mounted) return;
    if (to.isEmpty) {
      _snack('$_label标题不能为空');
      return;
    }
    if (to == item.title) return;
    await _run(() async {
      final moved = await _service.renameTaxonomy(
        widget.bankId,
        _kind,
        item.title,
        to,
      );
      _snack(moved > 0 ? '已改名，$moved 道题跟着换到「$to」' : '已改名为「$to」');
    });
  }

  /// 把整个章节搬到另一个学科：章节下所有题的 subject 一起改。
  Future<void> _changeSubject(TaxonomyTitle item) async {
    final picked = await _pickSubject(
      current: item.subject,
      title: '「${item.title}」归到哪个学科？',
    );
    if (picked == null || !mounted) return;
    if (picked == item.subject) return;
    await _run(() async {
      final moved = await _service.renameTaxonomy(
        widget.bankId,
        TaxonomyKind.chapter,
        item.title,
        item.title,
        subject: picked,
      );
      _snack(
        picked.isEmpty
            ? '已把「${item.title}」改成不分学科'
            : '已把「${item.title}」归到「$picked」${moved > 0 ? '，$moved 道题跟着改' : ''}',
      );
    });
  }

  Future<void> _delete(TaxonomyTitle item) async {
    TaxonomyDeleteResult preview;
    try {
      preview = await _service.deleteTaxonomy(
        widget.bankId,
        _kind,
        item.title,
      );
    } catch (e) {
      _snack(friendlyError(e));
      return;
    }
    if (!mounted) return;

    if (!preview.confirmed) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('删掉$_label「${item.title}」？'),
          content: Text(
            preview.message.isNotEmpty
                ? preview.message
                : '这个$_label下面还有 ${preview.questionCount} 道题，删掉标题后它们会变成未分类。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('算了'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(dialogContext).colorScheme.error,
              ),
              child: const Text('删掉标题'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }

    await _run(
      () async {
        final done = await _service.deleteTaxonomy(
          widget.bankId,
          _kind,
          item.title,
          confirm: true,
        );
        _snack(
          done.unassignedQuestions > 0
              ? '已删掉「${item.title}」，${done.unassignedQuestions} 道题回到未分类'
              : '已删掉$_label「${item.title}」',
        );
      },
      reload: true,
    );
  }

  /// 跑一个会改数据的动作：期间禁用按钮，出错弹提示，成功后刷新列表。
  Future<void> _run(
    Future<void> Function() action, {
    String? success,
    bool reload = true,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (success != null) _snack(success);
      if (reload) await _load();
    } catch (e) {
      _snack(friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('章节与学科'),
        actions: [
          IconButton(
            tooltip: '新增$_label',
            icon: const Icon(Icons.add),
            onPressed: _busy ? null : _add,
          ),
        ],
        bottom: _busy
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: TaxonomyKind.chapter,
                  icon: Icon(Icons.list_alt),
                  label: Text('章节'),
                ),
                ButtonSegment(
                  value: TaxonomyKind.subject,
                  icon: Icon(Icons.school_outlined),
                  label: Text('学科'),
                ),
              ],
              selected: {_kind},
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.comfortable,
              ),
              onSelectionChanged: (value) {
                setState(() => _kind = value.first);
              },
            ),
          ),
          if (_grouped && !_loading && _error == null) _buildSubjectFilter(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              _grouped
                  ? '章节按学科分组：先选学科，再看它下面的章节。删掉标题不会删题。'
                  : '删掉学科标题不会删题，那些题只是变成「未分类」。',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.outline),
            ),
          ),
          Expanded(child: _buildList()),
        ],
      ),
    );
  }

  /// 「全部 / 未分学科 / 各学科」的横向筛选条。
  Widget _buildSubjectFilter() {
    final names = _data.subjectNames;
    final entries = <(String?, String)>[
      (null, '全部'),
      ('', '未分学科'),
      for (final name in names) (name, name),
    ];
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: entries.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final (value, text) = entries[index];
          final selected = _subjectFilter == value;
          return Center(
            child: ChoiceChip(
              key: ValueKey('subject-filter-${value ?? 'all'}'),
              label: Text(text),
              selected: selected,
              onSelected: (_) => setState(() => _subjectFilter = value),
            ),
          );
        },
      ),
    );
  }

  Widget _buildList() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    final items = _items;
    if (items.isEmpty) {
      final scope = _grouped && _subjectFilter != null
          ? (_subjectFilter!.isEmpty ? '「未分学科」里' : '「$_subjectFilter」下')
          : '';
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '还没有$_label标题，点右上角 ＋ 建一个。$scope',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 32),
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 4),
      itemBuilder: (context, index) {
        final item = items[index];
        final subtitle = _grouped && _subjectFilter == null
            ? '${item.countLabel} · ${item.subjectLabel}'
            : item.countLabel;
        return Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            key: ValueKey('taxonomy-${item.title}'),
            leading: Icon(
              _grouped ? Icons.article_outlined : Icons.school_outlined,
            ),
            title: Text(item.title),
            subtitle: Text(subtitle),
            onTap: _busy ? null : () => _rename(item),
            trailing: PopupMenuButton<String>(
              tooltip: '更多',
              enabled: !_busy,
              onSelected: (value) {
                if (value == 'rename') _rename(item);
                if (value == 'subject') _changeSubject(item);
                if (value == 'delete') _delete(item);
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'rename', child: Text('重命名')),
                if (_grouped)
                  const PopupMenuItem(value: 'subject', child: Text('改到别的学科')),
                const PopupMenuItem(value: 'delete', child: Text('删除标题')),
              ],
            ),
          ),
        );
      },
    );
  }
}
