import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

/// 波往哪走。
enum DistortionWaveType {
  /// 从底部一个宽的源（按钮）往上：先贴着按钮轮廓，再张成弧线；跟着手指偏。
  vertical,

  /// 竖向那种转个身：从左边一个高的源（边缘、侧栏）往右。
  horizontal,

  /// 从圆形源（图标、头像）中心一圈圈扩散；源本身不动、不糊、不上色，可以原地变形。
  center,
}

@immutable
class DistortionWaveEasing extends Curve {
  const DistortionWaveEasing(this.x1, this.y1, this.x2, this.y2);

  final double x1;
  final double y1;
  final double x2;
  final double y2;

  /// [x] 时刻（0–1）的缓动值；区间外夹到 0 和 1。
  double call(double x) {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    // x 随曲线参数单调增长，二分总能找到它。
    var low = 0.0;
    var high = 1.0;
    for (var i = 0; i < 24; i++) {
      final s = (low + high) / 2;
      if (_bezier(s, x1, x2) < x) {
        low = s;
      } else {
        high = s;
      }
    }
    return _bezier((low + high) / 2, y1, y2);
  }

  /// 反函数：缓动值为 [y]（0–1）时的自变量 x。
  ///
  /// 用在回程上：想让波前的行程（内部又过了一遍缓动）随时间**匀速**回撤，
  /// 就得先反解出这一时刻该喂给波前的进度，否则路由层与波前两层缓动相乘，
  /// 行程被压进前 1/4 —— 画面秒切完，光效还在后面空转（真机踩过）。
  double inverse(double y) {
    if (y <= 0) return 0;
    if (y >= 1) return 1;
    var low = 0.0;
    var high = 1.0;
    for (var i = 0; i < 24; i++) {
      final x = (low + high) / 2;
      if (call(x) < y) {
        low = x;
      } else {
        high = x;
      }
    }
    return (low + high) / 2;
  }

  @override
  double transformInternal(double t) => call(t);

  static double _bezier(double s, double a, double b) {
    final r = 1 - s;
    return 3 * r * r * s * a + 3 * r * s * s * b + s * s * s;
  }

  @override
  bool operator ==(Object other) =>
      other is DistortionWaveEasing && other.x1 == x1 && other.y1 == y1 && other.x2 == x2 && other.y2 == y2;

  @override
  int get hashCode => Object.hash(x1, y1, x2, y2);
}

/// 波的配色：沿波前和边缘流动的几种颜色，加波前前方、后方各一道色边。
///
/// 着色器最多用前 8 种颜色。
@immutable
class DistortionWavePalette {
  const DistortionWavePalette({required this.colors, required this.ahead, required this.behind});

  /// 跟主题走：主色相和左右邻近色相，饱和度压低，浅色 / 深色各一档明度。
  factory DistortionWavePalette.fromScheme(ColorScheme scheme) {
    final light = scheme.brightness == Brightness.light;
    final base = HSLColor.fromColor(scheme.primary);
    // 灰色主题也留一点颜色；太艳的主题按下去。
    final sat = (base.saturation * 0.62).clamp(0.28, 0.5);
    final l = light ? 0.64 : 0.7;
    Color tone(double shift, double s, double lightness) =>
        HSLColor.fromAHSL(1, (base.hue + shift) % 360, s.clamp(0.0, 1.0), lightness.clamp(0.0, 1.0)).toColor();
    return DistortionWavePalette(
      colors: [
        tone(-30, sat * 0.9, l + 0.06),
        tone(14, sat, l - 0.04),
        tone(-8, sat * 1.1, l - 0.08),
        tone(32, sat * 0.85, l + 0.05),
        tone(-18, sat, l),
        tone(6, sat * 0.9, l + 0.08),
        tone(24, sat * 1.05, l - 0.03),
      ],
      ahead: tone(-22, sat * 0.8, l + 0.12),
      behind: tone(20, sat * 1.05, l - 0.12),
    );
  }

  final List<Color> colors;

  /// 波前前方的色边。
  final Color ahead;

  /// 波前后方的色边。
  final Color behind;

  /// 原作的彩色：粉色前边，蓝色后边。
  static const colorful = DistortionWavePalette(
    colors: [
      Color(0xFFFFC915),
      Color(0xFF7EC4FF),
      Color(0xFFB428E6),
      Color(0xFFEB64A0),
      Color(0xFFFFB07A),
      Color(0xFF9AA0FF),
      Color(0xFF7FD9EE),
    ],
    ahead: Color(0xFFFF7AB6),
    behind: Color(0xFF5ABEFF),
  );

