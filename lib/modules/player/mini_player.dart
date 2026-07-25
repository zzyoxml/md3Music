import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services/desktop_lyric_service.dart';
import '../../core/services/media_notification_service.dart';
import '../../providers/player_provider.dart';
import 'full_player_route.dart';

/// 底部常驻迷你播放条。
///
/// 支持两种方式展开为 FullPlayer：
/// 1. **点击**：调用 [fullPlayerRoute] push 路由，由路由自带 300ms 入场动画
/// 2. **向上拖拽**（抽屉式）：拖动期间手动驱动路由 AnimationController，
///    进度 = 累计上拖距离 / [kPlayerDragThreshold]，淡入淡出与拖拽距离线性绑定
///
/// 自身 opacity = `1 - playerExpansion`，由全局 [playerExpansion] Notifier 驱动，
/// FullPlayer 淡入时 mini bar 同步淡出，避免视觉打架。
class MiniPlayer extends StatefulWidget {
  const MiniPlayer({super.key});

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer> {
  /// 拖拽起点的全局 y 坐标，用于计算累计位移。
  double _dragStartY = 0;

  /// 当前拖拽关联的路由（拖拽期间非空，结束后置空）。
  DraggablePlayerRoute<void>? _activeRoute;

  /// 拖拽是否已触发 push（避免重复 push）。
  bool _routePushed = false;

  @override
  Widget build(BuildContext context) {
    final playerProvider = context.watch<PlayerProvider>();
    final currentSong = playerProvider.currentSong;

    if (currentSong == null) return const SizedBox.shrink();

    final colorScheme = Theme.of(context).colorScheme;
    final duration = playerProvider.duration ?? Duration.zero;
    final position = playerProvider.position;
    final progress = duration.inMilliseconds > 0
        ? position.inMilliseconds / duration.inMilliseconds
        : 0.0;

    return ValueListenableBuilder<double>(
      valueListenable: playerExpansion,
      builder: (context, expansion, child) {
        // opacity 与拖拽进度线性绑定：progress=0 时完全可见，progress=1 时完全隐藏
        // IgnorePointer 防止淡出过程中拦截下层手势
        final opacity = (1.0 - expansion).clamp(0.0, 1.0);
        return IgnorePointer(
          ignoring: expansion > 0.5,
          child: Opacity(opacity: opacity, child: child),
        );
      },
      child: GestureDetector(
        // === 抽屉式向上拖拽展开 ===
        onVerticalDragStart: _onDragStart,
        onVerticalDragUpdate: _onDragUpdate,
        onVerticalDragEnd: _onDragEnd,
        // 点击展开（无拖拽场景）
        onTap: _onTap,
        behavior: HitTestBehavior.opaque,
        child: _buildContent(
            context, playerProvider, currentSong, colorScheme, progress),
      ),
    );
  }

  // === 拖拽手势回调 ===

  void _onDragStart(DragStartDetails details) {
    _dragStartY = details.globalPosition.dy;
    _routePushed = false;
    _activeRoute = null;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final dy = details.globalPosition.dy - _dragStartY;
    // 向上拖：dy < 0，dragDistance = -dy > 0
    final dragDistance = -dy;
    if (dragDistance <= 0) return; // 向下拖不触发

    // 首次有效拖动时 push 路由
    if (!_routePushed) {
      _activeRoute = fullPlayerRoute(context);
      Navigator.of(context).push(_activeRoute!);
      _routePushed = true;
      // 立即停止路由默认 forward 动画，改为手动控制
      _activeRoute!.controller.stop();
    }

    // 进度 = 拖拽距离 / 阈值，clamp 到 [0, 1]
    final progress = (dragDistance / kPlayerDragThreshold).clamp(0.0, 1.0);
    _activeRoute!.controller.value = progress;
  }

  void _onDragEnd(DragEndDetails details) {
    if (!_routePushed || _activeRoute == null) {
      // 未触发拖拽展开（仅点击），由 _onTap 处理
      return;
    }

    final route = _activeRoute!;
    final currentProgress = route.controller.value;
    // primaryVelocity < 0 表示向上甩动
    final velocity = details.primaryVelocity ?? 0;

    if (currentProgress > 0.5 || velocity < -300) {
      // 完成：forward 到 1.0
      route.controller.forward();
    } else {
      // 回退：reverse 到 0.0，然后 pop
      route.controller.reverse().then((_) {
        if (mounted) {
          Navigator.of(context).removeRoute(route);
        }
      });
    }

    _activeRoute = null;
    _routePushed = false;
  }

  void _onTap() {
    if (_routePushed) return; // 拖拽已触发，忽略 tap
    Navigator.of(context).push(fullPlayerRoute(context));
  }

  // === 原 StatelessWidget 的内容渲染逻辑（保持不变） ===

  Widget _buildContent(
    BuildContext context,
    PlayerProvider playerProvider,
    dynamic currentSong,
    ColorScheme colorScheme,
    double progress,
  ) {
    return Container(
      // Container 在外提供整体背景色与顶部 border：
      // 颜色会自然填充 SafeArea 在底部留出的系统手势条区域，
      // 避免手势条区域露出 Scaffold 背景色与主体形成颜色断层
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        border: Border(
          top: BorderSide(color: colorScheme.outlineVariant, width: 0.5),
        ),
      ),
      child: SafeArea(
        // 仅吸收底部系统手势条/Home Indicator 高度
        top: false,
        bottom: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              minHeight: 2,
              backgroundColor: colorScheme.surfaceContainerHighest,
              color: colorScheme.primary,
            ),
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: currentSong.artworkUri != null
                          ? CachedNetworkImage(
                              imageUrl: currentSong.artworkUri!,
                              fit: BoxFit.cover,
                              placeholder: (_, _) => Container(
                                color: colorScheme.surfaceContainerHighest,
                                child: Icon(Icons.music_note,
                                    size: 20,
                                    color: colorScheme.onSurfaceVariant),
                              ),
                              errorWidget: (_, _, _) => Container(
                                color: colorScheme.surfaceContainerHighest,
                                child: Icon(Icons.music_note,
                                    size: 20,
                                    color: colorScheme.onSurfaceVariant),
                              ),
                            )
                          : Container(
                              color: colorScheme.surfaceContainerHighest,
                              child: Icon(Icons.music_note,
                                  size: 20,
                                  color: colorScheme.onSurfaceVariant),
                            ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          currentSong.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        Text(
                          currentSong.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                  color: colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      playerProvider.isPlaying
                          ? Icons.pause
                          : Icons.play_arrow,
                    ),
                    onPressed: () {
                      if (playerProvider.isPlaying) {
                        playerProvider.pause();
                      } else {
                        playerProvider.resume();
                      }
                    },
                  ),
                  IconButton(
                    tooltip: DesktopLyricService.instance.enabled
                        ? '关闭桌面歌词'
                        : '开启桌面歌词',
                    icon: Icon(
                      DesktopLyricService.instance.enabled
                          ? Icons.lyrics
                          : Icons.lyrics_outlined,
                      color: DesktopLyricService.instance.enabled
                          ? colorScheme.primary
                          : null,
                    ),
                    onPressed: () async {
                      await DesktopLyricService.instance.toggle();
                      if (context.mounted) {
                        (context as Element).markNeedsBuild();
                        // 同步通知栏"桌面歌词"按钮状态
                        final player = context.read<PlayerProvider>();
                        final song = player.currentSong;
                        await MediaNotificationService.updateNotification(
                          title: song?.title ?? '',
                          artist: song?.artist ?? '',
                          artUrl: song?.artworkUri,
                          isPlaying: player.isPlaying,
                          position: player.position,
                          duration: player.duration ?? Duration.zero,
                          desktopLyricEnabled:
                              DesktopLyricService.instance.enabled,
                        );
                      }
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.skip_next),
                    onPressed: () {
                      playerProvider.next();
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
