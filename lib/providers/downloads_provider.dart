import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/models/download_task.dart';
import '../data/models/song.dart';
import '../data/repositories/downloads_repository.dart';
import '../services/download_manager.dart';
import '../services/kugou_api/kugou_api_client.dart';

class DownloadsProvider extends ChangeNotifier {
  final DownloadsRepository _repository = DownloadsRepository();
  final DownloadManager _manager = DownloadManager();
  List<DownloadTask> _tasks = [];
  StreamSubscription<DownloadTask>? _subscription;

  List<DownloadTask> get tasks => _tasks;
  List<DownloadTask> get completedTasks =>
      _tasks.where((t) => t.status == DownloadStatus.completed).toList();
  List<DownloadTask> get activeTasks =>
      _tasks.where((t) =>
          t.status == DownloadStatus.downloading ||
          t.status == DownloadStatus.waiting).toList();

  DownloadsProvider() {
    loadTasks();
    _subscription = _manager.taskUpdates.listen(_onTaskUpdate);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> loadTasks() async {
    _tasks = await _repository.getTasks();
    notifyListeners();
  }

  void _onTaskUpdate(DownloadTask updatedTask) {
    final index = _tasks.indexWhere((t) => t.songId == updatedTask.songId);
    if (index >= 0) {
      _tasks[index] = updatedTask;
    }
    _repository.saveTask(updatedTask);
    notifyListeners();
  }

  bool isDownloading(String songId) {
    return _tasks.any((t) =>
        t.songId == songId &&
        (t.status == DownloadStatus.downloading ||
         t.status == DownloadStatus.waiting));
  }

  bool isDownloaded(String songId) {
    return _tasks.any((t) =>
        t.songId == songId && t.status == DownloadStatus.completed);
  }

  String? getLocalPath(String songId) {
    final task = _tasks.where((t) => t.songId == songId).firstOrNull;
    return task?.localPath;
  }

  Future<void> downloadSong(Song song, {String quality = '128'}) async {
    if (isDownloading(song.id)) return;

    
    String? downloadUrl = song.url;

    if (downloadUrl == null || downloadUrl.isEmpty) {
            try {
        final api = KugouApiClient();
                final result = await api.getSongUrl(
          song.id,
          quality: quality,
          albumId: song.albumId,
          albumAudioId: song.albumAudioId,
        );
                if (result != null && result.url.isNotEmpty) {
          downloadUrl = result.url;
        }
      } catch (e) {
                return;
      }
    }

    if (downloadUrl == null || downloadUrl.isEmpty) {
            return;
    }

        final task = DownloadTask(
      songId: song.id,
      title: song.title,
      artist: song.artist,
      artworkUri: song.artworkUri,
      downloadUrl: downloadUrl,
    );

    _tasks.add(task);
    notifyListeners();

    await _repository.saveTask(task);
        _manager.download(task);
  }

  void cancelDownload(String songId) {
    _manager.cancel(songId);
  }

  Future<void> removeTask(String songId) async {
    _manager.cancel(songId);
    await _manager.deleteFile(songId);
    _tasks.removeWhere((t) => t.songId == songId);
    await _repository.removeTask(songId);
    notifyListeners();
  }

  Future<void> retryDownload(DownloadTask task) async {
    if (task.status != DownloadStatus.failed) return;
    final retryTask = task.copyWith(
      status: DownloadStatus.waiting,
      progress: 0.0,
      error: null,
    );
    final index = _tasks.indexWhere((t) => t.songId == task.songId);
    if (index >= 0) {
      _tasks[index] = retryTask;
    }
    await _repository.saveTask(retryTask);
    notifyListeners();
    _manager.download(retryTask);
  }
}
