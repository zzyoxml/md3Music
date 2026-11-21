import 'dart:async';

// Material 已解耦为独立包：本项目所有 UI 一律走 material_ui，不能用
// package:flutter/material.dart —— 官方 ListTile/SwitchListTile 的 build 会
// debugCheckHasMaterial，而 material_ui 的组件树里没有 Flutter 的 Material widget，
// 进设置二级页会直接抛 "No Material widget found"（实测崩溃）。
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_dimens.dart';
import '../../core/utils/app_haptics.dart';
import '../../core/utils/app_text_context_menu.dart';
import '../../core/utils/app_toast.dart';
import '../mcp/mcp_service.dart';
import 'settings_group_heading.dart';

/// 「AI 代理」分类的二级内容：MCP 服务的全部设置。
///
/// 与 `_buildCacheSection` 同构：返回一个 `Column`（滚动容器由设置页外层提供），
/// 而不是带 Scaffold/AppBar 的 Page——设置页的一/二级导航由 `SettingsPage` 统一承担。
///
/// 服务默认不启用（持久化默认 false），未启用时只暴露一个总开关与说明文案，
/// 不绑定任何端口、不产生任何网络监听。
class McpAgentSection extends StatefulWidget {
  const McpAgentSection({super.key});

  @override
  State<McpAgentSection> createState() => _McpAgentSectionState();
}

