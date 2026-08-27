import 'package:flutter/material.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../core/utils/app_haptics.dart';
import '../../providers/dlna_provider.dart';

/// 投屏遥控页面：从悬浮窗点击进入，提供完整的传输控制。
class DlnaRemotePage extends StatefulWidget {
  const DlnaRemotePage({super.key});

  @override
  State<DlnaRemotePage> createState() => _DlnaRemotePageState();
}

class _DlnaRemotePageState extends State<DlnaRemotePage> {
  @override
  void initState() {
    super.initState();
    // 注册自动下一曲回调：投屏播放结束时自动切歌
    final dlna = context.read<DlnaProvider>();
    dlna.setAutoNextContext(context);
    dlna.onAutoNext = (ctx) async {
      await dlna.castNextSong(ctx, isAutoNext: true);
    };
  }

  @override
  void dispose() {
    // 清理回调，避免页面销毁后仍被调用
    final dlna = context.read<DlnaProvider>();
    dlna.onAutoNext = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('投屏遥控'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: ListenableBuilder(
        listenable: context.read<DlnaProvider>(),
        builder: (context, _) {
          final dlna = context.read<DlnaProvider>();
          final duration = dlna.duration;
          final totalSeconds = duration?.inSeconds ?? 0;
          final positionSeconds = totalSeconds > 0
              ? dlna.position.inSeconds.clamp(0, totalSeconds)
              : 0;

          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // 错误提示横幅（设备断开/控制失败等）
                  if (dlna.errorMessage != null) ...[
                    Card(
                      color: theme.colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 4),
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
                  // 设备名
                  Icon(
                    Icons.cast_connected,
                    size: 64,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    dlna.deviceName ?? '未知设备',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    dlna.castTitle ?? '',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 32),
                  // 进度条（设备不支持 Seek 时降级为只读进度）
                  if (totalSeconds > 0) ...[
                    if (dlna.canSeek)
                      Slider(
                        value: positionSeconds.toDouble(),
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
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(_fmt(dlna.position),
                              style: theme.textTheme.bodySmall),
                          Text(_fmt(duration!),
                              style: theme.textTheme.bodySmall),
                        ],
                      ),
                    ),
                  ] else
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(
                        _fmt(dlna.position),
                        style: theme.textTheme.headlineSmall,
                      ),
                    ),
                  const SizedBox(height: 24),
                  // 播放控制（设备不支持 Pause 时隐藏暂停/播放切换按钮）
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        iconSize: 48,
                        icon: const Icon(Icons.skip_previous),
                        onPressed: () {
                          AppHaptics.click();
                          dlna.castPreviousSong(context);
                        },
                      ),
                      if (dlna.canPause) ...[
                        const SizedBox(width: 24),
                        IconButton.filled(
                          iconSize: 56,
                          icon: Icon(
                            dlna.isPlaying ? Icons.pause : Icons.play_arrow,
                          ),
                          onPressed: () {
                            if (dlna.isPlaying) {
                              dlna.pause();
                            } else {
                              dlna.play();
                            }
                          },
                        ),
                        const SizedBox(width: 24),
                      ],
                      IconButton(
                        iconSize: 48,
                        icon: const Icon(Icons.skip_next),
                        onPressed: () {
                          AppHaptics.click();
                          dlna.castNextSong(context);
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 32),
                  // 音量控制
                  Row(
                    children: [
                      const Icon(Icons.volume_down),
                      Expanded(
                        child: Slider(
                          value: dlna.volume.toDouble(),
                          max: 100,
                          onChanged: (v) {
                            dlna.setVolume(v.round());
                          },
                        ),
                      ),
                      const Icon(Icons.volume_up),
                    ],
                  ),
                  const SizedBox(height: 32),
                  // 停止投屏
                  FilledButton.icon(
                    onPressed: () async {
                      await dlna.stop();
                      await dlna.restoreLocalPlayback(context);
                      if (context.mounted) Navigator.pop(context);
                    },
                    icon: const Icon(Icons.stop),
                    label: const Text('停止投屏'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}
