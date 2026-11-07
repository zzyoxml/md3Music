/// 歌曲的远程来源类型。
///
/// 新增字段而非复用 `Song.isOnline`：`isOnline=true` 在播放器中触发酷狗
/// 富化/歌词检索/CDN 卡顿检测等在线专属逻辑，远程歌曲不需要这些行为。
enum SongRemoteType {
  none,
  webdav,
  ftp;

  static SongRemoteType fromJson(String? value) {
    switch (value) {
      case 'webdav':
        return SongRemoteType.webdav;
      case 'ftp':
        return SongRemoteType.ftp;
      default:
        return SongRemoteType.none;
    }
  }

  /// 序列化：none 输出 null（旧 JSON 缺省向后兼容）。
  String? toJson() => switch (this) {
        SongRemoteType.none => null,
        SongRemoteType.webdav => 'webdav',
        SongRemoteType.ftp => 'ftp',
      };
}

/// 远程存储类型。
enum RemoteStorageType {
  webdav,
  ftp;

  static RemoteStorageType fromJson(String? value) => switch (value) {
        'webdav' => RemoteStorageType.webdav,
        _ => RemoteStorageType.ftp,
      };

  String toJson() => name;
}

/// 一条远程存储连接配置。
///
/// 密码**不进入 [toJson]**——配置元数据存 shared_preferences，
/// 密码单独经 flutter_secure_storage 加密（项目硬约束）。
class RemoteStorageConfig {
  final String id;
  final String name;
  final RemoteStorageType type;
  final String host;
  final int port;
  final bool useTls;
  final String username;
  final String password;

  /// 扫描根目录：webdav 形如 `/music`，ftp 形如 `/music`。
  final String rootPath;

  const RemoteStorageConfig({
    required this.id,
    required this.name,
    required this.type,
    required this.host,
    this.port = 0,
    this.useTls = false,
    this.username = '',
    this.password = '',
    this.rootPath = '/',
  });

  /// 未显式指定端口时按类型推导默认端口。
  int get effectivePort => port > 0 ? port : _defaultPort(type, useTls);

  static int _defaultPort(RemoteStorageType type, bool useTls) {
    switch (type) {
      case RemoteStorageType.webdav:
        return useTls ? 443 : 80;
      case RemoteStorageType.ftp:
        return 21;
    }
  }

  /// WebDAV 播放/请求的基准 URL（不含路径）。
  String get baseUrl {
    final scheme = type == RemoteStorageType.webdav
        ? (useTls ? 'https' : 'http')
        : 'ftp';
    return '$scheme://$host:$effectivePort';
  }

  /// WebDAV 完整文件 URL。ftp 场景不使用（just_audio 不支持 ftp://）。
  String webdavUrl(String remotePath) {
    final p = remotePath.startsWith('/') ? remotePath : '/$remotePath';
    return '${baseUrl.replaceFirst('ftp://', 'http://')}$p';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.toJson(),
        'host': host,
        'port': port,
        'useTls': useTls,
        'username': username,
        'rootPath': rootPath,
      };

  factory RemoteStorageConfig.fromJson(Map<String, dynamic> json) =>
      RemoteStorageConfig(
        id: json['id'] as String,
        name: (json['name'] as String?) ?? '远程存储',
        type: RemoteStorageType.fromJson(json['type'] as String?),
        host: (json['host'] as String?) ?? '',
        port: (json['port'] as num?)?.toInt() ?? 0,
        useTls: (json['useTls'] as bool?) ?? false,
        username: (json['username'] as String?) ?? '',
        rootPath: (json['rootPath'] as String?) ?? '/',
      );

  RemoteStorageConfig copyWith({
    String? name,
    int? port,
    bool? useTls,
    String? username,
    String? password,
    String? rootPath,
  }) =>
      RemoteStorageConfig(
        id: id,
        name: name ?? this.name,
        type: type,
        host: host,
        port: port ?? this.port,
        useTls: useTls ?? this.useTls,
        username: username ?? this.username,
        password: password ?? this.password,
        rootPath: rootPath ?? this.rootPath,
      );
}