import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'bottom_chrome_dimens.dart';

/// 播放页展开面板的全局信号。
///
/// **为什么住在 core**：底部导航栏由 `responsive_layout.dart` 的
/// [ResponsiveScaffold] 渲染，而它必须跟随面板下沿下沉（见 [BottomChromeSink]）。
/// 若这些信号留在 `modules/player`，core 就得反向 import player，而
/// `full_player.dart` 已经 import 了 `core/layout/responsive_layout.dart` —— 会成环。
/// 因此这里持有唯一一份状态，`modules/player/full_player_route.dart` 里那几个
/// 全局量改为**委托别名**（`playerExpansion` / `playerDragOriginTop` /
/// `playerDragOriginBottom` / `kPlayerFallbackMiniBarHeight`）：既有调用点一个都不用改，
/// 也不存在两份状态漂移的风险。
class PlayerPanelSignal {
  PlayerPanelSignal._();

  /// 播放页展开进度：0 = 迷你条，1 = 全屏。
  ///
  /// 由手势（跟手逐帧）与路由动画（`buildTransitions` 每帧）写入。
  static final ValueNotifier<double> expansion = ValueNotifier<double>(0.0);

  /// 面板锚点：迷你条顶端 / 底端（逻辑像素，屏幕坐标）。
  ///
  /// 两者**必须成对写**（走 [publishAnchor]）：分两次量会在切歌 / 转屏瞬间对不上，
  /// 面板起点会抖一下。
  static double anchorTop = 0.0;
  static double anchorBottom = 0.0;

  /// 锚点未登记时的迷你条兜底高度（dp）。
  ///
  /// **取值来源**：桌面外壳 `NowPlayingBar` 的固定高（`_kHeight = 72.0`，
  /// now_playing_bar.dart:24），**不是**移动端常驻迷你条的实测高（≈70/56）。
  /// 锚点已登记时真实测量值优先，本值不参与计算；未登记时仅供
  /// `playerMiniBarHeight()`（拖拽覆盖层反解条高的退化路径）使用。
  /// 面板展开起点 / 底栏下沉的兜底**不用本值**，改用胶囊几何
  /// [BottomChromeDimens.discReservedBottom]（见 `panelAnchorFor` 与
  /// [resolveBottomChromeSinkOffset]）。
  static const double fallbackBarHeight = 72.0;

  /// 登记锚点（顶端 + 底端，成对写）。
  static void publishAnchor({required double top, required double bottom}) {
    anchorTop = top;
    anchorBottom = bottom;
  }
}

/// 面板下沿扫过底部 chrome 时，chrome 应下沉的位移（px）。
///
/// 与 `player_panel_frame.dart` 的 `playerPanelGeometry` **同源**：
/// 面板下沿 `bottom = miniBottom + (屏高 − miniBottom) × p`；
/// 底栏顶边 `barTop = 屏高 − slotHeight`。两者相交之后底栏就跟着下沿往下走，
/// 于是「面板把底栏推下去」在**每一帧都不留缝**。
///
/// **为什么不能简化成 `slotHeight × p`**：迷你条自身可能离底栏还有一段净空
/// （悬浮条形态的 12dp + 手势条净空），此时面板下沿还没进到槽位里；按
/// `slotHeight × p` 提前下沉会推出一块露出 Scaffold 底色的空带。
///
/// [progress] ≤ 0 / 非有限、屏高或槽位高非法时返回 0（不动）。
/// 结果钳在 `[0, slotHeight]`：等于 slotHeight 时底栏整体离开屏幕
/// （面板此时已铺满全屏）。
double resolveBottomChromeSinkOffset({
  required double progress,
  required double screenHeight,
  required double slotHeight,
  required double anchorTop,
  required double anchorBottom,
  double fallbackBarHeight = BottomChromeDimens.discReservedBottom,
}) {
  if (!screenHeight.isFinite || screenHeight <= 0) return 0.0;
  if (!slotHeight.isFinite || slotHeight <= 0) return 0.0;
  final double p = progress.isFinite ? progress.clamp(0.0, 1.0) : 0.0;
  if (p <= 0.0) return 0.0;
  // 锚点兜底链与 DraggablePlayerRoute.panelAnchorFor **同式**：未登记时合成一条
  // **胶囊几何**的贴底条（底端 = 屏底、高 = discReservedBottom），保证底栏位移
  // 与面板真实几何一致。**不再**用桌面播放栏高（旧 72）冒充——移动端布局下
  // 根本没有那条 bar，取值只会在两处口径间漂移。
  final double top = (anchorTop > 0 && anchorTop < screenHeight)
      ? anchorTop
      : math.max(0.0, screenHeight - fallbackBarHeight);
  final double bottom =
      (anchorBottom - top) > 0 ? anchorBottom : top + fallbackBarHeight;
  final double panelBottom = math.min(
    screenHeight,
    bottom + (screenHeight - bottom) * p,
  );
  final double barTop = screenHeight - slotHeight;
  return (panelBottom - barTop).clamp(0.0, slotHeight);
}

