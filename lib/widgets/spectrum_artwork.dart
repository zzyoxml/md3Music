import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/services/spectrum_service.dart';
import 'player_artwork_image.dart';

/// 频谱环绕旋转封面组件：圆形旋转封面 + 环形频谱柱。
///
/// 结构（Stack）：
/// 1. 环形频谱柱层：[CustomPainter] 画 40 根放射柱，从 12 点方向起顺时针环布，
///    柱从圆形封面外缘向外辐射，高度 = FFT 幅值（上升快、回落慢，视觉更跟手）
/// 2. 圆形封面层：[ClipOval] 裁圆 + 1.5px 主题色细环，[Transform.rotate] 旋转
///
/// 旋转逻辑：
/// - `isPlaying=true` → `AnimationController.repeat()` **顺时针**（约 8s/圈）
/// - `isPlaying=false` → `stop()` **保持当前角度静止**（不 reset，恢复播放时续转）
///
/// 性能：环形频谱柱用 [ValueNotifier] + `super(repaint:)` 驱动重绘，
/// 旋转用 [AnimatedBuilder] 局部重建，避免每帧 setState。
///
/// 无数据（暂停/未播放/采集失败）时：环形柱为静止低柱，封面静止。
class SpectrumArtwork extends StatefulWidget {
  /// 封面 URI，支持 http(s)/content/local/file 协议（详见 [PlayerArtworkImage]）
  final String? artworkUri;

  /// content:// 加载失败时的回退文件路径
  final String? fallbackFilePath;

  /// 是否正在播放：true 时封面旋转、频谱跳动；false 时静止
  final bool isPlaying;

  /// 频谱柱颜色（默认取主题 primary）
  final Color? barColor;

  /// 封面描边颜色（默认取主题 primary）
  final Color? ringColor;

  /// 环形频谱柱数量（默认 40，与 Kotlin 端 BAND_COUNT 对齐）
  final int bandCount;

  /// 频谱样式：0=柱状图，1=曲线（默认 0）
  final int style;

  /// 旋转一圈耗时（默认 8s，慢速防眩晕）
  final Duration rotationDuration;

  const SpectrumArtwork({
    super.key,
    required this.artworkUri,
    required this.isPlaying,
    this.fallbackFilePath,
    this.barColor,
    this.ringColor,
    this.bandCount = 40,
    this.style = 0,
    this.rotationDuration = const Duration(seconds: 8),
  });

  @override
  State<SpectrumArtwork> createState() => _SpectrumArtworkState();
}

