import 'dart:async';
import 'package:flutter/material.dart';

import '../models/bank.dart';
import '../services/auth_service.dart';
import '../services/bank_service.dart';
import '../theme/app_colors.dart';
import '../utils/error_text.dart';
import '../widgets/async_view.dart';
import '../widgets/rename_bank_dialog.dart';
import 'bank_detail_page.dart';

/// 搜索页。
/// 修复：
/// - 改查 banks 表（不再全表拉 questions 在客户端分组），支持分页；
/// - 输入时不再整页闪转圈（保留旧结果，只在角落显示加载中）；
/// - 收藏按钮双向（已收藏可再点取消），重复收藏给明确提示；
/// - 从这里进考场带上 owner，留言功能恢复可用；
/// - 我的题库有确认删除。
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final BankService _bankService = BankService();
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  List<Bank> _banks = [];
  final Set<int> _favoriteIds = {};
  bool _isLoading = true; // 首次/刷新
  bool _isLoadingMore = false;
  bool _hasMore = true;
  String? _errorText;
  int _page = 0;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _refresh();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onScroll() {
    if (!_hasMore || _isLoadingMore || _isLoading) return;
    if (_scrollController.position.pixels >
        _scrollController.position.maxScrollExtent - 300) {
      _loadMore();
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _isLoading = true;
      _errorText = null;
      _page = 0;
      _hasMore = true;
    });
    await _fetch(page: 0, replace: true);
  }

  Future<void> _loadMore() async {
    setState(() => _isLoadingMore = true);
    await _fetch(page: _page + 1, replace: false);
    if (mounted) setState(() => _isLoadingMore = false);
  }

  Future<void> _fetch({required int page, required bool replace}) async {
    try {
      final (banks, hasMore) =
          await _bankService.fetchBanks(keyword: _searchController.text, page: page);
      if (!mounted) return;
      setState(() {
        _page = page;
        _hasMore = hasMore;
        if (replace) {
          _banks = banks;
        } else {
          final existing = _banks.map((b) => b.id).toSet();
          _banks.addAll(banks.where((b) => !existing.contains(b.id)));
        }
        _isLoading = false;
        _errorText = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        if (replace) _errorText = friendlyError(e);
      });
    }
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _refresh);
  }

  Future<void> _toggleFavorite(Bank bank) async {
    if (!AuthService.instance.isLoggedIn) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先登录')));
      return;
    }
    final wasFavorite = _favoriteIds.contains(bank.id);
    // 乐观更新，失败回滚
    setState(() {
      wasFavorite ? _favoriteIds.remove(bank.id) : _favoriteIds.add(bank.id);
    });
    try {
      if (wasFavorite) {
        await _bankService.removeFavorite(bank.id);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('已取消收藏《${bank.name}》')));
        }
      } else {
        await _bankService.addFavorite(bank.id);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('已收藏《${bank.name}》')));
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        wasFavorite ? _favoriteIds.add(bank.id) : _favoriteIds.remove(bank.id);
      });
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('操作失败：${friendlyError(e)}')));
    }
  }

  Future<void> _deleteMyBank(Bank bank) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除题库'),
        content: Text('确定要永久删除《${bank.name}》吗？\n所有人的收藏和做题记录也会一并失效。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: context.appColors.danger),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _bankService.deleteBank(bank.id);
      if (!mounted) return;
      setState(() {
        _banks.removeWhere((b) => b.id == bank.id);
        _favoriteIds.remove(bank.id);
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('题库《${bank.name}》已删除')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('删除失败：${friendlyError(e)}')));
    }
  }

  /// 改自己题库的名字。只在搜索结果里给自己上传的题库显示这个图标。
  Future<void> _renameMyBank(Bank bank) async {
    final name = await showRenameBankDialog(context, currentName: bank.name);
    if (name == null) return;
    if (!mounted) return;
    if (name.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('题库名称不能为空')));
      return;
    }
    if (name == bank.name) return;

    try {
      final saved = await _bankService.renameBank(bank.id, name);
      if (!mounted) return;
      setState(() {
        final i = _banks.indexWhere((b) => b.id == bank.id);
        if (i >= 0) _banks[i] = _banks[i].copyWith(name: saved);
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('题库已改名为《$saved》')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('改名失败：${friendlyError(e)}')));
    }
  }

  /// 点题库先进「章节列表」，再挑一章开始练。
  void _openBank(Bank bank) {
    Navigator.push(context,
        MaterialPageRoute(builder: (_) => BankDetailPage(bank: bank)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currentUserId = AuthService.instance.userId;

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _searchController,
          onChanged: _onSearchChanged,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _refresh(),
          decoration: InputDecoration(
            hintText: '搜索题库名…',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _searchController.text.isEmpty
                ? null
                : IconButton(
                    tooltip: '清空',
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      _searchController.clear();
                      _refresh();
                    },
                  ),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 10),
          ),
        ),
      ),
      body: _errorText != null
          ? AsyncView(
              status: AsyncStatus.error,
              errorText: _errorText,
              onRetry: _refresh,
              dataBuilder: (_) => const SizedBox.shrink(),
            )
          : _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _banks.isEmpty
                  ? AsyncView(
                      status: AsyncStatus.empty,
                      emptyIcon: Icons.search_off,
                      emptyText: '没有找到相关题库',
                      onRetry: _refresh,
                      dataBuilder: (_) => const SizedBox.shrink(),
                    )
                  : RefreshIndicator(
                      onRefresh: _refresh,
                      child: ListView.builder(
                        controller: _scrollController,
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.all(16),
                        itemCount: _banks.length + (_hasMore ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index >= _banks.length) {
                            return const Padding(
                              padding: EdgeInsets.symmetric(vertical: 16),
                              child: Center(
                                  child: SizedBox(
                                      width: 24,
                                      height: 24,
                                      child: CircularProgressIndicator(strokeWidth: 2))),
                            );
                          }
                          final bank = _banks[index];
                          final isMine = currentUserId != null &&
                              bank.ownerId == currentUserId;
                          final isFavorite = _favoriteIds.contains(bank.id);

                          return Card(
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor: isMine
                                    ? context.appColors.success.withValues(alpha: 0.15)
                                    : context.appColors.info.withValues(alpha: 0.12),
                                child: Icon(Icons.description,
                                    color: isMine
                                        ? context.appColors.success
                                        : context.appColors.info),
                              ),
                              title: Text(bank.name,
                                  style: const TextStyle(fontWeight: FontWeight.bold)),
                              subtitle: Row(
                                children: [
                                  Icon(Icons.person_outline,
                                      size: 12, color: theme.colorScheme.outline),
                                  const SizedBox(width: 4),
                                  Flexible(
                                    child: Text(
                                      isMine ? '我上传的' : bank.authorName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: isMine
                                            ? context.appColors.success
                                            : theme.colorScheme.outline,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Text('${bank.questionCount} 道题',
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: theme.colorScheme.outline)),
                                ],
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (isMine) ...[
                                    IconButton(
                                      tooltip: '改题库名',
                                      visualDensity: VisualDensity.compact,
                                      constraints: const BoxConstraints.tightFor(
                                          width: 36, height: 36),
                                      padding: EdgeInsets.zero,
                                      icon: Icon(
                                          Icons.drive_file_rename_outline,
                                          color: context.appColors.info),
                                      onPressed: () => _renameMyBank(bank),
                                    ),
                                    IconButton(
                                      tooltip: '删除我的题库',
                                      visualDensity: VisualDensity.compact,
                                      constraints: const BoxConstraints.tightFor(
                                          width: 36, height: 36),
                                      padding: EdgeInsets.zero,
                                      icon: Icon(Icons.delete_forever,
                                          color: context.appColors.danger),
                                      onPressed: () => _deleteMyBank(bank),
                                    ),
                                  ],
                                  IconButton(
                                    tooltip: isFavorite ? '取消收藏' : '收藏到藏书阁',
                                    visualDensity: VisualDensity.compact,
                                    constraints: const BoxConstraints.tightFor(
                                        width: 36, height: 36),
                                    padding: EdgeInsets.zero,
                                    icon: Icon(
                                      isFavorite
                                          ? Icons.bookmark
                                          : Icons.bookmark_add_outlined,
                                      color: isFavorite
                                          ? theme.colorScheme.primary
                                          : context.appColors.warning,
                                    ),
                                    onPressed: () => _toggleFavorite(bank),
                                  ),
                                ],
                              ),
                              onTap: () => _openBank(bank),
                            ),
                          );
                        },
                      ),
                    ),
    );
  }
}
