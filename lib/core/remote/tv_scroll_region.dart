import 'package:dpad/dpad.dart';
import 'package:flutter/widgets.dart';

import '../build_flags.dart';

/// TV 构建下的「滚动区域」焦点包装：给横向卡片带 / 网格 / 纵向列表补上
/// 区域语义——[memoryKey] 记忆（离开再回来落回原位）+ 边缘行为（横向带
/// 默认 [DpadEdgeBehavior.wrap] 回绕，防止焦点掉出带子后回不到原位）。
///
/// 非 TV 构建（kTvBuild=false，AOT 树摇）原样返回 child，零开销。
/// 典型用法：
/// - 横向卡片带：`TvScrollRegion(memoryKey: 'tv/home-row-1', child: ListView(...))`
/// - 纵向结果列表：`TvScrollRegion(memoryKey: 'tv/search-song',
///   horizontalEdge: DpadEdgeBehavior.leave, child: ...)`
class TvScrollRegion extends StatelessWidget {
  final String memoryKey;
  final DpadEdgeBehavior horizontalEdge;
  final DpadEdgeBehavior verticalEdge;
  final Widget child;

  const TvScrollRegion({
    super.key,
    required this.memoryKey,
    this.horizontalEdge = DpadEdgeBehavior.wrap,
    this.verticalEdge = DpadEdgeBehavior.leave,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (!kTvBuild) return child;
    return DpadRegion(
      memoryKey: memoryKey,
      horizontalEdge: horizontalEdge,
      verticalEdge: verticalEdge,
      child: child,
    );
  }
}
