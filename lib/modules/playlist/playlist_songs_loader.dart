import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../data/models/playlist.dart';
import '../../data/models/song.dart';
import '../../data/repositories/favorite_lists_cache.dart';
import '../../providers/kugou_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';

/// 歌单歌曲加载结果。[apiSucceeded] 用于区分「空歌单」与「网络失败」。
class PlaylistSongsResult {
  final List<Song> songs;
  final bool apiSucceeded;
  const PlaylistSongsResult(this.songs, this.apiSucceeded);
}

/// 歌单歌曲加载器：歌单详情页与收藏页「封面一键播放」共用同一套
/// 「listid / global_collection_id 接口 + 本地缓存」解析逻辑，
/// 避免出现第二套歌单解析实现（见改版计划四）。
class PlaylistSongsLoader {
  /// 「我的收藏」歌单的本地缓存 key。与歌单详情页一致：
  /// subscribedListId 优先，其次 listCreateListid，最后 id。
  static String? cacheKey(Playlist playlist, {required bool isInMyFavorites}) {
    if (!isInMyFavorites) return null;
    final key =
        playlist.subscribedListId ?? playlist.listCreateListid ?? playlist.id;
    return key.isEmpty ? null : key;
  }

  /// 读取本地缓存歌曲（无网络 / 秒开时先用）。失败或无缓存返回空列表。
  static Future<List<Song>> readCached(
    Playlist playlist, {
    required bool isInMyFavorites,
  }) async {
    final key = cacheKey(playlist, isInMyFavorites: isInMyFavorites);
    if (key == null) return const [];
    try {
      return await FavoriteListsCache.readPlaylistSongs(key);
    } catch (_) {
      return const [];
    }
  }

  /// 拉取歌单完整歌曲。与歌单详情页 `_fetchSongs` 同一优先级与接口：
  /// 已登录 + listid → `/playlist/track/all/new` 分页；否则走
  /// `global_collection_id`（KugouProvider.getPlaylistTrackAll）。
  /// 成功且 [isInMyFavorites] 时同步写入与详情页同 key 的本地缓存。
  static Future<PlaylistSongsResult> fetch(
    BuildContext context,
    Playlist playlist, {
    bool isInMyFavorites = true,
  }) async {
    final api = KugouApiClient();
    final isLoggedIn = api.isLoggedIn;
    final fetchListid = playlist.subscribedListId ?? playlist.listCreateListid;

    List<Song> all = [];
    bool apiSucceeded = false;

    if (isLoggedIn && fetchListid != null && fetchListid.isNotEmpty) {
      const int pageSize = 200;
      const int maxSongs = 9999;
      const int maxPages = (maxSongs + pageSize - 1) ~/ pageSize;
      for (int page = 1; page <= maxPages; page++) {
        final r = await api.getPlaylistSongsByListid(
          listid: fetchListid,
          page: page,
          pagesize: pageSize,
          noCache: true,
        );
        if (r == null) break;
        apiSucceeded = true;
        final batch = r.songs.map((s) => s.toSong()).toList();
        all.addAll(batch);
        if (all.length >= maxSongs) {
          all = all.sublist(0, maxSongs);
          break;
        }
        if (batch.length < pageSize) break;
      }
      // listid 拉不到时回退原始歌单的 global_collection_id
      final fallbackGid = playlist.listCreateGid ??
          (playlist.listCreateListid != null ? null : playlist.id);
      if (all.isEmpty && fallbackGid != null && fallbackGid.isNotEmpty) {
        if (!context.mounted) return PlaylistSongsResult(all, apiSucceeded);
        final kugou = context.read<KugouProvider>();
        await kugou.getPlaylistTrackAll(id: fallbackGid, forceRefresh: true);
        all = kugou.currentPlaylistSongs.map((e) => e.toSong()).toList();
        if (all.isNotEmpty) apiSucceeded = true;
      }
    } else if (playlist.id.isNotEmpty) {
      if (!context.mounted) return PlaylistSongsResult(all, apiSucceeded);
      final kugou = context.read<KugouProvider>();
      await kugou.getPlaylistTrackAll(id: playlist.id, forceRefresh: true);
      all = kugou.currentPlaylistSongs.map((e) => e.toSong()).toList();
      if (all.isNotEmpty) apiSucceeded = true;
    }

    // 只过滤标题为空的歌曲；保留时长未知（duration=0）的歌曲
    final filtered = all
        .where((song) => song.title.isNotEmpty && song.title != '-')
        .toList();

    if (apiSucceeded && filtered.isNotEmpty) {
      final key = cacheKey(playlist, isInMyFavorites: isInMyFavorites);
      if (key != null) {
        FavoriteListsCache.savePlaylistSongs(key, filtered);
      }
    }
    return PlaylistSongsResult(filtered, apiSucceeded);
  }
}
