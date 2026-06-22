import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

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

  Future<String> get _downloadDir async {
    Directory downloadDir;
    if (Platform.isAndroid) {
      final appDir = await getExternalStorageDirectory();
      if (appDir != null) {
        downloadDir = Directory('${appDir.path}/Music/MD3Music');
      } else {
        final dir = await getApplicationDocumentsDirectory();
        downloadDir = Directory('${dir.path}/Music/MD3Music');
      }
    } else {
      final dir = await getApplicationDocumentsDirectory();
      downloadDir = Directory('${dir.path}/Music/MD3Music');
    }
    if (!await downloadDir.exists()) {
      await downloadDir.create(recursive: true);
    }
    return downloadDir.path;
  }

  Future<void> download(DownloadTask task) async {
    if (_cancelTokens.containsKey(task.songId)) {
            return;
    }

        
    final cancelToken = CancelToken();
    _cancelTokens[task.songId] = cancelToken;

    final updatingTask = task.copyWith(status: DownloadStatus.downloading, progress: 0.0);
    _taskUpdateController.add(updatingTask);

    try {
      final dir = await _downloadDir;
      final ext = _getExtFromUrl(task.downloadUrl);
      final fileName = '${task.songId}.$ext';
      final filePath = '$dir/$fileName';
      
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

  Future<void> deleteFile(String songId) async {
    try {
      final dir = await _downloadDir;
      for (final ext in ['mp3', 'flac', 'aac', 'ogg', 'wav']) {
        final file = File('$dir/$songId.$ext');
        if (await file.exists()) {
          await file.delete();
          return;
        }
      }
    } catch (e) {
          }
  }

  String _getExtFromUrl(String url) {
    final path = Uri.parse(url).path;
    final dotIndex = path.lastIndexOf('.');
    if (dotIndex >= 0) {
      final ext = path.substring(dotIndex + 1).toLowerCase();
      if (['mp3', 'flac', 'aac', 'ogg', 'wav'].contains(ext)) {
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
