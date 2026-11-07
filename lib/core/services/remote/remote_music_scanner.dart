import 'dart:async';

import '../../../data/models/song.dart';
import 'remote_storage_config.dart';
import 'webdav_client.dart';

/// 可注入的目录列表器：屏蔽 WebDAV/FTP 差异（二者条目结构同构）。
typedef RemoteDirLister = Future<List<WebDavEntry>> Function(String path);

/// 远程目录扫描器：递归列出音频文件并构造 [Song]。
///
/// - WebDAV：`Song.url` = HTTP 播放 URL，播放时附加 Basic 鉴权头。
/// - FTP：`Song.url` = `ftp://…`（占位），播放时按需下载后替换为本地路径。
/// - 封面：优先与音频同名的图片，其次 `cover`/`folder`/`album`（jpg/jpeg/png）；
///   命中时 `artworkUri` 指向远程封面 URL（下载/展示由上层按需处理）。
///
/// 前置约定：[WebDavClient.list] 返回的 [WebDavEntry.path] 已是「解码后、
/// 无尾斜杠」的绝对路径，本扫描器直接使用，不再拼接或重复解码。
class RemoteMusicScanner {
  final RemoteDirLister listDir;

  RemoteMusicScanner({required this.listDir});

  /// 音频扩展名白名单（大小写不敏感）。
  static const Set<String> audioExts = {
    'mp3',
    'flac',
    'wav',
    'm4a',
    'ape',
    'ogg',
    'aac',
    'wma',
    'opus',
  };

  /// 目录级封面文件名候选（不含扩展名）。
  static const Set<String> coverNames = {'cover', 'folder', 'album'};

  /// 无损扩展名（用于推断质量标签）。
  static const Set<String> _losslessExts = {'flac', 'ape', 'wav', 'aiff'};

  /// 未识别元数据时的占位值（在线/本地两侧统一取「未知艺术家」）。
  static const String _unknownArtist = '未知艺术家';

  /// 递归子目录并发批量大小（限流，避免打爆服务器）。
  static const int _batchSize = 4;

  /// 扫描 [config] 的根目录，返回全部远程歌曲。
  Future<List<Song>> scan({required RemoteStorageConfig config}) async {
    final songs = <Song>[];
    await _walk(config, config.rootPath, songs, <String>{});
    return songs;
  }

  Future<void> _walk(
    RemoteStorageConfig config,
    String path,
    List<Song> out,
    Set<String> visited,
  ) async {
    if (!visited.add(path)) return; // 防循环（目录树成环或重复引用）
    final entries = await listDir(path);
    final dirs = entries.where((e) => e.isDirectory).toList();
    final files = entries.where((e) => !e.isDirectory).toList();

    // 候选封面：目录内所有图片
    final images = files.where((f) => _isImage(f.name)).toList();

    for (final f in files) {
      if (!audioExts.contains(_extOf(f.name))) continue;
      out.add(_toSong(config, f, _pickCoverFor(f, images)));
    }

    // 子目录并行但限流：一次最多 [_batchSize] 个
    for (var i = 0; i < dirs.length; i += _batchSize) {
      final end = (i + _batchSize).clamp(0, dirs.length);
      final slice = dirs.sublist(i, end);
      await Future.wait(slice.map((d) => _walk(config, d.path, out, visited)));
    }
  }

  Song _toSong(RemoteStorageConfig config, WebDavEntry f, String? coverPath) {
    return Song(
      id: 'remote_${config.type.name}_${config.id}_${f.path}',
      title: _stripExt(f.name),
      artist: _unknownArtist,
      album: _unknownArtist,
      duration: Duration.zero,
      url: config.type == RemoteStorageType.webdav
          ? config.webdavUrl(f.path)
          // FTP 占位 URL：播放时由下载缓存替换为本地路径
          : 'ftp://${config.host}:${config.effectivePort}${f.path}',
      // 封面：仅 WebDAV 可直接用 HTTP URL 展示。
      // FTP 无 HTTP 端点，webdavUrl() 会把 ftp:// 误转成 http://（必然 404），
      // 故 FTP 暂不下发封面（后续如需支持，应下载到本地后下发 file:// 路径）。
      artworkUri: coverPath != null && config.type == RemoteStorageType.webdav
          ? config.webdavUrl(coverPath)
          : null,
      isOnline: false,
      remoteType: config.type == RemoteStorageType.webdav
          ? SongRemoteType.webdav
          : SongRemoteType.ftp,
      remoteSourceId: config.id,
      quality: _qualityFor(f.name),
    );
  }

  /// 远程无码率信息：仅无损格式从扩展名推断，其余不标注。
  static String? _qualityFor(String name) {
    return _losslessExts.contains(_extOf(name)) ? 'flac' : null;
  }

  /// 返回扩展名（小写，不含点）；无扩展名返回空串。
  static String _extOf(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  /// 去掉扩展名；无扩展名或点为起始字符时原样返回。
  static String _stripExt(String name) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0) return name;
    return name.substring(0, dot);
  }

  /// 是否为封面候选图片（jpg/jpeg/png）。
  static bool _isImage(String name) {
    final ext = _extOf(name);
    return ext == 'jpg' || ext == 'jpeg' || ext == 'png';
  }

  /// 封面选择：优先与音频同名的图片，其次 cover/folder/album。
  String? _pickCoverFor(WebDavEntry audio, List<WebDavEntry> images) {
    if (images.isEmpty) return null;
    final audioBase = _stripExt(audio.name).toLowerCase();
    for (final c in images) {
      if (_stripExt(c.name).toLowerCase() == audioBase) return c.path;
    }
    for (final c in images) {
      if (coverNames.contains(_stripExt(c.name).toLowerCase())) return c.path;
    }
    return null;
  }
}