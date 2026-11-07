import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../services/kugou_api/kugou_models.dart';
import '../models/song.dart';

/// 「我的收藏」页相关数据的本地缓存仓库。
///
/// 目的：电脑本地 Node 服务端不可达时（如关闭电脑、飞行模式、服务挂了），
/// 仍然能看到上次成功同步过的歌单/专辑/歌手列表与歌单内歌曲。
///
/// 存储：所有数据用 SharedPreferences 字符串值（JSON 编码）。键名带 `_v1`
/// 后缀，未来若发生破坏性结构变更可平滑升级到 `_v2`。
class FavoriteListsCache {
  static const String _kPlaylistsV1 = 'fav_lists_playlists_v1';
  static const String _kAlbumsV1 = 'fav_lists_albums_v1';
  static const String _kArtistsV1 = 'fav_lists_artists_v1';
  static const String _kPlaylistSongsV1 = 'fav_lists_playlist_songs_v1';
  static const String _kLastSyncV1 = 'fav_lists_last_sync_v1';

  // 歌单歌曲缓存条目上限，防止单用户歌单过多撑爆 SharedPreferences。
  static const int _maxPlaylistSongsEntries = 200;

  // ==================== 歌单/专辑 列表 ====================

  static Future<List<KugouPlaylistBrief>> readPlaylists() async {
    return _readList<KugouPlaylistBrief>(
      _kPlaylistsV1,
      (m) => KugouPlaylistBrief.fromJson(m),
    );
  }

  static Future<void> savePlaylists(List<KugouPlaylistBrief> items) async {
    await _writeList(_kPlaylistsV1, items.map((e) => _briefToJson(e)).toList());
  }

  static Future<List<KugouPlaylistBrief>> readAlbums() async {
    return _readList<KugouPlaylistBrief>(
      _kAlbumsV1,
      (m) => KugouPlaylistBrief.fromJson(m),
    );
  }

  static Future<void> saveAlbums(List<KugouPlaylistBrief> items) async {
    await _writeList(_kAlbumsV1, items.map((e) => _briefToJson(e)).toList());
  }

  // ==================== 歌手列表 ====================

  static Future<List<Map<String, dynamic>>> readArtists() async {
    return _readList<Map<String, dynamic>>(_kArtistsV1, (m) => m);
  }

  static Future<void> saveArtists(List<Map<String, dynamic>> items) async {
    await _writeList(_kArtistsV1, items);
  }

  // ==================== 歌单歌曲（按 playlistKey） ====================

  /// 读取某个歌单的歌曲缓存。playlistKey 与 [PlaylistPage._fetchSongs] 取
  /// `subscribedListId ?? listCreateListid ?? id` 保持一致。
  static Future<List<Song>> readPlaylistSongs(String playlistKey) async {
    final map = await _readStringMap(_kPlaylistSongsV1);
    final raw = map[playlistKey];
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) {
            try {
              return Song.fromJson(e as Map<String, dynamic>);
            } catch (_) {
              return null;
            }
          })
          .whereType<Song>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 写入某个歌单的歌曲缓存。整体覆盖对应 key 的内容。
  static Future<void> savePlaylistSongs(
    String playlistKey,
    List<Song> songs,
  ) async {
    final map = await _readStringMap(_kPlaylistSongsV1);
    map[playlistKey] = jsonEncode(songs.map((s) => s.toJson()).toList());
    // 限制总条目数，超出时按插入顺序丢弃最旧的 key。
    if (map.length > _maxPlaylistSongsEntries) {
      final keysToRemove = map.keys
          .take(map.length - _maxPlaylistSongsEntries)
          .toList();
      for (final k in keysToRemove) {
        map.remove(k);
      }
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kPlaylistSongsV1, jsonEncode(map));
    } catch (_) {
      // 写入失败忽略
    }
  }

  // ==================== 上次同步时间 ====================

  static Future<DateTime?> readLastSyncTime() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kLastSyncV1);
      if (raw == null) return null;
      final millis = int.tryParse(raw);
      if (millis == null) return null;
      return DateTime.fromMillisecondsSinceEpoch(millis);
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveLastSyncTime(DateTime time) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kLastSyncV1,
        time.millisecondsSinceEpoch.toString(),
      );
    } catch (_) {
      // 忽略
    }
  }

  // ==================== 内部辅助 ====================

  static Future<List<T>> _readList<T>(
    String key,
    T Function(Map<String, dynamic>) parse,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .map((e) {
            try {
              return parse(e as Map<String, dynamic>);
            } catch (_) {
              return null;
            }
          })
          .whereType<T>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _writeList(
    String key,
    List<Map<String, dynamic>> items,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, jsonEncode(items));
    } catch (_) {
      // 忽略
    }
  }

  static Future<Map<String, String>> _readStringMap(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
    } catch (_) {
      return {};
    }
  }

  /// KugouPlaylistBrief 未自带 toJson，直接构造一份简洁 map，字段集与
  /// fromJson 读取的 key 对齐。
  static Map<String, dynamic> _briefToJson(KugouPlaylistBrief b) {
    return {
      'specialid': b.id,
      'specialname': b.name,
      'imgurl': b.coverUrl,
      'songcount': b.songCount,
      'global_collection_id': b.globalCollectionId,
      'albumid': b.numericId,
      'listid': b.listId,
      'list_create_userid': b.listCreateUserid,
      'list_create_listid': b.listCreateListid,
      'list_create_gid': b.listCreateGid,
      'type': b.type,
      'source': b.source,
      'intro': b.description,
    };
  }
}
