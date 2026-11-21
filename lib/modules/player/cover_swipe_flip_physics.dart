// AM 播放页封面「跟手拖拽翻转切歌」的纯逻辑：进度映射 / 运动学 / 松手判定 /
// 回弹弹簧分档。刻意不依赖 widget，手感边界用普通单测钉住。
//
// 坐标约定（与 CoverSwitchPager 相同）：
//   direction = +1 下一曲（手指左移）、-1 上一曲（手指右移）
//   progress p：0 = 封面正面，1 = 翻到 90°（交接点）；越界只允许橡皮筋的一点点
//   时钟 t = p * kCoverFlipSwap，与 CoverFlipCrossfade 的 _flip.value 同域

import 'package:flutter/physics.dart';

import 'cover_flip_physics.dart' show kCoverFlipHalfTurn, kCoverFlipSwap;
import 'cover_switch_physics.dart' show coverDragProgress;

/// 拖满一页（翻完 180°、卡背朝前）所需像素 = 封面边长 × 此比例。
/// 取 0.62：约 380px 的封面拖 235px 翻完，其中约 118px 过 90°——
/// 比 MD 横滑「一整页宽」更省力，拇指一次短扫即可翻面。
const double kCoverSwipeDragRatio = 0.62;

/// 无邻居一侧的橡皮筋上限（页）。复用 MD pager 的 0.35 会让 t 越过 0.5
/// （旧层被移出树、当前封面从背面翻回来穿帮），故手势路径单独取小值。
const double kCoverSwipeOverscrollPages = 0.12;

/// 松手判定阈值（与 shouldExpandPlayer 同族，按封面手势标定）。
const double kCoverSwipeCommitProgress = 0.5;
const double kCoverSwipeFlingVelocity = 900.0;
const double kCoverSwipeAcceleration = 6000.0;
const double kCoverSwipePullBackVelocity = 120.0;
const double kCoverSwipeMinImpulseProgress = 0.08;

/// 提交后等 provider 真正换歌的守卫时长（与 CoverSwitchPager._commitGuard 同款）。
const Duration kCoverSwipeCommitGuard = Duration(milliseconds: 1600);

/// 回弹最大负向过冲（页）：约 -10.8°，硬甩时封面会朝反方向轻翻一下再回正。
const double kCoverSwipeMaxOvershootPages = 0.12;

/// 强度分档用的加速度权重（秒）：把 px/s² 折算成等效 px/s。
const double kCoverSwipeAccelWeight = 0.02;

/// 跟手进度：把手指增量换算成页进度，越界走橡皮筋，无邻居侧钳到 0 页。
double coverDragProgressForSwipe({
  required double progress,
  required double dx,
  required double pitch,
  required int direction,
  required bool canSwitch,
}) {
  if (pitch <= 0 || direction == 0) return progress;
  final raw = coverDragProgress(
    progress: progress,
    dx: dx * direction,
    pitch: pitch,
    minProgress: 0,
    maxProgress: canSwitch ? 1.0 : 0.0,
  );
  // coverDragProgress 的越界上限是 0.35 页（MD pager 口径），手势路径压到
  // 0.12 页：无邻居侧拖到底也只转 ~10.8°，有邻居侧最多多出 0.12 页的
  // 「拖过头」余量。硬钳是刻意的：越界触顶后完全不动，正是「到头了」的触感；
  // widget 把 p 直接当时钟（1 = 翻完 180°），画面只取 [0, 1]。
  final max = canSwitch
      ? 1.0 + kCoverSwipeOverscrollPages
      : kCoverSwipeOverscrollPages;
  return raw.clamp(-kCoverSwipeMaxOvershootPages, max).toDouble();
}

/// 前半程角度：线性跟手（不是自动过渡的 easeIn），允许负向过冲。
double coverSwipeOldAngle(double t) => kCoverFlipHalfTurn *
    (t / kCoverFlipSwap).clamp(-kCoverSwipeMaxOvershootPages, 1.0);

/// 速度/加速度采样：按事件时间戳差分 + 一次 EMA 平滑。
/// x 是手指的原始横坐标（右为正），转换到「沿提交方向」由调用方乘 -direction。
class CoverSwipeKinematics {
  Duration? _lastT;
  double _lastX = 0;
  double _lastV = 0;
  bool _hasV = false;
  double _v = 0;
  double _a = 0;

