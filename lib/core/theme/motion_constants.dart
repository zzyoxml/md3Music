import 'package:flutter/animation.dart';

/// M3 Expressive Motion 常量
///
/// 参考：https://m3.material.io/styles/motion/easing-and-duration
/// M3 Expressive 强调"直觉性物理动效"——弹簧物理优先于固定 cubic 曲线，
/// 让动画带有自然的过冲和回弹感。
///
/// 使用方式：
/// - `AnimatedSwitcher` 的 `switchInCurve` / `switchOutCurve` 用 `expressiveEasing`
/// - 需要弹簧物理时用 `defaultSpring` 构造 `SpringSimulation`
/// - 强调动画（如 FullPlayer 入场）用 `emphasizedEasing` + `emphasisDuration`
class M3ExpressiveMotion {
  M3ExpressiveMotion._();

  /// 默认弹簧描述：阻尼比 0.825，刚度 180，质量 1
  /// 0.825 < 1.0 产生轻微过冲，符合 M3 Expressive"有生命感"的动效
  static final SpringDescription defaultSpring = SpringDescription.withDampingRatio(
    mass: 1.0,
    stiffness: 180,
    ratio: 0.825,
  );

  /// 默认动画时长 400ms（M3 标准时长，对应 medium duration）
  static const Duration defaultDuration = Duration(milliseconds: 400);

  /// 强调动画时长 600ms（对应 long duration，用于 FullPlayer 入场等）
  static const Duration emphasisDuration = Duration(milliseconds: 600);

  /// Expressive easing：略带过冲的减速曲线
  /// 用于 tab 切换、卡片入场
  static const Curve expressiveEasing = Cubic(0.05, 0.7, 0.1, 1.0);

  /// Emphasized easing：M3 标准 emphasized 缓动
  /// 用于大型状态转换（FullPlayer 展开、对话框入场）
  static const Curve emphasizedEasing = Cubic(0.2, 0.0, 0, 1.0);
}
