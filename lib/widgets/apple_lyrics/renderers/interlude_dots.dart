library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../layout/lyric_layout.dart';

/// 间奏点动画组件（严格照搬 AMLL 原版实现）。
///
/// 参考：https://github.com/amll-dev/applemusic-like-lyrics
/// packages/core/src/lyric-player/dom/interlude-dots.ts
///
/// AMLL 动画规则：
/// - **整体呼吸缩放**（持续整个间奏）：
///   `scale = 1 + sin(1.5π - currentDuration/breatheDuration * 2) / 20`
///   breatheDuration = interludeDuration / ceil(interludeDuration / 1500)
///   即间奏时长被分成若干个 1500ms 周期，整体微幅缩放
///
/// - **入场缩放**（前 2000ms）：
///   `scale *= easeOutExpo(currentDuration / 2000)`
///   easeOutExpo: `x == 1 ? 1 : 1 - 2^(-10*x)`
///
/// - **globalOpacity**：
///   - 前 500ms：0（全黑不可见）
///   - 500-1000ms：线性 0 → 1
///   - 1000ms ~ end-375ms：1
///   - end-375ms ~ end：线性 1 → 0
///
/// - **3 个点逐个亮起**（dotsDuration = interludeDuration - 750）：
///   - dot0: 0.25 → 1.0，从 0 开始线性
///   - dot1: 0.25 → 1.0，从 dotsDuration/3 开始
///   - dot2: 0.25 → 1.0，从 dotsDuration*2/3 开始
///   未亮时 alpha=0.25（基础暗态），亮起过程线性 0.25 → 1.0
///
/// - **消失缩放**（最后 750ms）：
///   `scale *= 1 - easeInOutBack((750 - remaining) / 750 / 2)`
///   easeInOutBack 带 overshoot 回弹效果
///
/// - **最终缩放系数**：`scale *= 0.7`（点比基准尺寸小一些）
class InterludeDots {
  InterludeDots();

  // ============== 时长参数（ms）==============
  /// AMLL 标准呼吸周期（ms）
  static const int _targetBreatheDuration = 1500;

  /// 入场缩放时长（ms）—— easeOutBack 超出回弹
  static const int _enterScaleMs = 400;

  /// globalOpacity 前 N ms 全黑
  static const int _opacityHideMs = 0;

  /// globalOpacity 渐显时长（ms）
  static const int _opacityFadeMs = 200;

  /// 消失缩放时长（ms）—— easeOutBack 带回弹
  static const int _exitScaleMs = 750;

  /// globalOpacity 渐隐时长（ms）
  static const int _opacityFadeOutMs = 400;

  /// 3 个点的相位错开角度（弧度）：0, 2π/3, 4π/3。
  static final List<double> dotPhases = [
    0.0,
    2 * math.pi / 3,
    4 * math.pi / 3,
  ];

  /// 间奏阈值：相邻行间隔 >= 此值才显示间奏点。
  static const int thresholdMs = LyricLayout.interludeThresholdMs;

  // ============== 状态 ==============

  int? _startTime;
  int? _endTime;

  /// 内部动画时钟（ms）—— 由 tick(dt) 推进，不受 positionStream 5fps 限制
  ///
  /// **关键**：动画时间用 Ticker 帧时钟（60fps），不用播放时间 currentTimeMs。
  /// 当 setInterlude 设置新间奏时，_animationTimeMs 重置为 0。
  /// 每帧 tick(dt) 时 `_animationTimeMs += dt * 1000`。
  double _animationTimeMs = 0;

  /// 当前是否处于间奏时段（由外部 _updateInterlude 设置）。
  bool _isActive = false;

  // ============== Getter ==============

  int? get startTime => _startTime;
  int? get endTime => _endTime;

  /// 当前动画时钟（毫秒）。仅测试断言用，非热路径。
  @visibleForTesting
  double get animationTimeMs => _animationTimeMs;

  /// 当前是否需要绘制（间奏激活时）。
  bool get shouldRender => _isActive;

  // ============== 状态设置 ==============

  /// 设置当前间奏时段。
  ///
  /// **重要**：本方法会被外部每帧调用，必须用"相同间奏不重置"保护。
  /// 只有切换到新间奏（startTime/endTime 变化）或从无到有才更新状态。
  /// 传 null 表示清除间奏。
  ///
  /// [forceReset] 为 true 时即使间奏与当前相同也重置动画时钟。
  /// 用于 seek/跳转回退到同一间奏窗口的场景：幂等保护无法区分
  /// "每帧重复调用"与"时间回跳"，若不重置，动画时钟从旧进度继续，
  /// 一旦超过间奏总时长，[paintAtLineY] 会直接 return 导致圆点隐藏。
  void setInterlude(int? startTime, int? endTime, {bool forceReset = false}) {
    if (startTime == null || endTime == null) {
      _isActive = false;
      _startTime = null;
      _endTime = null;
      _animationTimeMs = 0;
      return;
    }
    // 相同间奏不重置（保持 _animationTimeMs 等状态，避免每帧重置）
    if (!forceReset &&
        _startTime == startTime && _endTime == endTime && _isActive) {
      return;
    }
    _startTime = startTime;
    _endTime = endTime;
    _isActive = true;
    // 新间奏开始，重置动画时钟
    _animationTimeMs = 0;
  }

