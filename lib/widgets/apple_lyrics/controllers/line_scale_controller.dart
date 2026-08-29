import 'package:flutter/widgets.dart';
import 'package:md3music/widgets/apple_lyrics/animation/spring.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_layout.dart';

/// 行缩放动画管理器
///
/// 参照 spec.md "Requirement: 行缩放动画" 与 AMLL 项目 `group.ts:86-106` 实现。
/// 用 [Spring] 驱动单行的 `scale` 值，使当前行与非当前行之间通过弹簧平滑过渡。
///
/// 设计要点：
/// - 当前行 `scale = 1.0`，非当前行 `scale = 0.97`（`enableScale=true` 时）。
/// - 背景行（人声）：当前 `bgScale = 1.0`，非当前 `bgScale = 0.75`。
/// - 主行与背景行使用不同的弹簧参数，背景行更轻更快。
/// - 缩放基准点默认 `left`，对唱行为 `right`（影响视觉缩放方向）。
/// - `enableScale=false` 时所有行 scale 强制为 1.0。
class LineScaleController {
  LineScaleController() {
    _scaleSpring = Spring(
      mass: LyricLayout.scaleSpringMass,
      damping: LyricLayout.scaleSpringDamping,
      stiffness: LyricLayout.scaleSpringStiffness,
      // 初始即为当前行 scale，避免首帧从 0 弹起
      initialPosition: LyricLayout.activeScale,
    );
  }

  /// 行缩放弹簧
  late final Spring _scaleSpring;

  /// 是否为对唱行（影响 transform-origin）
  bool _isDuet = false;

  /// 设置某行是否为当前行
  ///
  /// [isActive] 是否当前行
  /// [isBackground] 是否背景行（人声）
  /// [isDuet] 是否对唱行（影响 transform-origin）
  /// [enableScale] 是否启用缩放（false 时所有行 scale=1.0）
  void setLineState({
    required bool isActive,
    bool isBackground = false,
    bool isDuet = false,
    bool enableScale = true,
  }) {
    // 未启用缩放：所有行保持 1.0
    if (!enableScale) {
      _scaleSpring.setTarget(LyricLayout.activeScale);
      _isDuet = isDuet;
      return;
    }

    if (isBackground) {
      // 背景行弹簧：更轻更快
      _scaleSpring.setParams(
        mass: LyricLayout.bgScaleSpringMass,
        damping: LyricLayout.bgScaleSpringDamping,
        stiffness: LyricLayout.bgScaleSpringStiffness,
      );
      _scaleSpring.setTarget(
        isActive
            ? LyricLayout.backgroundActiveScale
            : LyricLayout.backgroundInactiveScale,
      );
    } else {
      // 主行弹簧
      _scaleSpring.setParams(
        mass: LyricLayout.scaleSpringMass,
        damping: LyricLayout.scaleSpringDamping,
        stiffness: LyricLayout.scaleSpringStiffness,
      );
      _scaleSpring.setTarget(
        isActive ? LyricLayout.activeScale : LyricLayout.inactiveScale,
      );
    }

    _isDuet = isDuet;
  }

  /// 推进动画
  ///
  /// 返回是否需要重绘（即是否仍在运动中）
  bool tick(double dt) {
    _scaleSpring.tick(dt);
    return !_scaleSpring.isSettled;
  }

  /// 当前行缩放
  double get currentScale => _scaleSpring.position;

  /// 缩放基准点（对唱行为 right，其他为 left）
  Alignment get scaleOrigin =>
      _isDuet ? LyricLayout.scaleOriginDuet : LyricLayout.scaleOrigin;

  /// 是否在动画中
  bool get isAnimating => !_scaleSpring.isSettled;

  /// v3 优化：弹簧是否已收敛到目标（位移/速度/加速度都 < 0.01）。
  /// 用于 AppleLyricsView 判断是否可以停止 Ticker。
  bool get isConverged => _scaleSpring.isSettled;

  /// 重置：弹簧回到 1.0
  void reset() {
    _scaleSpring.setPosition(LyricLayout.activeScale, 0);
  }
}
