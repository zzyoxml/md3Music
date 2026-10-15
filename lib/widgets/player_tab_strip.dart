import 'dart:ui' show lerpDouble;

import 'package:material_ui/material_ui.dart';

import '../core/utils/app_haptics.dart';

/// 播放器页签条的形态。
///
/// 同一个控件（同一套切页手势、同一条 [TabController] 跟随逻辑）有两种长相，
/// 落在哪一栏决定用哪种：
///
/// - [PlayerTabStripVariant.dots] —— 竖屏顶栏中央那一排圆点（「顶栏页签圆点」开启
///   时），以及宽屏右栏底部那排在开关开启时的样子。那两条水平线上已有别的元素，
///   图标 + 指示线的视觉重量会把它们压掉。
/// - [PlayerTabStripVariant.icons] —— 开关关闭（默认）时**底部那两条带**（竖屏底部 /
///   宽屏右栏底部）的原形态：图标 + 一条跟随滑动的指示线。底部是一条独立的水平带，
///   图标比圆点更认得出「这是哪一页」。
enum PlayerTabStripVariant { dots, icons }

/// 播放器页签条的一个目标。
///
/// [icon] 只有在 [PlayerTabStripVariant.icons] 里才画得出来；圆点形态下它不参与
/// 渲染，[label] 因此不只是无障碍朗读名，而是那个点的**唯一语义来源** —— 新增 tab
/// 时必须给 label，否则 TalkBack 只念得出「按钮」。
class PlayerTabItem {
  const PlayerTabItem({required this.icon, this.label, this.onLongPress});

  /// 图标（底部 icon 形态用；圆点形态只读 [label]）
  final IconData icon;

  /// 无障碍朗读名（图标按钮在 TalkBack 下的名称；圆点形态的唯一语义）
  final String? label;

  /// 长按动作（如封面段长按下载、歌词段长按桌面歌词）
  final VoidCallback? onLongPress;
}

/// 两版宿主共用的页签项清单 —— **段序、label、图标与长按语义只有这一份来源**。
///
/// 段序口径由 `player_tab_layout.dart` 约定：播放列表 / 封面? / 控制? / 歌词 / 评论?。
/// 此前 MD 与 AM 各写一遍（各 ~25 行，只差配色），加一个 tab 就得改两处，漏一处
/// 就是两版行为分叉 —— 本仓已因这类双写漏改过一次（AM 缺 unity 分支）。
///
/// 只收清单，不收 [PlayerTabStrip] 本身：controller、配色、拖拽回调都留在宿主里传。
/// 三个布尔量代替 `PlayerTabLayout` 参数是有意的 ——  widget 层不该反向依赖
/// `modules/player/` 的类型。
///
/// [coverOnLongPress] 必须由宿主注入并且**不在这里读宿主静态字段**：封面段的下载钩子
/// 挂在 `FullPlayer.coverLongPressCallback` / `AmStyleFullPlayer.coverLongPressCallback`
/// 两个各自的静态上，共享代码一旦去读其中任意一个，另一版的长按就会静默失灵。
List<PlayerTabItem> buildPlayerTabItems({
  required bool hasCover,
  required bool hasControls,
  required bool hasComments,
  required bool desktopLyricEnabled,
  required VoidCallback? coverOnLongPress,
  required VoidCallback lyricsOnLongPress,
  required VoidCallback commentsOnLongPress,
}) {
  return [
    const PlayerTabItem(icon: Icons.queue_music, label: '播放列表'),
    if (hasCover)
      PlayerTabItem(
        icon: Icons.album,
        label: '封面',
        // 长按封面段：弹出下载音质选择（本地歌曲由调用侧屏蔽）
        onLongPress: coverOnLongPress,
      ),
    // 控制 tab 只在宽屏出现；宽屏形态随「顶栏页签圆点」开关变（默认 icon），清单不读
    // 开关，icon 一律备齐，避免开关切换时这一段缺图。
    // 位置在歌词之前：宽屏顺序为 播放列表 / 控制 / 歌词 / 评论。
    if (hasControls) const PlayerTabItem(icon: Icons.tune, label: '控制'),
    PlayerTabItem(
      // 桌面歌词开启时用实心 icon，与 mini_player 一致
      icon: desktopLyricEnabled ? Icons.lyrics : Icons.lyrics_outlined,
      label: '歌词',
      onLongPress: lyricsOnLongPress,
    ),
    if (hasComments)
      PlayerTabItem(
        icon: Icons.comment_outlined,
        label: '评论',
        // 长按评论段：切到评论 tab 并拉起输入框（界面上没有常驻入口）
        onLongPress: commentsOnLongPress,
      ),
  ];
}

/// 播放器页签条 —— 一排 [PlayerTabStripVariant] 指定的圆点或图标，跟随
/// [TabController] 的动画连续过渡（不是「跳变到当前页」）。
///
/// 圆点形态：当前页那颗更大更实，其余压暗。图标形态：图标明暗插值 + 底部一条
/// 宽度 18 的指示线在段间滑动（改造前的原形态）。
///
/// 挂在竖屏顶栏中央（「顶栏页签圆点」开启）、竖屏底部（开关关闭时的原形态），
/// 或宽屏右栏底部（位置恒定，形态随同一个开关变）。
///
/// 只负责切页这一件事：没有容器背景，因此不与传输控件抢视觉重量。
/// 水平拖动手势透传给外部（与原胶囊一致：拖动可跨多个 tab 连续切换）。
class PlayerTabStrip extends StatelessWidget {
  const PlayerTabStrip({
    super.key,
    required this.controller,
    required this.items,
    required this.activeColor,
    required this.inactiveColor,
    this.variant = PlayerTabStripVariant.dots,
    this.height,
    this.dotSize = 8,
    this.selectedDotSize = 12,
    this.iconSize = 20,
    this.indicatorColor,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
    this.onSegmentWidth,
  });

