import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/services/media_store_service.dart';
import '../data/models/song.dart';
import '../data/repositories/settings_repository.dart';
import '../services/kugou_api/kugou_api_client.dart';

/// 云盘上传任务状态。
enum CloudUploadStatus { waiting, uploading, success, failed }

/// 一条云盘上传任务（内存态，不入库；页面退出不中断，App 重启即清空）。
class CloudUploadTask {
  CloudUploadTask({
    required this.id,
    required this.title,
    required this.artist,
    required this.filePath,
    required this.ext,
    this.sizeBytes,
    this.durationMs = 0,
  });

  /// 任务唯一标识 = 本地文件路径（同一路径天然去重）。
  final String id;
  final String title;
  final String artist;
  final String filePath;
  final String ext;
  final int? sizeBytes;
  int durationMs;

  CloudUploadStatus status = CloudUploadStatus.waiting;
  /// 已上传字节（流式进度回传）。
  int uploaded = 0;
  /// 文件总字节（读文件成功后回填）。
  int total = 0;
  /// 正在 KMR 曲库匹配中。
  bool matching = false;
  /// 命中官方曲库（上传后由服务端 matchInfo 回填）。
  bool matched = false;
  /// 秒传（文件已在服务器）。
  bool instant = false;
  String? error;
  /// 服务端 503 upload_busy 的已重试次数（全局同时只允许 1 个上传）。
  int busyAttempts = 0;

  /// 0~1 的单项进度；total 未知（未读到文件）时为 null。
  double? get progress {
    if (status == CloudUploadStatus.success) return 1.0;
    if (total <= 0) return null;
    return (uploaded.clamp(0, total) / total).clamp(0.0, 1.0);
  }
}

/// 上传执行函数签名（与 [KugouApiClient.uploadCloudSong] 的入参对齐，
/// 测试可注入 fake）。
typedef CloudUploadFn =
    Future<Map<String, dynamic>?> Function(
      Uint8List body, {
      required String extendname,
      String? name,
      String? authorName,
      int? timelen,
      required bool matchUpload,
      void Function(int uploaded, int total)? onProgress,
      void Function(String stage)? onStage,
    });

/// 云盘上传队列：应用级常驻，批量任务严格串行处理（服务端
/// MAX_ACTIVE_UPLOADS=1，同时只允许一个上传）。
///
/// - 页面退出不影响进行中的上传；
/// - 「匹配官方曲库」开关实时生效（对尚未开始的任务）并持久化；
/// - 队列从运行转空闲且有新增成功时递增 [completedGeneration]，
///   云盘页据此去抖刷新列表。
class CloudUploadProvider extends ChangeNotifier {
  CloudUploadProvider({
    bool Function()? isLoggedInFn,
    CloudUploadFn? uploadFn,
  }) : _isLoggedInFn = isLoggedInFn,
       _uploadFn = uploadFn;

  final bool Function()? _isLoggedInFn;
  final CloudUploadFn? _uploadFn;

  final List<CloudUploadTask> _tasks = [];
  bool _running = false;
  bool _matchLoaded = false;
  bool _matchEnabled = true;
  int _successSinceIdle = 0;
  int _completedGeneration = 0;

  List<CloudUploadTask> get tasks => List.unmodifiable(_tasks);
  bool get isRunning => _running;
  bool get hasTasks => _tasks.isNotEmpty;
  bool get matchEnabled => _matchEnabled;
  int get completedGeneration => _completedGeneration;

  int get waitingCount =>
      _tasks.where((t) => t.status == CloudUploadStatus.waiting).length;
  int get successCount =>
      _tasks.where((t) => t.status == CloudUploadStatus.success).length;
  int get failedCount =>
      _tasks.where((t) => t.status == CloudUploadStatus.failed).length;

  /// 当前正在上传的任务（同时至多一个）。
  CloudUploadTask? get currentTask {
    for (final t in _tasks) {
      if (t.status == CloudUploadStatus.uploading) return t;
    }
    return null;
  }

  /// 全队列 0~1 总进度（按任务均权：成功=1，进行中=单项进度，等待=0）。
  double get overallProgress {
    if (_tasks.isEmpty) return 0;
    var sum = 0.0;
    for (final t in _tasks) {
      sum += t.progress ?? 0.0;
    }
    return (sum / _tasks.length).clamp(0.0, 1.0);
  }

  /// 首次需要展示开关状态时调用一次（读持久化）。
  Future<void> ensureMatchLoaded() async {
    if (_matchLoaded) return;
    _matchLoaded = true;
    try {
      _matchEnabled = await SettingsRepository().getCloudUploadMatchEnabled();
    } catch (e) {
      debugPrint('[CloudUpload] 读取匹配开关失败: $e');
    }
    notifyListeners();
  }

