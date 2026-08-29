import 'package:flutter/material.dart';

/// 播放器底部导航条的一个目标。
class PlayerTabItem {
  const PlayerTabItem({required this.icon, this.onLongPress});

  final IconData icon;

  /// 长按动作（如封面段长按下载、歌词段长按桌面歌词）
  final VoidCallback? onLongPress;
}

/// 播放器底部导航条 —— 替代原先把「倍速 / 4 个 tab / 收藏」混装在一起的操作胶囊。
///
/// 只负责页面切换这一件事：图标 + 一条跟随 [TabController] 动画连续滑动的指示线。
/// 没有容器背景，高度只有 [height]（默认 34），因此不与传输控件抢视觉重量。
/// 水平拖动手势透传给外部（与原胶囊一致：拖动可跨多个 tab 连续切换）。
class PlayerTabStrip extends StatelessWidget {
  const PlayerTabStrip({
    super.key,
    required this.controller,
    required this.items,
    required this.activeColor,
    required this.inactiveColor,
    this.indicatorColor,
    this.height = 34,
    this.iconSize = 20,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
    this.onSegmentWidth,
  });

  final TabController controller;
  final List<PlayerTabItem> items;
  final Color activeColor;
  final Color inactiveColor;

  /// 指示线颜色，默认取 [activeColor]
  final Color? indicatorColor;

  final double height;
  final double iconSize;

  final ValueChanged<DragStartDetails>? onDragStart;
  final ValueChanged<DragUpdateDetails>? onDragUpdate;
  final VoidCallback? onDragEnd;

  /// 回传单段宽度，供外部换算拖动位移 → tab offset
  final ValueChanged<double>? onSegmentWidth;

  /// 指示线宽度
  static const double _indicatorWidth = 18;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
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
              // 拖拽的 offset 都体现在 animation 上，指示线才能连续跟随。
              animation:
                  controller.animation ??
                  const AlwaysStoppedAnimation<double>(0),
              builder: (context, _) {
                final anim =
                    (controller.animation?.value ??
                            controller.index.toDouble())
                        .clamp(0.0, items.length - 1.0);
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
                    Padding(
                      padding: const EdgeInsets.only(bottom: 7),
                      child: Row(
                        children: [
                          for (int i = 0; i < items.length; i++)
                            Expanded(
                              child: _buildSegment(i, anim),
                            ),
                        ],
                      ),
                    ),
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
    // 用连续动画值做颜色过渡：滑动到一半时两侧图标各亮一半
    final t = (1 - (anim - index).abs()).clamp(0.0, 1.0);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (controller.index != index) controller.animateTo(index);
      },
      // 不挂 Tooltip：长按只执行长按动作，不弹按钮说明
      onLongPress: item.onLongPress,
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