  /// 只用绿色，从成功徽标的 #35BA00 到青柠和薄荷。
  static const green = DistortionWavePalette(
    colors: [
      Color(0xFF35BA00),
      Color(0xFF8CEB5A),
      Color(0xFF00C46E),
      Color(0xFFBEFA82),
      Color(0xFF28A03C),
      Color(0xFF6EE1A0),
      Color(0xFF5AD228),
    ],
    ahead: Color(0xFFC4FF78),
    behind: Color(0xFF009646),
  );

  /// 蓝和青。
  static const ocean = DistortionWavePalette(
    colors: [
      Color(0xFF2878FF),
      Color(0xFF5AC8FF),
      Color(0xFF1450C8),
      Color(0xFF78E6F0),
      Color(0xFF3C96FF),
      Color(0xFF96B4FF),
      Color(0xFF00B4DC),
    ],
    ahead: Color(0xFF96E6FF),
    behind: Color(0xFF1E46DC),
  );

  /// 橙、粉、洋红。
  static const sunset = DistortionWavePalette(
    colors: [
      Color(0xFFFF8C3C),
      Color(0xFFFF5A78),
      Color(0xFFFFC850),
      Color(0xFFF0465A),
      Color(0xFFFFAA78),
      Color(0xFFDC5AC8),
      Color(0xFFFF7850),
    ],
    ahead: Color(0xFFFFDC78),
    behind: Color(0xFFC83CA0),
  );

  /// 白和银。
  static const mono = DistortionWavePalette(
    colors: [
      Color(0xFFF0F0F5),
      Color(0xFFC8CDD7),
      Color(0xFFFFFFFF),
      Color(0xFFAAAFBE),
      Color(0xFFE1E4EB),
      Color(0xFFBEC3CD),
      Color(0xFFF5F5FA),
    ],
    ahead: Color(0xFFFFFFFF),
    behind: Color(0xFFA0A5B4),
  );

  /// 单色：前方浅一些，后方深一些。
  factory DistortionWavePalette.single(Color color) {
    const white = Color(0xFFFFFFFF);
    const black = Color(0xFF000000);
    return DistortionWavePalette(
      colors: [color, Color.lerp(color, white, 0.25)!, color, Color.lerp(color, black, 0.15)!],
      ahead: Color.lerp(color, white, 0.45)!,
      behind: Color.lerp(color, black, 0.3)!,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DistortionWavePalette &&
      other.ahead == ahead &&
      other.behind == behind &&
      listEquals(other.colors, colors);

  @override
  int get hashCode => Object.hash(ahead, behind, Object.hashAll(colors));
}

/// sRGB → OKLab，着色器就在这个空间里混色。
List<double> waveOklab(Color color) {
  double linear(double c) => c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  double cbrt(double v) => v < 0 ? -math.pow(-v, 1 / 3).toDouble() : math.pow(v, 1 / 3).toDouble();
  final lr = linear(color.r);
  final lg = linear(color.g);
  final lb = linear(color.b);
  final l = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb);
  final m = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb);
  final s = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb);
  return [
    0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
  ];
}

/// 一道扭曲波的样子和节奏。从三种类型调好的默认值（[vertical]、[horizontal]、
/// [center]）出发，用 `copyWith` 改需要的。
///
/// 长度单位都是逻辑像素，时间单位是秒。[palette] 留空就跟主题走
/// （[DistortionWavePalette.fromScheme]）。
@immutable
class DistortionWaveStyle {
  const DistortionWaveStyle._({
    required this.type,
    this.anticipation = 0.5,
    this.travel = 2.28,
    this.launchGap = 0,
    this.linger = -0.35,
    this.rimFade = 3.03,
    this.rimEasing = const DistortionWaveEasing(0.42, 0, 0.58, 1),
    this.returnSpeed = 1.45,
    this.easing = const DistortionWaveEasing(0.22, 1, 0.36, 1),
    this.pull = 24,
    this.inhale = 56,
    this.gatherGlow = 0.33,
    this.gatherDots = 1,
    this.amplitude = 34,
    this.lensWidth = 150,
    this.aberration = 0.78,
    this.swell = 22,
    this.blur = 18,
    this.blurAhead = 90,
    this.blurBehind = 240,
    this.lead = 130,
    this.tail = 300,
    this.strength = 0.92,
    this.rimWidth = 14,
    this.rimUnevenness = 1,
    this.rimStrength = 0.82,
    this.rimSoftness = 343,
    this.cornerRadius = 62,
    this.rimPulse = 0.6,
    this.hairlineWidth = 1.5,
    this.hairlineOpacity = 0.9,
    this.hairlineWhite = 0.95,
    this.hairlineLinger = 0.47,
    this.hairlineFade = 3,
    this.orientation = 0.91,
    this.particleCount = 64,
    this.particleSize = 1.8,
    this.particleReach = 150,
    this.particleFlight = 30,
    this.particleGap = 24,
    this.particleLife = 2.19,
    this.particleSpread = 1,
    this.palette,
  });

