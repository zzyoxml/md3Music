import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 本地缓存「歌单 id → 收藏后的 listid」映射。
///
/// 解决两个问题：
/// 1. Node 后端对用户歌单列表（/user/playlist）有约 1~2 分钟缓存，歌单详情页只靠服务器
///    比对是否收藏会导致重进要等很久才显示红心；本地优先可即时显示。
/// 2. 取消收藏时需要稳定的 listid 来源，避免依赖未稳定的接口响应字段。
class CollectedPlaylistStore {
  static const String _kKey = 'kugou_collected_playlist_map';

  static Future<Map<String, String>> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kKey);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (e) {
      // 忽略损坏的缓存
    }
    return {};
  }

  static Future<void> _save(Map<String, String> map) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kKey, jsonEncode(map));
    } catch (e) {
      // 忽略写入失败
    }
  }

  /// 读取收藏后的 listid；未收藏时返回 null
  static Future<String?> getListId(String playlistId) async {
    final map = await _load();
    return map[playlistId];
  }

  /// 记录「已收藏」及其 listid；listId 为空时清除该记录。
  static Future<void> setListId(String playlistId, String? listId) async {
    final map = await _load();
    if (listId == null || listId.isEmpty) {
      map.remove(playlistId);
    } else {
      map[playlistId] = listId;
    }
    await _save(map);
  }

  /// 清除某歌单的收藏记录
  static Future<void> remove(String playlistId) async {
    final map = await _load();
    map.remove(playlistId);
    await _save(map);
  }
}
