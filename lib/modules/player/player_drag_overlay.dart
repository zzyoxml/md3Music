import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../providers/theme_provider.dart';
import 'full_player.dart';
import 'full_player_am.dart';
import 'full_player_route.dart';
import 'player_panel_frame.dart';
import 'player_page_role.dart';

/// 上滑拖拽期间的跟手覆盖层（位于 Navigator 之上）。
///
/// 关键约束：手势期间不能 push 路由（实测 push 会立即切断 Flutter 事件流，
/// 导致跟手失效）。因此拖拽过程中由本覆盖层跟随手指显示**真实的 FullPlayer**
/// （MD / AM 风格，与路由渲染同一组件），与展开后的播放器界面完全一致，
/// 松手后由路由从相同进度接管，视觉无缝衔接：
/// - 几何：走 [PlayerPanelFrame] 的**双向展开**面板——p=0 时可视区域恰好等于
///   MiniPlayer 矩形（导航栏完整可见），上沿随手指 1:1 上移，下沿同时向下
///   扫过导航栏，p=1 铺满全屏；
/// - 透明度：前 20% 屏高内线性 0→1，之后保持 1。
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

/// 跟手面板 + 真实 FullPlayer。
class _DragPositionedContent extends StatelessWidget {
  const _DragPositionedContent();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: playerExpansion,
      builder: (context, progress, _) {
        if (progress <= 0.0) return const SizedBox.shrink();
        // 跟手覆盖层与路由**必须用同一份起点几何**（否则交接那一帧会跳一下）：
        // 矩形与圆角都从全局锚点读（五字段成组写，见 publishPlayerDragOrigin）。
        final Size screen = MediaQuery.sizeOf(context);
        return Positioned.fill(
          // 拖拽期间不拦截触摸（穿透到下层 MiniPlayer / 悬浮胶囊手势）
          child: IgnorePointer(
            // 淡入在 PlayerPanelFrame 内部（只作用于页面内容，底色按自己的曲线渐显），
            // 这里不要再包 Opacity —— 会把底色一起变透明，过渡态照样透出背后。
            child: PlayerPanelFrame(
              progress: progress,
              originRect: playerPanelAnchorRect(screen),
              originRadius: playerDragOriginRadius,
              screenRadii: MediaQuery.displayCornerRadiiOf(context),
              child: const _DragPlayerContent(),
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
    // 显式声明「这一份是拖拽覆盖层」：它用户可见但不负责真机副作用（频谱采集、
    // 麦克风权限由即将接管的路由持有）。原先靠 `ModalRoute == null && playerDragActive`
    // 反推，现在由挂载点自己写明，见 [PlayerPageRole]。
    return PlayerPageRoleScope(
      role: PlayerPageRole.dragOverlay,
      child: useAm ? const AmStyleFullPlayer() : const FullPlayer(),
    );
  }
}
