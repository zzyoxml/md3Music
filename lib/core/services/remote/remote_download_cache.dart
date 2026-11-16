import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import 'ftp_client.dart';
import 'remote_storage_config.dart';
import 'webdav_client.dart';

/// 远程文件按需下载缓存（FTP 音频整文件 + 远程封面）。
///
/// 文件路径约定：`tempDir/<configId>/<sha1(configId:remotePath)><ext>`。
/// 下载时先写 `<name>.part`，确认非空后再原子 `rename` 到目标文件——
/// 避免半成品文件被当作有效缓存播放；`.part` 存在即视为未完成。
/// 缓存总量超过 [maxBytes] 时按最近修改时间（近似 LRU）清理最旧文件。
class RemoteDownloadCache {
  /// 缓存根目录（生产为应用缓存目录下的子目录，测试为临时目录）。
  final Directory tempDir;

  /// 缓存容量上限（字节），默认 1GB。
  final int maxBytes;

  /// 下载执行器：把 [remotePath] 的内容写入 [destFile]。
  ///
  /// 可注入（测试用）；生产由 [create] 按 FTP/WebDAV 分别实现。
  final Future<void> Function(String remotePath, File destFile) downloader;

  RemoteDownloadCache({
    required this.tempDir,
    this.maxBytes = 1024 * 1024 * 1024,
    required this.downloader,
  }) {
    if (!tempDir.existsSync()) tempDir.createSync(recursive: true);
  }

  /// 生产用缓存目录：应用缓存目录下的 `remote_download_cache` 子目录。
  ///
  /// `getApplicationCacheDirectory()` 自 path_provider 2.1.0 起提供，
  /// 当前项目依赖 2.1.6，Android/iOS/macOS/Windows/Linux 均已实现。
  static Future<Directory> defaultCacheDir() async {
    final base = await getApplicationCacheDirectory();
    return Directory('${base.path}/remote_download_cache');
  }

  /// 生产工厂：按 [config] 类型构造下载器。
  ///
  /// - FTP：用 [FtpClient] 取回整文件字节后写入目标文件。
  /// - WebDAV：用 `dio.download` 直接下载到目标文件（附带 Basic 鉴权头）。
  static Future<RemoteDownloadCache> create({RemoteStorageConfig? config}) async {
    final dir = await defaultCacheDir();
    final effective = config ??
        const RemoteStorageConfig(
          id: 'none',
          name: '',
          type: RemoteStorageType.ftp,
          host: '',
        );
    return RemoteDownloadCache(
      tempDir: dir,
      downloader: (remotePath, dest) async {
        if (effective.type == RemoteStorageType.ftp) {
          final client = FtpClient(
            host: effective.host,
            port: effective.effectivePort,
            username: effective.username,
            password: effective.password,
          );
          await client.connect();
          try {
            final bytes = await client.retrieve(remotePath);
            await dest.writeAsBytes(bytes);
          } finally {
            await client.disconnect();
          }
        } else {
          final headers = <String, String>{};
          if (effective.username.isNotEmpty || effective.password.isNotEmpty) {
            headers['Authorization'] =
                WebDavClient.basicAuth(effective.username, effective.password);
          }
          final dio = Dio(BaseOptions(baseUrl: effective.baseUrl, headers: headers));
          await dio.download(remotePath, dest.path);
        }
      },
    );
  }

  /// 确保 [remotePath] 已下载到本地，返回本地文件路径；失败返回 null。
  ///
  /// 命中（文件存在且非空）时会刷新修改时间用于 LRU，不重复下载。
  Future<String?> ensureDownloaded(String configId, String remotePath) async {
    final file = _fileFor(configId, remotePath);
    if (file.existsSync() && file.lengthSync() > 0) {
      _touch(file);
      return file.path;
    }
    try {
      file.parent.createSync(recursive: true);
      final part = File('${file.path}.part');
      if (part.existsSync()) part.deleteSync();
      await downloader(remotePath, part);
      // 半成品（不存在/为空）不算缓存，直接放弃
      if (!part.existsSync() || part.lengthSync() == 0) {
        if (part.existsSync()) part.deleteSync();
        return null;
      }
      if (file.existsSync()) file.deleteSync();
      part.renameSync(file.path);
      _touch(file);
      _pruneIfNeeded();
      return file.path;
    } catch (_) {
      return null;
    }
  }

  /// 下载并缓存远程封面，成功返回本地路径。与音频共用同一套缓存机制。
  Future<String?> fetchCover(String configId, String remotePath) =>
      ensureDownloaded(configId, remotePath);

  File _fileFor(String configId, String remotePath) {
    final hash = sha1.convert(utf8.encode('$configId:$remotePath')).toString();
    final ext = _extOf(remotePath);
    return File('${tempDir.path}/$configId/$hash$ext');
  }

  static String _extOf(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || path.length - dot > 6) return '';
    return path.substring(dot);
  }

  void _touch(File file) {
    try {
      file.setLastModifiedSync(DateTime.now());
    } catch (_) {}
  }

  /// 缓存总量超限时，按修改时间升序删除最旧文件直到不超限。
  void _pruneIfNeeded() {
    int total = 0;
    final files = <File>[];
    for (final f in tempDir.listSync(recursive: true).whereType<File>()) {
      total += f.lengthSync();
      files.add(f);
    }
    if (total <= maxBytes) return;
    files.sort((a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()));
    var freed = 0;
    for (final f in files) {
      if (total - freed <= maxBytes) break;
      freed += f.lengthSync();
      try {
        f.deleteSync();
      } catch (_) {}
    }
  }

  /// 仅用于测试清理：删除本实例的缓存目录自身。
  ///
  /// 生产路径不要调用（会清空真实缓存）；测试注入的临时目录可安全删除。
  Future<void> dispose() async {
    try {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  }
}