  double get velocity => _v;
  double get acceleration => _a;

  void reset(Duration t, double x) {
    _lastT = t;
    _lastX = x;
    _lastV = 0;
    _hasV = false;
    _v = 0;
    _a = 0;
  }

  void addSample(Duration t, double x) {
    final last = _lastT;
    if (last == null) {
      reset(t, x);
      return;
    }
    final dt = (t - last).inMicroseconds / 1e6;
    if (dt < 0.001) return; // 合并事件 / 同一帧重复上报：连时间基线也不推进
    _lastT = t;
    final rawV = (x - _lastX) / dt;
    _lastX = x;
    _v = _hasV ? 0.6 * rawV + 0.4 * _v : rawV;
    if (_hasV) {
      final rawA = (_v - _lastV) / dt;
      _a = (0.5 * rawA + 0.5 * _a).clamp(-40000.0, 40000.0).toDouble();
    }
    _lastV = _v;
    _hasV = true;
  }
}

/// 松手判定：回拉否决优先，位移 / 速度 / 加速度三者任一达标即切歌。
/// velocity / acceleration 均为「沿提交方向」为正。
bool coverSwipeShouldCommit({
  required double progress,
  required double velocity,
  required double acceleration,
  required bool canSwitch,
}) {
  if (!canSwitch) return false;
  if (velocity < -kCoverSwipePullBackVelocity) return false;
  if (progress >= kCoverSwipeCommitProgress) return true;
  if (progress <= kCoverSwipeMinImpulseProgress || velocity <= 0) return false;
  return velocity > kCoverSwipeFlingVelocity ||
      acceleration.abs() > kCoverSwipeAcceleration;
}

/// 甩动强度分档（同时驱动回弹弹簧与翻入过冲）。
enum CoverSwipeReboundStrength { gentle, medium, hard }

CoverSwipeReboundStrength coverSwipeReboundStrength({
  required double velocity,
  required double acceleration,
}) {
  final energy =
      velocity.abs() + kCoverSwipeAccelWeight * acceleration.abs();
  if (energy < 300) return CoverSwipeReboundStrength.gentle;
  if (energy < 1200) return CoverSwipeReboundStrength.medium;
  return CoverSwipeReboundStrength.hard;
}

SpringDescription coverSwipeReboundSpring(CoverSwipeReboundStrength strength) =>
    switch (strength) {
      CoverSwipeReboundStrength.gentle => SpringDescription.withDampingRatio(
          mass: 1.0, stiffness: 120.0, ratio: 1.2),
      CoverSwipeReboundStrength.medium => SpringDescription.withDampingRatio(
          mass: 0.7, stiffness: 220.0, ratio: 0.95),
      CoverSwipeReboundStrength.hard => SpringDescription.withDampingRatio(
          mass: 0.5, stiffness: 380.0, ratio: 0.75),
    };

SpringDescription coverSwipeCommitSpring(CoverSwipeReboundStrength strength) =>
    switch (strength) {
      CoverSwipeReboundStrength.gentle => SpringDescription.withDampingRatio(
          mass: 0.8, stiffness: 180.0, ratio: 1.1),
      CoverSwipeReboundStrength.medium => SpringDescription.withDampingRatio(
          mass: 0.6, stiffness: 260.0, ratio: 1.0),
      CoverSwipeReboundStrength.hard => SpringDescription.withDampingRatio(
          mass: 0.5, stiffness: 360.0, ratio: 0.9),
    };

/// 新封面翻入的过冲幅度：轻放收敛克制、快甩翻过头更多（「回弹力度有区别」）。
double coverSwipeOvershoot(CoverSwipeReboundStrength strength) =>
    switch (strength) {
      CoverSwipeReboundStrength.gentle => 0.65,
      CoverSwipeReboundStrength.medium => 1.0,
      CoverSwipeReboundStrength.hard => 1.35,
    };

/// px/s（沿提交方向）→ t/秒：拖满 pitch 对应 t 增加 kCoverFlipSwap。
double coverSwipeVelocityInClock(double velocityPxPerSec, double pitch) =>
    pitch > 0 ? velocityPxPerSec * kCoverFlipSwap / pitch : 0.0;