class _McpAgentSectionState extends State<McpAgentSection> {
  @override
  Widget build(BuildContext context) {
    final service = context.watch<McpService>();
    final settings = service.settings;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    // 设置是异步从 SharedPreferences 装载的，未完成时只给一个加载态
    if (settings == null) {
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.xl),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SettingsGroupHeading('服务', first: true),
        // MCP 服务总开关：默认关闭。关闭态下本页其余设置全部隐藏，
        // 且 McpService 不会 bind 任何端口。
        // search: AI 代理 接口 mcp 大模型 智能体 claude 调用 开关
        SwitchListTile(
          title: const Text('启用 MCP 服务'),
          subtitle: const Text('允许外部 AI 客户端通过 MCP 协议调用本应用的播放与检索能力'),
          value: settings.enabled,
          onChanged: (v) {
            AppHaptics.lightImpact(HapticCategory.control);
            unawaited(service.update(settings.copyWith(enabled: v)));
          },
        ),
        if (!settings.enabled)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              0,
              AppSpacing.lg,
              AppSpacing.md,
            ),
            child: Text(
              '默认关闭。启用后应用会在本机固定端口上启动一个 MCP 端点；'
              '未开启「允许局域网访问」时只在 127.0.0.1 上监听，外部设备无法直连。',
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        if (settings.enabled) ...<Widget>[
          SettingsGroupHeading('访问控制'),
          // search: 只读模式 权限 禁止 控制 播放
          SwitchListTile(
            title: const Text('只读模式'),
            subtitle: const Text('仅暴露读取类工具，禁止播放/暂停/切歌/调音量等控制'),
            value: settings.readOnly,
            onChanged: (v) {
              AppHaptics.lightImpact(HapticCategory.control);
              unawaited(service.update(settings.copyWith(readOnly: v)));
            },
          ),
          // search: 局域网 访问 远程 绑定 0.0.0.0 wifi
          SwitchListTile(
            title: const Text('允许局域网访问'),
            subtitle: const Text('绑定 0.0.0.0 并强制校验访问令牌；关闭时仅本机回环可达'),
            value: settings.bindLan,
            onChanged: (v) {
              AppHaptics.lightImpact(HapticCategory.control);
              unawaited(service.update(settings.copyWith(bindLan: v)));
            },
          ),
          // search: MCP 二次确认 写操作确认 安全 开关
          SwitchListTile(
            title: const Text('写操作二次确认'),
            subtitle: const Text('高风险写工具执行前在手机上弹窗确认，超时视为拒绝'),
            value: settings.requireConfirm,
            onChanged: (v) {
              AppHaptics.lightImpact(HapticCategory.control);
              unawaited(service.update(settings.copyWith(requireConfirm: v)));
            },
          ),
          SettingsGroupHeading('工具分组'),
          // search: MCP 工具分组 播放控制 开关
          SwitchListTile(
            title: const Text('播放与队列'),
            subtitle: const Text('播放控制、进度音量、队列管理类工具'),
            value: settings.groupPlayer,
            onChanged: (v) {
              AppHaptics.lightImpact(HapticCategory.control);
              unawaited(service.update(settings.copyWith(groupPlayer: v)));
            },
          ),
          // search: MCP 工具分组 搜索 发现 歌单 榜单 开关
          SwitchListTile(
            title: const Text('检索与发现'),
            subtitle: const Text('搜索歌曲/歌单/专辑/歌手、歌词、榜单、每日推荐'),
            value: settings.groupDiscovery,
            onChanged: (v) {
              AppHaptics.lightImpact(HapticCategory.control);
              unawaited(service.update(settings.copyWith(groupDiscovery: v)));
            },
          ),
          // search: MCP 工具分组 收藏 歌单修改 开关
          SwitchListTile(
            title: const Text('曲库修改'),
            subtitle: const Text('收藏歌曲、加入歌单等写操作（配合二次确认）'),
            value: settings.groupLibraryWrite,
            onChanged: (v) {
              AppHaptics.lightImpact(HapticCategory.control);
              unawaited(service.update(settings.copyWith(groupLibraryWrite: v)));
            },
          ),
          // search: MCP 工具分组 均衡器 睡眠定时 桌面歌词 开关
          SwitchListTile(
            title: const Text('应用功能'),
            subtitle: const Text('睡眠定时、均衡器、桌面歌词、输出模式查询'),
            value: settings.groupAppFeatures,
            onChanged: (v) {
              AppHaptics.lightImpact(HapticCategory.control);
              unawaited(service.update(settings.copyWith(groupAppFeatures: v)));
            },
          ),
          SettingsGroupHeading('连接'),
          // search: 端口 监听 17888 地址
          ListTile(
            title: const Text('监听端口'),
            subtitle: Text('${settings.port}'),
            trailing: Icon(
              Icons.chevron_right,
              size: 20,
              color: colorScheme.onSurfaceVariant,
            ),
            onTap: () => _editPort(context, settings.port),
          ),
          // search: 连接地址 url 端点 endpoint 配置
          ListTile(
            title: const Text('连接地址'),
            subtitle: Text(service.isRunning ? service.endpointUrl : '（服务未运行）'),
            trailing: IconButton(
              icon: const Icon(Icons.copy),
              tooltip: '复制连接地址',
              onPressed: () => _copy(context, service.endpointUrl),
            ),
          ),
          // search: 令牌 token 密钥 鉴权 authorization bearer 复制
          ListTile(
            title: const Text('访问令牌'),
            subtitle: Text(
              settings.bindLan ? settings.token : '（仅本机模式无需令牌）',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                // 复制按钮：仅局域网模式下令牌有意义，回环模式下隐藏
                if (settings.bindLan)
                  IconButton(
                    tooltip: '复制访问令牌',
                    icon: const Icon(Icons.copy, size: 20),
                    onPressed: () => _copy(context, settings.token),
                  ),
                Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: colorScheme.onSurfaceVariant,
                ),
              ],
            ),
            onTap: () => _confirmResetToken(context),
          ),
          SettingsGroupHeading('状态'),
          // search: 服务状态 运行中 启动失败 日志 调用
          ListTile(
            title: const Text('服务状态'),
            subtitle: Text(_statusText(service)),
          ),
          // search: 使用指南 教程 文档 帮助 github 说明
          ListTile(
            leading: Icon(Icons.menu_book_outlined, color: colorScheme.primary),
            title: const Text('使用指南'),
            subtitle: const Text('完整功能介绍、接入方式与常见问题（GitHub）'),
            trailing: Icon(
              Icons.open_in_new,
              size: 20,
              color: colorScheme.onSurfaceVariant,
            ),
            onTap: () => unawaited(_openGuide()),
          ),
          if (service.log.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.xs,
                AppSpacing.lg,
                AppSpacing.md,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '最近调用（50 条）',
                    style: textTheme.labelLarge?.copyWith(
                      color: colorScheme.primary,
                    ),
                  ),
                  for (final entry in service.log.take(10))
                    Text(
                      '${_hhmmss(entry.at)}  ${entry.ok ? '✓' : '✗'}  ${entry.tool}',
                      style: textTheme.bodySmall,
                    ),
                  // 导出全部日志（含参数摘要），便于贴给 AI 复盘调用问题。
                  TextButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: service.exportLog()),
                      );
                      if (context.mounted) {
                        showToast('调用日志已复制');
                      }
                    },
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('复制日志'),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }

  String _statusText(McpService service) {
    switch (service.status) {
      case McpStatus.running:
        return '运行中（端口 ${service.port}）';
      case McpStatus.starting:
        return '启动中…';
      case McpStatus.error:
        return '启动失败：${service.error}';
      case McpStatus.stopped:
        return '已停止';
    }
  }

  static String _hhmmss(DateTime at) {
    final h = at.hour.toString().padLeft(2, '0');
    final m = at.minute.toString().padLeft(2, '0');
    final s = at.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  Future<void> _copy(BuildContext context, String text) async {
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    showToast('已复制：$text');
  }

  /// 端口是客户端配置里的静态 URL 组成部分，改动后服务会重启，故走弹窗确认。
  Future<void> _editPort(BuildContext context, int current) async {
    final controller = TextEditingController(text: '$current');
    final value = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('监听端口'),
        content: TextField(
          controller: controller,
          contextMenuBuilder: buildAppTextContextMenu,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(hintText: '1024 - 65535'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final port = int.tryParse(controller.text.trim());
              if (port == null || port < 1024 || port > 65535) return;
              Navigator.of(ctx).pop(port);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (value == null || !context.mounted) return;
    final service = context.read<McpService>();
    final settings = service.settings;
    if (settings == null) return;
    unawaited(service.update(settings.copyWith(port: value)));
  }

  Future<void> _confirmResetToken(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重置访问令牌'),
        content: const Text('重置后，已配置的 AI 客户端需要更新令牌才能继续连接。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('重置'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await context.read<McpService>().regenerateToken();
  }

  /// 打开 GitHub 上的 MCP 使用指南（对应仓库根目录 MCP_GUIDE.md）。
  Future<void> _openGuide() async {
    const url = 'https://github.com/zzyoxml/md3Music/blob/main/MCP_GUIDE.md';
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
