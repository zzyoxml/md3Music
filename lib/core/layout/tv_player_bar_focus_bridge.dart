import 'package:flutter/widgets.dart';

/// tv: 内容区 → 底部常驻 [MiniPlayer] 的**焦点移交桥**。
///
/// ## 为什么需要它
///
/// 与 [TvNavFocusBridge] 同源的同一个坑：dpad 收集候选用
/// `currentNode.nearestScope.traversalDescendants`（dpad `traversal.dart:60`），
/// 而 Flutter 的 `traversalDescendants` 只返回该 scope 的**后代**
/// （`focus_manager.dart:729`）。每个 tab 的内容区包在自己的 `Navigator`
/// 里（Navigator 即 FocusScope），底部常驻播放条是它的**兄弟**节点，
/// 于是内容区按到列表底部后 `leave` 行为在候选里找不到播放条，
/// **下键完全失效**（2026-10-04：MiniPlayer 在 TV 上永远选不中）。
///
/// 解法同导航栏：播放条把自己的焦点节点登记在这里，内容区检测到下边缘事件时
/// 直接 `requestFocus`，绕过 dpad 的候选收集。反向（播放条 → 内容区）不需要
/// 桥：播放条在根路由 scope 内，其 `traversalDescendants` 覆盖得到各 tab 内容。
///
/// 仅 TV 构建使用。
class TvPlayerBarFocusBridge {
  TvPlayerBarFocusBridge._();

  static final TvPlayerBarFocusBridge instance = TvPlayerBarFocusBridge._();

  FocusNode? _node;

  /// 登记播放条的焦点节点。反复登记会覆盖旧值。
  void register(FocusNode node) {
    _node = node;
  }

  /// 撤销 [node] 的登记（仅当它仍是当前登记值时才清，避免误删新宿主登记的节点）。
  void unregister(FocusNode node) {
    if (identical(_node, node)) _node = null;
  }

  /// 把焦点移交给播放条。返回是否成功发出移交请求。
  ///
  /// [FocusNode.requestFocus] 是**异步**生效的（scope 应用发生在微任务里），
  /// 故这里只表示"请求已发出"；播放条被隐藏（悬浮播放条开启 / 沉浸态）时
  /// 节点已随子树卸载，`canRequestFocus` 为 false，移交静默失败、焦点留在原处。
  bool focusPlayerBar() {
    final node = _node;
    if (node == null || !node.canRequestFocus) return false;
    if (node.hasFocus) return true;
    node.requestFocus();
    return true;
  }
}
