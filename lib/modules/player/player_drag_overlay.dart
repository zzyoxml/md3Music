import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/player_provider.dart';
import '../../widgets/smart_artwork_image.dart';
import 'full_player_route.dart';

/// 上滑拖拽期间的跟手覆盖层（位于 Navigator 之上）。
///
/// 关键约束：手势期间不能 push 路由（实测 push 会立即切断 Flutter 事件流，
/// 导致跟手失效）。因此拖拽过程中由本覆盖层跟随手指显示 FullPlayer 的
/// 简化预览：
/// - 位置：顶端从 [playerDragOriginTop]（= MiniPlayer 顶端）随进度上移到 0
/// - 透明度：前 20% 屏高内线性 0→1，之后保持 1
/// 松手判定展开时，MiniPlayer 会隐藏本覆盖层并 push 拖拽路由，由路由从
/// 相同进度接管显示（位置/透明度一致，视觉无缝衔接）。
class PlayerDragOverlay extends StatelessWidget {
  const PlayerDragOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: playerDragActive,
      builder: (context, active, _) {
        if (!active) return const SizedBox.shrink();
        return ValueListenableBuilder<double>(
          valueListenable: playerExpansion,
          builder: (context, progress, _) {
            if (progress <= 0.0) return const SizedBox.shrink();
            final height = MediaQuery.sizeOf(context).height;
            final origin = playerDragOriginTop;
            final dy = origin * (1 - progress);
            final opacity = (progress * origin /
                    (kPlayerExpandDistanceRatio * height))
                .clamp(0.0, 1.0);
            return Positioned.fill(
              // 拖拽期间不拦截触摸（穿透到下层 MiniPlayer 手势）
              child: IgnorePointer(
                child: Opacity(
                  opacity: opacity,
                  child: Transform.translate(
                    offset: Offset(0, dy),
                    child: const _DragPreviewContent(),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// 简化 FullPlayer 视觉预览：背景 + 居中大封面 + 歌曲信息。
class _DragPreviewContent extends StatelessWidget {
  const _DragPreviewContent();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final player = context.watch<PlayerProvider>();
    final song = player.currentSong;
    return Container(
      color: scheme.surfaceContainerHigh,
      child: SafeArea(
        child: Column(
          children: [
            const Spacer(flex: 3),
            // 居中大封面（与 FullPlayer 顶部区域接近，减少展开时视觉跳变）
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 48),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: song == null
                      ? ColoredBox(color: scheme.surfaceContainerHighest)
                      : SmartArtworkImage(
                          artworkUri: song.artworkUri?.toString(),
                          fallbackFilePath: song.isOnline
                              ? null
                              : (song.localPath?.isEmpty ?? true)
                                  ? null
                                  : song.localPath,
                          songId: song.isOnline ? song.id : null,
                          size: 320,
                          borderRadius: 28,
                        ),
                ),
              ),
            ),
            const Spacer(flex: 1),
            // 歌曲信息
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                song?.title ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                song?.artist ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
            const Spacer(flex: 3),
          ],
        ),
      ),
    );
  }
}
