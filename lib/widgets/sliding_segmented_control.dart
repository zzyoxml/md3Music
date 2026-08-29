import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../core/theme/motion_constants.dart';
import '../core/utils/app_haptics.dart';

/// [SlidingSegmentedControl] 的一段。图标要给就每段都给。
class SlidingSegment {
  const SlidingSegment({required this.label, this.icon, this.semanticLabel});

  final String label;
  final IconData? icon;
  final String? semanticLabel;
}

/// 轨道高度，与被替换的 M3E sm button group 同高。
const double _kTrackHeight = 40.0;
const double _kThumbInset = 3.0;
const double _kIconSize = 18.0;
const double _kIconGap = 6.0;
const double _kDividerHeight = 16.0;
const Duration _kSlideDuration = Duration(milliseconds: 320);
const Duration _kPressDuration = Duration(milliseconds: 140);
const double _kPressedScale = 0.96;

/// 等宽分段控件：选中项由一个在段间滑动的指示器承载。
///
/// 配色、排版、形状、尺寸走 MD3 角色：轨道 surfaceContainerHigh、指示器
/// primary、前景 onPrimary / onSurfaceVariant、竖线 outlineVariant、
/// labelLarge、全圆角、40dp 高，状态层和涟漪走 InkWell。
///
/// 与 M3E connected button group 的差别都在行为上：段宽等分不随选中变化、
/// 指示器滑动而非就地换色、每段都带图标、选中态不改字重。换档时布局不动，
/// 只有颜色和指示器在移动；按住也可以横向拖着换档。
class SlidingSegmentedControl extends StatefulWidget {
  const SlidingSegmentedControl({
    super.key,
    required this.segments,
    required this.selectedIndex,
    required this.onSelected,
    this.semanticLabel,
  });

  final List<SlidingSegment> segments;
  final int selectedIndex;

  /// 点或拖到当前段不触发。
  final ValueChanged<int> onSelected;

  final String? semanticLabel;

  @override
  State<SlidingSegmentedControl> createState() =>
      _SlidingSegmentedControlState();
}

class _SlidingSegmentedControlState extends State<SlidingSegmentedControl> {
  int? _pressedIndex;

  /// 上一次拖拽落在哪一段：跨过段边界才换档。
  int? _dragIndex;

  int get _count => widget.segments.length;

  void _select(int index) {
    if (index == widget.selectedIndex) return;
    AppHaptics.tick();
    widget.onSelected(index);
  }

  void _setPressed(int? index) {
    if (_pressedIndex == index) return;
    setState(() => _pressedIndex = index);
  }

  void _handleDragTo(Offset localPosition, double width) {
    if (_count <= 1 || width <= 0 || !width.isFinite) return;
    final index = (localPosition.dx / (width / _count)).floor().clamp(
      0,
      _count - 1,
    );
    if (index == _dragIndex) return;
    _dragIndex = index;
    _select(index);
  }

  void _endDrag() {
    _dragIndex = null;
    _setPressed(null);
  }