  Future<void> setMatchEnabled(bool enabled) async {
    if (_matchEnabled == enabled) return;
    _matchEnabled = enabled;
    notifyListeners();
    try {
      await SettingsRepository().setCloudUploadMatchEnabled(enabled);
    } catch (e) {
      debugPrint('[CloudUpload] 持久化匹配开关失败: $e');
    }
  }

  /// 批量加入本地曲库歌曲。返回实际新加入的数量（按路径去重；
  /// 已失败的路径会重置为等待并计入新加入）。
  int enqueueSongs(List<Song> songs) {
    final added = _enqueueAll(
      songs.map(
        (s) => (
          path: s.localPath ?? '',
          title: s.displayName,
          artist: s.artist,
          durationMs: s.duration.inMilliseconds,
        ),
      ),
    );
    return added;
  }

  /// 批量加入文件夹扫描结果（scanAudioFilesInIsolate 的输出：
  /// filePath/title/artist/durationMs）。返回实际新加入的数量。
  int enqueueScannedFiles(List<Map<String, dynamic>> metas) {
    return _enqueueAll(
      metas.map(
        (m) => (
          path: (m['filePath'] ?? '').toString(),
          title: (m['title'] ?? '').toString(),
          artist: (m['artist'] ?? '').toString(),
          durationMs: (m['durationMs'] as num?)?.toInt() ?? 0,
        ),
      ),
    );
  }

  int _enqueueAll(
    Iterable<({String path, String title, String artist, int durationMs})>
    items,
  ) {
    var added = 0;
    for (final item in items) {
      if (item.path.isEmpty) continue;
      final existing = _tasks.indexWhere((t) => t.id == item.path);
      if (existing >= 0) {
        final t = _tasks[existing];
        if (t.status == CloudUploadStatus.failed) {
          // 同路径失败重选：重置为等待（保留原队列位置）
          t
            ..status = CloudUploadStatus.waiting
            ..error = null
            ..uploaded = 0
            ..total = 0
            ..busyAttempts = 0;
          added++;
        }
        continue;
      }
      _tasks.add(
        CloudUploadTask(
          id: item.path,
          title: item.title.isEmpty ? '未知歌曲' : item.title,
          artist: item.artist.isEmpty ? '未知歌手' : item.artist,
          filePath: item.path,
          ext: _extensionOf(item.path),
          durationMs: item.durationMs,
          sizeBytes: _sizeOf(item.path),
        ),
      );
      added++;
    }
    if (added > 0) {
      notifyListeners();
      _kick();
    }
    return added;
  }

  static String _extensionOf(String path) {
    final dot = path.lastIndexOf('.');
    if (dot > 0 && dot < path.length - 1) {
      return path.substring(dot + 1).toLowerCase();
    }
    return 'mp3';
  }

  static int? _sizeOf(String path) {
    try {
      if (path.startsWith('content://') || path.startsWith('file://')) return null;
      return File(path).lengthSync();
    } catch (_) {
      return null;
    }
  }

  void _kick() {
    if (_running) return;
    _running = true;
    _successSinceIdle = 0;
    scheduleMicrotask(() {
      // 微任务里跑，避免在 build/enqueue 调用栈内同步开始网络操作
      _processQueue();
    });
  }

  Future<void> _processQueue() async {
    try {
      while (true) {
        final next = _tasks
            .indexWhere((t) => t.status == CloudUploadStatus.waiting);
        if (next < 0) break;
        await _processTask(_tasks[next]);
      }
    } finally {
      _running = false;
      if (_successSinceIdle > 0) {
        _completedGeneration++;
        _successSinceIdle = 0;
      }
      notifyListeners();
    }
  }

