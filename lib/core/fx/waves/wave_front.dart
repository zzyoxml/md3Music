import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'distortion_wave_style.dart';

/// [type] 的波不给源时，从 [size] 里的哪一块出发：底部一个宽按钮、左边一条高
/// 竖条，或正中一个头像。
Rect waveDefaultSource(DistortionWaveType type, Size size) => switch (type) {
  DistortionWaveType.vertical => Rect.fromLTWH(20, size.height - 92, size.width - 40, 58),
  DistortionWaveType.horizontal => Rect.fromLTWH(0, size.height * 0.343, 24, size.height * 0.3135),
  DistortionWaveType.center => Rect.fromCenter(center: size.center(Offset.zero), width: 64, height: 64),
};

/// 波在某个进度上的样子 —— 只由 progress 决定的纯函数，所以可以定格截图、
/// 倒放、逐帧校对。
///
/// 它的一生，按顺序：重力把一切拉向源；波前离开源自己的轮廓，按 style 的缓动穿过
/// 视口，在远端停稳，同时鼓包、模糊和颜色衰减；它留在视口边缘的颜色，由 `linger`
/// 秒之后出发的第二道波前擦掉。
class WaveFront {
  WaveFront._({
    required this.origin,
    required this.tilt,
    required this.spine,
    required this.radius,
    required this.moved,
    required this.squash,
    required this.time,
    required this.energy,
    required this.swell,
    required this.size,
    required this.gravity,
    required this.glow,
    required this.clearRadius,
    required this.hairClearRadius,
    required this.rim,
    required this.fallen,
    required this.sparkle,
    required this.flying,
    required this.launched,
    required this.hasCleared,
    required this.ring,
    required this.sideways,
    required this.hold,
  });