  /// 波边缘 SDF 圆角按设备屏幕 R 角取值（取四角中的**最大**半径）。
  ///
  /// 为什么要按设备值：[screenCenter] 预设的 62 是手机屏圆角量级，pad 的方角屏 /
  /// 小圆角机型沿用会四角光效与屏边脱节（真机反馈）。
  ///
  /// dx ≠ dy 的椭圆角取较大者：取小会让该角的光效提前拐弯。**未上报与方角
  /// 同为 0**：Android < 12 / 厂商未实现时四角不报值，与方角屏返回的全零无法区分 ——
  /// 沿播放页展开面板（player_panel_frame.dart 的终点口径）与 MiniPlayer 避让
  /// 同一条路：把「没值」当方角处理。
  static double maxCornerRadiusOf(BorderRadius? radii) {
    if (radii == null) return 0.0;
    return [
      radii.topLeft,
      radii.topRight,
      radii.bottomRight,
      radii.bottomLeft,
    ].map((c) => math.max(c.x, c.y)).fold<double>(0.0, math.max);
  }

  /// 从底部按钮往上，整屏，原作调好的默认值。
  static const vertical = DistortionWaveStyle._(type: DistortionWaveType.vertical);

  /// 从左边高的源往右。
  static const horizontal = DistortionWaveStyle._(type: DistortionWaveType.horizontal);

  /// 从头像或图标扩散，按约 500 高的面板或卡片调的：圈走得慢些，只在出发前收一下，
  /// 颜色轻一些，没有色散（会把白色拆成红蓝），小点留在画面里。
  static const center = DistortionWaveStyle._(
    type: DistortionWaveType.center,
    anticipation: 0.25,
    travel: 3.43,
    rimFade: 2.51,
    hairlineLinger: 0.96,
    strength: 0.6,
    rimStrength: 0.6,
    aberration: 0,
    gatherGlow: 0,
    gatherDots: 0,
    particleCount: 89,
    particleLife: 3.93,
    particleSpread: 0.64,
    cornerRadius: 48,
    // 面板大约是屏幕的六成高，长度也跟着缩。
    pull: 14.4,
    inhale: 33.6,
    amplitude: 20.4,
    lensWidth: 90,
    swell: 13.2,
    blur: 10.8,
    blurAhead: 54,
    blurBehind: 144,
    lead: 78,
    tail: 180,
    rimSoftness: 205.8,
    particleReach: 90,
    particleFlight: 18,
    particleGap: 11,
  );

  /// 从屏幕角落的图标扩散的整屏版本：[center] 的几何 + [vertical] 的尺度。
  ///
  /// [center] 是按约 500 高的面板调的 —— 长度只有整屏的六成，节奏也慢，直接铺满
  /// 手机屏会显得又小又拖。这里把长度换成 [vertical] 的整屏值，节奏收到 2.4s：
  /// 波前约 2.1s 扫完整屏，之后只剩边缘色和细线在淡。
  static final screenCenter = center.copyWith(
    anticipation: 0.3,
    travel: 2.0,
    linger: -0.3,
    rimFade: 2.0,
    hairlineLinger: 0.4,
    hairlineFade: 2.0,
    particleLife: 2.0,
    particleSpread: 0.8,
    gatherGlow: 0.3,
    gatherDots: 1,
    pull: 24,
    inhale: 56,
    amplitude: 34,
    lensWidth: 150,
    // 中心向外扩散时色散会把白色拆成红蓝，原作这一型干脆关掉；这里只留一点点。
    aberration: 0.3,
    swell: 22,
    blur: 18,
    blurAhead: 90,
    blurBehind: 240,
    lead: 130,
    tail: 300,
    strength: 0.8,
    rimWidth: 14,
    rimSoftness: 343,
    rimStrength: 0.8,
    cornerRadius: 62,
    particleReach: 150,
    particleFlight: 30,
    particleGap: 24,
  );