class _SpectrumArtworkState extends State<SpectrumArtwork>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotationController;
  late final Animation<double> _rotationAnimation;

  /// 频谱幅值数组（0..1）。驱动 CustomPainter 重绘，不触发 setState。
  late final ValueNotifier<List<double>> _bandsNotifier;

  /// 当前显示的幅值（带插值：上升快、回落慢）
  late List<double> _displayedBands;

  /// 频谱流订阅
  StreamSubscription<List<double>>? _subscription;

  @override
  void initState() {
    super.initState();
    _rotationController = AnimationController(
      duration: widget.rotationDuration,
      vsync: this,
    );
    // 注意：Tween begin=0 end=2π（顺时针）；AnimatedBuilder 旋转角度从 0 递增
    _rotationAnimation =
        Tween<double>(begin: 0.0, end: 2 * math.pi).animate(_rotationController);

    _displayedBands = List<double>.filled(widget.bandCount, 0.0);
    _bandsNotifier = ValueNotifier<List<double>>(List.from(_displayedBands));

    _subscribeSpectrum();
    _applyPlayingState();
  }

  @override
  void didUpdateWidget(covariant SpectrumArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying != widget.isPlaying) {
      _applyPlayingState();
    }
    if (oldWidget.bandCount != widget.bandCount) {
      _displayedBands = List<double>.filled(widget.bandCount, 0.0);
      _bandsNotifier.value = List.from(_displayedBands);
    }
    if (oldWidget.rotationDuration != widget.rotationDuration) {
      _rotationController.duration = widget.rotationDuration;
    }
  }

  /// 根据 isPlaying 启停旋转：播放时顺时针 repeat，暂停时 stop 保持角度
  void _applyPlayingState() {
    if (widget.isPlaying) {
      if (!_rotationController.isAnimating) {
        _rotationController.repeat();
      }
    } else {
      _rotationController.stop();
    }
  }

  /// 订阅 SpectrumService 数据流，做帧间插值（上升快、回落慢）。
  void _subscribeSpectrum() {
    _subscription?.cancel();
    _subscription = SpectrumService.instance.spectrumStream.listen((bands) {
      if (!mounted) return;
      // 长度兜底：与 widget.bandCount 对齐
      final n = _displayedBands.length;
      for (int i = 0; i < n; i++) {
        final target = (i < bands.length) ? bands[i] : 0.0;
        final current = _displayedBands[i];
        // 上升快（直接取目标值），回落慢（衰减 35%）
        final next = target > current
            ? target
            : current * 0.65 + target * 0.35;
        _displayedBands[i] = next;
      }
      _bandsNotifier.value = List.from(_displayedBands);
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _rotationController.dispose();
    _bandsNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final barColor = widget.barColor ?? cs.primary;
    // ringColor 不再使用（去掉了专辑外围描边）

    return LayoutBuilder(
      builder: (context, constraints) {
        // 组件总尺寸 = 父约束最小边（正方形）
        final size = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : (constraints.maxHeight.isFinite
                  ? constraints.maxHeight
                  : 280.0);
        // 环形频谱预留外圈空间：柱最大长度 = size × 0.12
        const barMaxLenRatio = 0.12;
        final coverDiameter = size * (1.0 - 2 * barMaxLenRatio);
        final coverRadius = coverDiameter / 2;
        final center = Offset(size / 2, size / 2);

        return SizedBox(
          width: size,
          height: size,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // ── 1. 环形频谱层（柱状或曲线） ──
              Positioned.fill(
                child: CustomPaint(
                  painter: widget.style == 1
                      ? _SpectrumCurvePainter(
                          bandsNotifier: _bandsNotifier,
                          center: center,
                          coverRadius: coverRadius,
                          barMaxLen: size * barMaxLenRatio,
                          color: barColor,
                          bandCount: widget.bandCount,
                        )
                      : _SpectrumRingPainter(
                          bandsNotifier: _bandsNotifier,
                          center: center,
                          coverRadius: coverRadius,
                          barMaxLen: size * barMaxLenRatio,
                          color: barColor,
                          bandCount: widget.bandCount,
                        ),
                ),
              ),
              // ── 2. 圆形旋转封面层 ──
              Positioned(
                left: center.dx - coverRadius,
                top: center.dy - coverRadius,
                width: coverDiameter,
                height: coverDiameter,
                child: AnimatedBuilder(
                  animation: _rotationAnimation,
                  builder: (context, child) {
                    return Transform.rotate(
                      angle: _rotationAnimation.value,
                      alignment: Alignment.center,
                      child: child,
                    );
                  },
                  child: ClipOval(
                    child: PlayerArtworkImage(
                      artworkUri: widget.artworkUri,
                      fallbackFilePath: widget.fallbackFilePath,
                      fit: BoxFit.cover,
                      isFill: true,
                      iconSize: coverDiameter * 0.3,
                      backgroundColor: cs.surfaceContainerHighest,
                      iconColor: cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 环形频谱柱 painter：从 12 点方向起顺时针环布 [bandCount] 根细柱。
///
/// 性能：`super(repaint: bandsNotifier)` 驱动重绘，不触发外层 widget rebuild。
class _SpectrumRingPainter extends CustomPainter {
  final ValueNotifier<List<double>> bandsNotifier;
  final Offset center;
  final double coverRadius;
  final double barMaxLen;
  final Color color;
  final int bandCount;

  _SpectrumRingPainter({
    required this.bandsNotifier,
    required this.center,
    required this.coverRadius,
    required this.barMaxLen,
    required this.color,
    required this.bandCount,
  }) : super(repaint: bandsNotifier);

  @override
  void paint(Canvas canvas, Size size) {
    final bands = bandsNotifier.value;
    final n = bandCount;
    if (n <= 0) return;

    // 柱宽度：根据柱数等分圆周，间距小（0.78 = 柱占78%、间距22%）
    final circumference = 2 * math.pi * (coverRadius + barMaxLen / 2);
    final barWidth = (circumference / n) * 0.78;

    // 基准高度：无数据时显示静止低柱（视觉上不空）
    final baseLen = barMaxLen * 0.12;

    final paint = Paint()
      ..color = color
      ..strokeCap = StrokeCap.butt // 顶部不圆角，且不延伸
      ..style = PaintingStyle.fill;

    // 从 12 点方向（-π/2）起顺时针：每个柱角度 = -π/2 + i * 2π/n
    for (int i = 0; i < n; i++) {
      final angle = -math.pi / 2 + (i * 2 * math.pi / n);
      final v = (i < bands.length) ? bands[i].clamp(0.0, 1.0) : 0.0;
      final len = baseLen + barMaxLen * v;

      // 柱起点：紧贴圆形封面外缘（无空隙）
      final startX = center.dx + coverRadius * math.cos(angle);
      final startY = center.dy + coverRadius * math.sin(angle);
      // 柱终点：向外辐射
      final endX = center.dx + (coverRadius + len) * math.cos(angle);
      final endY = center.dy + (coverRadius + len) * math.sin(angle);

      paint.strokeWidth = barWidth;
      canvas.drawLine(
        Offset(startX, startY),
        Offset(endX, endY),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SpectrumRingPainter oldDelegate) {
    // bands 变化由 Listenable (super(repaint:)) 自动驱动重绘，
    // 这里只检查不变参数
    return oldDelegate.center != center ||
        oldDelegate.coverRadius != coverRadius ||
        oldDelegate.barMaxLen != barMaxLen ||
        oldDelegate.color != color ||
        oldDelegate.bandCount != bandCount;
  }
}

/// 环形频谱曲线 painter：用平滑闭合曲线连接各频点，环绕封面外圈。
///
/// 每个频点对应一个角度（从 12 点方向顺时针），半径 = coverRadius + barMaxLen * value。
/// 用 quadraticBezierTo 做平滑过渡，描边 + 半透明填充。
class _SpectrumCurvePainter extends CustomPainter {
  final ValueNotifier<List<double>> bandsNotifier;
  final Offset center;
  final double coverRadius;
  final double barMaxLen;
  final Color color;
  final int bandCount;

  _SpectrumCurvePainter({
    required this.bandsNotifier,
    required this.center,
    required this.coverRadius,
    required this.barMaxLen,
    required this.color,
    required this.bandCount,
  }) : super(repaint: bandsNotifier);

  @override
  void paint(Canvas canvas, Size size) {
    final bands = bandsNotifier.value;
    final n = bandCount;
    if (n < 3) return;

    // 基准高度：无数据时紧贴封面外缘
    final baseLen = barMaxLen * 0.05;

    // 计算每个频点的坐标
    final points = <Offset>[];
    for (int i = 0; i < n; i++) {
      final angle = -math.pi / 2 + (i * 2 * math.pi / n);
      final v = (i < bands.length) ? bands[i].clamp(0.0, 1.0) : 0.0;
      final r = coverRadius + baseLen + barMaxLen * v;
      points.add(Offset(
        center.dx + r * math.cos(angle),
        center.dy + r * math.sin(angle),
      ));
    }

    // 用平滑闭合曲线连接所有点（quadraticBezierTo，控制点=当前点，终点=相邻两点中点）
    final path = Path();
    if (points.isNotEmpty) {
      // 起点 = 第一个点和最后一个点的中点（闭合平滑）
      final midStart = Offset(
        (points[0].dx + points[n - 1].dx) / 2,
        (points[0].dy + points[n - 1].dy) / 2,
      );
      path.moveTo(midStart.dx, midStart.dy);
      // 对每个点 i：控制点 = points[i]，终点 = points[i] 和 points[i+1] 的中点
      for (int i = 0; i < n; i++) {
        final next = points[(i + 1) % n];
        final mid = Offset(
          (points[i].dx + next.dx) / 2,
          (points[i].dy + next.dy) / 2,
        );
        path.quadraticBezierTo(points[i].dx, points[i].dy, mid.dx, mid.dy);
      }
      path.close();
    }

    // 半透明填充
    final fillPaint = Paint()
      ..color = color.withValues(alpha: 0.15)
      ..style = PaintingStyle.fill;
    canvas.drawPath(path, fillPaint);

    // 描边
    final strokePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(path, strokePaint);
  }

  @override
  bool shouldRepaint(covariant _SpectrumCurvePainter oldDelegate) {
    return oldDelegate.center != center ||
        oldDelegate.coverRadius != coverRadius ||
        oldDelegate.barMaxLen != barMaxLen ||
        oldDelegate.color != color ||
        oldDelegate.bandCount != bandCount;
  }
}
