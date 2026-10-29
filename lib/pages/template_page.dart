import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';
import '../utils/error_text.dart';
// 保存 .xlsx：原生端走 file_picker/path_provider，Web 端走 Blob 下载。
import '../utils/save_bytes_stub.dart'
    if (dart.library.io) '../utils/save_bytes_io.dart'
    if (dart.library.js_interop) '../utils/save_bytes_web.dart';

/// 题库模板页。
///
/// 保存 .xlsx 依赖平台的「另存为」能力，个别平台会抛 UnimplementedError，
/// 所以这里给了两条永远可用的兜底路径：
///   1. 表格直接摊开给你看，表头/示例一眼就能抄；
///   2. 「复制表格内容」把 TSV 放进剪贴板，粘到 Excel 的 A1 就是一张表。
/// 只有前两条都拿到手之后，「保存 .xlsx」才是个加分项而不是唯一出路。
class TemplatePage extends StatefulWidget {
  const TemplatePage({super.key});

  @override
  State<TemplatePage> createState() => _TemplatePageState();
}

class _TemplatePageState extends State<TemplatePage> {
  static const _asset = 'assets/templates/bank_template.xlsx';
  static const _fileName = '题库模板.xlsx';

  static const _headers = [
    '题目',
    '选项A',
    '选项B',
    '选项C',
    '选项D',
    '选项E',
    '答案',
    '章节',
    '学科',
  ];

  static const _samples = <List<String>>[
    [
      '心肌梗死最常见的心律失常是？',
      '室性早搏',
      '心房颤动',
      '房室传导阻滞',
      '心室颤动',
      '',
      'A',
      '循环系统疾病',
      '内科学',
    ],
    [
      '胃溃疡最好发的部位是？',
      '胃底',
      '胃体',
      '胃窦',
      '幽门管',
      '',
      'C',
      '消化系统疾病',
      '内科学',
    ],
    [
      '（多选题示例）下列属于脂溶性维生素的有？',
      '维生素 A',
      '维生素 B1',
      '维生素 C',
      '维生素 D',
      '维生素 E',
      'ADE',
      '维生素',
      '生物化学',
    ],
  ];

  bool _saving = false;

  Future<void> _copyTsv() async {
    final lines = <String>[
      _headers.join('\t'),
      for (final row in _samples) row.join('\t'),
    ];
    await Clipboard.setData(ClipboardData(text: lines.join('\n')));
    _msg('已复制。打开 Excel 点 A1 直接粘贴就是一张表。');
  }

  Future<void> _saveXlsx() async {
    setState(() => _saving = true);
    try {
      final data = await rootBundle.load(_asset);
      final bytes =
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);

      final path = await saveBytes(fileName: _fileName, bytes: bytes);
      if (path == null) {
        _msg('这台设备没有可用的保存位置，用「复制表格内容」吧');
        return;
      }
      _msg(path == _fileName ? '已开始下载：$_fileName' : '模板已保存到：$path');
    } catch (e) {
      _msg('保存失败：${friendlyError(e)}',
          isError: true, hint: '用上面的「复制表格内容」同样能拿到格式');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _msg(String text, {bool isError = false, String? hint}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(
      content: Text(hint == null ? text : '$text\n$hint'),
      backgroundColor:
          isError ? context.appColors.danger : context.appColors.success,
      duration: const Duration(seconds: 4),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('题库模板')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
        children: [
          Text(
            '第一行是表头，从第二行开始每行一道题。'
            '只读第一个工作表，多出来的工作表会被忽略。',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline, height: 1.5),
          ),
          const SizedBox(height: 14),
          _buildTable(theme),
          const SizedBox(height: 10),
          Text(
            '选项两种写法随便挑一种：\n'
            '· 多列：选项A / 选项B / 选项C …（最多到 选项E）\n'
            '· 单列：一列「选项」，内容用 | 分隔，例如 甲 | 乙 | 丙\n'
            '答案写字母：单选 A，多选 ADE，大小写都行。\n'
            '「章节」不填就归到「未分类」；「学科」是可选列，填了能按学科筛章节。',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline, height: 1.7),
          ),
          const SizedBox(height: 20),
          SizedBox(
            height: 46,
            child: OutlinedButton.icon(
              onPressed: _copyTsv,
              icon: const Icon(Icons.copy_all_outlined, size: 18),
              label: const Text('复制表格内容（粘到 Excel 就能用）'),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 46,
            child: ElevatedButton.icon(
              onPressed: _saving ? null : _saveXlsx,
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.download_outlined, size: 18),
              label: const Text('保存 .xlsx 文件到本机'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTable(ThemeData theme) {
    const cellStyle = TextStyle(fontSize: 11.5, height: 1.3);
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          defaultColumnWidth: const FixedColumnWidth(96),
          border: TableBorder.all(
            color: theme.colorScheme.outline.withValues(alpha: 0.2),
            width: 0.6,
          ),
          children: [
            TableRow(
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.10),
              ),
              children: [
                for (final h in _headers)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                    child: Text(h,
                        textAlign: TextAlign.center,
                        style: cellStyle.copyWith(
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.primary)),
                  ),
              ],
            ),
            for (final row in _samples)
              TableRow(
                children: [
                  for (final cell in row)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                      child: Text(
                        cell.isEmpty ? '（空）' : cell,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: cellStyle.copyWith(
                          color: cell.isEmpty
                              ? theme.colorScheme.outline
                              : theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
