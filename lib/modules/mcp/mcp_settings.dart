import 'dart:convert';
import 'dart:math';

import 'package:md3music/data/repositories/settings_repository.dart';

import 'mcp_tool.dart';

/// MCP 服务配置快照。
class McpSettings {
  const McpSettings({
    required this.enabled,
    required this.port,
    required this.bindLan,
    required this.readOnly,
    required this.token,
    this.groupPlayer = true,
    this.groupDiscovery = true,
    this.groupLibraryWrite = true,
    this.groupAppFeatures = true,
    this.requireConfirm = true,
  });

  final bool enabled;

  /// 监听端口（默认 17888）。端口固定是刚需：MCP 客户端配置是静态 URL。
  final int port;

  /// true = 绑定 0.0.0.0（局域网可达，强制 token 鉴权）；false = 仅回环。
  final bool bindLan;

  /// true = 隐藏并拒绝所有会改变播放状态的工具。
  final bool readOnly;

  final String token;

  /// 工具组开关（默认全开；关掉的组对客户端不可见）。
  final bool groupPlayer;
  final bool groupDiscovery;
  final bool groupLibraryWrite;
  final bool groupAppFeatures;

  /// 写操作是否需要 App 内二次确认（默认 true；关闭后 requiresConfirmation
  /// 工具被注册表直接拒绝，而不是跳过确认执行）。
  final bool requireConfirm;

  /// 组名 → 开关 的快照，供服务端装配注册表。
  Map<String, bool> get groupFlags => <String, bool>{
        kMcpGroupPlayer: groupPlayer,
        kMcpGroupDiscovery: groupDiscovery,
        kMcpGroupLibraryWrite: groupLibraryWrite,
        kMcpGroupAppFeatures: groupAppFeatures,
      };

  McpSettings copyWith({
    bool? enabled,
    int? port,
    bool? bindLan,
    bool? readOnly,
    String? token,
    bool? groupPlayer,
    bool? groupDiscovery,
    bool? groupLibraryWrite,
    bool? groupAppFeatures,
    bool? requireConfirm,
  }) =>
      McpSettings(
        enabled: enabled ?? this.enabled,
        port: port ?? this.port,
        bindLan: bindLan ?? this.bindLan,
        readOnly: readOnly ?? this.readOnly,
        token: token ?? this.token,
        groupPlayer: groupPlayer ?? this.groupPlayer,
        groupDiscovery: groupDiscovery ?? this.groupDiscovery,
        groupLibraryWrite: groupLibraryWrite ?? this.groupLibraryWrite,
        groupAppFeatures: groupAppFeatures ?? this.groupAppFeatures,
        requireConfirm: requireConfirm ?? this.requireConfirm,
      );
}

class McpSettingsStore {
  McpSettingsStore([SettingsRepository? repository])
      : _repo = repository ?? SettingsRepository();

  final SettingsRepository _repo;

  Future<McpSettings> load() async {
    final token = await _resolveToken();
    return McpSettings(
      enabled: await _repo.getMcpEnabled(),
      port: await _repo.getMcpPort(),
      bindLan: await _repo.getMcpBindLan(),
      readOnly: await _repo.getMcpReadOnly(),
      groupPlayer: await _repo.getMcpGroupPlayer(),
      groupDiscovery: await _repo.getMcpGroupDiscovery(),
      groupLibraryWrite: await _repo.getMcpGroupLibraryWrite(),
      groupAppFeatures: await _repo.getMcpGroupAppFeatures(),
      requireConfirm: await _repo.getMcpRequireConfirm(),
      // 首次读取即生成并落盘，保证 token 在会话间稳定
      token: token.isEmpty ? await regenerateToken() : token,
    );
  }

  /// 令牌读取与迁移：secure storage 优先；旧明文值存在时搬过去并清除。
  Future<String> _resolveToken() async {
    final secure = await _repo.getMcpTokenSecure();
    if (secure.isNotEmpty) return secure;
    final legacy = await _repo.getMcpToken();
    if (legacy.isEmpty) return '';
    await _repo.setMcpTokenSecure(legacy);
    await _repo.clearMcpToken();
    return legacy;
  }

  Future<void> save(McpSettings s) async {
    await _repo.setMcpEnabled(s.enabled);
    await _repo.setMcpPort(s.port);
    await _repo.setMcpBindLan(s.bindLan);
    await _repo.setMcpReadOnly(s.readOnly);
    await _repo.setMcpGroupPlayer(s.groupPlayer);
    await _repo.setMcpGroupDiscovery(s.groupDiscovery);
    await _repo.setMcpGroupLibraryWrite(s.groupLibraryWrite);
    await _repo.setMcpGroupAppFeatures(s.groupAppFeatures);
    await _repo.setMcpRequireConfirm(s.requireConfirm);
    await _repo.setMcpTokenSecure(s.token);
  }

  Future<String> regenerateToken() async {
    final bytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    final token = base64UrlEncode(bytes).replaceAll('=', '');
    await _repo.setMcpTokenSecure(token);
    return token;
  }
}
