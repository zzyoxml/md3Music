import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/layout/responsive_layout.dart';
import '../providers/grid_columns_provider.dart';

/// 封装捏合手势调整列数的可复用网格组件。
///
/// Pad 模式下双指捏合可动态调整列数（向内捏合增列、向外捏合减列），
/// 列数由 [GridColumnsProvider] 管理并持久化；非 Pad 模式固定 2 列、
/// 不挂载手势。列数变化时通过 [AnimatedSwitcher] 做淡入淡出过渡。
class PinchableGridView extends StatefulWidget {
  final IndexedWidgetBuilder itemBuilder;
  final int itemCount;
  final double childAspectRatio;
  // 同时用于 mainAxisSpacing 和 crossAxisSpacing
  final double spacing;
  final EdgeInsets padding;
  final ScrollController? controller;
  final bool shrinkWrap;
  final ScrollPhysics? physics;
  // 底部加载更多指示器，非空时放在 GridView 下方
  final Widget? loadingWidget;

  const PinchableGridView({
    super.key,
    required this.itemBuilder,
    required this.itemCount,
    this.childAspectRatio = 0.75,
    this.spacing = 12.0,
    this.padding = EdgeInsets.zero,
    this.controller,
    this.shrinkWrap = false,
    this.physics,
    this.loadingWidget,
  });

  @override
  State<PinchableGridView> createState() => _PinchableGridViewState();
}

class _PinchableGridViewState extends State<PinchableGridView> {
  // 捏合手势的缩放基准：onScaleStart 时重置为 1.0，
  // 触发阈值后重置为当前 scale，避免一次捏合连续多次触发。
  double _scaleStart = 1.0;

  void _onScaleStart(ScaleStartDetails details) {
    _scaleStart = 1.0;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    // scale 相对基准的变化比例
    final ratio = details.scale / _scaleStart;
    if (ratio <= 0.8) {
      // 向内捏合（缩小）：增加列数
      context.read<GridColumnsProvider>().increment();
      _scaleStart = details.scale;
    } else if (ratio >= 1.2) {
      // 向外捏合（放大）：减少列数
      context.read<GridColumnsProvider>().decrement();
      _scaleStart = details.scale;
    }
  }

  Widget _buildGrid(int columns) {
    final gridView = GridView.builder(
      // 列数变化时让 AnimatedSwitcher 识别为新 child，触发过渡
      key: ValueKey(columns),
      controller: widget.controller,
      shrinkWrap: widget.shrinkWrap,
      physics: widget.physics,
      padding: widget.padding,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        childAspectRatio: widget.childAspectRatio,
        mainAxisSpacing: widget.spacing,
        crossAxisSpacing: widget.spacing,
      ),
      itemCount: widget.itemCount,
      itemBuilder: widget.itemBuilder,
    );

    // 有底部加载指示器时用 Column 包裹：GridView 占满剩余空间
    if (widget.loadingWidget != null) {
      return Column(
        children: [
          Expanded(child: gridView),
          widget.loadingWidget!,
        ],
      );
    }
    return gridView;
  }

  @override
  Widget build(BuildContext context) {
    final isPad = isPadLayout(context);
    // Pad 模式取 provider 列数（watch 以便列数变化时重建），非 Pad 固定 2
    final columns = isPad
        ? context.watch<GridColumnsProvider>().gridColumns
        : 2;

    // AnimatedSwitcher + ValueKey 让列数变化时整体淡入淡出
    final gridContent = AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      child: _buildGrid(columns),
    );

    // 非 Pad 模式不挂载捏合手势，直接返回
    if (!isPad) {
      return gridContent;
    }

    // Pad 模式包裹 GestureDetector；behavior opaque 确保空白区域也能接收手势，
    // 手势竞技场中双指 scale 会胜出、单指 drag 让给 GridView 滚动
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onScaleStart: _onScaleStart,
      onScaleUpdate: _onScaleUpdate,
      child: gridContent,
    );
  }
}
