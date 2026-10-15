import 'package:flutter/foundation.dart';

/// 跨页面广播「我收藏的歌单」变更。
///
/// 场景：用户在「歌单详情页」点击收藏/取消收藏后，希望「我的收藏」tab 立刻刷新。
/// 原实现只能靠 `FavoritesProvider` 的红心变更，但红心（喜欢/不喜欢歌曲）和
/// 「收藏歌单」是两件事，前者变更不会刷新歌单列表，导致下拉刷新要等本地代理
/// apicache 2 分钟过期。
///
/// 通过本类：`playlist_page` 在 `_collectPlaylist` / `_uncollectPlaylist` 成功后
/// 调用 `notifyChanged()`，`favorites_page` 在 `initState` 里 `addListener`，
/// 收到通知后强制重新拉一次歌单列表。
class PlaylistCollectionNotifier extends ChangeNotifier {
  int _version = 0;

  int get version => _version;

  void notifyChanged() {
    _version++;
    notifyListeners();
  }
}
