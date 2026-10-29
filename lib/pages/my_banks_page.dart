import 'package:flutter/material.dart';

import '../models/bank.dart';
import '../services/app_events.dart';
import '../services/bank_service.dart';
import '../theme/app_colors.dart';
import '../utils/error_text.dart';
import '../widgets/async_view.dart';
import '../widgets/rename_bank_dialog.dart';
import 'manage_bank_page.dart';

/// 我上传的题库。
/// 这里只列 owner_id == 自己的题库，改名和改题目的入口都从这里进，
/// 别人搜到我的题库也看不到编辑按钮（后端还有 403 兜着）。
class MyBanksPage extends StatefulWidget {
  const MyBanksPage({super.key});

  @override
  State<MyBanksPage> createState() => _MyBanksPageState();
}

class _MyBanksPageState extends State<MyBanksPage> {
  final BankService _service = BankService();

  List<Bank> _banks = [];
  AsyncStatus _status = AsyncStatus.loading;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _load();
    // 上传页新建了题库、搜索页删了题库，这里要立刻反映出来。
    AppEvents.banks.addListener(_onDataChanged);
  }

  @override
  void dispose() {
    AppEvents.banks.removeListener(_onDataChanged);
    super.dispose();
  }

  void _onDataChanged() {
    if (!mounted) return;
    _load(silent: true);
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _status = AsyncStatus.loading;
        _errorText = null;
      });
    }
    try {
      final banks = await _service.fetchMyBanks();
      if (!mounted) return;
      setState(() {
        _banks = banks;
        _status = banks.isEmpty ? AsyncStatus.empty : AsyncStatus.data;
      });
    } catch (e) {
      if (!mounted || silent) return;
      setState(() {
        _status = AsyncStatus.error;
        _errorText = friendlyError(e);
      });
    }
  }

  Future<void> _rename(Bank bank) async {
    final name = await showRenameBankDialog(context, currentName: bank.name);
    if (name == null) return;
    if (!mounted) return;
    if (name.isEmpty) {
      _msg('题库名称不能为空');
      return;
    }
    if (name == bank.name) return;

    try {
      final saved = await _service.renameBank(bank.id, name);
      if (!mounted) return;
      setState(() {
        _banks = [
          for (final b in _banks) b.id == bank.id ? b.copyWith(name: saved) : b,
        ];
      });
      AppEvents.banksChanged(); // 搜索页/藏书阁里的旧名字一起更新
      _msg('题库已改名为《$saved》');
    } catch (e) {
      if (mounted) _msg(friendlyError(e), isError: true);
    }
  }

  Future<void> _openManage(Bank bank) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ManageBankPage(bank: bank)),
    );
    // 从管理页回来题数可能变了（改题不会变，但改名/删除会），统一刷一遍
    if (mounted) await _load();
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
      appBar: AppBar(title: const Text('我上传的题库')),
      body: AsyncView(
        status: _status,
        onRetry: _load,
        errorText: _errorText,
        loadingText: '正在读取题库…',
        emptyIcon: Icons.cloud_upload_outlined,
        emptyText: '还没有上传过题库\n去「添加」页导入一个吧',
        dataBuilder: (_) => RefreshIndicator(
          onRefresh: _load,
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: _banks.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10, left: 4, right: 4),
                  child: Text(
                    '只有你自己能看到这里。点进去可以改题库名，也可以逐题改题干、选项和答案。',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                );
              }
              final bank = _banks[index - 1];
              return Card(
                key: ValueKey('my-bank:${bank.id}'),
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor:
                        context.appColors.info.withValues(alpha: 0.12),
                    child: Icon(Icons.description, color: context.appColors.info),
                  ),
                  title: Text(bank.name,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(
                    '共 ${bank.questionCount} 题'
                    '${bank.chapterCount > 1 ? ' · ${bank.chapterCount} 个章节' : ''}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: '改题库名',
                        icon: Icon(Icons.drive_file_rename_outline,
                            color: context.appColors.info),
                        onPressed: () => _rename(bank),
                      ),
                      Icon(Icons.chevron_right,
                          color: theme.colorScheme.outline),
                    ],
                  ),
                  onTap: () => _openManage(bank),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
