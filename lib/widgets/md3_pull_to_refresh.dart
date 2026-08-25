import 'package:flutter/material.dart';
import 'package:m3e_core/m3e_core.dart';

/// 修复 [M3EPullToRefreshIndicator] 松手后"闪回"的下拉刷新包装器。
///
/// **问题**：m3e_core 的 `_startRefresh` 中，松手后"回弹到
/// indicatorHeight"的动画与 `await onRefresh()` 是并行执行的，且不等待
/// 动画；同时默认回弹弹簧 [M3EMotion.expressiveSpatialDefault]
/// （stiffness 380）很软，从最大下拉位置回弹到位需 500ms 以上。本项目
/// API 走本地 Rust 服务器转发，`onRefresh` 常在动画到位前完成（毫秒~
/// 百毫秒级），`finally` 随即触发收回动画，把还没回弹到位的指示器直接
/// 打断 —— 视觉上"松手后 loading 闪一下就没了"（闪回刷新）。
///
/// **修复**（两处配合）：
/// 1. 改用快速回弹弹簧 [springMotion]（默认 stiffness 1600，约 200ms
///    到位），保证动画总能先于 onRefresh 完成而自然到位；
/// 2. 给 `onRefresh` 包一层 [minDisplay] 最短展示时间，避免数据返回过快
///    时指示器"到位即收回"，让其停留转圈再平滑收回。
class Md3PullToRefresh extends StatelessWidget {
  /// 触发刷新的回调。
  final Future<void> Function() onRefresh;

  /// 可滚动的内容（[ListView]、[GridView]、[CustomScrollView] 等）。
  final Widget child;

  /// 回弹动画的弹簧。
  ///
  /// 默认 [M3EMotion.expressiveEffectsDefault]（stiffness 1600 / damping
  /// 1.0，临界阻尼无振荡），约 200ms 即可从最大下拉位置回弹到
  /// indicatorHeight；替换包默认的 expressiveSpatialDefault（stiffness
  /// 380，需 500ms+）是消除"闪回"的关键。
  final M3EMotion springMotion;

  /// 刷新指示器的最短展示时间（含回弹到位过程）。
  ///
  /// 默认 500ms：回弹约 200ms + 停留约 300ms，视觉上"自然到位→短暂转圈
  /// →平滑收回"。仅当 `onRefresh` 本身耗时短于 [minDisplay] 时才生效；
  /// 网络较慢时指示器照常停留至数据返回。
  final Duration minDisplay;

  const Md3PullToRefresh({
    super.key,
    required this.onRefresh,
    required this.child,
    this.springMotion = M3EMotion.expressiveEffectsDefault,
    this.minDisplay = const Duration(milliseconds: 500),
  });

  @override
  Widget build(BuildContext context) {
    return M3EPullToRefreshIndicator(
      onRefresh: () async {
        // eagerError: onRefresh 抛错时立即向上传播（不额外等待 minDisplay），
        // 与包原行为一致；正常情况等两者都完成（取较长的）。
        await Future.wait<void>(
          [onRefresh(), Future<void>.delayed(minDisplay)],
          eagerError: true,
        );
      },
      springMotion: springMotion,
      child: child,
    );
  }
}