  final TabController controller;
  final List<PlayerTabItem> items;
  final Color activeColor;
  final Color inactiveColor;

  /// 形态：圆点（顶栏 / 开关开启时的宽屏底部）或图标 + 指示线（开关关闭时的
  /// 竖屏底部与宽屏底部）。
  final PlayerTabStripVariant variant;

  /// 条高。不传时按形态取默认：圆点 48（Android 可触达基线 —— 视觉点径远小于它，
  /// 靠整段命中区撑开），图标 34（原底部栏的高度，不与传输控件抢视觉重量）。
  final double? height;

  /// 未选中的点径 / 选中的点径（圆点形态）。
  ///
  /// 段宽被 48dp 触控基线撑着（见 [PlayerTopBarTabDots._baseSegmentWidth]），
  /// 点距因此固定是段宽，视觉密度只能靠**点径**给：原先 6/10 在 48dp 间距下
  /// 是四颗散碎小点，且压在动态封面上几乎看不出选中态，故抬到 8/12。
  /// 不能再靠收窄段宽来加密点距 —— 段宽即命中区，收窄到 48 以下就破了触控地板。
  final double dotSize;
  final double selectedDotSize;

  /// 图标尺寸（图标形态）
  final double iconSize;

  /// 指示线颜色，默认取 [activeColor]（图标形态）
  final Color? indicatorColor;

  final ValueChanged<DragStartDetails>? onDragStart;
  final ValueChanged<DragUpdateDetails>? onDragUpdate;
  final VoidCallback? onDragEnd;

  /// 回传单段宽度，供外部换算拖动位移 → tab offset
  final ValueChanged<double>? onSegmentWidth;

  /// 指示线宽度
  static const double _indicatorWidth = 18;

  /// 圆点形态条高（顶栏 / 宽屏底部）：Android 可触达基线，视觉点径远小于它。
  static const double dotsHeight = 48;

  /// 图标 + 指示线形态条高（竖屏底部原形态）：不与传输控件抢视觉重量。
  static const double iconsHeight = 34;

  double get _height =>
      height ??
      (variant == PlayerTabStripVariant.icons ? iconsHeight : dotsHeight);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final segmentWidth = constraints.maxWidth / items.length;
          onSegmentWidth?.call(segmentWidth);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: onDragStart,
            onHorizontalDragUpdate: onDragUpdate,
            onHorizontalDragEnd: onDragEnd == null ? null : (_) => onDragEnd!(),
            onHorizontalDragCancel: onDragEnd,
            child: AnimatedBuilder(
              // 监听 animation 而非 controller：点击 animateTo 的补间与手指
              // 拖拽的 offset 都体现在 animation 上，指示线 / 圆点才能连续跟随。
              animation:
                  controller.animation ??
                  const AlwaysStoppedAnimation<double>(0),
              builder: (context, _) {
                final anim =
                    (controller.animation?.value ??
                            controller.index.toDouble())
                        .clamp(0.0, items.length - 1.0);
                final segments = Row(
                  children: [
                    for (int i = 0; i < items.length; i++)
                      Expanded(child: _buildSegment(i, anim)),
                  ],
                );
                if (variant != PlayerTabStripVariant.icons) return segments;
                return Stack(
                  children: [
                    Positioned(
                      left:
                          anim * segmentWidth +
                          (segmentWidth - _indicatorWidth) / 2,
                      bottom: 0,
                      width: _indicatorWidth,
                      height: 3,
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: indicatorColor ?? activeColor,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                    segments,
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }

  Widget _buildSegment(int index, double anim) {
    final item = items[index];
    // 用连续动画值同时插值粗细与明暗：滑到一半时相邻两段各占一半
    final t = (1 - (anim - index).abs()).clamp(0.0, 1.0);
    return Semantics(
      button: true,
      selected: controller.index == index,
      label: item.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (controller.index != index) {
            AppHaptics.tick(HapticCategory.navigation);
            controller.animateTo(index);
          }
        },
        // 不挂 Tooltip：长按只执行长按动作，不弹按钮说明
        onLongPress: item.onLongPress,
        child: variant == PlayerTabStripVariant.icons
            ? _buildIcon(item, t)
            : _buildDot(t),
      ),
    );
  }

  Widget _buildDot(double t) {
    final size = lerpDouble(dotSize, selectedDotSize, t)!;
    return Center(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Color.lerp(inactiveColor, activeColor, t),
          shape: BoxShape.circle,
        ),
      ),
    );
  }

  Widget _buildIcon(PlayerTabItem item, double t) {
    // 指示线预留位改在图标内侧：触控盒占满条高，视觉位置不变
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Center(
        child: Icon(
          item.icon,
          size: iconSize,
          color: Color.lerp(inactiveColor, activeColor, t),
        ),
      ),
    );
  }
}