/// 把底部 chrome 本体按面板下沿的下沉量整体下移。
///
/// 只做 `Transform`，**不参与布局**：拖拽跟手期间不引起任何页面重排
/// （AGENTS §10 的性能口径：跟手动画只重绘、不重排）。子树由 [AnimatedBuilder]
/// 的 `child` 短路复用，逐帧只重建这一层 Transform。
class BottomChromeSink extends StatelessWidget {
  const BottomChromeSink({
    super.key,
    required this.slotHeight,
    this.progress,
    required this.child,
  });

  /// 底栏槽位总高（含系统手势条净空）；与 `BottomChromeSlot.slotHeight` 同源。
  final double slotHeight;

  /// 展开进度源（生产传 [PlayerPanelSignal.expansion]）。null = 不参与面板下沉。
  final ValueListenable<double>? progress;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ValueListenable<double>? listenable = progress;
    if (listenable == null) return child;
    return AnimatedBuilder(
      animation: listenable,
      builder: (BuildContext context, Widget? child) => Transform.translate(
        offset: Offset(
          0,
          resolveBottomChromeSinkOffset(
            progress: listenable.value,
            screenHeight: MediaQuery.sizeOf(context).height,
            slotHeight: slotHeight,
            anchorTop: PlayerPanelSignal.anchorTop,
            anchorBottom: PlayerPanelSignal.anchorBottom,
          ),
        ),
        child: child,
      ),
      child: child,
    );
  }
}

/// 底部 chrome 的槽位：底栏收起时**槽位高度连续收缩、底栏本体整体下沉**。
///
/// 两个效果由同一个几何关系给出：槽位顶边随高度收缩而下移
/// （`屏高 − slotHeight × (1 − collapse)`），底栏钉在槽位顶边、保持自身完整高度，
/// 超出槽位的部分由外层 `Clip.hardEdge` 裁掉（槽位下边缘就是屏幕底边）。
/// 于是底栏读起来是"被向下推走"，而不是"被压扁"或"被裁掉一截"。
///
/// **布局语义（问题 1 的全部机制）**：本组件的高度就是底栏占位高度，
/// `Scaffold` 每帧据此重排 body —— body（以及贴在其底部的播放条）会**逐帧跟着
/// 连续下移**。也就是说"播放条平滑落到屏幕底部"不需要给播放条另做动画，
/// 槽位高度连续变化本身就是那条动画。
///
/// `collapse >= 1` 时槽位高度为 0，调用方应直接把 `null` 传给
/// `Scaffold.bottomNavigationBar`（`Scaffold` 只在 `bottomNavigationBar != null`
/// 时移除 body 底部 padding，传零高盒子会让二级页面丢掉底部安全区）。
class BottomChromeSlot extends StatelessWidget {
  const BottomChromeSlot({
    super.key,
    required this.collapse,
    required this.slotHeight,
    required this.child,
  });

  /// 收起进度：0 = 完整在场，1 = 完全收起。
  final double collapse;

  /// 底栏完整高度（含系统手势条净空）。
  final double slotHeight;

  /// 底栏本体（NavigationBar，可选已包 [BottomChromeSink]）。
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final double t = collapse.isFinite ? collapse.clamp(0.0, 1.0) : 0.0;
    return SizedBox(
      height: slotHeight * (1 - t),
      child: Stack(
        // 裁掉被推到底栏槽位之外的部分（槽位下边缘即屏幕底边）。
        clipBehavior: Clip.hardEdge,
        children: <Widget>[
          // Positioned 只给 top/left/right：底栏拿到**紧宽度 + 无限高度**，
          // 因此保持自身完整高度而不会被槽位高度压扁（这是"下沉不压扁"的实现点）。
          Positioned(top: 0, left: 0, right: 0, child: child),
        ],
      ),
    );
  }
}
