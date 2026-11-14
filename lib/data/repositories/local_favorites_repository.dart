import 'package:shared_preferences/shared_preferences.dart';

/// 本地音乐收藏仓库（与云端 `FavoritesRepository` 隔离）。
///
/// 存储格式：`SharedPreferences` 的 StringList，元素是 `Song.id`。
/// 完整 Song 对象不从这里读，渲染时由 `LibraryProvider.allSongs` 提供。
class LocalFavoritesRepository {
  static const String _key = 'local_favorite_songs';
  static const int _maxCount = 500;

  Future<void> addFavorite(String songId) async {
    final prefs = await SharedPreferences.getInstance();
    final ids = await getFavoriteIds();
    if (ids.contains(songId)) return;
    ids.insert(0, songId);
    if (ids.length > _maxCount) {
      ids.removeRange(_maxCount, ids.length);
    }
    await prefs.setStringList(_key, ids);
  }

  Future<void> removeFavorite(String songId) async {
    final prefs = await SharedPreferences.getInstance();
    final ids = await getFavoriteIds();
    ids.remove(songId);
    await prefs.setStringList(_key, ids);
  }

  Future<bool> isFavorite(String songId) async {
    final ids = await getFavoriteIds();
    return ids.contains(songId);
  }

  Future<List<String>> getFavoriteIds() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_key) ?? <String>[];
  }

  Future<void> clearLocalFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