  Future<void> _processTask(CloudUploadTask task) async {
    _patch(task, status: CloudUploadStatus.uploading);

    final bytes = await _readFileBytes(task.filePath);
    if (task.status != CloudUploadStatus.uploading) {
      // 读取期间任务被取消/重置
      return;
    }
    if (bytes == null || bytes.isEmpty) {
      _fail(task, '读取文件失败');
      return;
    }
    _patch(task, total: bytes.length, uploaded: 0);

    if (!(_isLoggedInFn?.call() ?? KugouApiClient().isLoggedIn)) {
      _fail(task, '未登录');
      return;
    }

    final upload = _uploadFn ?? KugouApiClient().uploadCloudSong;
    Map<String, dynamic>? result;
    try {
      result = await upload(
        bytes,
        extendname: task.ext,
        name: task.title,
        authorName: task.artist,
        timelen: task.durationMs > 0 ? task.durationMs : null,
        matchUpload: _matchEnabled,
        onProgress: (uploaded, total) {
          _patch(task, uploaded: uploaded, total: total, matching: false);
        },
        onStage: (stage) {
          if (stage == 'matching') {
            _patch(task, matching: true);
          } else if (stage == 'instant') {
            _patch(task, instant: true);
          }
        },
      );
    } catch (e) {
      _fail(task, '$e');
      return;
    }

    // 服务端全局串行：503 upload_busy（retryable）时等待重试
    if (result != null &&
        result['status'] == null &&
        result['error'] == 'upload_busy') {
      if (task.busyAttempts < 3) {
        task.busyAttempts++;
        _patch(task, status: CloudUploadStatus.waiting, matching: false);
        await Future<void>.delayed(const Duration(seconds: 1));
        return;
      }
      _fail(task, '服务器上传通道忙');
      return;
    }

    // 关键：只有服务端明确返回 status == 1 才算成功
    //（授权/分片/完成/添加到云盘任一环节失败都会返回 status: 0）。
    if (result != null && result['status'] == 1) {
      final matchInfo = result['matchInfo'];
      _patch(
        task,
        status: CloudUploadStatus.success,
        uploaded: bytes.length,
        matching: false,
        matched: matchInfo is Map && matchInfo['matched'] == true,
      );
      _successSinceIdle++;
      debugPrint('[CloudUpload] 成功: ${task.title} (matched=${task.matched})');
      return;
    }
    final msg = (result?['msg'] ?? result?['error_msg'] ?? '未知错误').toString();
    _fail(task, msg);
  }

  void _fail(CloudUploadTask task, String msg) {
    debugPrint('[CloudUpload] 失败: ${task.title} -> $msg');
    _patch(task, status: CloudUploadStatus.failed, matching: false, error: msg);
  }

  void _patch(
    CloudUploadTask task, {
    CloudUploadStatus? status,
    int? uploaded,
    int? total,
    bool? matching,
    bool? matched,
    bool? instant,
    String? error,
  }) {
    if (status != null) task.status = status;
    if (uploaded != null) task.uploaded = uploaded;
    if (total != null) task.total = total;
    if (matching != null) task.matching = matching;
    if (matched != null) task.matched = matched;
    if (instant != null) task.instant = instant;
    if (error != null) task.error = error;
    notifyListeners();
  }

  /// 读取本地文件二进制。
  /// 兼容 file:// URI、content:// URI（经 MediaStore 解析）与裸绝对路径。
  /// 30 秒超时：content:// 的原生解析/拷贝若挂起，不会拖死整个队列。
  Future<Uint8List?> _readFileBytes(String raw) async {
    if (raw.isEmpty) return null;
    try {
      Future<Uint8List> read;
      if (raw.startsWith('content://')) {
        read = () async {
          final resolved = await MediaStoreService.resolveLocalPath(raw);
          if (resolved == null || resolved.isEmpty) {
            throw Exception('content URI 解析失败');
          }
          return File(resolved).readAsBytes();
        }();
      } else if (raw.startsWith('file://')) {
        read = File(Uri.parse(raw).toFilePath()).readAsBytes();
      } else {
        read = File(raw).readAsBytes();
      }
      return await read.timeout(const Duration(seconds: 30));
    } catch (e) {
      debugPrint('[CloudUpload] 读取文件失败: $raw -> $e');
      return null;
    }
  }

  /// 取消全部未开始任务（进行中的任务不可中断——http 层无请求取消，
  /// 由服务端 stall 超时兜底）。返回移除的数量。
  int cancelWaiting() {
    final before = _tasks.length;
    _tasks.removeWhere((t) => t.status == CloudUploadStatus.waiting);
    final removed = before - _tasks.length;
    if (removed > 0) notifyListeners();
    return removed;
  }

  /// 重试全部失败任务（重置为等待并继续处理）。返回重试的数量。
  int retryFailed() {
    var retried = 0;
    for (final t in _tasks) {
      if (t.status == CloudUploadStatus.failed) {
        t
          ..status = CloudUploadStatus.waiting
          ..error = null
          ..uploaded = 0
          ..total = 0
          ..busyAttempts = 0;
        retried++;
      }
    }
    if (retried > 0) {
      notifyListeners();
      _kick();
    }
    return retried;
  }

  /// 重试单条失败任务。返回是否已重置。
  bool retryTask(String id) {
    final idx = _tasks.indexWhere(
      (t) => t.id == id && t.status == CloudUploadStatus.failed,
    );
    if (idx < 0) return false;
    _tasks[idx]
      ..status = CloudUploadStatus.waiting
      ..error = null
      ..uploaded = 0
      ..total = 0
      ..busyAttempts = 0;
    notifyListeners();
    _kick();
    return true;
  }

  /// 清除已完成/已失败的任务记录（运行中也可清，仅留进行中与等待）。
  void clearFinished() {
    _tasks.removeWhere(
      (t) =>
          t.status == CloudUploadStatus.success ||
          t.status == CloudUploadStatus.failed,
    );
    notifyListeners();
  }
}
