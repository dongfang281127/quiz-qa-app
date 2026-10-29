import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:spreadsheet_decoder/spreadsheet_decoder.dart';
import 'package:flutter/foundation.dart';

import '../models/bank.dart';
import '../services/app_events.dart';
import '../services/auth_service.dart';
import '../services/bank_service.dart';
import '../theme/app_colors.dart';
import '../utils/error_text.dart';
import 'template_page.dart';

/// 表格解析结果（在 isolate 里产出，必须可序列化）。
class ParseResult {
  final List<Map<String, dynamic>> rows;
  final int skipped; // 被跳过的行数
  final String skipReason;

  /// 解析出的不同章节数（含「未分类」），用于上传前的预览提示。
  final int chapterCount;

  ParseResult(this.rows, this.skipped, this.skipReason, [this.chapterCount = 0]);
}

/// 上传模式：新建题库 / 追加到已有题库。
enum UploadMode { create, append }

/// 上传题目页。
/// - 解析放进 isolate，几千行不再卡死 UI，插入分批并显示进度；
/// - 答案/选项非法的行会被跳过并在结果里说明，不再入库后“永远判错”；
/// - 可以下载内置的 Excel 模板，表头照着填就行；
/// - 支持「新建题库」和「追加到已有题库」两种模式，追加只能选自己名下的题库。
class AddPage extends StatefulWidget {
  const AddPage({super.key});

  @override
  State<AddPage> createState() => _AddPageState();
}

class _AddPageState extends State<AddPage> {
  bool _isLoading = false;
  double _progress = 0;
  final TextEditingController _groupNameCtrl = TextEditingController();

  UploadMode _mode = UploadMode.create;

  List<Bank> _myBanks = [];
  bool _banksLoading = false;
  String? _banksError;
  int? _selectedBankId;

  final BankService _bankService = BankService();

  @override
  void initState() {
    super.initState();
    if (AuthService.instance.isLoggedIn) {
      _loadMyBanks();
    }
  }

  @override
  void dispose() {
    _groupNameCtrl.dispose();
    super.dispose();
  }

  // ---------- 我的题库（追加模式用） ----------

