import 'package:flutter/material.dart';

import '../models/bank.dart';
import '../services/app_events.dart';
import '../services/bank_service.dart';
import '../theme/app_colors.dart';
import '../utils/error_text.dart';
import '../widgets/async_view.dart';
import 'bank_detail_page.dart';

/// 藏书阁（我的收藏）。
/// 修复：
/// - 网络失败不再伪装成“暂无收藏”（统一四态）；
/// - 未登录 / 收藏为空时不再永远转圈；
/// - 移除收藏有撤销，不再一碰就没了；
/// - 下拉刷新代替右上角“整页转圈”的刷新按钮。
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final BankService _bankService = BankService();

  List<Bank> _banks = [];
  Set<int> _favoriteIds = {};
  AsyncStatus _status = AsyncStatus.loading;
  String _errorText = '';

  @override
  void initState() {
    super.initState();
    _load();
    // 这个页面被 IndexedStack 保活着，别处收藏/取消收藏不会重建它，
    // 所以挂监听：收藏一变就在后台静默重拉，切回来就是新的。
    AppEvents.favorites.addListener(_onDataChanged);
    AppEvents.banks.addListener(_onDataChanged);
  }

  @override
  void dispose() {
    AppEvents.favorites.removeListener(_onDataChanged);
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
        _errorText = '';
      });
    }
    try {
      final banks = await _bankService.fetchFavoriteBanks();
      final ids = await _bankService.fetchFavoriteIds();
      if (!mounted) return;
      setState(() {
        _banks = banks;
        _favoriteIds = ids;
        _status = banks.isEmpty ? AsyncStatus.empty : AsyncStatus.data;
      });
    } catch (e) {
      if (!mounted) return;
      // 静默刷新失败就保留旧列表，不把页面打成错误态。
      if (silent) return;
      setState(() {
        _errorText = friendlyError(e);
        _status = AsyncStatus.error;
      });
    }
  }

  /// 移除收藏：本地乐观移除 + SnackBar 撤销，不再一碰就永久消失。
  Future<void> _removeFavorite(Bank bank) async {
    setState(() {
      _banks.removeWhere((b) => b.id == bank.id);
      _favoriteIds.remove(bank.id);
    });
    try {
      await _bankService.removeFavorite(bank.id);
      AppEvents.favoritesChanged(); // 搜索页的收藏角标也要跟着灭
    } catch (e) {
      if (!mounted) return;
      _restoreLocally(bank);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('移除失败：${friendlyError(e)}')));
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('已把《${bank.name}》移出藏书阁'),
      action: SnackBarAction(
        label: '撤销',
        onPressed: () async {
          try {
            await _bankService.addFavorite(bank.id);
            if (!mounted) return;
            AppEvents.favoritesChanged();
            _restoreLocally(bank);
          } catch (e) {
            if (!mounted) return;
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text('恢复失败：${friendlyError(e)}')));
          }
        },
      ),
    ));
  }

  void _restoreLocally(Bank bank) {
    setState(() {
      if (!_banks.any((b) => b.id == bank.id)) _banks.add(bank);
      _banks.sort((a, b) => b.id.compareTo(a.id));
      _favoriteIds.add(bank.id);
    });
  }

  /// 点题库先进「章节列表」，再挑一章开始练。
  void _openBank(Bank bank) {
    Navigator.push(context,
        MaterialPageRoute(builder: (_) => BankDetailPage(bank: bank)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('藏书阁')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: AsyncView(
          status: _status,
          onRetry: _load,
          emptyIcon: Icons.menu_book_outlined,
          emptyText: '还没有收藏的题库\n去“搜索”页看看吧',
          errorText: _errorText,
          dataBuilder: (context) => ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            itemCount: _banks.length,
            itemBuilder: (context, index) {
              final bank = _banks[index];
              return Card(
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: context.appColors.info.withValues(alpha: 0.12),
                    child: Icon(Icons.menu_book, color: context.appColors.info),
                  ),
                  title: Text(bank.name,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(bank.hasChapters
                      ? '${bank.questionCount} 道题 · ${bank.chapterCount} 章 · ${bank.authorName}'
                      : '${bank.questionCount} 道题 · ${bank.authorName}'),
                  trailing: IconButton(
                    tooltip: '移出藏书阁',
                    icon: Icon(Icons.bookmark_remove_outlined,
                        color: context.appColors.danger),
                    onPressed: () => _removeFavorite(bank),
                  ),
                  onTap: () => _openBank(bank),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
