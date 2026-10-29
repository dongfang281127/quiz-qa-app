import 'package:flutter/foundation.dart';

/// 跨页面的「数据变了」广播。
///
/// 底部 Tab 用 IndexedStack 保活，每个页面只在 initState 里请求一次；
/// 别的地方新建题库、增删收藏、改题之后，这些活着的页面收不到任何通知，
/// 于是看起来「必须杀掉进程重启才显示」。这里用两个自增计数器把改动喊出去，
/// 页面在 initState 里挂监听，收到就重载。
///
/// 为什么是计数器而不是 ChangeNotifier 的事件对象：
/// 监听方只关心「有变化」，不关心变化内容，收到后统一重新拉服务端即可；
/// 计数器天然可重入，连续两次改动都能触发。
class AppEvents {
  AppEvents._();

  /// 题库集合变了：新建、删除、改名、题数变化、换账号。
  static final ValueNotifier<int> banks = ValueNotifier<int>(0);

  /// 收藏变了：题库收藏、题目收藏。
  static final ValueNotifier<int> favorites = ValueNotifier<int>(0);

  static void banksChanged() => banks.value = banks.value + 1;

  static void favoritesChanged() => favorites.value = favorites.value + 1;

  /// 换账号后两边数据都变了，一起喊。
  static void accountChanged() {
    banksChanged();
    favoritesChanged();
  }
}