  void clear() {
    _startTime = null;
    _endTime = null;
    _animationTimeMs = 0;
    _isActive = false;
  }

  // ============== 时间推进 ==============

  /// 推进动画时钟（由 _onTick 每帧调用，基于 Ticker elapsed）。
  ///
  /// **关键**：用 dt（帧间隔秒）推进内部时钟，不用 currentTimeMs。
  /// 这样动画始终 60fps 流畅，不受 positionStream 5fps 限制。
  void tick(double dt) {
    if (!_isActive) return;
    _animationTimeMs += dt * 1000;
  }

  /// 将动画时钟对齐到真实播放位置（毫秒，绝对时间）。
  ///
  /// 用于 Ticker 被 mute（TabBarView 切走 / App 退后台）后恢复：
  /// 动画时钟由帧 dt 累积，mute 期间帧回调冻结而歌曲继续播放，
  /// 需重新对齐到当前间奏窗口内的偏移（`currentTimeMs - start`，
  /// clamp 到 [0, 间奏时长]），避免"跟不上进度"（如滞后到间奏
  /// 后期才显示，或已过消失动画阶段被 [paintAtLineY] 隐藏）。
  void alignToRealTime(int currentTimeMs) {
    final start = _startTime;
    final end = _endTime;
    if (!_isActive || start == null || end == null) return;
    final int offset = (currentTimeMs - start).clamp(0, end - start);
    _animationTimeMs = offset.toDouble();
  }

  /// 判断帧时钟是否滞后于真实窗口进度超过 [driftMs]。
  ///
  /// 帧时钟由 dt 累积：Ticker 被 mute（切走 tab / 退后台）或页面重建
  /// （TabBarView 默认销毁 State）期间不推进，而歌曲继续播放 → 真实窗口
  /// 偏移 `currentTimeMs - start` 会远超帧时钟。返回 true 表示需要
  /// [alignToRealTime] 校正。
  /// 正常播放下两者偏差不超过 position 更新粒度（约 200ms），不会误触发。
  bool shouldRealignTo(int currentTimeMs, {int driftMs = 1000}) {
    final start = _startTime;
    final end = _endTime;
    if (!_isActive || start == null || end == null) return false;
    final int realOffset = (currentTimeMs - start).clamp(0, end - start);
    return (_animationTimeMs - realOffset).abs() > driftMs;
  }

  bool isInterlude(int currentTimeMs) {
    final start = _startTime;
    final end = _endTime;
    if (start == null || end == null) return false;
    return currentTimeMs >= start && currentTimeMs < end;
  }

  // ============== 缓动函数 ==============

  /// easeOutBack（带超出回弹）
  /// 公式：1 + c3 * (x-1)^3 + c1 * (x-1)^2，c1=1.70158, c3=c1+1=2.70158
  /// x=0 → 0, x=1 → 1, 中间会超出 1 再回弹到 1
  static double _easeOutBack(double x) {
    if (x <= 0.0) return 0.0;
    if (x >= 1.0) return 1.0;
    const double c1 = 1.70158;
    const double c3 = c1 + 1.0;
    final double t = x - 1.0;
    return 1.0 + c3 * t * t * t + c1 * t * t;
  }

  /// easeInBack（带负 overshoot）
  /// 公式：c3 * x^3 - c1 * x^2，c1=1.70158, c3=c1+1=2.70158
  /// x=0 → 0, x=1 → 1, 中间会先变负（低于 0）再上升到 1
  /// 用于消失动画：1 - easeInBack(t) 中间会 >1（先放大），t=1 时 → 0
  static double _easeInBack(double x) {
    if (x <= 0.0) return 0.0;
    if (x >= 1.0) return 1.0;
    const double c1 = 1.70158;
    const double c3 = c1 + 1.0;
    return c3 * x * x * x - c1 * x * x;
  }

  /// clamp01
  static double _clamp01(double x) => x.clamp(0.0, 1.0).toDouble();

  /// clamp(value, min, max)
  static double _clamp(double min, double value, double max) {
    if (value < min) return min;
    if (value > max) return max;
    return value;
  }

  /// clampPositive（>=0）
  static double _clampPositive(double x) => x < 0 ? 0 : x;

  // ============== 绘制 ==============

