import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/utils/permissions.dart';
import '../data/models/download_task.dart';
import '../data/models/song.dart';
import '../data/repositories/downloads_repository.dart';
import '../data/repositories/settings_repository.dart';
import '../services/download_manager.dart';
import '../services/kugou_api/kugou_api_client.dart';
import '../services/metadata_writer.dart';

class DownloadsProvider extends ChangeNotifier {
  final DownloadsRepository _repository = DownloadsRepository();
  final DownloadManager _manager = DownloadManager();
  final SettingsRepository _settings = SettingsRepository();
  List<DownloadTask> _tasks = [];
  StreamSubscription<DownloadTask>? _subscription;

  /// 上一次权限检查的结果缓存：避免每次点下载都触发系统弹窗。
  /// 用户从设置返回后再次点下载，重新检查。
  bool? _lastPermissionGranted;

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
    final wasActive = index >= 0 &&
        (_tasks[index].status == DownloadStatus.downloading ||
            _tasks[index].status == DownloadStatus.waiting);
    if (index >= 0) {
      _tasks[index] = updatedTask;
    }
    _repository.saveTask(updatedTask);
    notifyListeners();

    // 下载完成 → 触发元数据嵌入（fire-and-forget）
    if (wasActive && updatedTask.status == DownloadStatus.completed) {
      _embedMetadata(updatedTask);
    }
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

  /// 检查存储权限：用户首次下载时触发系统弹窗 / 跳转设置。
  /// 返回 true 表示已授权；false 表示需要用户去设置开启。
  Future<bool> ensureStoragePermission() async {
    final granted = await requestStoragePermission();
    _lastPermissionGranted = granted;
    return granted;
  }

  /// 上一次权限检查的缓存值（供 UI 判断是否需要提示用户去设置）。
  bool? get lastPermissionGranted => _lastPermissionGranted;

  /// 触发下载。
  /// 返回值：
  ///   - true  = 已成功加入下载队列
  ///   - false = 因权限被拒 / URL 解析失败 / 已在下载中等原因未开始
  /// UI 层可根据返回值显示对应 SnackBar 提示。
  Future<bool> downloadSong(Song song, {String quality = '128'}) async {
    if (isDownloading(song.id)) return false;

    // 1. 检查存储权限（首次下载触发系统授权弹窗 / 设置跳转）
    final granted = await ensureStoragePermission();
    if (!granted) {
      // lastPermissionGranted 供 UI 判断是"用户主动拒绝"还是"权限异常"
      return false;
    }

    // 2. 解析下载 URL
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
        return false;
      }
    }
    if (downloadUrl == null || downloadUrl.isEmpty) return false;

    // 3. 读取下载目录
    final downloadDir = await _settings.getDownloadDir();

    // 4. 构造下载任务（带 album 字段，供元数据嵌入使用）
    final task = DownloadTask(
      songId: song.id,
      title: song.title,
      artist: song.artist,
      album: song.album,
      artworkUri: song.artworkUri,
      downloadUrl: downloadUrl,
    );

    _tasks.add(task);
    notifyListeners();
    await _repository.saveTask(task);

    // 5. 启动下载
    _manager.download(task, downloadDir);
    return true;
  }

  void cancelDownload(String songId) {
    _manager.cancel(songId);
  }

  Future<void> removeTask(String songId) async {
    _manager.cancel(songId);
    // 找到对应任务，传入新命名规则所需的元数据
    final task = _tasks.where((t) => t.songId == songId).firstOrNull;
    final downloadDir = await _settings.getDownloadDir();
    await _manager.deleteFile(
      songId,
      downloadDir: downloadDir,
      artist: task?.artist,
      title: task?.title,
    );
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
    final downloadDir = await _settings.getDownloadDir();
    _manager.download(retryTask, downloadDir);
  }

  /// 下载完成后嵌入元数据（fire-and-forget，失败不阻断）。
  ///
  /// 流程：
  /// 1. 并行：下载封面图到临时文件 + 拉取歌词（任一失败容忍）
  /// 2. 调用 MetadataWriter.writeMetadata 写入标签
  /// 3. 清理临时封面文件
  Future<void> _embedMetadata(DownloadTask task) async {
    if (task.localPath == null) {
      debugPrint('[EmbedMetadata] ❌ skipped: localPath is null for ${task.songId}');
      return;
    }
    debugPrint('[EmbedMetadata] ▶ start for "${task.title}" (id=${task.songId})');

    String? artworkPath;
    try {
      // 并行：拉封面 + 拉歌词
      final results = await Future.wait([
        _downloadArtwork(task.songId, task.artworkUri),
        _fetchLyric(task.songId, task.title),
      ]);
      artworkPath = results[0];
      final lyricText = results[1];

      debugPrint('[EmbedMetadata] artwork=${artworkPath ?? "null"}, '
          'lyricLen=${lyricText?.length ?? 0}, '
          'file=${task.localPath}');

      final ok = await MetadataWriter.writeMetadata(
        filePath: task.localPath!,
        title: task.title,
        artist: task.artist,
        album: task.album ?? '',
        artworkPath: artworkPath,
        lyrics: lyricText,
      );
      debugPrint('[EmbedMetadata] writeMetadata returned: $ok');
    } catch (e) {
      debugPrint('[EmbedMetadata] ❌ error: $e');
    } finally {
      // 清理临时封面文件
      if (artworkPath != null) {
        try {
          final f = File(artworkPath);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
  }

  /// 下载封面图到 app 临时目录，返回本地路径。
  /// 使用 KugouApiClient 的 Dio 单例（带 Authorization header），
  /// 否则裸 Dio 请求 Kugou CDN 会 403 拒绝。
  /// 失败返回 null（容忍）。
  Future<String?> _downloadArtwork(String songId, String? artworkUri) async {
    if (artworkUri == null || artworkUri.isEmpty) return null;
    try {
      final tmpDir = await getTemporaryDirectory();
      final path = '${tmpDir.path}/${songId}_art.jpg';
      // KugouApiClient 是单例，其 Dio 带 Authorization + dfid，
      // 封面 CDN 也需要这些 header 才能下载。
      final kugouDio = KugouApiClient().dio;
      await kugouDio.download(artworkUri, path);
      debugPrint('[EmbedMetadata] artwork downloaded: $path');
      return path;
    } catch (e) {
      debugPrint('[EmbedMetadata] artwork download failed: $e');
      return null;
    }
  }

  /// 拉取歌词 LRC 文本。
  /// 优先 LRC 明文（displayLrcLyric），降级原始 decodedContent；KRC 不嵌入。
  /// 失败返回 null（容忍）。
  Future<String?> _fetchLyric(String songId, String songName) async {
    try {
      final api = KugouApiClient();
      final lyric = await api.getLyric(songId, songName: songName);
      if (lyric == null) {
        debugPrint('[EmbedMetadata] getLyric returned null for $songId');
        return null;
      }
      final text = lyric.displayLrcLyric ?? lyric.decodedContent;
      debugPrint('[EmbedMetadata] lyric: displayLrcLyric=${lyric.displayLrcLyric?.length ?? 0}, '
          'decodedContent=${lyric.decodedContent?.length ?? 0}, '
          'result=${text?.length ?? 0} chars');
      return text;
    } catch (e) {
      debugPrint('[EmbedMetadata] fetchLyric failed: $e');
      return null;
    }
  }
}
