import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

import '../data/models/download_task.dart';

class DownloadManager {
  static final DownloadManager _instance = DownloadManager._internal();
  factory DownloadManager() => _instance;
  DownloadManager._internal();

  final Dio _dio = Dio();
  final Map<String, CancelToken> _cancelTokens = {};
  final StreamController<DownloadTask> _taskUpdateController =
      StreamController<DownloadTask>.broadcast();

  Stream<DownloadTask> get taskUpdates => _taskUpdateController.stream;

  /// 确保下载目录存在；不存在则递归创建。
  /// 由调用方（DownloadsProvider）传入从 settings 读取的目录路径。
  Future<void> ensureDir(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }

  /// 下载文件到 [downloadDir]。
  /// 文件名格式：`${artist} - ${title}.${ext}`，同名自动追加 ` (2)` / ` (3)` 序号。
  Future<void> download(DownloadTask task, String downloadDir) async {
    if (_cancelTokens.containsKey(task.songId)) {
      return;
    }

    final cancelToken = CancelToken();
    _cancelTokens[task.songId] = cancelToken;

    final updatingTask = task.copyWith(status: DownloadStatus.downloading, progress: 0.0);
    _taskUpdateController.add(updatingTask);

    try {
      await ensureDir(downloadDir);
      var filePath = await _buildFilePath(downloadDir, task);

      await _dio.download(
        task.downloadUrl,
        filePath,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            final progress = received / total;
            _taskUpdateController.add(
              updatingTask.copyWith(progress: progress),
            );
          }
        },
      );

