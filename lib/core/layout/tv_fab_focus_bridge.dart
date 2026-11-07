import 'package:flutter/widgets.dart';

/// tv: 内容区 → 右下角浮动操作按钮（FAB）的**焦点移交桥**。
///
/// ## 为什么它连几何遍历都过不去
///
/// 与 [TvPlayerBarFocusBridge] 是同一类死键，但成因不同：播放条是在
/// Navigator scope **之外**，FAB 则在 scope **之内**，只是几何上不合格。
/// dpad 的候选判定有两条（dpad `traversal.dart`）：
/// - `_isCandidate(down)`：要求 `source.bottom < candidate.bottom`——FAB 被
///   `padding.bottom` 抬高，底边反而**高于**内容末行的底边；
/// - `_inBeam(down)`：要求水平投影与源重叠——FAB 贴在右下角，内容末行的
///   右边界够不到它。
///
/// 两条都不成立 → 下键直接落空（tmp 探针实测：末行宽 600 居中、FAB 在
/// x=728、视口宽 800，按下键后 `fab.hasFocus == false`、焦点留在原行）。
///
/// 故由页面把 FAB 的焦点节点登记到这里，内容区触发下边缘事件时优先交 FAB，
/// 交不到（当前页没有 FAB）再退给播放条。
///
/// 仅 TV 构建使用。
class TvFabFocusBridge {
  TvFabFocusBridge._();

  static final TvFabFocusBridge instance = TvFabFocusBridge._();

  FocusNode? _node;

  /// 登记当前页 FAB 的焦点节点。反复登记会覆盖旧值。
  void register(FocusNode node) {
    _node = node;
  }

  /// 撤销 [node] 的登记（仅当它仍是当前登记值时才清，避免误删新页面登记的节点）。
  void unregister(FocusNode node) {
    if (identical(_node, node)) _node = null;
  }

  /// 把焦点移交给 FAB。返回是否成功发出移交请求。
  ///
  /// 页面没有 FAB（未登记）或节点已随子树卸载时返回 false，调用方据此退到
  /// 下一个落点（底部播放条）。[FocusNode.requestFocus] 异步生效，故这里只
  /// 表示"请求已发出"。
  bool focusFab() {
    final node = _node;
    if (node == null || !node.canRequestFocus) return false;
    if (node.hasFocus) return true;
    node.requestFocus();
    return true;
  }
}