  @override
  Widget build(BuildContext context) {
    if (_count == 0) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Semantics(
      container: true,
      label: widget.semanticLabel,
      child: SizedBox(
        height: _kTrackHeight,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            return GestureDetector(
              // 水平拖拽与页面的竖向滚动不同轴，段上的 InkWell 也仍能拿到 tap。
              onHorizontalDragStart: (d) =>
                  _handleDragTo(d.localPosition, width),
              onHorizontalDragUpdate: (d) =>
                  _handleDragTo(d.localPosition, width),
              onHorizontalDragEnd: (_) => _endDrag(),
              onHorizontalDragCancel: _endDrag,
              child: Material(
                color: cs.surfaceContainerHigh,
                shape: const StadiumBorder(),
                // 不裁，否则指示器的投影会被切掉，浮起感没了。
                clipBehavior: Clip.none,
                child: Stack(
                  // 三层都是叠满的，没有 child 能给 Stack 定尺寸。
                  fit: StackFit.expand,
                  children: [
                    _buildThumb(cs),
                    ..._buildDividers(cs),
                    _buildSegments(cs, textTheme),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// 指示器。等分下第 i 段的中心落在 Alignment.x = -1 + 2i/(n-1)，
  /// 换档时靠 [AnimatedAlign] 插值滑过去。
  Widget _buildThumb(ColorScheme cs) {
    final x = _count > 1
        ? -1.0 + 2.0 * widget.selectedIndex / (_count - 1)
        : 0.0;
    final height = _kTrackHeight - _kThumbInset * 2;
    return Padding(
      padding: const EdgeInsets.all(_kThumbInset),
      child: AnimatedAlign(
        alignment: Alignment(x, 0),
        duration: _kSlideDuration,
        curve: M3ExpressiveMotion.expressiveEasing,
        child: FractionallySizedBox(
          widthFactor: 1 / _count,
          heightFactor: 1,
          child: AnimatedScale(
            scale: _pressedIndex == widget.selectedIndex ? _kPressedScale : 1.0,
            duration: _kPressDuration,
            curve: Curves.easeOut,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: cs.primary,
                borderRadius: BorderRadius.circular(height / 2),
                boxShadow: [
                  BoxShadow(
                    color: cs.shadow.withValues(alpha: 0.12),
                    blurRadius: 3,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 段边界上的竖线，只分隔两段都没选中的地方；紧贴指示器的那条淡出。
  List<Widget> _buildDividers(ColorScheme cs) {
    final selected = widget.selectedIndex;
    return [
      for (var i = 1; i < _count; i++)
        Align(
          alignment: Alignment(2.0 * i / _count - 1.0, 0),
          child: AnimatedOpacity(
            opacity: (i == selected || i == selected + 1) ? 0.0 : 1.0,
            duration: _kSlideDuration,
            curve: Curves.easeInOut,
            child: SizedBox(
              width: 1,
              height: _kDividerHeight,
              child: ColoredBox(color: cs.outlineVariant),
            ),
          ),
        ),
    ];
  }

  /// 文字层与手势层。透明 Material 必须叠在指示器**上面**：涟漪画在它所属
  /// Material 的表面上，放在下面会被不透明的指示器整个挡住。
  Widget _buildSegments(ColorScheme cs, TextTheme textTheme) {
    return Material(
      color: Colors.transparent,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: Row(
        children: [
          for (var i = 0; i < _count; i++)
            Expanded(child: _buildSegment(cs, textTheme, i)),
        ],
      ),
    );
  }

  Widget _buildSegment(ColorScheme cs, TextTheme textTheme, int index) {
    final segment = widget.segments[index];
    final isSelected = index == widget.selectedIndex;
    final foreground = isSelected ? cs.onPrimary : cs.onSurfaceVariant;
    return Semantics(
      button: true,
      selected: isSelected,
      inMutuallyExclusiveGroup: true,
      label: segment.semanticLabel ?? segment.label,
      excludeSemantics: true,
      child: InkWell(
        onTap: () => _select(index),
        onTapDown: (_) => _setPressed(index),
        onTapUp: (_) => _setPressed(null),
        onTapCancel: () => _setPressed(null),
        customBorder: const StadiumBorder(),
        child: AnimatedScale(
          // 选中段的形变由指示器那层做，两层都缩会缩两次。
          scale: (_pressedIndex == index && !isSelected) ? _kPressedScale : 1.0,
          duration: _kPressDuration,
          curve: Curves.easeOut,
          child: TweenAnimationBuilder<Color?>(
            tween: ColorTween(end: foreground),
            duration: _kSlideDuration,
            curve: Curves.easeInOut,
            builder: (context, color, child) => IconTheme.merge(
              data: IconThemeData(size: _kIconSize, color: color),
              child: DefaultTextStyle.merge(
                // 轨道和指示器都是实色，壁纸透不过来：带上全局文字阴影只会让
                // 标签发虚，所以这里显式去掉。
                style: AppTheme.withoutTextShadow(
                  textTheme.labelLarge,
                )?.copyWith(color: color),
                child: child!,
              ),
            ),
            child: _buildSegmentContent(segment),
          ),
        ),
      ),
    );
  }

  Widget _buildSegmentContent(SlidingSegment segment) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (segment.icon != null) ...[
          Icon(segment.icon),
          const SizedBox(width: _kIconGap),
        ],
        Flexible(
          child: Text(
            segment.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }
}
