import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/services/remote/ftp_client.dart';
import '../core/services/remote/remote_music_scanner.dart';
import '../core/services/remote/remote_storage_config.dart';
import '../core/services/remote/remote_storage_repository.dart';
import '../core/services/remote/webdav_client.dart';
import '../data/models/song.dart';

/// 一次远程存储扫描所需的「目录列举会话」。
///
/// 会话持有扫描期间需要复用的连接资源（目前主要是 FTP 的单条控制连接）：
/// 递归扫描会逐目录调用 [listDir]，若每次都新建连接将开几百条连接，
/// 因此由会话统一持有、结束时一次性释放（[dispose]）。
class RemoteScanSession {
  /// 目录列举器，供 [RemoteMusicScanner] 递归调用。
  final RemoteDirLister listDir;

  /// 释放会话持有的连接资源（幂等，可重复调用）。
  final Future<void> Function() dispose;

  RemoteScanSession({required this.listDir, required this.dispose});
}

/// 为某条配置构造扫描会话。
///
/// 生产用 [RemoteStorageProvider.defaultSessionFactory]；测试可替换 provider 的
/// [RemoteStorageProvider.sessionFactory] 为假实现，绕过真实网络。
typedef RemoteScanSessionFactory = RemoteScanSession Function(
  RemoteStorageConfig config,
);

/// 远程存储状态管理：配置列表、扫描进度、远程歌曲缓存。
///
/// 与 [LibraryProvider] 平级、独立 notifyListeners；本地音乐页的「远程」Tab 消费本
/// provider。配置持久化交由 [RemoteStorageRepository]（密码单独加密），
/// 远程歌曲列表用 [Song.toJson] 缓存到 shared_preferences。
class RemoteStorageProvider extends ChangeNotifier {
  /// 远程歌曲缓存 key（与 [LibraryProvider] 的本地缓存模式一致）。
  static const String remoteSongsKey = 'remote_storage_songs';

  final RemoteStorageRepository _repository = RemoteStorageRepository();

  /// 构造扫描会话的钩子。默认走真实 WebDAV/FTP 客户端；
  /// 测试可替换为假实现以便在无网络环境下验证扫描汇聚逻辑。
  @visibleForTesting
  RemoteScanSessionFactory sessionFactory = defaultSessionFactory;

  List<RemoteStorageConfig> _configs = [];
  List<Song> _remoteSongs = [];
  bool _isScanning = false;
  String? _scanError;

  List<RemoteStorageConfig> get configs => _configs;
  List<Song> get remoteSongs => _remoteSongs;
  bool get isScanning => _isScanning;
  String? get scanError => _scanError;

  /// 按 id 取配置；id 为空或未命中返回 null。
  RemoteStorageConfig? configById(String? id) {
    if (id == null) return null;
    for (final c in _configs) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// 启动时加载配置并恢复上次扫描结果。
  Future<void> init() async {
    _configs = await _repository.getConfigs();
    _remoteSongs = await _loadRemoteSongs();
    notifyListeners();
  }

  /// 测试注入用：直接替换配置列表。
  void setConfigs(List<RemoteStorageConfig> configs) {
    _configs = configs;
    notifyListeners();
  }

  /// 测试注入用：直接替换远程歌曲列表。
  void setRemoteSongs(List<Song> songs) {
    _remoteSongs = songs;
    notifyListeners();
  }

  Future<void> saveConfig(RemoteStorageConfig cfg) async {
    await _repository.saveConfig(cfg);
    _configs = await _repository.getConfigs();
    notifyListeners();
  }

  /// 删除配置：同时移除该配置的歌曲并持久化。
  Future<void> deleteConfig(String id) async {
    await _repository.deleteConfig(id);
    _configs = await _repository.getConfigs();
    _remoteSongs =
        _remoteSongs.where((s) => s.remoteSourceId != id).toList();
    await saveRemoteSongs();
    notifyListeners();
  }

  /// 测试连通性：成功返回「连接成功」，失败返回「连接失败：<原因>」。
  Future<String> testConnection(RemoteStorageConfig cfg) async {
    try {
      if (cfg.type == RemoteStorageType.webdav) {
        final ok = await WebDavClient(cfg).ping();
        return ok ? '连接成功' : '连接失败：服务器无响应';
      }
      final client = FtpClient(
        host: cfg.host,
        port: cfg.effectivePort,
        username: cfg.username,
        password: cfg.password,
      );
      await client.connect();
      await client.disconnect();
      return '连接成功';
    } catch (e) {
      return '连接失败：$e';
    }
  }

  /// 顺序扫描全部已配置存储，合并结果。
  ///
  /// 单条配置扫描失败不中断整体：记录 [scanError] 后继续下一条。
  Future<void> scanAll() async {
    if (_isScanning) return;
    _isScanning = true;
    _scanError = null;
    notifyListeners();

    final all = <Song>[];
    for (final cfg in _configs) {
      try {
        final session = sessionFactory(cfg);
        try {
          final scanner = RemoteMusicScanner(listDir: session.listDir);
          all.addAll(await scanner.scan(config: cfg));
        } finally {
          // 释放本配置扫描期内复用的连接（FTP 单连接在此断开）。
          await session.dispose();
        }
      } catch (e) {
        _scanError = '${cfg.name} 扫描失败：$e';
      }
    }

    _remoteSongs = all;
    _isScanning = false;
    notifyListeners();
  }

  /// 把当前远程歌曲持久化到 shared_preferences。
  Future<void> saveRemoteSongs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      remoteSongsKey,
      jsonEncode(_remoteSongs.map((s) => s.toJson()).toList()),
    );
  }

  Future<List<Song>> _loadRemoteSongs() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(remoteSongsKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => Song.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 默认会话构造：
  /// - WebDAV：PROPFIND 为无状态请求，客户端可直接复用；
  /// - FTP：闭包内惰性创建**单条**控制连接并在本次扫描期内复用，
  ///   每次列举只 `list(path)`（内部自带 PASV 数据连接），
  ///   扫描结束由 [RemoteScanSession.dispose] 断开，避免逐目录反复建连。
  static RemoteScanSession defaultSessionFactory(RemoteStorageConfig config) {
    if (config.type == RemoteStorageType.webdav) {
      final client = WebDavClient(config);
      return RemoteScanSession(
        listDir: client.list,
        dispose: () async {},
      );
    }

    FtpClient? ftp;
    return RemoteScanSession(
      listDir: (path) async {
        ftp ??= await _connectFtp(config);
        final entries = await ftp!.list(path);
        // FtpEntry 与 WebDavEntry 同构，逐字段映射即可。
        return entries
            .map((e) => WebDavEntry(
                  path: e.path,
                  name: e.name,
                  isDirectory: e.isDirectory,
                  size: e.size,
                ))
            .toList();
      },
      dispose: () async {
        final client = ftp;
        ftp = null;
        await client?.disconnect();
      },
    );
  }

  static Future<FtpClient> _connectFtp(RemoteStorageConfig config) async {
    final client = FtpClient(
      host: config.host,
      port: config.effectivePort,
      username: config.username,
      password: config.password,
    );
    await client.connect();
    return client;
  }
}