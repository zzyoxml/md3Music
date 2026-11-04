import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'player_cover_morph.dart';

/// 封面投影强度（0 = 关闭）。进程内唯一来源：设置页写、播放页读，
/// 启动时由 `app.dart` 从 [SettingsRepository] 载入。
final ValueNotifier<double> kCoverShadowIntensity = ValueNotifier<double>(0.7);

/// 全屏播放器封面的投影：MD3 与 AM 两版共用一份口径。
///
/// 两层阴影（贴边的「硬影」+ 大范围弥散的「环境影」）才出得来层次：单层要么
/// 像一圈脏边，要么糊成一片没有形状。圆角默认取 [kCoverMorphFullRadius]（封面
/// `ClipRRect` 用的同一个值）—— 阴影轮廓一旦比封面圆角更方，四角就会露出一圈
/// 暗边，看着像封面自带边框；封面形变层会改传插值中的局部圆角，让阴影轮廓
/// 与飞行中封面的裁剪轮廓逐帧一致。
///
/// 模糊/位移/内缩全部按**封面边长取比例**并夹在上下限：同一档投影要同时服务
/// 窄横屏 ~82dp 与平板展开 ~464dp 的封面，写死数值必然在一端几乎没有、另一端糊团。
///
/// 强度 [kCoverShadowIntensity] 由设置页调节：它只缩放浓度与位移，不改圆角来源。
class PlayerCoverShadow {
  const PlayerCoverShadow._();

  /// 默认强度（设置项缺省值，与 [kCoverShadowIntensity] 初始值一致）。
  static const double defaultIntensity = 0.7;

  /// 强度上下限：0 直接不画投影。
  static const double minIntensity = 0.0;
  static const double maxIntensity = 1.0;

  /// 「硬影」浓度上限：叠在封面上缘内侧，撑出实体感。
  static const double _keyAlpha = 0.45;

  /// 「环境影」浓度上限：大范围弥散，撑出悬浮感。
  static const double _ambientAlpha = 0.28;

  /// 订阅 [kCoverShadowIntensity] 并按当前封面边长画投影。
  ///
  /// 用法是包住封面裁剪层（`ClipRRect`）：`BoxShadow` 纯绘制不参与布局，封面各处
  /// 的几何（正方形判定、与曲名同轴、形变层交接矩形）都不受影响。
  /// 注意祖先 `Stack` 默认会裁到布局盒，投影画在盒外会被裁掉，宿主需给
  /// `clipBehavior: Clip.none`（两个播放页的长按包装层已这么写）。
  ///
  /// [shadowColor] 由宿主传 `colorScheme.shadow` 而非在这里 `Theme.of`：两个播放页
  /// 用的 [ColorScheme] 是 `material_ui` 的同名类，与 flutter/material 的是两个不同
  /// 类型（`Color` 才是两边共通的）。
  static Widget wrap({
    required Color shadowColor,
    required Widget child,
  }) {
    return ValueListenableBuilder<double>(
      valueListenable: kCoverShadowIntensity,
      builder: (context, intensity, cached) {
        if (intensity <= minIntensity) return cached!;
        return LayoutBuilder(
          builder: (context, constraints) => DecoratedBox(
            decoration: decoration(
              shadowColor: shadowColor,
              side: _shortestSide(constraints),
              intensity: intensity,
            ),
            child: child,
          ),
        );
      },
      child: child,
    );
  }

  static BoxDecoration decoration({
    required Color shadowColor,
    required double side,
    double intensity = defaultIntensity,
    double? radius,
  }) {
    final t = intensity.clamp(minIntensity, maxIntensity);
    return BoxDecoration(
      borderRadius: BorderRadius.circular(radius ?? kCoverMorphFullRadius),
      boxShadow: [
        // 硬影：紧贴轮廓、向下偏移，负责「这块封面是个实体」
        BoxShadow(
          color: shadowColor.withValues(alpha: _keyAlpha * t),
          blurRadius: _clamped(side * 0.09, 8.0, 30.0),
          offset: Offset(0, _clamped(side * 0.06 * t, 3.0, 22.0)),
          // 负扩散：先把阴影往里收再模糊，否则它会在封面轮廓外匀出一圈灰边
          spreadRadius: -_clamped(side * 0.02, 1.0, 8.0),
        ),
        // 环境影：不偏移、大范围弥散、同样内收，负责「它浮在背景之上」
        BoxShadow(
          color: shadowColor.withValues(alpha: _ambientAlpha * t),
          blurRadius: _clamped(side * 0.22, 16.0, 60.0),
          spreadRadius: -_clamped(side * 0.05, 2.0, 12.0),
        ),
      ],
    );
  }

  /// 封面恒为正方形，取两轴里小的那个；非有限约束（无限宽/高）时退回另一轴。
  static double _shortestSide(BoxConstraints constraints) {
    final width = constraints.maxWidth;
    final height = constraints.maxHeight;
    if (width.isFinite && height.isFinite) return math.min(width, height);
    if (width.isFinite) return width;
    if (height.isFinite) return height;
    return 200.0;
  }

  static double _clamped(double value, double min, double max) =>
      value.isFinite ? value.clamp(min, max) : min;
}
