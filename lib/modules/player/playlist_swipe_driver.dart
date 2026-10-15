// 播放列表「从右往左滑 → 切到下一页」的跟手驱动。
//
// 把面板逐帧上报的进度换算成页位置，交给 PlayerTabPager 执行。
// 与本类解耦的是「执行动作」——通过三个回调注入，因此本类不依赖任何
// Flutter 页面类，可直接单测。
//
// 为什么吸附不自己起 AnimationController：TabController.animateTo 在
// 「目标页 == 当前页」时会直接 return（Flutter SDK material/tab_controller.dart:205），
// 回弹会卡在半路，所以早期版本曾自带补间时钟。现在执行方换成
// PageController.animateTo，没有该限制，逻辑随之简化。

import 'package:material_ui/material_ui.dart';

import 'playlist_swipe.dart';

/// 吸附补间曲线：起步快、收尾稳，贴手但不突兀。
const Curve _kPlaylistSwipeSettleCurve = Curves.easeOutCubic;

/// 吸附时长 = 基数 + 每整页毫秒 × 距离，再钳到 [_minSettleMs, _maxSettleMs]。
const int _minSettleMs = 120;
const int _maxSettleMs = 300;
const int _baseSettleMs = 120;
const int _perPageSettleMs = 180;

/// 播放列表跟手滑页的驱动。
///
/// 播放列表恒为 index 0（见 player_tab_layout.dart），故 [_progress] 的有效
/// 范围就是 0~1 页。
class PlaylistSwipeDriver {
  PlaylistSwipeDriver({
    required this.readPage,
    required this.jumpToPage,
    required this.animateToPage,
  });

  /// 读当前连续页位置（pager.page）。
  final double Function() readPage;

  /// 立刻定位到某个（可带小数的）页位置。
  final void Function(double) jumpToPage;

  /// 补间到某个页位置。
  final void Function(double, Duration, Curve) animateToPage;

  /// 本次手势进入跟手时的起点页位置（正常就是 0）。
  double _base = 0;

  /// 本次手势已上报的最新进度（0~1 页）。
  double _progress = 0;

  /// 吸附动画时长：距离越短动画越短，避免短距离回弹被固定时长拖成慢动作。
  static Duration settleDuration(double from, double to) {
    final distance = (to - from).abs().clamp(0.0, 1.0);
    final ms = (_baseSettleMs + _perPageSettleMs * distance)
        .round()
        .clamp(_minSettleMs, _maxSettleMs);
    return Duration(milliseconds: ms);
  }

  /// 进入跟手：记下起点页位置。
  void start() {
    _base = readPage().clamp(0.0, 1.0);
    _progress = 0;
  }

  /// 拖动中：逐帧定位，让页面 1:1 跟随手指。
  void update(double progress) {
    _progress = progress;
    jumpToPage((_base + progress).clamp(0.0, 1.0));
  }

  /// 松手：按速度折算出目标页并补间过去。
  ///
  /// [velocityPxPerSec] 为水平速度（逻辑像素/秒，向左为负），[panelWidth]
  /// 为面板（一页）的宽度，两者由面板提供——只有它知道自己的尺寸。
  void settle({
    required double velocityPxPerSec,
    required double panelWidth,
  }) {
    final from = (_base + _progress).clamp(0.0, 1.0);
    final to = playlistSwipeSettleTarget(
      progress: from,
      velocityPxPerSec: velocityPxPerSec,
      panelWidth: panelWidth,
    ).toDouble();
    _progress = 0;
    animateToPage(
      to,
      settleDuration(from, to),
      _kPlaylistSwipeSettleCurve,
    );
  }
}