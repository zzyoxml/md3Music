import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:material_ui/material_ui.dart';

/// 流光渐变绘制器（回退实现，只画光斑；不透明基底由宿主铺一层渐变）。
///
/// shader 可用时 [FlowingBackground] 走单次全屏 fragment pass，本 painter 只在
/// shader 不可用（加载失败 / 平台不支持）时兜底，并供设置页预览卡复用，保证
/// 「设置页预览 ≈ 播放页实况」。
///
/// 逐帧零分配：每层一个常驻 [Paint]，shader 只在 `(size, colors)` 变化时重建
/// （见 [_ensureShaders]）；每帧只剩 save/translate/drawRect/restore。
///
/// [repaintSignal] 供播放页在调色板交叉淡化期间使用：此时流光时间可能不变
/// （暂停切歌），但配色每拍都在变，必须由外部信号驱动重绘。设置页预览卡
/// 不传（默认只跟 [timeNotifier]），行为与改动前一致。
class FlowingGradientPainter extends CustomPainter {
  final List<Color> colors;
  final ValueNotifier<double> timeNotifier;

  /// 每层一个常驻 Paint。
  ///
  /// 原实现每帧 `Paint() + RadialGradient() + createShader()`，30fps 下 ≈120 个
  /// 对象/秒、且每帧让 Impeller 重建渐变 effect / uniform buffer，全属零收益开销。
  final Paint _paint1 = Paint();
  final Paint _paint2 = Paint();
  final Paint _paint3 = Paint();
  final Paint _paint4 = Paint();

  /// shader 缓存键：只在 size 与 colors 同时未变时复用上次的 shader。
  Size? _cachedSize;
  List<Color>? _cachedColors;

  FlowingGradientPainter({
    required this.colors,
    required this.timeNotifier,
    Listenable? repaintSignal,
  }) : super(repaint: repaintSignal ?? timeNotifier);

  /// 3 层光斑的半径 / 中心 alpha（与抽取前的实现逐字一致，勿"优化"）。
  static const double _radius1 = 1.4;
  static const double _radius2 = 1.2;
  static const double _radius3 = 1.1;
  static const int _alpha1 = 235;
  static const int _alpha2 = 220;
  static const int _alpha3 = 205;

  /// 第 4 层（第 4 个 pigment，调色板化后新增）：更小更淡，补足四场色彩。
  static const double _radius4 = 1.05;
  static const int _alpha4 = 190;

  @override
  void paint(Canvas canvas, Size size) {
    if (colors.isEmpty) return;

    // 从 ValueNotifier 读取当前时间（由 _onSharedTick 每 2 拍更新一次）
    final time = timeNotifier.value;

    _ensureShaders(size);

    final double hw = size.width / 2;
    final double hh = size.height / 2;

    // 层 1：主色，大幅慢速流动
    _paintLayer(
      canvas,
      size,
      _paint1,
      (2 * (0.3 + 0.3 * math.sin(time)) - 1) * hw,
      (2 * (0.3 + 0.3 * math.cos(time * 1.4)) - 1) * hh,
    );

    // 层 2：强调色，中速流动
    _paintLayer(
      canvas,
      size,
      _paint2,
      (2 * (0.7 + 0.25 * math.cos(time * 0.8)) - 1) * hw,
      (2 * (0.6 + 0.25 * math.sin(time)) - 1) * hh,
    );

    // 层 3：深色，快速流动
    _paintLayer(
      canvas,
      size,
      _paint3,
      (2 * (0.5 + 0.2 * math.sin(time * 1.2 + 1.0)) - 1) * hw,
      (2 * (0.8 + 0.2 * math.cos(time * 1.1 + 1.0)) - 1) * hh,
    );

    // 层 4：第 4 个 pigment（无第 4 色时跳过，保持旧 3 层行为逐字一致）
    if (colors.length >= 4) {
      _paintLayer(
        canvas,
        size,
        _paint4,
        (2 * (0.35 + 0.25 * math.sin(time * 0.9 + 2.0)) - 1) * hw,
        (2 * (0.45 + 0.25 * math.cos(time * 1.15 + 0.5)) - 1) * hh,
      );
    }
  }

  /// 仅在 `(size, colors)` 变化时重建光斑 shader。
  ///
  /// shader 建在**屏幕矩形**上、中心固定 [Alignment.center]，光斑的位置改由
  /// 每帧画布平移实现，与矩形的选择无关（径向渐变的 t 只取决于到中心的距离）。
  void _ensureShaders(Size size) {
    if (_cachedSize == size && listEquals(_cachedColors, colors)) return;
    _cachedSize = size;
    _cachedColors = List<Color>.of(colors);
    final Rect screen = Offset.zero & size;
    _paint1.shader = _buildBlobShader(screen, colors[0], _radius1, _alpha1);
    _paint2.shader = _buildBlobShader(screen, colors[1], _radius2, _alpha2);
    _paint3.shader = _buildBlobShader(screen, colors[2], _radius3, _alpha3);
    if (colors.length >= 4) {
      _paint4.shader = _buildBlobShader(screen, colors[3], _radius4, _alpha4);
    }
  }

  /// 居中的径向光斑渐变（中心固定在屏幕中心，位置靠画布平移）。
  Shader _buildBlobShader(Rect screen, Color color, double radius, int alpha) {
    return RadialGradient(
      center: Alignment.center,
      radius: radius,
      colors: [
        color.withAlpha(alpha),
        color.withAlpha(0),
      ],
      stops: const [0.0, 1.0],
    ).createShader(screen);
  }

  /// 把已建好 shader 的光斑画到 (dx, dy) 偏移处：save/translate/draw/restore。
  ///
  /// 绘制矩形取**恰好铺满整屏**的那个：画布已按 (dx,dy) 平移，局部矩形 R 的
  /// 实际覆盖区是 `R + (dx,dy)`，令其等于屏幕矩形 `(0,0,w,h)` 即
  /// `R = (0,0,w,h).shift(-(dx,dy))`。这样每帧绘制面积恒为 **1× 屏面**。
  void _paintLayer(
      Canvas canvas, Size size, Paint paint, double dx, double dy) {
    canvas.save();
    canvas.translate(dx, dy);
    canvas.drawRect(Rect.fromLTWH(-dx, -dy, size.width, size.height), paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant FlowingGradientPainter oldDelegate) {
    // time 变化由 Listenable (super(repaint: timeNotifier)) 自动驱动重绘，
    // 这里只需检查 colors 是否变化以触发 painter 重建（取色完成后）
    return !listEquals(colors, oldDelegate.colors);
  }
}