  /// 绘制 3 个间奏点（整体缩放版）。
  ///
  /// 动画时间线（用户确认版本）：
  /// - 入场：前 400ms easeOutBack scale 0→1（带超出回弹）
  /// - 全程：呼吸缩放（微幅 sin 波动）
  /// - 消失：最后 750ms easeInBack scale 1→0（先放大 10% 再缩小到 0）
  /// - opacity：前 200ms 渐显，最后 400ms 渐隐
  /// - 3 点错开亮起：dotsDuration = interludeDuration - 750
  ///
  /// **整体缩放**：以第 2 个点圆心为中心，用 canvas.save() + translate + scale
  /// 实现整体缩放，3 个点作为整体放大/缩小，而非各自独立缩放。
  ///
  /// [startX]：左对齐起点（与歌词 startX 一致）
  /// [centerY]：占位区域的中心 y 坐标
  /// [dotRadius]：单点基准半径
  /// [spacing]：点间距（点圆心到圆心）
  /// [colorValue]：ARGB 颜色值，默认纯白；传入当前行动态色时间奏点跟随歌词高亮色
  void paintAtLineY(
    Canvas canvas,
    double startX,
    double centerY, {
    double dotRadius = 4,
    double spacing = 16,
    int colorValue = 0xFFFFFFFF,
  }) {
    if (!_isActive) return;
    final start = _startTime;
    final end = _endTime;
    if (start == null || end == null) return;

    final int interludeDuration = end - start;
    final double currentDuration = _animationTimeMs;

    // 超过间奏时段，不绘制
    if (currentDuration > interludeDuration) return;

    // ===== 1. 整体呼吸缩放（微幅 sin 波动）=====
    final int breatheDuration = (interludeDuration ~/
            math.max(1, (interludeDuration / _targetBreatheDuration).ceil()))
        .clamp(1, interludeDuration);
    double scale = 1.0 +
        math.sin(1.5 * math.pi -
                (currentDuration / breatheDuration) * 2) /
            20;

    // ===== 2. 入场缩放（前 400ms easeOutBack 超出回弹）=====
    if (currentDuration < _enterScaleMs) {
      scale *= _easeOutBack(currentDuration / _enterScaleMs);
    }

    // ===== 3. globalOpacity（前 200ms 渐显）=====
    double globalOpacity = 1.0;
    if (currentDuration < _opacityHideMs) {
      globalOpacity = 0;
    } else if (currentDuration < _opacityFadeMs) {
      globalOpacity *= (currentDuration - _opacityHideMs) /
          (_opacityFadeMs - _opacityHideMs);
    }

    // ===== 4. 消失缩放（最后 750ms：先稍微放大再缩小到 0）=====
    // 用 1 - easeInBack(t)：
    // - t=0：1（保持原 scale）
    // - t=0.5：1 - (-0.1) = 1.1（放大 10%）
    // - t=1：1 - 1 = 0（完全消失）
    final double remaining = interludeDuration - currentDuration;
    if (remaining < _exitScaleMs) {
      final double t = (_exitScaleMs - remaining) / _exitScaleMs;
      scale *= 1.0 - _easeInBack(t);
    }

    // ===== 5. globalOpacity 渐隐（最后 400ms）=====
    if (remaining < _opacityFadeOutMs) {
      globalOpacity *= _clamp01(remaining / _opacityFadeOutMs);
    }

    // ===== 6. 3 个点逐个亮起 =====
    final double dotsDuration =
        _clampPositive((interludeDuration - _exitScaleMs).toDouble());

    scale = _clampPositive(scale);
    if (scale <= 0 || globalOpacity <= 0) return;

    // ===== 整体缩放：以第 2 个点圆心为中心 =====
    // 3 个点的相对位置（相对第 2 个点圆心）：
    //   dot0: (-spacing, 0)
    //   dot1: (0, 0)  ← 中心
    //   dot2: (+spacing, 0)
    // 第 2 个点圆心绝对位置：startX + spacing + dotRadius（左对齐 + 1 间距 + 半径）
    final double centerX = startX + spacing + dotRadius;
    final double centerY2 = centerY;

    canvas.save();
    canvas.translate(centerX, centerY2);
    canvas.scale(scale);

    for (int i = 0; i < 3; i++) {
      // dot0: currentDuration * 3 / dotsDuration * 0.75 + 0.25 (clamp 0.25~1)
      // dot1: (currentDuration - dotsDuration/3) * 3 / dotsDuration * 0.75 + 0.25
      // dot2: (currentDuration - dotsDuration*2/3) * 3 / dotsDuration * 0.75 + 0.25
      final double offset = i * dotsDuration / 3;
      final double t = (currentDuration - offset) * 3 / dotsDuration;
      final double dotAlpha = _clamp(0.25, t * 0.75 + 0.25, 1.0);
      final double alpha = _clamp01(globalOpacity * dotAlpha);

      if (alpha <= 0) continue;

      // 相对中心点的 x 偏移：-spacing, 0, +spacing
      final double dx = (i - 1) * spacing;
      final double dy = 0.0;
      // 颜色跟随传入的 colorValue（默认基础歌词色，动态色开启时跟随当前行高亮色）
      final paint = Paint()
        ..style = PaintingStyle.fill
        ..color = Color.fromRGBO(
          (colorValue >> 16) & 0xFF,
          (colorValue >> 8) & 0xFF,
          colorValue & 0xFF,
          alpha,
        );
      canvas.drawCircle(Offset(dx, dy), dotRadius, paint);
    }

    canvas.restore();
  }

  /// 兼容旧接口 [paint]，转发到 [paintAtLineY]。
  void paint(
    Canvas canvas,
    Offset center,
    double radius,
    double dotRadius,
  ) {
    paintAtLineY(
      canvas,
      center.dx,
      center.dy,
      dotRadius: dotRadius,
      spacing: radius,
    );
  }
}