  /// [focus]：源上被按下的位置，给了波就跟着它偏。
  factory WaveFront({
    required double progress,
    required Rect source,
    required Size size,
    required DistortionWaveStyle style,
    Offset? focus,
  }) {
    final duration = style.duration;
    final t = progress.clamp(0.0, 1.0) * duration;
    final sinceLaunch = t - style.anticipation;
    // 两端都缓：猛地入拉力阶段会看着像被撞了一下。
    final gathered = smooth(0, math.max(style.anticipation, 0.001), t);
    final x = (sinceLaunch / style.travel).clamp(0.0, 1.0);
    final moved = style.easing(x);

    final ring = style.type == DistortionWaveType.center;
    final sideways = style.type == DistortionWaveType.horizontal;
    final fullSquash = ring ? 1.0 : _arcSquash;
    final startRadius = math.min(source.width, source.height) / 2;
    // 源的长边：波前一出发是贴着这条边的胶囊。
    final length = sideways ? source.height : source.width;
    // 环形从源的中心散开，不管源什么形状。
    final startSpine = ring ? 0.0 : math.max(0.0, length / 2 - startRadius);
    // 横向波是竖向波转了四分之一：它的"上"就是屏幕的右。
    final turned = sideways ? math.pi / 2 : 0.0;
    final axisX = math.cos(turned);
    final axisY = math.sin(turned);
    final centre = source.center;

    // 摸在源的一侧时，波从手指下面长出来并朝那边偏。偏只在胶囊张开成弧线的过程中
    // 发生，所以它出发时仍贴着源自己的轮廓。
    var lean = 0.0;
    if (!ring && focus != null) {
      final off = sideways ? focus.dy - centre.dy : focus.dx - centre.dx;
      lean = (off / math.max(length / 2, 1)).clamp(-1.0, 1.0);
    }
    final fullShift = lean * length / 2 * style.orientation;
    final fullLean = lean * style.orientation * _maxTilt;
    final fullTilt = turned + fullLean;
    final opening = smooth(0, 0.45, moved);

    // 波前离开视口最远那个角所需的半径，按它偏完之后自己的坐标系算。
    final cs = math.cos(fullTilt);
    final sn = math.sin(fullTilt);
    var reach = 0.0;
    for (final corner in [
      Offset.zero,
      Offset(size.width, 0),
      Offset(0, size.height),
      Offset(size.width, size.height),
    ]) {
      final dx = corner.dx - centre.dx - fullShift * axisX;
      final dy = corner.dy - centre.dy - fullShift * axisY;
      reach = math.max(reach, _hypot((cs * dx + sn * dy) * fullSquash, -sn * dx + cs * dy));
    }
    // ……并且把它身后的旧页也带走。场的梯度最多是 fullSquash。
    final crossed = reach + (style.swell + coverZone) * fullSquash;
    final settling = 1 - smooth(_settleStart, _settleEnd, x);

    // 发射前，一圈颜色向波将要起步的地方落下去：style 的 gap，在源轮廓之外。
    final launchRadius = startRadius + math.max(style.launchGap, 0);
    final radius = sinceLaunch < 0
        ? launchRadius + style.inhale * (1 - gathered)
        : launchRadius + (crossed + _overshoot - launchRadius) * moved;
    // 从已经聚到源上的那点开始，发射的瞬间不会有东西"跳"一下。
    final gatheredGlow = math.min(_gatheredGlowCap * math.max(style.gatherGlow, 0), 1.0);
    // 起点退得够远，颜色一路完整地连到源；终点正好在它的软边离开最远那个角时，
    // 于是整段缓动都发生在屏幕上。
    final clearStart = startRadius - style.rimSoftness;
    final clearEnd = reach + (style.rimSoftness + style.swell) * fullSquash;
    // 下落：先慢后快，像受重力。
    final falling = math.min(t / math.max(style.anticipation, 0.001), 1.0);

    return WaveFront._(
      origin: Offset(centre.dx + fullShift * opening * axisX, centre.dy + fullShift * opening * axisY),
      tilt: turned + fullLean * opening,
      // 胶囊只在波前移动的过程中张开成弧线，半径还小的时候两侧不会往回缩。
      spine: startSpine * (1 - opening),
      radius: radius,
      moved: moved,
      squash: 1 + (fullSquash - 1) * smooth(0, 0.5, moved),
      time: t,
      energy: smooth(0, 0.05, x) * settling,
      swell: style.swell * smooth(0, 0.3, moved),
      size: size,
      gravity: style.pull * gathered * (1 - smooth(0, _release, sinceLaunch)),
      glow: sinceLaunch < 0
          ? gatheredGlow * gathered
          : (gatheredGlow + (1 - gatheredGlow) * smooth(0, 0.07, x)) * settling,
      clearRadius:
          clearStart +
          (clearEnd - clearStart) * style.rimEasing((sinceLaunch - style.linger) / math.max(style.rimFade, 0.01)),
      hairClearRadius:
          clearStart +
          (clearEnd - clearStart) *
              style.rimEasing(
                (sinceLaunch - style.linger - style.hairlineLinger) / math.max(style.hairlineFade, 0.01),
              ),
      rim: style.rimStrength * smooth(0, 0.1, x) * (1 - smooth(0.9, 1, t / duration)),
      fallen: falling * falling,
      sparkle: smooth(0, math.max(style.anticipation, 0.001) * 0.35, t),
      flying: math.max(sinceLaunch, 0),
      launched: sinceLaunch > 0,
      hasCleared: radius > crossed,
      ring: ring,
      sideways: sideways,
      hold: ring ? startRadius : 0,
    );
  }

  final Offset origin;

  /// 波坐标系转了多少，弧度：正数是往右偏。
  final double tilt;

  /// 波前所依附的那条胶囊的直边一半长。
  final double spine;

  /// 波前到那条脊线的距离。
  final double radius;

  /// 波前走到哪了，0–1。
  final double moved;

  /// 场里 x 轴的缩放：大于 1，波前就弓起来。
  final double squash;

  /// 波开始到现在多少秒。
  final double time;

  /// 鼓包和模糊的作用强度，0–1。在它们各自那段的头尾都是 0，所以 shader 开关时
  /// 不会有东西"跳"一下。
  final double energy;

  final double swell;
  final Size size;

  /// 内容被拉向源多远。
  final double gravity;

  /// 波前上的颜色有多浓，0–1。
  final double glow;

