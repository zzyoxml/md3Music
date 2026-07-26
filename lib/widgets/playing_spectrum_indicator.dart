import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// 正在播放频谱标识。
///
/// 用 Ticker 驱动 3 根粒度柱高度做 sin 波动，周期 800ms，
/// 三根柱相位错开 0 / 0.4 / 0.8，呈现类似 Apple Music / 网易云的「正在播放」装饰性动画。
///
/// 仅是装饰性动画（不订阅 amplitudeStream / 不需要任何权限），
/// 用来替代 [CircularProgressIndicator] loading 圈作为歌曲列表「正在播放」标识。
///
/// **性能优化**：用 [ValueNotifier] 驱动 [CustomPainter] 重绘，
/// 避免 _onTick 每帧 setState 触发 widget 重建。
class PlayingSpectrumIndicator extends StatefulWidget {
  final Color color;

  /// 整体尺寸（正方形），默认 14×14
  final double size;

  /// 是否正在播放：true 时 ticker 运行动画，false 时 ticker 停止保留最后一帧
  final bool isPlaying;

  const PlayingSpectrumIndicator({
    super.key,
    required this.color,
    this.size = 14,
    this.isPlaying = true,
  });

  @override
  State<PlayingSpectrumIndicator> createState() =>
      _PlayingSpectrumIndicatorState();
}

class _PlayingSpectrumIndicatorState extends State<PlayingSpectrumIndicator>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _lastElapsed = Duration.zero;

  /// 时间累积通过 ValueNotifier 驱动 CustomPainter 重绘，
  /// 避免 _onTick 每帧 setState 触发 widget 重建
  final ValueNotifier<double> _tNotifier = ValueNotifier<double>(0);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    // 根据 isPlaying 决定是否启动 ticker
    if (widget.isPlaying) {
      _ticker.start();
    }
  }

  @override
  void didUpdateWidget(covariant PlayingSpectrumIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    // isPlaying 状态变化时启停 ticker：
    // - false → true：重置 _lastElapsed 避免 dt 跳跃，然后 start
    // - true → false：stop 保留最后一帧（_tNotifier 不再更新，画面冻结）
    if (widget.isPlaying != oldWidget.isPlaying) {
      if (widget.isPlaying) {
        _lastElapsed = Duration.zero;
        _ticker.start();
      } else {
        _ticker.stop();
      }
    }
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastElapsed).inMicroseconds / 1000000.0;
    _lastElapsed = elapsed;
    // 推进时间并通过 ValueNotifier 触发 CustomPainter 重绘
    // 不需要 setState：painter 通过 _tNotifier 自动重绘
    _tNotifier.value = _tNotifier.value + dt;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _tNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _SpectrumPainter(
          color: widget.color,
          tNotifier: _tNotifier,
          size: size,
          barWidth: size / 4.5,
          spacing: size / 6,
        ),
      ),
    );
  }
}

class _SpectrumPainter extends CustomPainter {
  final Color color;
  final ValueNotifier<double> tNotifier;
  final double size;
  final double barWidth;
  final double spacing;

  _SpectrumPainter({
    required this.color,
    required this.tNotifier,
    required this.size,
    required this.barWidth,
    required this.spacing,
  }) : super(repaint: tNotifier);

  @override
  void paint(Canvas canvas, Size canvasSize) {
    final t = tNotifier.value;
    // 3 根柱基础高度 + 振幅
    final baseHeight = size * 0.4;
    final ampHeight = size * 0.5;
    // 周期 800ms = 0.8s
    const period = 0.8;

    final paint = Paint()..color = color;
    final totalWidth = 3 * barWidth + 2 * spacing;
    final startX = (canvasSize.width - totalWidth) / 2;
    for (int i = 0; i < 3; i++) {
      // 相位错开 0 / 0.4 / 0.8
      final phase = i * 0.4;
      final s = (math.sin((t / period + phase) * 2 * math.pi) + 1) / 2;
      final h = baseHeight + ampHeight * s;
      final x = startX + i * (barWidth + spacing);
      final y = (canvasSize.height - h) / 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, barWidth, h),
          Radius.circular(barWidth / 2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SpectrumPainter oldDelegate) {
    // t 变化由 Listenable (super(repaint: tNotifier)) 自动驱动重绘，
    // 这里只需检查不变的参数是否变化（color/size 等）
    return oldDelegate.color != color ||
        oldDelegate.size != size ||
        oldDelegate.barWidth != barWidth ||
        oldDelegate.spacing != spacing;
  }
}
