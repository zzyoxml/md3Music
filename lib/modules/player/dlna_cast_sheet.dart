import 'package:flutter/material.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../core/services/dlna_service.dart';
import '../../providers/dlna_provider.dart';
import '../../providers/player_provider.dart';

/// 投屏二级菜单 BottomSheet。
///
/// 支持两种模式：
/// - 歌曲投屏（默认）：从 PlayerProvider 获取当前歌曲 URL
/// - MV 投屏：通过 [mvUrl] 参数传入已解析的播放地址
class DlnaCastSheet extends StatefulWidget {
  /// MV 投屏时传入播放地址，null 表示歌曲投屏。
  final String? mvUrl;
  final String? mvTitle;

  const DlnaCastSheet({super.key, this.mvUrl, this.mvTitle});

  @override
  State<DlnaCastSheet> createState() => _DlnaCastSheetState();
}

class _DlnaCastSheetState extends State<DlnaCastSheet> {
  @override
  void initState() {
    super.initState();
    // 打开即开始搜索设备
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<DlnaProvider>().startSearch();
    });
  }

  /// 用户选择设备后的投屏逻辑。
  Future<void> _onDeviceSelected(DlnaDeviceInfo device) async {
    final dlna = context.read<DlnaProvider>();
    dlna.selectDevice(device);

    if (widget.mvUrl != null) {
      await dlna.castMv(widget.mvUrl!, widget.mvTitle ?? 'MV');
    } else {
      final song = context.read<PlayerProvider>().currentSong;
      if (song != null) {
        await dlna.castSong(context, song);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: context.read<DlnaProvider>(),
      builder: (context, _) {
        final dlna = context.read<DlnaProvider>();

        // 投屏中 → 显示传输控制面板
        if (dlna.state == DlnaCastState.casting ||
            dlna.state == DlnaCastState.connecting) {
          return _buildControlPanel(context, dlna);
        }

        // 设备列表
        return _buildDeviceList(context, dlna);
      },
    );
  }

  /// 设备列表面板。
  Widget _buildDeviceList(BuildContext context, DlnaProvider dlna) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 标题栏
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(Icons.cast, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.mvUrl != null ? '投屏 MV 到设备' : '投屏到设备',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                if (dlna.state == DlnaCastState.searching)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: M3ECircularProgressIndicator(size: 20, strokeWidth: 2),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          // 错误提示
          if (dlna.state == DlnaCastState.error && dlna.errorMessage != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                dlna.errorMessage!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          // 设备列表
          if (dlna.devices.isEmpty && dlna.state == DlnaCastState.searching)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(
                child: Text('正在搜索设备...\n请确保设备已连接同一 WiFi'),
              ),
            )
          else if (dlna.devices.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(
                child: Text('未发现设备\n请确保设备已连接同一 WiFi 并支持 DLNA'),
              ),
            )
          else
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.5,
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: dlna.devices.length,
                itemBuilder: (context, index) {
                  final device = dlna.devices[index];
                  return ListTile(
                    leading: const Icon(Icons.tv),
                    title: Text(device.name),
                    subtitle: Text(
                      device.urlBase,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                    onTap: () => _onDeviceSelected(device),
                  );
                },
              ),
            ),
          // 设备断开/投屏出错后：提供明确的结束投屏入口
          // （控制面板此时已隐藏，若不提供该按钮用户将无法退出）
          if (dlna.state == DlnaCastState.error)
            Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton.icon(
                onPressed: () async {
                  await dlna.stop();
                  if (!context.mounted) return;
                  await dlna.restoreLocalPlayback(context);
                  if (context.mounted) Navigator.pop(context);
                },
                icon: const Icon(Icons.stop),
                label: const Text('结束投屏'),
              ),
            ),
          // 重新搜索按钮
          if (dlna.state != DlnaCastState.searching)
            Padding(
              padding: const EdgeInsets.all(16),
              child: OutlinedButton.icon(
                onPressed: () => dlna.startSearch(),
                icon: const Icon(Icons.refresh),
                label: const Text('重新搜索'),
              ),
            ),
        ],
      ),
    );
  }

  /// 传输控制面板（投屏中）。
  Widget _buildControlPanel(BuildContext context, DlnaProvider dlna) {
    final theme = Theme.of(context);
    final duration = dlna.duration;
    final position = dlna.position;
    final totalSeconds = duration?.inSeconds ?? 0;
    final positionSeconds = totalSeconds > 0
        ? position.inSeconds.clamp(0, totalSeconds)
        : 0;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 设备名 + 标题
            Row(
              children: [
                Icon(Icons.cast_connected, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '正在投屏到 ${dlna.deviceName ?? '设备'}',
                        style: theme.textTheme.titleSmall,
                      ),
                      if (dlna.castTitle != null)
                        Text(
                          dlna.castTitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // 错误提示横幅（控制失败等，保持投屏态）
            if (dlna.errorMessage != null) ...[
              Card(
                color: theme.colorScheme.errorContainer,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: Row(
                    children: [
                      Icon(
                        Icons.error_outline,
                        color: theme.colorScheme.onErrorContainer,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          dlna.errorMessage!,
                          style: TextStyle(
                            color: theme.colorScheme.onErrorContainer,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        color: theme.colorScheme.onErrorContainer,
                        onPressed: () => dlna.clearError(),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            // 连接中提示
            if (dlna.state == DlnaCastState.connecting)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: M3ECircularProgressIndicator()),
              )
            else ...[
              // 进度条（设备不支持 Seek 时降级为只读进度）
              if (totalSeconds > 0) ...[
                if (dlna.canSeek)
                  Slider(
                    value: positionSeconds.toDouble().clamp(0, totalSeconds.toDouble()),
                    max: totalSeconds.toDouble(),
                    onChanged: (v) {
                      dlna.seek(Duration(seconds: v.round()));
                    },
                  )
                else
                  M3ELinearProgressIndicator(
                    value: positionSeconds / totalSeconds,
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(_formatDuration(position),
                          style: theme.textTheme.bodySmall),
                      Text(_formatDuration(duration!),
                          style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 8),
              // 播放控制（设备不支持 Pause 时隐藏暂停/播放切换按钮）
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: const Icon(Icons.skip_previous, size: 36),
                    onPressed: widget.mvUrl == null
                        ? () => dlna.castPreviousSong(context)
                        : null,
                  ),
                  if (dlna.canPause) ...[
                    const SizedBox(width: 16),
                    IconButton.filled(
                      icon: Icon(
                        dlna.isPlaying ? Icons.pause : Icons.play_arrow,
                        size: 36,
                      ),
                      onPressed: () {
                        if (dlna.isPlaying) {
                          dlna.pause();
                        } else {
                          dlna.play();
                        }
                      },
                    ),
                    const SizedBox(width: 16),
                  ],
                  IconButton(
                    icon: const Icon(Icons.skip_next, size: 36),
                    onPressed: widget.mvUrl == null
                        ? () => dlna.castNextSong(context)
                        : null,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // 停止投屏按钮
              FilledButton.tonalIcon(
                onPressed: () async {
                  await dlna.stop();
                  await dlna.restoreLocalPlayback(context);
                  if (context.mounted) Navigator.pop(context);
                },
                icon: const Icon(Icons.cast_connected),
                label: const Text('停止投屏'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}