  Future<void> _loadMyBanks() async {
    setState(() {
      _banksLoading = true;
      _banksError = null;
    });
    try {
      final banks = await _bankService.fetchMyBanks();
      if (!mounted) return;
      setState(() {
        _myBanks = banks;
        _banksLoading = false;
        if (_selectedBankId != null &&
            !banks.any((b) => b.id == _selectedBankId)) {
          _selectedBankId = null;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _banksLoading = false;
        _banksError = friendlyError(e);
      });
    }
  }

  /// 在下拉里按 id 找回题库（不引 package:collection，手写一遍更省事）。
  Bank? _findMyBank(int id) {
    for (final bank in _myBanks) {
      if (bank.id == id) return bank;
    }
    return null;
  }

  // ---------- 模板 ----------

  /// 模板页里既有表格预览，也有「复制成 TSV」和「保存 .xlsx」两条路，
  /// 保存能力缺失时格式照样看得到，不会再卡在一句报错上。
  void _openTemplate() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const TemplatePage()),
    );
  }

  // ---------- 解析（在 isolate 中执行） ----------

  static ParseResult parseWorkbook(Uint8List bytes) {
    final decoder = SpreadsheetDecoder.decodeBytes(bytes);
    if (decoder.tables.isEmpty) return ParseResult(const [], 0, '表格里没有工作表');

    final table = decoder.tables[decoder.tables.keys.first];
    if (table == null || table.rows.isEmpty) return ParseResult(const [], 0, '工作表是空的');

    final headers = table.rows[0];
    final headerMap = <String, int>{};
    for (int i = 0; i < headers.length; i++) {
      final h = headers[i]?.toString().trim().toLowerCase() ?? '';
      if (h.isNotEmpty && !headerMap.containsKey(h)) headerMap[h] = i;
    }

    String getValue(List<String> names, List<dynamic> row) {
      for (final name in names) {
        final idx = headerMap[name.toLowerCase()];
        if (idx != null && idx < row.length) {
          return row[idx]?.toString().trim() ?? '';
        }
      }
      return '';
    }

    final rows = <Map<String, dynamic>>[];
    int skipped = 0;
    final reasons = <String>[];

    for (int i = 1; i < table.rows.length; i++) {
      final row = table.rows[i];
      final question = getValue(['question', '题目', 'questions', 'title', '题干'], row);
      if (question.isEmpty) {
        skipped++;
        continue;
      }

      // 选项：单列 or 分列 A-E
      var optionsRaw = getValue(['options', '选项', 'option', 'all options'], row);
      if (optionsRaw.isEmpty) {
        final merged = <String>[];
        for (final c in ['a', 'b', 'c', 'd', 'e']) {
          final v = getValue([c, 'option $c', '选项$c', '选项 $c', 'option_$c'], row);
          if (v.isNotEmpty) merged.add(v);
        }
        optionsRaw = merged.join(' | ');
      }

      final answerRaw =
          getValue(['answer', '答案', 'correct answer', '正确答案', '我的答案'], row)
              .replaceAll(RegExp(r'[\s,，.]'), '')
              .toUpperCase();

      // 章节归属：Excel 里没有这一列就归到「未分类」，不影响老表格导入。
      final chapter = getValue(
          ['chapter', '章节', '所属章节', '章节名', '章', 'section'], row);
      final subject = getValue(['subject', '学科', '科目'], row);

      // 校验：没选项、没答案，或答案里有超出选项范围的字母 → 这题做不了，跳过
      final optionCount = optionsRaw.isEmpty ? 0 : optionsRaw.split(' | ').length;
      String? reason;
      if (optionsRaw.isEmpty) {
        reason = '缺选项';
      } else if (answerRaw.isEmpty) {
        reason = '缺答案';
      } else if (answerRaw.contains(RegExp(r'[^A-E]'))) {
        reason = '答案含无法识别的字符';
      } else if (answerRaw.runes.any((code) => (code - 65) >= optionCount)) {
        reason = '答案超出选项数量';
      }

      if (reason != null) {
        skipped++;
        if (reasons.length < 3) reasons.add('第${i + 1}行：$reason');
        continue;
      }

      rows.add({
        'question': question,
        'options': optionsRaw,
        'answer': answerRaw,
        'chapter': chapter,
        'subject': subject,
      });
    }

    final chapters = <String>{};
    for (final r in rows) {
      final c = (r['chapter'] as String?)?.trim() ?? '';
      chapters.add(c.isEmpty ? '未分类' : c);
    }

    return ParseResult(rows, skipped, reasons.join('；'), chapters.length);
  }

  // ---------- 导入 ----------

  Future<void> _pickFile() async {
    // 1. 先看模式相关的必填项，别让用户选完文件才发现名称没填
    String bankName = '';
    int? targetBankId;

    if (_mode == UploadMode.create) {
      final name = _groupNameCtrl.text.trim();
      if (name.isEmpty) {
        _showMsg('请先给题库起个名字');
        return;
      }
      if (name.length > 50) {
        _showMsg('题库名称太长了（最多 50 字）');
        return;
      }
      bankName = name;
    } else {
      final id = _selectedBankId;
      if (id == null) {
        _showMsg('先选一个要追加的题库');
        return;
      }
      final bank = _findMyBank(id);
      if (bank == null) {
        _showMsg('选中的题库不见了，请下拉刷新后重试');
        return;
      }
      targetBankId = bank.id;
      bankName = bank.name;
    }

    setState(() => _isLoading = true);

    try {
      if (!AuthService.instance.isLoggedIn) {
        throw AppException('请先登录再上传题目');
      }
      final authorName = AuthService.instance.nickname;

      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) {
        _showMsg('没有选择文件，已取消');
        return;
      }

      final bytes = result.files.first.bytes;
      if (bytes == null) {
        throw AppException('读取文件失败，请重试');
      }

      // 解析放 isolate，大文件不卡 UI
      final parsed = await compute(parseWorkbook, bytes);

      if (parsed.rows.isEmpty) {
        throw AppException(
            '未解析到有效题目（跳过 ${parsed.skipped} 行）。请检查表头是否包含“题目/选项/答案”'
            '${parsed.skipReason.isEmpty ? '' : '；${parsed.skipReason}'}');
      }

      // 解析成功才建题库：以前是先建后解析，解析失败会留下一个空题库。
      final bankId = targetBankId ??
          await _bankService.createBank(bankName, authorName);
      final inserted = await _bankService.uploadQuestions(
        bankId,
        parsed.rows,
        onProgress: (done, total) {
          if (mounted && total > 0) {
            setState(() => _progress = done / total);
          }
        },
      );

      if (!mounted) return;
      final skipNote = parsed.skipped > 0
          ? '，跳过 ${parsed.skipped} 行（${parsed.skipReason}）'
          : '';
      final chapterNote =
          parsed.chapterCount > 1 ? '，共 ${parsed.chapterCount} 个章节' : '（未分章节）';
      final action = _mode == UploadMode.create ? '导入' : '追加';
      _showMsg('$action 成功：$inserted 道题 → 《$bankName》$chapterNote$skipNote');

      if (_mode == UploadMode.create) {
        _groupNameCtrl.clear();
      }
      // 新建/追加都算题库变了：首页、搜索、我的题库、下拉里的题数都要跟上。
      // 以前这里什么都不通知，页面又是保活的，只能杀掉进程重启才看到新题库。
      AppEvents.banksChanged();
      await _loadMyBanks();
    } catch (e) {
      if (mounted) _showMsg(friendlyError(e), isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _progress = 0;
        });
      }
    }
  }

  void _showMsg(String msg, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: isError ? context.appColors.danger : context.appColors.success,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('上传题库')),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
          children: [
            Center(
              child: Icon(Icons.note_add, size: 64, color: context.appColors.info),
            ),
            const SizedBox(height: 20),
            SegmentedButton<UploadMode>(
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              segments: const [
                ButtonSegment(
                    value: UploadMode.create,
                    icon: Icon(Icons.add_box_outlined, size: 16),
                    label: Text('新建题库')),
                ButtonSegment(
                    value: UploadMode.append,
                    icon: Icon(Icons.playlist_add, size: 16),
                    label: Text('加入已有题库')),
              ],
              selected: {_mode},
              onSelectionChanged: (sel) {
                setState(() => _mode = sel.first);
                if (_mode == UploadMode.append && _myBanks.isEmpty) {
                  _loadMyBanks();
                }
              },
            ),
            const SizedBox(height: 20),
            if (_mode == UploadMode.create)
              TextField(
                controller: _groupNameCtrl,
                maxLength: 50,
                decoration: const InputDecoration(
                  labelText: '题库名称',
                  hintText: '例如：医学期末复习',
                  counterText: '',
                  prefixIcon: Icon(Icons.edit),
                ),
              )
            else
              _buildBankPicker(theme),
            const SizedBox(height: 16),
            // 模板：先看清楚格式，再决定要不要存成文件
            OutlinedButton.icon(
              onPressed: _openTemplate,
              icon: const Icon(Icons.table_chart_outlined, size: 18),
              label: const Text('查看 / 下载 Excel 模板'),
            ),
            const SizedBox(height: 16),
            Text(
              '只支持 .xlsx（不支持 .xls / .csv）。\n'
              '表头需要的列：题目、答案；选项两种写法随便挑一种——\n'
              '1. 一列「选项」，内容用「 | 」分隔\n'
              '2. 多列：选项A | 选项B | 选项C …（最多到 E）\n'
              '想按章节练：加一列「章节」；有多个学科：再加一列「学科」。',
              style: TextStyle(
                  color: theme.colorScheme.outline, fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 28),
            if (_isLoading) ...[
              LinearProgressIndicator(value: _progress > 0 ? _progress : null),
              const SizedBox(height: 12),
              Text(
                _progress > 0
                    ? '正在上传题目… ${(_progress * 100).toStringAsFixed(0)}%'
                    : '正在解析文件…',
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.outline, fontSize: 13),
              ),
            ] else
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  onPressed: _pickFile,
                  icon: const Icon(Icons.upload_file),
                  label: Text(_mode == UploadMode.create
                      ? '选择 Excel 并创建题库'
                      : '选择 Excel 追加到该题库'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 追加模式：从「我上传的题库」里挑一个。
  /// 只能挑自己的，所以下拉里永远是本人名下的题库（后端还会再校验一次作者）。
  Widget _buildBankPicker(ThemeData theme) {
    if (_banksLoading && _myBanks.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
              width: 22, height: 22,
              child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    if (_banksError != null && _myBanks.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('读取我的题库失败：$_banksError',
              style: TextStyle(color: context.appColors.danger, fontSize: 13)),
          TextButton(onPressed: _loadMyBanks, child: const Text('重试')),
        ],
      );
    }
    if (_myBanks.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: context.appColors.warning.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          '你名下还没有题库。切到「新建题库」先建一个，之后再往里面追加。',
          style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurface),
        ),
      );
    }

    return DropdownButtonFormField<int>(
      initialValue: _selectedBankId,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: '追加到哪个题库',
        prefixIcon: Icon(Icons.folder_open),
      ),
      hint: const Text('选一个你自己的题库'),
      items: [
        for (final bank in _myBanks)
          DropdownMenuItem(
            value: bank.id,
            child: Text(
              '${bank.name}（${bank.questionCount} 题）',
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: (id) => setState(() => _selectedBankId = id),
    );
  }
}
