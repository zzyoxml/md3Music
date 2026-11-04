import 'package:flutter/widgets.dart';

/// tv: 内容区 → 主导航栏的**焦点移交桥**。
///
/// ## 为什么需要它
///
/// dpad 收集候选用的是 `currentNode.nearestScope.traversalDescendants`
/// （dpad `traversal.dart:60`），而 Flutter 的 `traversalDescendants` 只返回
/// 该 scope 的**后代**（`focus_manager.dart:729`），不含父/兄弟 scope。
///
/// 本项目每个 tab 的内容区包在自己的 `Navigator` 里（`responsive_shell.dart`
/// `_buildTab`），而 Navigator 是 FocusScope；主导航栏是它的**兄弟**节点。
/// 于是内容区里的焦点走到左边缘后，`leave` 行为的跨区域搜索在
/// `traversalDescendants` 里找不到任何 scope 外的候选，**左键完全失效**
/// （2026-10-04 真机实测：连按 12 次左键焦点纹丝不动；widget 测试
/// `test/core/remote/dpad_scope_probe_test.dart` 复现：有 FocusScope 时焦点
/// 出不去，去掉后立即可达）。
///
/// Navigator 的 scope 无法移除（`routeTraversalEdgeBehavior` 只决定"到达本
/// scope 边缘后往哪走"，不改变候选收集范围），因此改用**显式桥接**：导航栏
/// 把各导航项的焦点节点登记到这里，内容区检测到横向边缘事件时直接
/// `requestFocus` 把焦点交给目标节点，绕过 dpad 的候选收集。
///
/// 仅 TV 构建使用（`kTvBuild` 为 false 时相关接线整段树摇剔除）。
class TvNavFocusBridge {
  TvNavFocusBridge._();

  static final TvNavFocusBridge instance = TvNavFocusBridge._();

  /// 索引 → 导航项焦点节点。索引是 tab 序号，两种布局（NavigationBar /
  /// NavigationRail）共用同一套语义。
  final Map<int, FocusNode> _nodes = {};

  /// 登记导航项 [index] 的焦点节点。同索引重复登记会覆盖旧值。
  ///
  /// 导航项每次构建都会新建节点（同一 tab 的 icon / selectedIcon 是两棵互斥
  /// 子树，不能复用同一节点——Flutter 的焦点节点只允许一个挂载点，复用会让
  /// 两个 DpadFocusable 争抢并使 OK 键链路失效，2026-10-04 实测踩过）。
  ///
  /// 旧节点不做 dispose：判断「是否仍挂在树上」没有公开可靠的 API（dispose 后
  /// 访问 context 会抛断言），误 dispose 会直接崩在焦点系统里。泄漏量以导航项
  /// 选中态切换次数计（每次切换一个节点、几十字节），换稳定性是划算的。
  void register(int index, FocusNode node) {
    _nodes[index] = node;
  }

  /// 把焦点移交给第 [index] 个导航项。返回是否成功发出移交请求。
  ///
  /// 注意 [FocusNode.requestFocus] 是**异步**生效的（scope 应用发生在微任务
  /// 里），故这里只表示"请求已发出"而非"焦点已落位"；调用方若要确认结果，
  /// 应在下一帧检查 [FocusManager.instance.primaryFocus]。
  bool focusNavItem(int index) {
    final node = _nodes[index];
    if (node == null || !node.canRequestFocus) return false;
    if (node.hasFocus) return true;
    node.requestFocus();
    return true;
  }

  /// [node] 是否属于主导航栏（等于某个导航项节点，或是它的后代）。
  ///
  /// 用途：焦点校正（`ResponsiveShell._ensureFocusNotStuck`）判断"焦点在导航栏上"
  /// 属合法落点，不能把它抢回内容区——用户在导航栏上按上下键换 tab 时会被打断。
  bool isNavNode(FocusNode node) {
    for (final nav in _nodes.values) {
      if (identical(nav, node)) return true;
      if (node.ancestors.contains(nav)) return true;
    }
    return false;
  }

  /// 当前是否有已登记的导航项节点（诊断用）。
  bool get hasNodes => _nodes.isNotEmpty;

  /// 第 [index] 个导航项的焦点节点（未登记返回 null）。
  ///
  /// 用途：切 tab / 首帧的焦点归还（见 `ResponsiveShell` 的
  /// `_scheduleNavFocusRetention`）需要直接拿到导航项节点再决定是否 requestFocus。
  FocusNode? nodeFor(int index) => _nodes[index];

  /// 当前已登记的导航项索引（诊断用）。
  Iterable<int> get registeredIndices => _nodes.keys;
}