  /// 擦掉视口边缘颜色的那道后发波前的距离。
  final double clearRadius;

  /// 更晚、更慢地擦掉细线的那道波前的距离。
  final double hairClearRadius;

  /// 视口边缘的颜色不透明度，0–1。
  final double rim;

  /// 小点落向源多少，0–1。
  final double fallen;

  /// 小点淡入多少，0–1。
  final double sparkle;

  /// 波前离开源多少秒，之前是 0。
  final double flying;

  /// 波前是否已经离开源。
  final bool launched;

  /// 波前是否已经扫过整个视口：它身后的旧页一点都露不出来了，那一面就不用再画。
  final bool hasCleared;

  /// 是不是从源中心散开的环，而不是一条弧。
  final bool ring;

  /// 是不是从左往右走的弧，而不是从下往上。
  final bool sideways;

  /// 源自己那块不动的半径：环的半径，弧为 0。
  final double hold;

  /// 两屏交叉淡入的区间一半（着色器里的 `coverZone`）。
  static const coverZone = 60.0;

  /// 弧的 x 轴最多压到多少；环永远不压。
  static const _arcSquash = 1.4;

  /// 发射后重力用多少秒松开。
  static const _release = 0.22;

  /// 发射前聚在源周围的颜色最浓到多少。
  static const _gatheredGlowCap = 0.5;

  /// 波前停稳处超出"已经扫过视口"多远：够看清缓动的收尾，也够在它停稳前就把
  /// 旧页那一面停掉。
  static const _overshoot = 100.0;

  /// 摸在源的末端时，波最多转多少：约 26°。
  static const _maxTilt = 0.45;

  /// 波前走过的最后这段里，鼓包、模糊和颜色衰减掉：它开始时波前已经扫过屏幕。
  static const _settleStart = 0.2;
  static const _settleEnd = 0.55;

  static double smooth(double a, double b, double x) {
    final t = ((x - a) / (b - a)).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  static double _hypot(double x, double y) => math.sqrt(x * x + y * y);
}

/// 让视口边缘的颜色不均匀的那些团块：沿周长七个，各有长度和厚度，缘边走边漂、
/// 一呼一吸。每帧算一次，不用逐像素算。
abstract final class WaveRim {
  static const count = 7;

  /// 每个团块沿周长的中心、长度和厚度（占边缘色宽度的比例），写进 [out]
  /// （3 × [count]）。[pulse] 0–1，让它们漂得更快、呼吸更深。
  static void lumps(
    Float64List out, {
    required double time,
    required Size size,
    required double cornerRadius,
    double pulse = 0,
  }) {
    final ex = math.max(size.width / 2 - cornerRadius, 0.0);
    final ey = math.max(size.height / 2 - cornerRadius, 0.0);
    final perimeter = 4 * (ex + ey + 0.5 * math.pi * cornerRadius);
    const n = count;
    for (var i = 0; i < n; i++) {
      final fi = i.toDouble();
      // 每个团块固定，所以每次运行的图案都一样。
      final a = _hash(fi, 12.9898, 1.3);
      final b = _hash(fi, 78.233, 4.1);
      final c = _hash(fi, 39.425, 2.7);
      final breath = (0.25 + 0.3 * pulse) * math.sin(time * (1.1 + 1.2 * a) * (1 + pulse) + fi * 2.4);
      out[i * 3] = perimeter * (fi + 0.35 * a) / n + time * (-22 + 44 * b) * (1 + 2 * pulse);
      out[i * 3 + 1] = perimeter / n * (0.2 + 0.25 * c);
      out[i * 3 + 2] = (0.2 + 2.6 * b) * (1 + breath);
    }
  }

