import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../data/models/download_task.dart';
import '../data/models/song.dart';
import '../data/repositories/downloads_repository.dart';
import '../data/repositories/settings_repository.dart';
import '../services/download_manager.dart';
import '../services/kugou_api/kugou_api_client.dart';
import '../services/metadata_writer.dart';
import '../widgets/apple_lyrics/parsers/krc_parser.dart';

/// 下载服务 Provider。
///
/// 协调 [DownloadManager]（DIO 下载）+ [DownloadsRepository]（任务持久化）+
/// [SettingsRepository]（下载目录配置）+ [MetadataWriter]（嵌入元数据）。
///
/// 主要职责：
/// 1. 接收 UI/Service 的下载请求，按用户配置的下载目录写入文件
/// 2. 文件名采用 `artist - title.ext` 规则（同名自动追加 `(2)`/`(3)`）
///    并在完成后修正扩展名（避免 URL 扩展名与实际格式不符导致的双后缀）
/// 3. 下载完成后异步调用原生 [MetadataWriter] 嵌入标题/艺术家/专辑/
///    封面/歌词，便于在其他播放器中正确显示
/// 4. 维护 [tasks] 列表供 UI 订阅
class DownloadsProvider extends ChangeNotifier {
  final DownloadsRepository _repository = DownloadsRepository();
  final DownloadManager _manager = DownloadManager();
  final SettingsRepository _settingsRepository = SettingsRepository();
  final KugouApiClient _api = KugouApiClient();

  List<DownloadTask> _tasks = [];
  StreamSubscription<DownloadTask>? _subscription;

  /// 用于取消文件下载时的封面图保存。
  final Map<String, CancelToken> _artworkCancels = {};

  List<DownloadTask> get tasks => _tasks;
  List<DownloadTask> get completedTasks =>
      _tasks.where((t) => t.status == DownloadStatus.completed).toList();
  List<DownloadTask> get activeTasks => _tasks
      .where(
        (t) =>
            t.status == DownloadStatus.downloading ||
            t.status == DownloadStatus.waiting,
      )
      .toList();

  DownloadsProvider() {
    loadTasks();
    _subscription = _manager.taskUpdates.listen(_onTaskUpdate);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    for (final c in _artworkCancels.values) {
      c.cancel();
    }
    _artworkCancels.clear();
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
    } else {
      _tasks.add(updatedTask);
    }
    _repository.saveTask(updatedTask);
    notifyListeners();

