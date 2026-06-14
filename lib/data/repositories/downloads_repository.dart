import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/download_task.dart';

class DownloadsRepository {
  static const String _key = 'download_tasks';

  Future<void> saveTask(DownloadTask task) async {
    final prefs = await SharedPreferences.getInstance();
    final tasks = await getTasks();
    final existingIndex = tasks.indexWhere((t) => t.songId == task.songId);
    if (existingIndex >= 0) {
      tasks[existingIndex] = task;
    } else {
      tasks.add(task);
    }
    final jsonList = tasks.map((t) => jsonEncode(t.toJson())).toList();
    await prefs.setStringList(_key, jsonList);
  }

  Future<void> removeTask(String songId) async {
    final prefs = await SharedPreferences.getInstance();
    final tasks = await getTasks();
    tasks.removeWhere((t) => t.songId == songId);
    final jsonList = tasks.map((t) => jsonEncode(t.toJson())).toList();
    await prefs.setStringList(_key, jsonList);
  }

  Future<List<DownloadTask>> getTasks() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = prefs.getStringList(_key);
    if (jsonList == null) return [];
    return jsonList
        .map((str) {
          try {
            return DownloadTask.fromJson(
              jsonDecode(str) as Map<String, dynamic>,
            );
          } catch (_) {
            return null;
          }
        })
        .whereType<DownloadTask>()
        .toList();
  }

  Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
