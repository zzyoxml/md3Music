import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';

class FavoritesRepository {
  static const String _key = 'favorite_songs';
  static const int _maxCount = 500;

  Future<void> addFavorite(Song song) async {
    final prefs = await SharedPreferences.getInstance();
    final favorites = await getFavorites();
    if (favorites.any((s) => s.id == song.id)) return;
    favorites.insert(0, song);
    if (favorites.length > _maxCount) {
      favorites.removeRange(_maxCount, favorites.length);
    }
    final jsonList = favorites.map((s) => jsonEncode(s.toJson())).toList();
    await prefs.setStringList(_key, jsonList);
  }

  Future<void> removeFavorite(String songId) async {
    final prefs = await SharedPreferences.getInstance();
    final favorites = await getFavorites();
    favorites.removeWhere((s) => s.id == songId);
    final jsonList = favorites.map((s) => jsonEncode(s.toJson())).toList();
    await prefs.setStringList(_key, jsonList);
  }

  Future<bool> isFavorite(String songId) async {
    final favorites = await getFavorites();
    return favorites.any((s) => s.id == songId);
  }

  Future<List<Song>> getFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = prefs.getStringList(_key);
    if (jsonList == null) return [];
    return jsonList
        .map((str) {
          try {
            return Song.fromJson(jsonDecode(str) as Map<String, dynamic>);
          } catch (_) {
            return null;
          }
        })
        .whereType<Song>()
        .toList();
  }

  Future<void> clearFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