  static double _hash(double i, double a, double b) {
    final x = math.sin(i * a + b) * 43758.5453;
    return x - x.floorToDouble();
  }
}

/// 一个白色小点。位置只由波前决定，所以它跟着定格、倒放。
///
/// 出发前它一小跳一小跳地朝源飞：每跳都从源外某处开始，越跳越快，在离源还远时
/// 就淡掉。波前离开时，它被甩出去：最快的贴着波前，最慢的拖在很后面。之后它飘着，
/// 一边摇一边闪，直到淡出。没有两颗一样亮。环形时就是绕一圈同样的道理。
class WaveParticle {
  factory WaveParticle(int index, DistortionWaveStyle style) {
    // 低差异序列：散得均匀，每次运行都一样。
    final i = (index + 1).toDouble();
    double scatter(double step) => (i * step) % 1;
    final small = scatter(0.5497004779);
    return WaveParticle._(
      index: i,
      // 收在源的两端之内，从源里出来的点才落在源后面。
      column: (scatter(0.7548776662) * 2 - 1) * 0.92,
      heading: scatter(0.7548776662) * 2 * math.pi,
      // 靠波前的多些，其余往波前后头铺开。
      pace: 0.35 + 0.72 * math.sqrt(scatter(0.8191725134)),
      drift: 15 + 50 * scatter(0.6710436067),
      sway: 3 + 11 * scatter(0.4142135624),
      swayRate: 2.5 + 3.5 * scatter(0.7320508076),
      twinkleRate: 8 + 12 * scatter(0.2360679775),
      phase: scatter(0.6180339887) * 2 * math.pi,
      life: style.particleLife * (0.4 + 0.6 * scatter(0.6457513111)),
      size: style.particleSize * (0.55 + 0.45 * small * small),
      brightness: 0.3 + 0.7 * scatter(0.6055512755),
      hop: 0.16 + 0.14 * scatter(0.1231056256),
      hopOffset: scatter(0.4721359550),
      reach: style.particleReach,
      flight: style.particleFlight,
      gap: style.particleGap,
      anticipation: style.anticipation,
      gatherDots: style.gatherDots,
      spread: style.particleSpread.clamp(0.0, 1.0),
    );
  }

  WaveParticle._({
    required this.index,
    required this.column,
    required this.heading,
    required this.pace,
    required this.drift,
    required this.sway,
    required this.swayRate,
    required this.twinkleRate,
    required this.phase,
    required this.life,
    required this.size,
    required this.brightness,
    required this.hop,
    required this.hopOffset,
    required this._reach,
    required this._flight,
    required this._gap,
    required this._anticipation,
    required this._gatherDots,
    required this._spread,
  });

  final double index;

  /// 从源的哪一段出去，-1…1。
  final double column;

  /// 环形时它朝哪个方向离开，弧度。
  final double heading;

  /// 它分担波前走的路：1 贴着波前，越小拖得越后。
  final double pace;

  /// 波前慢下来之后它自己还在往上飘多快，每秒。
  final double drift;

  /// 左右摇摆多远。
  final double sway;
  final double swayRate;
  final double twinkleRate;
  final double phase;

  /// 发射后多少秒它已经淡掉。
  final double life;

  /// 它的直径。
  final double size;

  /// 最亮时多亮，0–1。
  final double brightness;

  /// 每跳朝源飞多少秒。
  final double hop;
  final double hopOffset;

  final double _reach;
  final double _flight;
  final double _gap;
  final double _anticipation;
  final double _gatherDots;
  final double _spread;

  /// 最快的那些比源宽出多少：波前是个正在张开的弧。
  static const _fan = 0.22;

  /// 它们在源的两端比中间飞得低多少，跟波前一样。
  static const _bow = 0.3;

  Offset point(WaveFront front, Rect source) {
    if (front.ring) return front.launched ? _ringOutflow(front, source) : _ringInflow(front, source);
    return front.launched ? _outflow(front, source) : _inflow(front, source);
  }

  double opacity(WaveFront front) {
    final twinkle = 0.5 + 0.5 * math.sin(front.time * twinkleRate + phase);
    final glint = brightness * (0.7 + 0.3 * twinkle);
    if (!front.launched) {
      // 每一跳里亮起又灭掉，发射时全都已经没了。
      final along = hopAt(front.time).along;
      final hopping = WaveFront.smooth(0, 0.25, along) * (1 - WaveFront.smooth(0.55, 1, along));
      final ending = 1 - WaveFront.smooth(_anticipation * 0.75, _anticipation, front.time);
      return front.sparkle * hopping * ending * glint * _gatherDots;
    }
    final burning = 1 - WaveFront.smooth(life * 0.55, life, front.flying);
    return burning * glint;
  }