    // 任务刚完成时触发元数据嵌入（仅在 completed 状态变化时执行一次）。
    if (updatedTask.status == DownloadStatus.completed &&
        updatedTask.localPath != null) {
      // ignore: discarded_futures
      _embedMetadata(updatedTask);
    }
  }

  bool isDownloading(String songId) {
    return _tasks.any(
      (t) =>
          t.songId == songId &&
          (t.status == DownloadStatus.downloading ||
              t.status == DownloadStatus.waiting),
    );
  }

  bool isDownloaded(String songId) {
    return _tasks.any(
      (t) => t.songId == songId && t.status == DownloadStatus.completed,
    );
  }

  String? getLocalPath(String songId) {
    final task = _tasks.where((t) => t.songId == songId).firstOrNull;
    return task?.localPath;
  }

  /// 计算当前生效的下载目录。
  /// 用户通过设置自定义的目录优先；否则使用 Android 应用专属外部目录
  /// /storage/emulated/0/Android/data/<package>/files/downloads
  /// （文件管理器可见，卸装 App 时自动清理，零权限要求）。
  Future<String> _resolveDownloadDir() async {
    final customDir = await _settingsRepository.getDownloadDir();
    if (customDir != null && customDir.isNotEmpty) {
      return customDir;
    }
    final external = await getExternalStorageDirectory();
    if (external != null) {
      // 不用 path.join（path 不在 pubspec 直接依赖中），用平台原生分隔符。
      // Android 上 getExternalStorageDirectory() 已返回
      // /storage/emulated/0/Android/data/<package>/files，带 / 分隔符。
      final sep = Platform.pathSeparator;
      return '${external.path}${sep}downloads';
    }
    // 兜底：极端情况下拿不到外部目录时使用应用私有目录
    final docs = await getApplicationDocumentsDirectory();
    final sep = Platform.pathSeparator;
    return '${docs.path}${sep}downloads';
  }

  /// 下载歌曲。返回实际使用的音质（可能因自动降级与请求的不同），失败返回 null。
  Future<String?> downloadSong(Song song, {String quality = '128'}) async {
    if (isDownloading(song.id)) return null;

    // 始终调用 API 获取指定音质的下载链接，不使用 song.url 缓存
    // 因为播放时获取的 URL 可能是最高音质（VIP 用户），与用户选择的音质不一致
    // 使用带降级的获取方法：当指定音质不可用时自动降级到更低音质
    String? downloadUrl;
    String actualQuality = quality;
    try {
      final result = await _api.getSongUrlWithFallback(
        song.id,
        quality: quality,
        albumId: song.albumId,
        albumAudioId: song.albumAudioId,
      );
      if (result != null && result.url.isNotEmpty) {
        downloadUrl = result.url;
        actualQuality = result.quality;
      }
    } catch (e) {
      debugPrint('[DownloadsProvider] getSongUrl failed: $e');
      return null;
    }

    if (downloadUrl == null || downloadUrl.isEmpty) {
      return null;
    }

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
    final dir = await _resolveDownloadDir();
    _manager.download(task, dir, quality: actualQuality);
    return actualQuality;
  }

  void cancelDownload(String songId) {
    _artworkCancels[songId]?.cancel();
    _artworkCancels.remove(songId);
    _manager.cancel(songId);
  }

  Future<void> removeTask(String songId) async {
    _artworkCancels[songId]?.cancel();
    _artworkCancels.remove(songId);
    _manager.cancel(songId);

    final task = _tasks.where((t) => t.songId == songId).firstOrNull;
    final dir = await _resolveDownloadDir();
    await _manager.deleteFile(
      songId,
      downloadDir: dir,
      artist: task?.artist,
      title: task?.title,
      downloadUrl: task?.downloadUrl,
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
    final dir = await _resolveDownloadDir();
    _manager.download(retryTask, dir);
  }

  /// 下载完成后嵌入元数据（标题/艺术家/专辑/封面/歌词）。
  ///
  /// 流程：
  /// 1. 若 task 有 artworkUri，先下载到临时文件 `artwork_<songId>.<ext>`
  ///    若 artworkUri 为空，尝试通过酷狗 getImages API 获取封面
  /// 2. 若 task 有 songId，尝试通过酷狗 API 拉取歌词（不阻塞主流程）
  /// 3. 调用 [MetadataWriter.writeMetadata] 写入标签
  /// 4. 清理临时封面文件
  ///
  /// 整个流程 fire-and-forget，失败仅 debugPrint，不影响下载/播放。
  Future<void> _embedMetadata(DownloadTask task) async {
    try {
      final filePath = task.localPath;
      if (filePath == null) return;

      debugPrint(
        '[DownloadsProvider] embedMetadata start: songId=${task.songId}, '
        'title=${task.title}, artist=${task.artist}, '
        'artworkUri=${task.artworkUri}, filePath=$filePath',
      );

      String? artworkPath;
      // 1. 封面图：优先用 task.artworkUri，若为空则尝试酷狗 getImages API
      if (task.artworkUri != null && task.artworkUri!.isNotEmpty) {
        try {
          artworkPath = await _downloadArtworkToTemp(task);
          debugPrint(
            '[DownloadsProvider] artwork downloaded from task: $artworkPath',
          );
        } catch (e) {
          debugPrint(
            '[DownloadsProvider] artwork download from task failed: $e',
          );
        }
      }

      // artworkUri 为空时，尝试通过酷狗 getImages API 获取封面
      if (artworkPath == null) {
        try {
          final imgResult = await _api.getImages(task.songId);
          final imgUrl =
              imgResult?['img_url'] ??
              imgResult?['imgurl'] ??
              imgResult?['img_5'] ??
              imgResult?['sizable_cover'];
          if (imgUrl != null && imgUrl.toString().isNotEmpty) {
            final tempDir = await getTemporaryDirectory();
            final ext = _extFromUrl(imgUrl.toString()) ?? 'jpg';
            final sep = Platform.pathSeparator;
            final tempPath = '${tempDir.path}${sep}artwork_${task.songId}.$ext';
            final cancel = CancelToken();
            _artworkCancels[task.songId] = cancel;
            try {
              await _api.dio.download(
                imgUrl.toString().replaceAll('{size}', '400'),
                tempPath,
                cancelToken: cancel,
              );
              artworkPath = tempPath;
              debugPrint(
                '[DownloadsProvider] artwork downloaded from getImages: $artworkPath',
              );
            } finally {
              _artworkCancels.remove(task.songId);
            }
          }
        } catch (e) {
          debugPrint('[DownloadsProvider] getImages fallback failed: $e');
        }
      }

      if (artworkPath == null) {
        debugPrint(
          '[DownloadsProvider] no artwork available for ${task.songId}',
        );
      }

      // 2. 歌词：尝试从酷狗拉取（best-effort，失败也不影响嵌入）
      // 嵌入格式由用户设置决定：字级 LRC（逐字）或行级 LRC（逐行）。
      // 字级 LRC 是标准 LRC 格式（[mm:ss.xxx]字），播放器可正常解析。
      String? lyrics;
      try {
        debugPrint(
          '[DownloadsProvider] fetching lyric for hash=${task.songId}, title=${task.title}',
        );
        final lyric = await _api.getLyric(
          task.songId,
          songName: task.title,
          fmt: 'lrc', // 并发拉取 LRC + KRC
        );

        // 读取用户设置：是否嵌入字级 LRC
        final wantWordLevel = await SettingsRepository().getDownloadWordLevelLyrics();
        final lrcText = lyric?.displayLrcLyric ?? lyric?.content;
        final krcText = lyric?.displayKrcLyric;

        if (wantWordLevel && krcText != null && krcText.isNotEmpty) {
          // 尝试将 KRC 转换为字级 LRC
          final wordLevelLrc = KrcParser.toWordLevelLrc(krcText);
          if (wordLevelLrc.isNotEmpty) {
            lyrics = wordLevelLrc;
            debugPrint('[DownloadsProvider] embedded word-level LRC: ${wordLevelLrc.length} chars');
          } else {
            // 降级：KRC 转换失败，使用行级 LRC
            lyrics = lrcText;
            debugPrint('[DownloadsProvider] KRC conversion empty, fallback to line-level LRC');
          }
        } else {
          // 行级 LRC 或未开启逐字
          lyrics = lrcText;
          if (lyrics != null && lyrics.isNotEmpty) {
            debugPrint('[DownloadsProvider] embedded line-level LRC: ${lyrics.length} chars');
          } else {
            debugPrint('[DownloadsProvider] lyric returned empty for ${task.songId}');
          }
        }
      } catch (e) {
        debugPrint('[DownloadsProvider] fetch lyric failed: $e');
      }

      // 3. 写入标签（使用 displayName 剥离音频扩展名）
      debugPrint(
        '[DownloadsProvider] calling writeMetadata: artwork=$artworkPath, '
        'lyricsLen=${lyrics?.length ?? 0}',
      );
      final ok = await MetadataWriter.writeMetadata(
        filePath: filePath,
        title: task.displayName,
        artist: task.artist,
        album: task.album ?? '',
        artworkPath: artworkPath,
        lyrics: lyrics,
      );
      debugPrint('[DownloadsProvider] writeMetadata ok=$ok for ${task.songId}');

      // 4. 清理临时封面文件
      if (artworkPath != null) {
        try {
          await File(artworkPath).delete();
          debugPrint('[DownloadsProvider] temp artwork deleted: $artworkPath');
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('[DownloadsProvider] embedMetadata unexpected error: $e');
    }
  }

  /// 下载封面图到临时文件，返回本地路径。
  /// 使用 KugouApiClient.dio 复用同一 Cookie/UA。
  Future<String?> _downloadArtworkToTemp(DownloadTask task) async {
    final tempDir = await getTemporaryDirectory();
    final ext = _extFromUrl(task.artworkUri!) ?? 'jpg';
    final sep = Platform.pathSeparator;
    final path = '${tempDir.path}${sep}artwork_${task.songId}.$ext';
    final cancel = CancelToken();
    _artworkCancels[task.songId] = cancel;
    try {
      await _api.dio.download(task.artworkUri!, path, cancelToken: cancel);
      return path;
    } finally {
      _artworkCancels.remove(task.songId);
    }
  }

  String? _extFromUrl(String url) {
    try {
      final path = Uri.parse(url).path;
      final dot = path.lastIndexOf('.');
      if (dot < 0) return null;
      final ext = path.substring(dot + 1).toLowerCase();
      if (RegExp(r'^[a-z0-9]{2,4}$').hasMatch(ext)) return ext;
    } catch (_) {}
    return null;
  }
}
