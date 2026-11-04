import 'remote_storage_config.dart';
import 'remote_storage_repository.dart';
import 'webdav_client.dart';

/// 为远程歌曲构造流式播放请求头。
///
/// 仅 WebDAV 需要鉴权头（`just_audio` 通过本地代理把 `Authorization` 附加到
/// 播放请求）；FTP 走「下载到本地后播放」，无请求头。
///
/// 配置进程内缓存未命中（[RemoteStorageRepository.peekConfig] 返回 null）
/// 或账号与密码均为空时返回 null，调用方按「无鉴权」处理。
Map<String, String>? buildPlaybackHeaders({
  required SongRemoteType remoteType,
  String? remoteSourceId,
}) {
  if (remoteType != SongRemoteType.webdav) return null;
  final cfg = RemoteStorageRepository.peekConfig(remoteSourceId);
  if (cfg == null || (cfg.username.isEmpty && cfg.password.isEmpty)) return null;
  return {
    'Authorization': WebDavClient.basicAuth(cfg.username, cfg.password),
  };
}