import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';

class HistoryRepository {
  static const String _key = 'play_history';
  static const int _maxCount = 100;

  Future<void> addHistory(Song song) async {
    final prefs = await SharedPreferences.getInstance();
    final history = await getHistory();
    history.removeWhere((s) => s.id == song.id);
    history.insert(0, song);
    if (history.length > _maxCount) {
      history.removeRange(_maxCount, history.length);
    }
    final jsonList = history.map((s) => jsonEncode(s.toJson())).toList();
    await prefs.setStringList(_key, jsonList);
  }

  Future<List<Song>> getHistory() async {
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

  Future<void> clearHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
