import 'package:flutter/foundation.dart';

import '../data/repositories/local_favorites_repository.dart';

/// 本地音乐收藏 Provider。
///
/// 与云端 `FavoritesProvider` 完全隔离：
/// - 数据源：`LocalFavoritesRepository`（SharedPreferences `local_favorite_songs`）
/// - 渲染数据：从 `LibraryProvider.allSongs` 中按 id 匹配
class LocalFavoritesProvider extends ChangeNotifier {
  final LocalFavoritesRepository _repository = LocalFavoritesRepository();
  Set<String> _localFavoriteIds = <String>{};

  Set<String> get favoriteIds => _localFavoriteIds;

  LocalFavoritesProvider() {
    loadFavorites();
  }

  Future<void> loadFavorites() async {
    final ids = await _repository.getFavoriteIds();
    _localFavoriteIds = ids.toSet();
    notifyListeners();
  }

  bool isFavorite(String songId) => _localFavoriteIds.contains(songId);

  Future<void> toggleFavorite(String songId) async {
    if (_localFavoriteIds.contains(songId)) {
      _localFavoriteIds.remove(songId);
      await _repository.removeFavorite(songId);
    } else {
      _localFavoriteIds.add(songId);
      await _repository.addFavorite(songId);
    }
    notifyListeners();
  }

  Future<void> clearAll() async {
    _localFavoriteIds.clear();
    await _repository.clearLocalFavorites();
    notifyListeners();
  }
}
