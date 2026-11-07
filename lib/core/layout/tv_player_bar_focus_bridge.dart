import 'package:flutter/widgets.dart';

/// tv: → MiniPlayer 的**焦点移交桥**（原「内容区 → 底部常驻播放条」）。
///
/// ## 为什么改成节点池
///
/// MiniPlayer 移到顶部第一层后，桥的消费者从「内容区下边缘」变成「顶栏长按
/// 上键 / 第二层上边缘」。同一根桥上有多个登记者：顶栏常驻实例（`TvMainShell`），
/// 以及二级路由自带的实例（SearchPage 等的 `SecondaryMiniPlayerHost` 回落）。
/// 单节点会被后登记者覆盖，先登记者卸载时又被 `unregister` 清空——长按上键
/// 随即失效。故按登记顺序存池，取**最后可用的**（视觉最上层）节点。
///
/// 仅 TV 构建使用。
class TvPlayerBarFocusBridge {
  TvPlayerBarFocusBridge._();

  static final TvPlayerBarFocusBridge instance = TvPlayerBarFocusBridge._();

  /// 已登记的迷你播放器焦点节点（按登记顺序）。
  final List<FocusNode> _nodes = <FocusNode>[];

  /// 登记 [node]。重复登记幂等（FocusNode 的 == 是恒等）。
  void register(FocusNode node) {
    if (!_nodes.contains(node)) _nodes.add(node);
  }

  /// 撤销 [node] 的登记。
  void unregister(FocusNode node) {
    _nodes.remove(node);
  }

  /// 把焦点移交给最上层可用的迷你播放器。返回是否成功发出移交请求。
  ///
  /// [FocusNode.requestFocus] 异步生效，故只表示「请求已发出」。
  bool focusMiniPlayer() {
    for (final FocusNode node in _nodes.reversed) {
      if (!node.canRequestFocus) continue;
      if (node.hasFocus) return true;
      node.requestFocus();
      return true;
    }
    return false;
  }

  /// [node] 是否属于某个已登记的迷你播放器（焦点校正判定用）。
  bool isMiniNode(FocusNode node) {
    for (final FocusNode n in _nodes) {
      if (identical(n, node)) return true;
    }
    return false;
  }
}
