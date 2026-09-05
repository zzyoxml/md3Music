import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../data/models/song.dart';

/// 外部音频打开请求（待消费）。
///
/// [uri] 为原始 intent data（仅日志用），[path] 为原生侧解析后的可播放绝对路径
/// （content:// 已解析为真实路径或私有拷贝；file:// 已规范化）。
class ExternalMediaRequest {
  const ExternalMediaRequest({required this.uri, required this.path});

  final String uri;
  final String path;
}

/// 最新的外部音频打开请求。
///
/// 由 [ExternalMediaIntentService] 写入；_MainLayout 监听并在挂载后消费
/// （构建 Song → playSong → push 播放器页）。冷启动时值可能先于用户协议 /
/// 引导页到达，_MainLayout 挂载后会补消费一次当前值，不会丢失。
final ValueNotifier<ExternalMediaRequest?> externalMediaRequest =
    ValueNotifier<ExternalMediaRequest?>(null);

/// 外部调用（ACTION_VIEW）音频接收服务。
///
/// 原生侧 ExternalMediaBridge 以「推送（onExternalMedia）+ 拉取（takePendingMedia）」
/// 双通道交付，本服务汇聚为 [externalMediaRequest] 供主页消费。
class ExternalMediaIntentService {
  ExternalMediaIntentService._();

  static final ExternalMediaIntentService instance =
      ExternalMediaIntentService._();

  static const _channel = MethodChannel('com.md3music.md3music/external_media');

  /// push/pull 重复送达去重窗口：窗口内相同 uri+path 视为同一次调用。
  static const _dedupeWindowMs = 5000;

  bool _started = false;
  String? _lastDispatchKey;
  int _lastDispatchAtMs = 0;

  /// 首帧后调用：注册原生推送回调，并主动拉取一次冷启动期间积压的待处理项。
  Future<void> start() async {
    if (_started || kIsWeb || !Platform.isAndroid) return;
    _started = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onExternalMedia') {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        _dispatch(args['uri'] as String?, args['path'] as String?);
      }
      return null;
    });
    try {
      final pending = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('takePendingMedia');
      if (pending != null) {
        _dispatch(pending['uri'] as String?, pending['path'] as String?);
      }
    } catch (e) {
      debugPrint('[ExternalMedia] takePendingMedia 失败: $e');
    }
  }

  void _dispatch(String? uri, String? path) {
    if (path == null || path.isEmpty) return;
    final fsPath = normalizeToFsPath(path);
    final key = '${uri ?? ''}|$fsPath';
    final now = DateTime.now().millisecondsSinceEpoch;
    if (key == _lastDispatchKey && now - _lastDispatchAtMs < _dedupeWindowMs) {
      // 推送与拉取把同一次调用送达了两遍，忽略第二遍
      return;
    }
    _lastDispatchKey = key;
    _lastDispatchAtMs = now;
    externalMediaRequest.value =
        ExternalMediaRequest(uri: uri ?? '', path: fsPath);
  }

  /// 文件是否存在可读。
  bool isPathReadable(String path) => File(path).existsSync();

  /// 读取音频元数据（独立 Isolate，失败返回空 Map，不抛异常）。
  Future<Map<String, dynamic>> readMetadata(String path) async {
    try {
      return await compute(_readMetadataInIsolate, path);
    } catch (e) {
      debugPrint('[ExternalMedia] readMetadata 失败: $e');
      return <String, dynamic>{};
    }
  }

  /// 由请求 + 元数据构建可播放的 [Song]。
  ///
  /// [Song.localPath] 存绝对路径；`PlayerProvider._resolvePlaybackUrl`
  /// 会把它转换为 `file://` URI 交给 just_audio。
  ///
  /// [Song.artworkUri] 置为 `local://<path>`：与曲库本地歌曲一致，让
  /// `PlayerArtworkImage`/`LocalArtworkCache` 从音频文件懒加载内嵌封面。
  Song buildSong(ExternalMediaRequest request, Map<String, dynamic> meta) {
    final path = request.path;
    final fileName = path.split('/').last;
    return Song(
      id: externalSongId(path),
      title: _nonEmpty(meta['title'] as String?) ?? titleFromFileName(fileName),
      artist: _nonEmpty(meta['artist'] as String?) ?? '未知艺术家',
      album: _nonEmpty(meta['album'] as String?) ?? '未知专辑',
      duration: Duration(milliseconds: (meta['durationMs'] as int?) ?? 0),
      localPath: path,
      // 本地内嵌封面标识：UI 层据此从音频文件读取封面，缺省（无封面）时回落占位
      artworkUri: 'local://$path',
      isOnline: false,
    );
  }
}

/// 把原生侧交付的路径规范化为 dart:io 可用的文件系统路径（剥离 file:// 前缀）。
String normalizeToFsPath(String path) {
  if (path.startsWith('file://')) {
    try {
      return Uri.parse(path).toFilePath(windows: false);
    } catch (_) {
      return path;
    }
  }
  return path;
}

/// 外部歌曲的 Song id：external_ 前缀 + 路径 FNV-1a 哈希。
///
/// 不使用 String.hashCode：Dart 规范不保证其在进程重启间稳定，
/// 同一文件重启后得到不同 id 会造成历史记录 / 收藏记录碎片化。
String externalSongId(String path) {
  var hash = 0xcbf29ce484222325;
  for (final c in path.codeUnits) {
    hash ^= c;
    hash = hash * 0x100000001b3;
  }
  return 'external_${(hash & 0x7fffffffffffffff).toRadixString(16)}';
}

/// 从文件名取标题（剥离扩展名）。
String titleFromFileName(String fileName) {
  final lastDot = fileName.lastIndexOf('.');
  return lastDot > 0 ? fileName.substring(0, lastDot) : fileName;
}

String? _nonEmpty(String? value) =>
    (value == null || value.isEmpty) ? null : value;

/// Isolate 入口：读取内嵌标签（标题 / 艺术家 / 专辑 / 时长）。
Map<String, dynamic> _readMetadataInIsolate(String path) {
  final file = File(path);
  if (!file.existsSync()) return <String, dynamic>{};
  final metadata = readMetadata(file, getImage: false);
  return <String, dynamic>{
    'title': metadata.title,
    'artist': metadata.artist,
    'album': metadata.album,
    'durationMs': metadata.duration?.inMilliseconds ?? 0,
  };
}
