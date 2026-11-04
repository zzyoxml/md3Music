import 'package:shared_preferences/shared_preferences.dart';

import '../data/repositories/settings_repository.dart';

/// 歌单排序工具：让「添加到歌单」对话框中的歌单顺序与收藏页
/// 「创建的歌单」自定义顺序保持一致。
///
/// 排序规则与 [lib/modules/user/favorites_page.dart] 的 `_applySort` 对齐：
/// 1. 存在手动拖拽顺序（createdPlaylistOrder）时优先按该顺序；
///    未列入手动顺序的歌单排在最后并保持原相对顺序。
/// 2. 无手动顺序且开启「按最近点击排序」时，按访问时间戳降序。
///
/// 任何读取失败都静默忽略（不排序），保证对话框始终可用。
class PlaylistOrderUtils {
  PlaylistOrderUtils._();

  static const String _accessOrderKey = 'playlist_access_order';

  /// 取歌单 map 在排序持久化中的稳定 key。
  /// 与收藏页 `globalCollectionId ?? id` 口径一致：
  /// map 中对应字段为 'global_collection_id' 与 'specialid'。
  static String _mapKey(Map<String, dynamic> map) =>
      (map['global_collection_id'] ?? map['specialid'])?.toString() ?? '';

  /// 解析 'playlist_access_order'（格式 "key:ts,key:ts"）为 key→时间戳 映射。
  static Map<String, int> _parseAccessOrder(String? raw) {
    final map = <String, int>{};
    if (raw == null || raw.isEmpty) return map;
    for (final part in raw.split(',')) {
      final kv = part.split(':');
      if (kv.length == 2) {
        final ts = int.tryParse(kv[1]);
        if (ts != null) map[kv[0]] = ts;
      }
    }
    return map;
  }

  /// 按收藏页相同规则对 [playlists] 原地排序。
  /// 读取失败时静默忽略（保持原顺序）。
  static Future<void> sortCreatedPlaylistMaps(
    List<Map<String, dynamic>> playlists,
  ) async {
    if (playlists.isEmpty) return;
    try {
      final repo = SettingsRepository();
      final manualOrder = await repo.getCreatedPlaylistOrder();
      final sortByLatestClick = await repo.getSortCollectedByLatestClick();

      if (manualOrder.isNotEmpty) {
        final rank = <String, int>{
          for (var i = 0; i < manualOrder.length; i++) manualOrder[i]: i,
        };
        final originalIndex = <String, int>{
          for (var i = 0; i < playlists.length; i++) _mapKey(playlists[i]): i,
        };
        playlists.sort((a, b) {
          final keyA = _mapKey(a);
          final keyB = _mapKey(b);
          final fallbackA =
              manualOrder.length + (originalIndex[keyA] ?? 0);
          final fallbackB =
              manualOrder.length + (originalIndex[keyB] ?? 0);
          return (rank[keyA] ?? fallbackA).compareTo(rank[keyB] ?? fallbackB);
        });
      } else if (sortByLatestClick) {
        final prefs = await SharedPreferences.getInstance();
        final accessOrder = _parseAccessOrder(prefs.getString(_accessOrderKey));
        int accessTime(Map<String, dynamic> m) =>
            accessOrder[_mapKey(m)] ?? 0;
        playlists.sort((a, b) => accessTime(b).compareTo(accessTime(a)));
      }
    } catch (_) {
      // 静默忽略：排序失败不影响对话框展示
    }
  }
}
