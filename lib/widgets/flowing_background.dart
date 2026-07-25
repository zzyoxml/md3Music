import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:palette_generator/palette_generator.dart';

/// 动态流光背景效果。
///
/// 参照 AMLL WebGL Mesh Gradient 背景渲染系统的简化 Flutter 实现。
/// 从专辑封面提取主色调，用多层径向渐变叠加 + 动画偏移模拟"色彩流动"。
class FlowingBackground extends StatefulWidget {
  final String? artworkUrl;
  final bool isPlaying;

  const FlowingBackground({
    super.key,
    this.artworkUrl,
    this.isPlaying = true,
  });

  @override
  State<FlowingBackground> createState() => _FlowingBackgroundState();
}

class _FlowingBackgroundState extends State<FlowingBackground>
    with TickerProviderStateMixin {
  Ticker? _ticker;
  double _time = 0;
  Duration _lastElapsed = Duration.zero;
  List<Color> _colors = const [Colors.deepPurple, Colors.indigo, Colors.teal];
  String? _lastArtworkUrl;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _ticker!.start();
    _extractColors();
  }

  @override
  void didUpdateWidget(covariant FlowingBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artworkUrl != widget.artworkUrl) {
      _extractColors();
    }
    // 播放状态变化时控制 ticker
    if (oldWidget.isPlaying != widget.isPlaying) {
      if (widget.isPlaying) {
        _lastElapsed = Duration.zero;
        _ticker?.start();
      } else {
        _ticker?.stop();
      }
    }
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastElapsed).inMicroseconds / 1000000.0;
    _lastElapsed = elapsed;
    // 累积时间，sin/cos 自然周期性，无跳变
    _time += dt * 0.5; // 0.5 倍速，4秒一个周期
    setState(() {});
  }

  Future<void> _extractColors() async {
    final url = widget.artworkUrl;
    if (url == null || url.isEmpty) return;
    if (_lastArtworkUrl == url) return;
    _lastArtworkUrl = url;

    try {
      final palette = await PaletteGenerator.fromImageProvider(
        NetworkImage(url),
        maximumColorCount: 5,
      );
      if (!mounted) return;
      final dominant = palette.dominantColor?.color ?? Colors.deepPurple;
      final vibrant = palette.vibrantColor?.color ?? Colors.indigo;
      final darkVibrant = palette.darkVibrantColor?.color ?? Colors.teal;
      setState(() {
        _colors = [
          HSLColor.fromColor(dominant).withSaturation(0.8).toColor(),
          HSLColor.fromColor(vibrant).withSaturation(0.85).toColor(),
          HSLColor.fromColor(darkVibrant).withSaturation(0.7).toColor(),
        ];
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _FlowingGradientPainter(
          colors: _colors,
          time: _time,
        ),
        size: Size.infinite,
      ),
    );
  }
}

/// 流光渐变绘制器。
///
/// 3 层径向渐变叠加，每层中心点随时间偏移，模拟色彩流动。
class _FlowingGradientPainter extends CustomPainter {
  final List<Color> colors;
  final double time;

  _FlowingGradientPainter({required this.colors, required this.time});

  @override
  void paint(Canvas canvas, Size size) {
    if (colors.isEmpty) return;

    final rect = Offset.zero & size;

    // 层 1：主色，大幅慢速流动
    _paintLayer(
      canvas,
      rect,
      color: colors[0],
      cx: 0.3 + 0.3 * math.sin(time),
      cy: 0.3 + 0.3 * math.cos(time * 1.4),
      radius: 1.4,
      alpha: 160,
    );

    // 层 2：强调色，中速流动
    _paintLayer(
      canvas,
      rect,
      color: colors[1],
      cx: 0.7 + 0.25 * math.cos(time * 0.8),
      cy: 0.6 + 0.25 * math.sin(time),
      radius: 1.2,
      alpha: 140,
    );

    // 层 3：深色，快速流动
    _paintLayer(
      canvas,
      rect,
      color: colors[2],
      cx: 0.5 + 0.2 * math.sin(time * 1.2 + 1.0),
      cy: 0.8 + 0.2 * math.cos(time * 1.1 + 1.0),
      radius: 1.1,
      alpha: 130,
    );
  }

  void _paintLayer(
    Canvas canvas,
    Rect rect, {
    required Color color,
    required double cx,
    required double cy,
    required double radius,
    required int alpha,
  }) {
    final paint = Paint()
      ..shader = RadialGradient(
        center: Alignment(cx * 2 - 1, cy * 2 - 1),
        radius: radius,
        colors: [
          color.withAlpha(alpha),
          color.withAlpha(0),
        ],
        stops: const [0.0, 1.0],
      ).createShader(rect);
    canvas.drawRect(rect, paint);
  }

  @override
  bool shouldRepaint(covariant _FlowingGradientPainter oldDelegate) {
    return oldDelegate.time != time;
  }
}
