/// 声明「当前子树之下是否还有占据屏幕底部的固定 chrome（底部导航栏）」，
/// 以及该 chrome **正在被收起的进度**。
///
/// 用途：
/// - MiniPlayer 只有在自身就是屏幕最底部元素时，才需要为屏幕圆角与系统手势条
///   预留底部净空、并加宽左右内边距（见 `resolveMiniPlayerCornerClearance`）；
///   当它下方还压着 NavigationBar 时，那段空间已由导航栏占据，再留就是一条多余的
///   空带，左右加宽也没有意义；
/// - 底栏收起是**逐帧**的（进出二级页面各约 260ms），净空口径若按 bool 二选一，
///   转场末帧会连同底栏高度一起突变。故这里同时暴露 [bottomChromeCollapse]
///   （快照）与 [collapseProgress]（逐帧进度源），让消费方在这两套口径之间线性过渡。
///
/// 两种交付方式的分工（重要，别混用）：
/// - **快照**（[bottomChromeCollapse] / [chromeCollapseOf]）：一次性读数用 ——
///   转场闸门 `waitUntilBottomChromeSettled`、widget test、build 期快照；
/// - **逐帧源**（[collapseProgress] / [collapseStateOf]）：**逐帧**消费专用。消费方
///   订阅它（`AnimatedBuilder`）而不是对本 InheritedWidget 建立依赖：坞位收起期间
///   快照字段每帧都变，一旦在 build 里读 [chromeCollapseOf]（`dependOn…`），整棵
///   消费子树就会被拖去逐帧重建 —— MiniPlayer 的圆角避让净空层正是为此重写的
///   （见 `lib/modules/player/mini_player.dart` 的留白层注释）。
///
/// 由 [ResponsiveScaffold] 独家提供：
/// - 竖屏紧凑布局且底栏还在槽位里 → `hasBottomChrome = true`，进度为 0（在场）
///   到 <1（收起中）；
/// - 横屏（侧栏 NavigationRail）、沉浸态、底栏已完全收起 → `false`；
/// - 无 scope 祖先（push 出来的二级路由）→ 读取结果默认"按最底部处理"。
library;

import 'package:flutter/widgets.dart';

/// 坞位状态 + 逐帧进度源的**一次性读数**（见 [BottomChromeScope] 的分工说明）。
typedef BottomChromeState = ({
  Animation<double>? animation,
  bool hasBottomChrome,
});

class BottomChromeScope extends InheritedWidget {
  const BottomChromeScope({
    super.key,
    required this.hasBottomChrome,
    this.bottomChromeCollapse = 0.0,
    this.collapseProgress,
    required super.child,
  });

  /// 子树下方是否有占据屏幕底部的 chrome（**坞位存在性**，不表示它此刻完全在场：
  /// 收起动画期间坞位仍在、进度 > 0）。
  final bool hasBottomChrome;

  /// 底栏**收起进度**：0 = 完整在场，1 = 已完全让位。
  ///
  /// 只在「进/出二级页面」这类转场期间取中间值；坞位不存在时本字段无意义
  /// （消费方一律经 [chromeCollapseOf] 读取）。
  final double bottomChromeCollapse;

  /// 底栏收起的**逐帧进度源**（`ResponsiveScaffold` 的收起动画本体，与
  /// [bottomChromeCollapse] 是同一份进度的两种交付方式）。
  ///
  /// 逐帧消费方订阅它即可，无需对本 InheritedWidget 建立依赖；坞位不存在
  /// （横屏侧栏 / 已收起）或无祖先时，消费方按「自身即屏幕最底部」（t = 1）
  /// 处理，与 [chromeCollapseOf] 的兜底口径一致。
  final Animation<double>? collapseProgress;

  /// 读取当前子树下方是否有底部 chrome；无 scope 祖先时返回 `false`。
  ///
  /// 在 build 内调用会建立依赖：竖屏↔横屏切换导致取值变化时子树自动重建。
  static bool hasBottomChromeOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<BottomChromeScope>()
          ?.hasBottomChrome ??
      false;

  /// 读取底栏收起进度：无 scope 祖先、或坞位不存在（侧栏 / 底栏已收起）时返回 1.0
  /// —— 即「按自身就是屏幕最底部处理」，与 [hasBottomChromeOf] 的兜底口径一致。
  ///
  /// 适合**一次性读数**（转场闸门、测试、build 期快照）。逐帧消费请改订阅
  /// [collapseProgress]（经 [collapseStateOf] 取），不要在 build 里读本方法 ——
  /// 它会对本 InheritedWidget 建立依赖，而收起进度每帧都变，整棵子树会被拖去
  /// 逐帧重建。
  static double chromeCollapseOf(BuildContext context) {
    final BottomChromeScope? scope = context
        .dependOnInheritedWidgetOfExactType<BottomChromeScope>();
    if (scope == null || !scope.hasBottomChrome) return 1.0;
    final double t = scope.bottomChromeCollapse;
    return t.isFinite ? t.clamp(0.0, 1.0) : 0.0;
  }

  /// 一次性读取「坞位存在性 + 逐帧进度源」，**不建立 InheritedWidget 依赖**。
  ///
  /// 用 `getElementFor…` 而非 `dependOn…`，理由同
  /// `entry_transition_gate.dart` 的注释：需要逐帧跟着收起进度动的消费方（如
  /// MiniPlayer 的净空层）订阅 [BottomChromeScope.collapseProgress] 就够了，
  /// 建立依赖只会让它被快照字段的每帧变化拖去整棵重建。
  static BottomChromeState collapseStateOf(BuildContext context) {
    final BuildContext? element =
        context.getElementForInheritedWidgetOfExactType<BottomChromeScope>();
    final BottomChromeScope? scope = element?.widget as BottomChromeScope?;
    return (
      animation: scope?.collapseProgress,
      hasBottomChrome: scope?.hasBottomChrome ?? false,
    );
  }

  @override
  bool updateShouldNotify(BottomChromeScope oldWidget) =>
      oldWidget.hasBottomChrome != hasBottomChrome ||
      oldWidget.bottomChromeCollapse != bottomChromeCollapse;
}
