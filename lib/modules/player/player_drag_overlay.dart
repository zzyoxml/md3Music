import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/theme_provider.dart';
import 'full_player.dart';
import 'full_player_am.dart';
import 'full_player_route.dart';

/// 上滑拖拽期间的跟手覆盖层（位于 Navigator 之上）。
///
/// 关键约束：手势期间不能 push 路由（实测 push 会立即切断 Flutter 事件流，
/// 导致跟手失效）。因此拖拽过程中由本覆盖层跟随手指显示**真实的 FullPlayer**
/// （MD / AM 风格，与路由渲染同一组件），与展开后的播放器界面完全一致，
/// 松手后由路由从相同进度接管，视觉无缝衔接：
/// - 位置：顶端从 [playerDragOriginTop]（= MiniPlayer 顶端）随进度上移到 0
/// - 透明度：前 20% 屏高内线性 0→1，之后保持 1
class PlayerDragOverlay extends StatelessWidget {
  const PlayerDragOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: playerDragActive,
      builder: (context, active, _) {
        if (!active) return const SizedBox.shrink();
        // 覆盖层位于 Navigator 之外（MaterialApp.builder 的 Stack），
        // FullPlayer 内 Tooltip 等组件需要 Overlay 祖先，这里提供本地 Overlay。
        // 内容随 playerExpansion 更新位置/透明度。
        return Overlay(
          initialEntries: [
            OverlayEntry(
              builder: (context) => const _DragPositionedContent(),
            ),
          ],
        );
      },
    );
  }
}

/// 跟手位置/透明度 + 真实 FullPlayer。
class _DragPositionedContent extends StatelessWidget {
  const _DragPositionedContent();

  @override
  Widget build(BuildContext context) {
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
                child: const _DragPlayerContent(),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 渲染真实 FullPlayer（与路由同一组件，保证展开前后界面一致）。
class _DragPlayerContent extends StatelessWidget {
  const _DragPlayerContent();

  @override
  Widget build(BuildContext context) {
    final useAm = context.watch<ThemeProvider>().useAmStylePlayer;
    return useAm ? const AmStyleFullPlayer() : const FullPlayer();
  }
}