  /// [type] 调好的默认值。
  static DistortionWaveStyle of(DistortionWaveType type) => switch (type) {
    DistortionWaveType.vertical => vertical,
    DistortionWaveType.horizontal => horizontal,
    DistortionWaveType.center => center,
  };

  final DistortionWaveType type;

  // ── 节奏 ──

  /// 出发前把一切往源头拉的秒数。
  final double anticipation;

  /// 从离开源到波前停稳的秒数。
  final double travel;

  /// 波前从源轮廓往外多远起步。
  final double launchGap;

  /// 离开源后多少秒开始擦掉边缘的颜色；负数是提前，紧跟着波前。
  final double linger;

  /// 边缘颜色擦掉要多少秒。
  final double rimFade;

  /// 擦边缘颜色的缓动：慢起慢停。
  final DistortionWaveEasing rimEasing;

  /// 收回比展开快多少倍。
  final double returnSpeed;

  /// 波前在 [travel] 里怎么走：全速离开源，在屏幕另一头轻轻停下。
  final DistortionWaveEasing easing;

  // ── 重力 ──

  /// 出发前把内容往源头拉多远。
  final double pull;

  /// 落到源上的那圈颜色从多远开始。
  final double inhale;

  /// 出发前颜色多浓，0–2：1 到出发时攒到一半，2 攒满；0 出发前不上色。
  final double gatherGlow;

  /// 出发前往源跳的小点多明显，0–1。
  final double gatherDots;

  // ── 鼓包 ──

  /// 鼓包经过时把内容抬多高。
  final double amplitude;

  /// 鼓包的宽度。
  final double lensWidth;

  /// 红蓝分开的程度，按内容被挪动的距离算：没挪动的地方颜色不分开。
  final double aberration;

  /// 波前沿长度方向弯多少。
  final double swell;

  // ── 渐进模糊 ──

  /// 波前上的模糊半径。
  final double blur;

  /// 模糊在波前前方多远内聚起。
  final double blurAhead;

  /// 模糊在波前后方多远内散开。
  final double blurBehind;

  // ── 波前上的颜色 ──

  /// 颜色在波前前方羽化多远。
  final double lead;

  /// 颜色拖在波前后面多长。
  final double tail;

  /// 颜色最浓时的不透明度。
  final double strength;

  // ── 边缘的颜色 ──

  /// 边缘颜色往里伸多远。
  final double rimWidth;

  /// 边缘颜色厚薄多不均，0–2。
  final double rimUnevenness;

  /// 边缘颜色最浓时的不透明度。
  final double rimStrength;

  /// 边缘颜色擦除的软边。
  final double rimSoftness;

  /// 波铺满的那块区域的圆角（屏幕的，或面板的），边缘颜色和细线顺着它走。
  final double cornerRadius;

  /// 边缘颜色有多"活"，0–1：团块漂移呼吸、亮光绕边跑、颜色流动。
  final double rimPulse;

  /// 贴着边的细线宽度；0 不画。
  final double hairlineWidth;

  /// 细线最浓时的不透明度。
  final double hairlineOpacity;

  /// 亮光经过处细线发白的程度。
  final double hairlineWhite;

  /// 边缘颜色开始擦掉后，细线再多留几秒。
  final double hairlineLinger;

  /// 细线擦掉要多少秒。
  final double hairlineFade;

  // ── 触摸 ──

  /// 跟着按下的位置偏多少，0–1；center 类型不偏。
  final double orientation;

  // ── 小点 ──

  /// 小点个数。
  final int particleCount;

  /// 最大的小点直径。
  final double particleSize;

  /// 出发前最远的小点在源外多远出生。
  final double particleReach;

  /// 每跳往源飞多远。
  final double particleFlight;

  /// 小点淡出前离源最近多远。
  final double particleGap;

  /// 出发后多少秒内最后一个小点淡出。
  final double particleLife;

