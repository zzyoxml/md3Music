import 'dart:async';

import 'package:flutter/material.dart';

import '../core/services/spectrum_service.dart';

/// 背景条形频谱图：从屏幕底部向上延伸的频谱柱，铺满整个屏幕宽度。
///
/// 类似歌手写真背景的层叠方式，作为播放器背景层显示。
/// 订阅 [SpectrumService] 的频谱数据流，用 [CustomPainter] 绘制。
///
/// 参数：
/// - [color] 频谱柱颜色（MD3 用主题 primary，AM 用白色）
/// - [opacity] 整体透明度（0.0-1.0）
/// - [heightRatio] 频谱区域占屏幕高度的比例（0.2-0.8）
class SpectrumBackground extends StatefulWidget {
  /// 频谱柱颜色
  final Color color;

  /// 整体透明度（0.0-1.0）
  final double opacity;

  /// 频谱区域占屏幕高度的比例（0.2-0.8）
  final double heightRatio;

  /// 是否可见（播放时 true）：AnimatedOpacity 淡入淡出过渡
  final bool visible;

  const SpectrumBackground({
    super.key,
    required this.color,
    this.opacity = 0.4,
    this.heightRatio = 0.4,
    this.visible = true,
  });

  @override
  State<SpectrumBackground> createState() => _SpectrumBackgroundState();
}

class _SpectrumBackgroundState extends State<SpectrumBackground> {
  /// 频谱幅值数组（0..1），驱动 CustomPainter 重绘
  late final ValueNotifier<List<double>> _bandsNotifier;

  /// 当前显示的幅值（带插值：上升快、回落慢）
  late List<double> _displayedBands;

  /// 频谱流订阅
  StreamSubscription<List<double>>? _subscription;

  /// 柱数量（根据屏幕宽度计算，约每 5px 一根）
  int _barCount = 64;

  @override
  void initState() {
    super.initState();
    _displayedBands = List<double>.filled(_barCount, 0.0);
    _bandsNotifier = ValueNotifier<List<double>>(List.from(_displayedBands));
    _subscribeSpectrum();
  }

  void _subscribeSpectrum() {
    _subscription?.cancel();
    _subscription = SpectrumService.instance.spectrumStream.listen((bands) {
      if (!mounted) return;
      // 将原生 40 段数据重采样到 _barCount 段
      final resampled = _resample(bands, _barCount);
      for (int i = 0; i < _barCount; i++) {
        final target = resampled[i];
        final current = _displayedBands[i];
        // 上升快、回落慢
        final next = target > current
            ? target
            : current * 0.7 + target * 0.3;
        _displayedBands[i] = next;
      }
      _bandsNotifier.value = List.from(_displayedBands);
    });
  }

  /// 线性插值重采样
  List<double> _resample(List<double> input, int targetCount) {
    if (input.isEmpty) return List<double>.filled(targetCount, 0.0);
    if (input.length == targetCount) return input;
    final result = List<double>.filled(targetCount, 0.0);
    for (int i = 0; i < targetCount; i++) {
      final srcIdx = i * (input.length - 1) / (targetCount - 1);
      final lo = srcIdx.floor();
      final hi = srcIdx.ceil().clamp(0, input.length - 1);
      final frac = srcIdx - lo;
      result[i] = input[lo] * (1 - frac) + input[hi] * frac;
    }
    return result;
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _bandsNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: widget.visible ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOut,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 根据屏幕宽度动态计算柱数量（约每 5px 一根）
          final newBarCount = (constraints.maxWidth / 5).round().clamp(32, 128);
          if (newBarCount != _barCount) {
            _barCount = newBarCount;
            _displayedBands = List<double>.filled(_barCount, 0.0);
          }

          return Opacity(
            opacity: widget.opacity,
            child: CustomPaint(
              painter: _SpectrumBarsPainter(
                bandsNotifier: _bandsNotifier,
                color: widget.color,
                barCount: _barCount,
                heightRatio: widget.heightRatio,
              ),
              child: const SizedBox.expand(),
            ),
          );
        },
      ),
    );
  }
}

/// 底部条形频谱 painter：从底部向上延伸的频谱柱，铺满宽度。
/// 只在底部 heightRatio 比例区域绘制。
class _SpectrumBarsPainter extends CustomPainter {
  final ValueNotifier<List<double>> bandsNotifier;
  final Color color;
  final int barCount;
  final double heightRatio;

  _SpectrumBarsPainter({
    required this.bandsNotifier,
    required this.color,
    required this.barCount,
    required this.heightRatio,
  })  : _paint = Paint()
          ..color = color
          ..style = PaintingStyle.fill,
        super(repaint: bandsNotifier);

  /// 填充画笔（构造时一次创建）
  final Paint _paint;

  /// 复用的 Path 与柱位置缓冲：每帧 reset 后重建，避免每帧分配对象
  final Path _path = Path();
  final List<double> _xPositions = <double>[];

  @override
  void paint(Canvas canvas, Size size) {
    final bands = bandsNotifier.value;
    final n = barCount;
    if (n <= 0) return;

    // 频谱区域高度 = 总高度 × heightRatio，从底部向上
    final spectrumHeight = size.height * heightRatio;
    final barWidth = size.width / n;
    // 柱间距为柱宽的 20%
    final gap = barWidth * 0.2;
    final actualBarWidth = barWidth - gap;
    // 基准高度：无数据时显示静止低柱
    final baseHeight = spectrumHeight * 0.03;

    // 柱 x 位置只依赖尺寸，复用缓冲避免每帧分配
    final xs = _xPositions..clear();
    for (int i = 0; i < n; i++) {
      xs.add(i * barWidth + gap / 2);
    }

    // 所有柱合并为一条 Path 一次绘制，替代 128 次 drawRect
    final path = _path..reset();
    for (int i = 0; i < n; i++) {
      final v = (i < bands.length) ? bands[i].clamp(0.0, 1.0) : 0.0;
      final h = baseHeight + (spectrumHeight - baseHeight) * v;
      final x = xs[i];
      // 从底部向上画
      final y = size.height - h;
      path.addRect(Rect.fromLTWH(x, y, actualBarWidth, h));
    }
    canvas.drawPath(path, _paint);
  }

  @override
  bool shouldRepaint(covariant _SpectrumBarsPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.barCount != barCount ||
        oldDelegate.heightRatio != heightRatio;
  }
}