  /// [time] 时它在第几跳上，以及这一跳走了多少，0–1。
  ({double count, double along}) hopAt(double time) {
    final hops = time / hop + hopOffset;
    final count = hops.floorToDouble();
    return (count: count, along: hops - count);
  }

  /// 在源自己的坐标系里：[along] 沿它的长边，[out] 是波将要去的方向
  /// （竖向波朝上，横向波朝右）。
  static Offset _onSource(Rect source, bool sideways, double along, double out) => sideways
      ? Offset(source.center.dx + out, source.center.dy + along)
      : Offset(source.center.dx + along, source.center.dy - out);

  Offset _inflow(WaveFront front, Rect source) {
    final (:count, :along) = hopAt(front.time);
    final half = (front.sideways ? source.height : source.width) / 2;
    final face = (front.sideways ? source.width : source.height) / 2;
    // 生在源这一面的外面某处，绝不比一跳加一个间隙更近。
    final x = (_hash(index, count, 1) * 2 - 1) * (half + 24);
    final nearest = _gap + _flight;
    final away = nearest + math.max(_reach - nearest, 0) * _hash(index, count, 2);
    final start = _onSource(source, front.sideways, x, face + away);
    // 朝源这一面上最近的点飞，越来越快。
    final corner = math.min(source.width, source.height) / 2;
    final target = _onSource(source, front.sideways, x.clamp(-half + corner, half - corner), face);
    final dx = target.dx - start.dx;
    final dy = target.dy - start.dy;
    final length = math.max(math.sqrt(dx * dx + dy * dy), 1);
    final travelled = _flight * along * along;
    return Offset(start.dx + dx / length * travelled, start.dy + dy / length * travelled);
  }

  Offset _outflow(WaveFront front, Rect source) {
    final start = math.min(source.width, source.height) / 2;
    final widening = 1 + _fan * front.moved * pace * _spread;
    final swaying = sway * math.sin(swayRate * front.flying + phase) * math.min(front.flying / 0.25, 1);
    final x = column * (front.sideways ? source.height : source.width) / 2 * widening + swaying;
    final height =
        (start + (front.radius - start) * pace * _spread) * (1 - _bow * column * column) +
        drift * front.flying * _spread;
    // 转到波的坐标系里，它跟着触摸偏。
    final cs = math.cos(front.tilt);
    final sn = math.sin(front.tilt);
    return Offset(front.origin.dx + cs * x + sn * height, front.origin.dy + sn * x - cs * height);
  }

  /// 绕圆形源朝中心跳一下。
  Offset _ringInflow(WaveFront front, Rect source) {
    final (:count, :along) = hopAt(front.time);
    final angle = _hash(index, count, 1) * 2 * math.pi;
    final nearest = math.min(source.width, source.height) / 2 + _gap + _flight;
    final away = nearest + math.max(_reach - nearest, 0) * _hash(index, count, 2);
    final distance = away - _flight * along * along;
    return Offset(source.center.dx + math.cos(angle) * distance, source.center.dy + math.sin(angle) * distance);
  }

  /// 跟着环直直甩出去，横着摇。
  Offset _ringOutflow(WaveFront front, Rect source) {
    final edge = math.min(source.width, source.height) / 2;
    final distance = edge + ((front.radius - edge) * pace + drift * front.flying) * _spread;
    final swaying = sway * math.sin(swayRate * front.flying + phase) * math.min(front.flying / 0.25, 1);
    final dx = math.cos(heading);
    final dy = math.sin(heading);
    return Offset(front.origin.dx + dx * distance - dy * swaying, front.origin.dy + dy * distance + dx * swaying);
  }

  static double _hash(double i, double n, double salt) {
    final x = math.sin(i * 12.9898 + n * 78.233 + salt * 37.719) * 43758.5453;
    return x - x.floorToDouble();
  }
}