      // 检测实际音频格式，修正文件扩展名（URL 中的扩展名可能与实际内容不符）
      filePath = await _fixFileExtension(filePath);
      final completedTask = task.copyWith(
        localPath: filePath,
        status: DownloadStatus.completed,
        progress: 1.0,
      );
      _taskUpdateController.add(completedTask);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        _taskUpdateController.add(
          task.copyWith(status: DownloadStatus.waiting, progress: 0.0),
        );
      } else {
        _taskUpdateController.add(
          task.copyWith(
            status: DownloadStatus.failed,
            error: e.message,
          ),
        );
      }
    } catch (e) {
      _taskUpdateController.add(
        task.copyWith(
          status: DownloadStatus.failed,
          error: e.toString(),
        ),
      );
    } finally {
      _cancelTokens.remove(task.songId);
    }
  }

  void cancel(String songId) {
    _cancelTokens[songId]?.cancel();
    _cancelTokens.remove(songId);
  }

  /// 删除指定歌曲的本地文件。
  /// 优先按新命名规则（`${artist} - ${title}.${ext}`）查找；
  /// 找不到则 fallback 到旧的 `${songId}.${ext}` 命名（兼容历史下载）。
  Future<void> deleteFile(String songId, {
    String? downloadDir,
    String? artist,
    String? title,
    String? downloadUrl,
  }) async {
    final exts = ['mp3', 'flac', 'aac', 'ogg', 'wav', 'm4a'];
    try {
      // 1. 新命名规则：artist - title.ext
      if (downloadDir != null && artist != null && title != null) {
        final safeArtist = _sanitize(artist);
        final safeTitle = _sanitize(_stripAudioExtension(title));
        for (final ext in exts) {
          final file = File('$downloadDir/$safeArtist - $safeTitle.$ext');
          if (await file.exists()) {
            await file.delete();
            return;
          }
          // 也尝试带序号的命名
          for (var i = 2; i < 100; i++) {
            final seqFile = File('$downloadDir/$safeArtist - $safeTitle ($i).$ext');
            if (await seqFile.exists()) {
              await seqFile.delete();
              return;
            }
          }
        }
      }

      // 2. Fallback：旧命名规则 songId.ext
      if (downloadDir != null) {
        for (final ext in exts) {
          final file = File('$downloadDir/$songId.$ext');
          if (await file.exists()) {
            await file.delete();
            return;
          }
        }
      }
    } catch (e) {
      // 静默失败：删除失败不影响 UI
    }
  }

  /// 构造下载文件路径：`${artist} - ${title}.${ext}`，同名追加序号。
  Future<String> _buildFilePath(String dir, DownloadTask task) async {
    final ext = _getExtFromUrl(task.downloadUrl);
    final safeArtist = _sanitize(task.artist);
    // 去掉标题中已带的音频扩展名，避免双后缀（如 "歌名.mp3" + ".flac"）
    final safeTitle = _sanitize(_stripAudioExtension(task.title));
    var name = '$safeArtist - $safeTitle.$ext';
    var path = '$dir/$name';
    if (!await File(path).exists()) return path;

    // 同名追加序号
    var i = 2;
    while (true) {
      name = '$safeArtist - $safeTitle ($i).$ext';
      path = '$dir/$name';
      if (!await File(path).exists()) return path;
      i++;
      // 防御性兜底
      if (i > 9999) break;
    }
    return path;
  }

  /// 读取文件头 magic bytes 检测实际音频格式，若扩展名不匹配则重命名。
  /// 解决 URL 中扩展名与实际内容不符导致的双后缀（如 .mp3.flac）问题。
  Future<String> _fixFileExtension(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return filePath;

      final bytes = await file.openRead(0, 12).first;
      if (bytes.length < 4) return filePath;

      // 检测实际格式
      String? actualExt;
      if (bytes.length >= 4 &&
          bytes[0] == 0x66 && bytes[1] == 0x4C &&
          bytes[2] == 0x61 && bytes[3] == 0x43) {
        actualExt = 'flac'; // fLaC
      } else if (bytes.length >= 3 &&
          bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33) {
        actualExt = 'mp3'; // ID3
      } else if (bytes.length >= 4 &&
          bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0) {
        actualExt = 'mp3'; // MPEG sync word
      } else if (bytes.length >= 4 &&
          bytes[0] == 0x4F && bytes[1] == 0x67 &&
          bytes[2] == 0x67 && bytes[3] == 0x53) {
        actualExt = 'ogg'; // OggS
      } else if (bytes.length >= 4 &&
          bytes[0] == 0x66 && bytes[1] == 0x74 &&
          bytes[2] == 0x79 && bytes[3] == 0x70) {
        actualExt = 'm4a'; // ftyp (MP4/M4A)
      }

      if (actualExt == null) return filePath;

      // 检查当前扩展名是否正确
      final dotIdx = filePath.lastIndexOf('.');
      if (dotIdx < 0) return filePath;
      final currentExt = filePath.substring(dotIdx + 1).toLowerCase();

      // 扩展名已正确，无需修改
      if (currentExt == actualExt) return filePath;

      // 替换扩展名（处理双后缀情况如 .mp3.flac → .flac）
      // 先去掉所有已知音频扩展名后缀
      var baseName = filePath;
      final knownExts = ['mp3', 'flac', 'aac', 'ogg', 'wav', 'm4a'];
      // 从末尾剥离已知扩展名（最多剥两层，处理双后缀）
      for (var i = 0; i < 2; i++) {
        final idx = baseName.lastIndexOf('.');
        if (idx < 0) break;
        final ext = baseName.substring(idx + 1).toLowerCase();
        if (knownExts.contains(ext)) {
          baseName = baseName.substring(0, idx);
        } else {
          break;
        }
      }
      final newPath = '$baseName.$actualExt';
      await file.rename(newPath);
      return newPath;
    } catch (e) {
      return filePath;
    }
  }

  /// 去掉文件名末尾的音频扩展名（如 "歌名.mp3" → "歌名"），
  /// 避免标题自带扩展名时 _buildFilePath 产生双后缀。
  String _stripAudioExtension(String name) {
    final knownExts = ['mp3', 'flac', 'aac', 'ogg', 'wav', 'm4a'];
    var result = name.trim();
    // 最多剥两层（处理 ".mp3.flac" 这种已有双后缀的极端情况）
    for (var i = 0; i < 2; i++) {
      final dotIdx = result.lastIndexOf('.');
      if (dotIdx < 0) break;
      final ext = result.substring(dotIdx + 1).toLowerCase();
      if (knownExts.contains(ext)) {
        result = result.substring(0, dotIdx).trim();
      } else {
        break;
      }
    }
    return result.isEmpty ? 'unknown' : result;
  }

  /// 过滤文件系统非法字符（Windows / Android 通用）：`\ / : * ? " < > |`
  /// 并折叠多余空白、trim 首尾。
  String _sanitize(String s) {
    if (s.isEmpty) return 'unknown';
    final cleaned = s
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return cleaned.isEmpty ? 'unknown' : cleaned;
  }

  String _getExtFromUrl(String url) {
    final path = Uri.parse(url).path;
    final dotIndex = path.lastIndexOf('.');
    if (dotIndex >= 0) {
      final ext = path.substring(dotIndex + 1).toLowerCase();
      if (['mp3', 'flac', 'aac', 'ogg', 'wav', 'm4a'].contains(ext)) {
        return ext;
      }
    }
    return 'mp3';
  }

  void dispose() {
    for (final token in _cancelTokens.values) {
      token.cancel();
    }
    _cancelTokens.clear();
    _taskUpdateController.close();
  }
}
