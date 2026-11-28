// 项目统一使用 material_ui（Flutter 3.47 起 Material 库已解耦为独立包）
import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/services/remote/remote_storage_config.dart';
import '../../core/utils/app_toast.dart';
import '../../providers/remote_storage_provider.dart';
import 'remote_storage_edit_sheet.dart';
import 'songs_page.dart';

/// 本地音乐页「远程」Tab：远程存储配置管理 + 远程歌曲列表。
///
/// Provider 走项目惯例：从 Provider 树（已在 `app.dart` 注册）读取，
/// 因此本页为无参构造，不接收外部注入的 provider 实例。
class RemoteStoragePage extends StatelessWidget {
  const RemoteStoragePage({super.key});

  /// 添加（[initial] 为空）或编辑已有配置，保存成功后重新扫描。
  ///
  /// 编辑同样触发 `scanAll`：用户改了根路径 / 地址后必须重新扫描才能看到新歌。
  Future<void> _openEditSheet(
    BuildContext context, {
    RemoteStorageConfig? initial,
  }) async {
    final provider = context.read<RemoteStorageProvider>();
    final saved = await showM3EModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => RemoteStorageEditSheet(initial: initial),
    );
    if (saved != true || !context.mounted) return;
    await _scan(context, provider,
        initial == null ? '已保存，正在扫描远程存储...' : '已保存，正在重新扫描...');
  }

  /// 触发全量扫描并持久化结果，结束时提示成功或失败原因。
  Future<void> _scan(
    BuildContext context,
    RemoteStorageProvider provider,
    String startMsg,
  ) async {
    showToast(startMsg, long: true);
    await provider.scanAll();
    await provider.saveRemoteSongs();
    if (!context.mounted) return;
    final error = provider.scanError;
    showToast(error ?? '远程扫描完成', long: error != null);
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<RemoteStorageProvider>();
    final configs = provider.configs;
    final songs = provider.remoteSongs;

    return Column(
      children: [
        // 存储配置区标题 + 添加按钮
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
          child: Row(
            children: [
              Text(
                '远程存储',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: '添加远程存储',
                onPressed: () => _openEditSheet(context),
              ),
            ],
          ),
        ),
        if (configs.isEmpty)
          Expanded(
            child: _EmptyRemote(onAdd: () => _openEditSheet(context)),
          )
        else ...[
          // 配置列表：条目数量有限，shrinkWrap 自适应高度
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: [
                for (final cfg in configs)
                  _ConfigTile(
                    cfg: cfg,
                    onScan: () => _scan(context, provider, '正在扫描远程存储...'),
                    onEdit: () => _openEditSheet(context, initial: cfg),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          // 远程歌曲列表（复用 SongsPage）
          Expanded(
            child: songs.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        provider.isScanning
                            ? '正在扫描远程存储...'
                            : '点击配置右侧菜单中的「扫描音乐」获取远程歌曲',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                    ),
                  )
                : SongsPage(songs: songs),
          ),
        ],
        // 扫描进行中：顶部细进度条（不阻塞列表交互），用 M3E 波浪款
        if (provider.isScanning) const M3ELinearWavyProgressIndicator(),
      ],
    );
  }
}

/// 无任何配置时的引导空态。
class _EmptyRemote extends StatelessWidget {
  final VoidCallback onAdd;

  const _EmptyRemote({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.cloud_outlined,
              size: 64,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              '还没有远程存储',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              '添加 WebDAV 或 FTP 服务器，直接播放远程音乐',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
            ),
            const SizedBox(height: 20),
            M3EButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('添加远程存储'),
              style: M3EButtonStyle.tonal,
            ),
          ],
        ),
      ),
    );
  }
}

/// 单条远程存储配置：名称、协议标签、地址端口 + 操作菜单。
class _ConfigTile extends StatelessWidget {
  final RemoteStorageConfig cfg;
  final VoidCallback onScan;
  final VoidCallback onEdit;

  const _ConfigTile({
    required this.cfg,
    required this.onScan,
    required this.onEdit,
  });

  Future<void> _onSelected(BuildContext context, String action) async {
    final provider = context.read<RemoteStorageProvider>();
    switch (action) {
      case 'scan':
        onScan();
      case 'test':
        showToast('正在测试连接...');
        final msg = await provider.testConnection(cfg);
        if (context.mounted) showToast(msg, long: true);
      case 'edit':
        onEdit();
      case 'delete':
        final confirmed = await showM3EModalBottomSheet<bool>(
          context: context,
          builder: (_) => _ConfirmDeleteSheet(name: cfg.name),
        );
        if (confirmed == true) {
          await provider.deleteConfig(cfg.id);
          if (context.mounted) showToast('已删除远程存储');
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    // 这里用 ListTile 而非 M3EListItem：M3EListItem 是给 M3ESegmentedList
    // 内部使用的，脱离该容器（独立 ListView）时其内部 Row 会拿到无界约束并
    // 溢出（实测 RenderFlex overflowed by 99331px）。ListTile 在 Material
    // 祖先下表现正常，且本就是可点击/带 trailing 列表项的标准 MD3 组件。
    return ListTile(
      leading: Icon(
        cfg.type == RemoteStorageType.webdav
            ? Icons.cloud_outlined
            : Icons.dns_outlined,
      ),
      title: Text(cfg.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${cfg.host}:${cfg.effectivePort}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _TypeBadge(type: cfg.type),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (v) => _onSelected(context, v),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'scan', child: Text('扫描音乐')),
              PopupMenuItem(value: 'test', child: Text('测试连接')),
              PopupMenuItem(value: 'edit', child: Text('编辑')),
              PopupMenuItem(value: 'delete', child: Text('删除')),
            ],
          ),
        ],
      ),
    );
  }
}

/// 协议标签（WebDAV / FTP），独立 Text 便于识别与无障碍朗读。
class _TypeBadge extends StatelessWidget {
  final RemoteStorageType type;

  const _TypeBadge({required this.type});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        type == RemoteStorageType.webdav ? 'WebDAV' : 'FTP',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: colorScheme.onSecondaryContainer,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

/// 删除前的确认底部弹窗。
class _ConfirmDeleteSheet extends StatelessWidget {
  final String name;

  const _ConfirmDeleteSheet({required this.name});

  @override
  Widget build(BuildContext context) {
    // 同编辑表单：必须返回 M3EBottomSheet 才有 Material 祖先，
    // 否则下方按钮会因「No Material widget found」被兜底成「此处内容加载出错」。
    return M3EBottomSheet(
      title: const Text('删除远程存储'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('确定删除「$name」？其远程歌曲也将一并移除。'),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: M3EButton(
                  onPressed: () => Navigator.pop(context, false),
                  style: M3EButtonStyle.text,
                  child: const Text('取消'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: M3EButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: M3EButtonStyle.filled,
                  child: const Text('删除'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}