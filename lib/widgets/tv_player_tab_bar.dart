import 'package:dpad/dpad.dart';
import 'package:flutter/widgets.dart';

/// tv: 播放页底部遥控 TabBar——左右方向键直接切换，无需 OK 确认。
///
/// 段序必须与 `PlayerTabLayout.tabKinds` 一致（调用方按 tabKinds 派生 labels），
/// 与 TabController.length / PlayerTabPager.children 同源，杜绝数量不一致断言。
/// 焦点进入某段即回调 [onSelected]（切换 tab）；OK 保留为兼容入口。
class TvPlayerTabBar extends StatelessWidget {
  const TvPlayerTabBar({
    super.key,
    required this.labels,
    required this.currentIndex,
    required this.activeColor,
    required this.inactiveColor,
    required this.onSelected,
    this.autofocus = false,
  });

  final List<String> labels;
  final int currentIndex;
  final Color activeColor;
  final Color inactiveColor;
  final ValueChanged<int> onSelected;

  /// 首段 autofocus（默认 false：播放页打开时焦点不该落在 tab 栏上；
  /// 供测试与特殊布局使用）。
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return DpadRegion(
      memoryKey: 'tv/player-tab-bar',
      debugLabel: 'tv-player-tab-bar',
      horizontalEdge: DpadEdgeBehavior.stop,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < labels.length; i++)
            _TvPlayerTabSegment(
              label: labels[i],
              selected: i == currentIndex,
              activeColor: activeColor,
              inactiveColor: inactiveColor,
              autofocus: autofocus && i == 0,
              onFocused: () {
                if (i != currentIndex) onSelected(i);
              },
              onSelect: () => onSelected(i),
            ),
        ],
      ),
    );
  }
}

class _TvPlayerTabSegment extends StatelessWidget {
  const _TvPlayerTabSegment({
    required this.label,
    required this.selected,
    required this.activeColor,
    required this.inactiveColor,
    required this.onFocused,
    required this.onSelect,
    this.autofocus = false,
  });

  final String label;
  final bool selected;
  final Color activeColor;
  final Color inactiveColor;
  final VoidCallback onFocused;
  final VoidCallback onSelect;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final Color color = selected ? activeColor : inactiveColor;
    return DpadFocusable(
      autofocus: autofocus,
      onFocusChange: (focused) {
        if (focused) onFocused();
      },
      onSelect: onSelect,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                color: color,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
            const SizedBox(height: 4),
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              height: 3,
              width: selected ? 20 : 0,
              decoration: BoxDecoration(
                color: activeColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
