import 'package:material_ui/material_ui.dart';

import '../theme/app_dimens.dart';
import 'responsive_layout.dart';

/// 按**实际可用宽度**自适应列数的内容网格（计划 ⑥ 宽屏密度）。
///
/// 设计目标：把散落在各页（`home_page` / `albums_page` / `explore_sections` 等）
/// 的 `LayoutBuilder + gridColumnsForWidth + SliverGrid` 模式收敛成一个可复用组件，
/// 统一列数 / 间距 / 目标列宽入参，供各**卡片 / 封面类**列表页复用。
///
/// 关键原则（与 `isDesktopLayout` 桌面开关**无关**）：
/// - 一律按 [LayoutBuilder] 的**局部约束宽度**判定列数，而非全局 `MediaQuery` 或
///   开关。因此分栏 / 双栏 / 窄窗 / 竖屏手机都能自然回落到单列或少列，不会把内容
///   拉伸撑满，也不会在窄面板里塞进过多列。
/// - 宽度低于 [singleColumnBelow] 时强制单列（[ListView] / [SliverList]），保证窄屏
///   仍是清晰的单列列表；越过阈值后按每列目标宽度 [targetExtent] 均分列数，夹在
///   [minColumns, maxColumns]。
///
/// 提供 [AdaptiveContentGrid]（box 版，自身可滚动）与 [SliverAdaptiveContentGrid]
/// （sliver 版，放进 [CustomScrollView]）两种形态。
///
/// **仅用于卡片 / 封面类内容**（歌单 / 专辑 / 歌手卡片等）。歌曲列表须保持单列以
/// 呈现清晰的播放顺序，不要用本组件多列化。
class AdaptiveContentGrid extends StatelessWidget {
  const AdaptiveContentGrid({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.controller,
    this.physics,
    this.shrinkWrap = false,
    this.padding,
    this.targetExtent = AppLayout.gridTargetExtent,
    this.childAspectRatio = 0.75,
    this.spacing = AppSpacing.md,
    this.minColumns = 2,
    this.maxColumns = 6,
    this.singleColumnBelow = compactBreakpoint,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final ScrollController? controller;
  final ScrollPhysics? physics;
  final bool shrinkWrap;
  final EdgeInsetsGeometry? padding;

  /// 每列目标宽度：越宽的卡片给越大的值（封面卡 ~180，横向行卡 ~360）。
  final double targetExtent;

  /// 多列网格模式下每个格子的宽高比（封面卡 <1 竖，横向行卡 >1 扁）。
  final double childAspectRatio;

  /// 主轴 + 交叉轴间距（同值）。
  final double spacing;

  /// 越过 [singleColumnBelow] 后的列数下限 / 上限。
  final int minColumns;
  final int maxColumns;

  /// 低于此宽度强制单列列表（保证窄屏 / 竖屏手机仍是清晰单列）。
  final double singleColumnBelow;

  int _columnsFor(double width) {
    if (width < singleColumnBelow) return 1;
    return gridColumnsForWidth(
      width,
      targetExtent: targetExtent,
      min: minColumns,
      max: maxColumns,
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = _columnsFor(constraints.maxWidth);
        if (columns <= 1) {
          return ListView.builder(
            controller: controller,
            physics: physics,
            shrinkWrap: shrinkWrap,
            padding: padding,
            itemCount: itemCount,
            itemBuilder: itemBuilder,
          );
        }
        return GridView.builder(
          controller: controller,
          physics: physics,
          shrinkWrap: shrinkWrap,
          padding: padding,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            childAspectRatio: childAspectRatio,
            crossAxisSpacing: spacing,
            mainAxisSpacing: spacing,
          ),
          itemCount: itemCount,
          itemBuilder: itemBuilder,
        );
      },
    );
  }
}

/// [AdaptiveContentGrid] 的 sliver 版：放进 [CustomScrollView] 的 slivers 列表。
///
/// 与 box 版判定逻辑一致（按 [SliverConstraints.crossAxisExtent] 局部宽度定列数），
/// 单列回落到 [SliverList]，多列用 [SliverGrid]。
class SliverAdaptiveContentGrid extends StatelessWidget {
  const SliverAdaptiveContentGrid({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.targetExtent = AppLayout.gridTargetExtent,
    this.childAspectRatio = 0.75,
    this.spacing = AppSpacing.md,
    this.minColumns = 2,
    this.maxColumns = 6,
    this.singleColumnBelow = compactBreakpoint,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final double targetExtent;
  final double childAspectRatio;
  final double spacing;
  final int minColumns;
  final int maxColumns;
  final double singleColumnBelow;

  int _columnsFor(double width) {
    if (width < singleColumnBelow) return 1;
    return gridColumnsForWidth(
      width,
      targetExtent: targetExtent,
      min: minColumns,
      max: maxColumns,
    );
  }

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final columns = _columnsFor(constraints.crossAxisExtent);
        final delegate = SliverChildBuilderDelegate(
          itemBuilder,
          childCount: itemCount,
        );
        if (columns <= 1) {
          return SliverList(delegate: delegate);
        }
        return SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            childAspectRatio: childAspectRatio,
            crossAxisSpacing: spacing,
            mainAxisSpacing: spacing,
          ),
          delegate: delegate,
        );
      },
    );
  }
}
