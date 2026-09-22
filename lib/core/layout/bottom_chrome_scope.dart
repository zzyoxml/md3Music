/// 声明「当前子树之下是否还有占据屏幕底部的固定 chrome（底部导航栏）」。
///
/// 用途：MiniPlayer 只有在自身就是屏幕最底部元素时，才需要为屏幕圆角与系统
/// 手势条预留底部净空、并加宽左右内边距（见 `resolveMiniPlayerCornerClearance`）；
/// 当它下方还压着 NavigationBar 时，那段空间已由导航栏占据，再留就是一条多余
/// 的空带，左右加宽也没有意义。
///
/// 由 [ResponsiveScaffold] 独家提供：
/// - 竖屏紧凑布局且导航栏可见 → `hasBottomChrome = true`
/// - 横屏（侧栏 NavigationRail）或导航栏被隐藏（沉浸）→ `false`
/// - 无 scope 祖先（push 出来的二级路由）→ 读取结果默认 `false`，
///   即按「最底部」处理，落在保守（会留白）的一侧。
library;

import 'package:flutter/widgets.dart';

class BottomChromeScope extends InheritedWidget {
  const BottomChromeScope({
    super.key,
    required this.hasBottomChrome,
    required super.child,
  });

  /// 子树下方是否有占据屏幕底部的 chrome。
  final bool hasBottomChrome;

  /// 读取当前子树下方是否有底部 chrome；无 scope 祖先时返回 `false`。
  ///
  /// 在 build 内调用会建立依赖：竖屏↔横屏切换导致取值变化时子树自动重建。
  static bool hasBottomChromeOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<BottomChromeScope>()
          ?.hasBottomChrome ??
      false;

  @override
  bool updateShouldNotify(BottomChromeScope oldWidget) =>
      oldWidget.hasBottomChrome != hasBottomChrome;
}