  /// 小点被甩多远，按波前走的路程算，0–1。
  final double particleSpread;

  // ── 配色 ──

  /// 沿波前和边缘流动的颜色；null 跟主题。
  final DistortionWavePalette? palette;

  /// 整个过程的秒数：到这时鼓包停了、边缘清了、最后一个小点也灭了。
  ///
  /// 注意它必须不短于 `anticipation + travel`，否则波前走到一半就被路由收掉。
  double get duration =>
      anticipation +
      math.max(
        math.max(travel * 0.6, linger + rimFade),
        math.max(linger + hairlineLinger + hairlineFade, particleLife),
      );

  /// [palette]，没给就从 [scheme] 取。
  DistortionWavePalette paletteFor(ColorScheme scheme) => palette ?? DistortionWavePalette.fromScheme(scheme);

  DistortionWaveStyle copyWith({
    double? anticipation,
    double? travel,
    double? launchGap,
    double? linger,
    double? rimFade,
    DistortionWaveEasing? rimEasing,
    double? returnSpeed,
    DistortionWaveEasing? easing,
    double? pull,
    double? inhale,
    double? gatherGlow,
    double? gatherDots,
    double? amplitude,
    double? lensWidth,
    double? aberration,
    double? swell,
    double? blur,
    double? blurAhead,
    double? blurBehind,
    double? lead,
    double? tail,
    double? strength,
    double? rimWidth,
    double? rimUnevenness,
    double? rimStrength,
    double? rimSoftness,
    double? cornerRadius,
    double? rimPulse,
    double? hairlineWidth,
    double? hairlineOpacity,
    double? hairlineWhite,
    double? hairlineLinger,
    double? hairlineFade,
    double? orientation,
    int? particleCount,
    double? particleSize,
    double? particleReach,
    double? particleFlight,
    double? particleGap,
    double? particleLife,
    double? particleSpread,
    DistortionWavePalette? palette,
  }) => DistortionWaveStyle._(
    type: type,
    anticipation: anticipation ?? this.anticipation,
    travel: travel ?? this.travel,
    launchGap: launchGap ?? this.launchGap,
    linger: linger ?? this.linger,
    rimFade: rimFade ?? this.rimFade,
    rimEasing: rimEasing ?? this.rimEasing,
    returnSpeed: returnSpeed ?? this.returnSpeed,
    easing: easing ?? this.easing,
    pull: pull ?? this.pull,
    inhale: inhale ?? this.inhale,
    gatherGlow: gatherGlow ?? this.gatherGlow,
    gatherDots: gatherDots ?? this.gatherDots,
    amplitude: amplitude ?? this.amplitude,
    lensWidth: lensWidth ?? this.lensWidth,
    aberration: aberration ?? this.aberration,
    swell: swell ?? this.swell,
    blur: blur ?? this.blur,
    blurAhead: blurAhead ?? this.blurAhead,
    blurBehind: blurBehind ?? this.blurBehind,
    lead: lead ?? this.lead,
    tail: tail ?? this.tail,
    strength: strength ?? this.strength,
    rimWidth: rimWidth ?? this.rimWidth,
    rimUnevenness: rimUnevenness ?? this.rimUnevenness,
    rimStrength: rimStrength ?? this.rimStrength,
    rimSoftness: rimSoftness ?? this.rimSoftness,
    cornerRadius: cornerRadius ?? this.cornerRadius,
    rimPulse: rimPulse ?? this.rimPulse,
    hairlineWidth: hairlineWidth ?? this.hairlineWidth,
    hairlineOpacity: hairlineOpacity ?? this.hairlineOpacity,
    hairlineWhite: hairlineWhite ?? this.hairlineWhite,
    hairlineLinger: hairlineLinger ?? this.hairlineLinger,
    hairlineFade: hairlineFade ?? this.hairlineFade,
    orientation: orientation ?? this.orientation,
    particleCount: particleCount ?? this.particleCount,
    particleSize: particleSize ?? this.particleSize,
    particleReach: particleReach ?? this.particleReach,
    particleFlight: particleFlight ?? this.particleFlight,
    particleGap: particleGap ?? this.particleGap,
    particleLife: particleLife ?? this.particleLife,
    particleSpread: particleSpread ?? this.particleSpread,
    palette: palette ?? this.palette,
  );
}
