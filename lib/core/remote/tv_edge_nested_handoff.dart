import 'package:dpad/dpad.dart';
import 'package:flutter/widgets.dart';

/// tv: 区域边缘的「嵌套区域移交」。
///
/// ## 要解决的问题
/// dpad 的方向搜索**只在同一个 DpadRegion 的成员之间**比候选
/// （dpad `traversal.dart:65-71`：`inRegion = candidates.where(DpadRegion.ofNode(node) == 当前区域)`），
/// 而本 App 给每个 Tab 的内容都套了一层 `horizontalEdge/verticalEdge: stop` 的
/// `DpadRegion`（`responsive_shell.dart`，为了在边缘把焦点桥接给导航栏 / FAB /
/// 常驻播放条）。于是页面里那些**横向卡片带自己的区域**（`TvScrollRegion`）
/// 变成屏障：从带外的行按「下」，dpad 在 tab 区域的成员里找不到候选 →
/// 走 `stop` 分支 `notifyEdge` 后**直接吃掉按键**，永远不再做跨区域搜索
/// → 带子里的卡片落不下焦点。
///
/// 真机表现（2026-10-08）：频道详情页「相似频道」带、场景专区「音乐/歌单/视频」
/// 标签带——上方的行能选，带里的卡片怎么都选不中；给卡片补上 `DpadFocusable`
/// 后**仍然**选不中（停点是对的，挡住的是区域边缘）。复现与定案见
/// `test/core/remote/tv_band_below_fold_focus_test.dart` 的 C/D 两组。
///
/// ## 本函数的定位
/// 在 `onEdge` 里**先**做一次跨区域搜索：只考察「不属于当前区域」的候选
/// （同区域的 dpad 已经找过，交给它），按 Android FocusFinder 的加权距离
/// （主轴距离²×13 + 交叉轴距离²）择优，命中就经 [Dpad.requestFocus] 移交
/// （顺带写入目标区域的记忆位，`DpadEnterBehavior.restore` 才会生效）。
/// 找不到才回到原来的桥接——`stop` 边缘原本的用途不变，只是不再吞掉
/// 「其实那个方向还有可选项」的那次按键。
///
/// 注意：导航栏 / 常驻播放条在 Tab 的 Navigator scope **之外**（兄弟 scope），
/// 不在 `traversalDescendants` 里，本函数永远找不到它们，因此不会和既有桥接抢焦点。
bool focusNestedRegionBeyond(FocusNode from, TraversalDirection direction) {
  final scope = from.nearestScope;
  final context = from.context;
  if (scope == null || context == null || !context.mounted) return false;

  final fromRect = _rectOf(from);
  if (fromRect == null) return false;
  final fromRegion = DpadRegion.ofNode(from);

  FocusNode? best;
  bool bestInBeam = false;
  double bestScore = double.infinity;

  for (final node in scope.traversalDescendants) {
    if (identical(node, from)) continue;
    if (node.hasFocus) continue;
    // 只移交到**具体条目**：scope 节点的矩形是整块区域，落上去等于把焦点
    // 交给那个 scope 自己裁决（多为 null → 又被 dpad 的 restoreFocus 兜底抢走）。
    if (node is FocusScopeNode) continue;
    if (node.skipTraversal || !node.canRequestFocus) continue;
    // 只找别的区域（含嵌套带区域）的候选；同区域的 dpad 自己会处理。
    if (identical(DpadRegion.ofNode(node), fromRegion)) continue;
    // 而且必须还在**当前区域的子树里**：导航栏 / 常驻播放条这类兄弟分支节点
    // 可能挂在同一个 Navigator scope 上（例如双栏详情面板），它们不在本区域里，
    // 该由 onEdge 后面的专用桥接处理，不能在这里被当成「方向上的候选」抢走。
    if (!_withinRegion(node, fromRegion)) continue;
    final rect = _rectOf(node);
    if (rect == null) continue;
    if (!_isCandidate(fromRect, rect, direction)) continue;

    final inBeam = _inBeam(fromRect, rect, direction);
    final score = _weightedDistance(
      _majorDistance(fromRect, rect, direction),
      _minorDistance(fromRect, rect, direction),
    );
    // 与 dpad 同一优先级规则：在束流里的候选一律胜出。
    if (best == null ||
        (inBeam && !bestInBeam) ||
        (inBeam == bestInBeam && score < bestScore)) {
      best = node;
      bestInBeam = inBeam;
      bestScore = score;
    }
  }

  if (best == null) return false;
  return Dpad.of(context).requestFocus(best);
}

/// 候选是否仍在 [region] 的子树内（[region] 为 null 时不额外限制）。
///
/// 用 Element 身份比对（dpad 自己在 `_scrollForMore` 的 boundary 也是这么做的）：
/// 兄弟分支（导航栏、常驻播放条）虽然可能同属一个 Navigator scope，但不在
/// 本区域子树里，交给 onEdge 后面的专用桥接，不在这里抢焦点。
bool _withinRegion(FocusNode node, DpadRegionState? region) {
  if (region == null) return true;
  final regionContext = region.context;
  final nodeContext = node.context;
  if (nodeContext == null || !nodeContext.mounted) return false;
  bool within = false;
  nodeContext.visitAncestorElements((element) {
    if (identical(element, regionContext)) {
      within = true;
      return false;
    }
    return true;
  });
  return within;
}

Rect? _rectOf(FocusNode node) {
  final context = node.context;
  if (context == null || !context.mounted) return null;
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.attached || !box.hasSize) return null;
  final rect = box.localToGlobal(Offset.zero) & box.size;
  if (rect.isEmpty) return null;
  return rect;
}

/// 与 dpad `traversal.dart:_isCandidate` 同规则（边缘判定，允许部分重叠的大块）。
bool _isCandidate(Rect source, Rect candidate, TraversalDirection direction) {
  switch (direction) {
    case TraversalDirection.left:
      return (source.right > candidate.right ||
              source.left >= candidate.right) &&
          source.left > candidate.left;
    case TraversalDirection.right:
      return (source.left < candidate.left ||
              source.right <= candidate.left) &&
          source.right < candidate.right;
    case TraversalDirection.up:
      return (source.bottom > candidate.bottom ||
              source.top >= candidate.bottom) &&
          source.top > candidate.top;
    case TraversalDirection.down:
      return (source.top < candidate.top ||
              source.bottom <= candidate.bottom) &&
          source.bottom < candidate.bottom;
  }
}

bool _inBeam(Rect source, Rect candidate, TraversalDirection direction) {
  switch (direction) {
    case TraversalDirection.left:
    case TraversalDirection.right:
      return candidate.bottom > source.top && candidate.top < source.bottom;
    case TraversalDirection.up:
    case TraversalDirection.down:
      return candidate.right > source.left && candidate.left < source.right;
  }
}

double _majorDistance(
  Rect source,
  Rect candidate,
  TraversalDirection direction,
) {
  final double distance = switch (direction) {
    TraversalDirection.left => source.left - candidate.right,
    TraversalDirection.right => candidate.left - source.right,
    TraversalDirection.up => source.top - candidate.bottom,
    TraversalDirection.down => candidate.top - source.bottom,
  };
  return distance < 0 ? 0 : distance;
}

double _minorDistance(
  Rect source,
  Rect candidate,
  TraversalDirection direction,
) {
  final horizontal =
      direction == TraversalDirection.left || direction == TraversalDirection.right;
  return horizontal
      ? (candidate.center.dx - source.center.dx).abs()
      : (candidate.center.dy - source.center.dy).abs();
}

double _weightedDistance(double major, double minor) => 13 * major * major + minor * minor;
