import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services/desktop_lyric_service.dart';
import '../../core/services/media_notification_service.dart';
import '../../providers/player_provider.dart';
import 'full_player_route.dart';

/// 底部常驻迷你播放条。
///
/// 点击调用 [fullPlayerRoute] push 路由，由路由自带 300ms 入场动画。
///
/// 自身 opacity = `1 - playerExpansion`，由全局 [playerExpansion] Notifier 驱动，
/// FullPlayer 淡入时 mini bar 同步淡出，避免视觉打架。
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

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
        // opacity 与展开进度线性绑定：expansion=0 时完全可见，expansion=1 时完全隐藏
        // IgnorePointer 防止淡出过程中拦截下层手势
        final opacity = (1.0 - expansion).clamp(0.0, 1.0);
        return IgnorePointer(
          ignoring: expansion > 0.5,
          child: Opacity(opacity: opacity, child: child),
        );
      },
      child: GestureDetector(
        // 点击展开 FullPlayer
        onTap: () => Navigator.of(context).push(fullPlayerRoute(context)),
        behavior: HitTestBehavior.opaque,
        child: _buildContent(
            context, playerProvider, currentSong, colorScheme, progress),
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    PlayerProvider playerProvider,
    dynamic currentSong,
    ColorScheme colorScheme,
    double progress,
  ) {
    return Container(
      // Container 在外提供整体背景色：
      // 使用 surfaceContainerHigh 比 NavigationBar 的 surface 更深，
      // 形成明确的层级关系（mini player 浮于内容之上，NavigationBar 之下）
      // 颜色会自然填充 SafeArea 在底部留出的系统手势条区域
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
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
              // M3 Expressive：8/4 → 12/6，更呼吸
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  ClipRRect(
                    // M3 Expressive：6dp → 12dp，与 SongListItem 一致
                    borderRadius: BorderRadius.circular(12),
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
                          // M3 Expressive：当前播放曲目字重 w600 更突出
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
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
