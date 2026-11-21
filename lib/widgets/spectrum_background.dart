import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/services/player_frame_driver.dart';
import '../core/services/spectrum_band_envelope.dart';
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

  /// 频谱包络：瞬时上升 + 时基指数回落，由 60fps 共享节拍推进。
  late SpectrumBandEnvelope _envelope;

  /// 频谱流订阅
  StreamSubscription<List<double>>? _subscription;

  /// 柱数量（根据屏幕宽度计算，约每 5px 一根）
  int _barCount = 64;

  /// 包络是否已挂在共享 60fps 帧驱动上
  bool _bandDriverBound = false;

  /// 测量真实帧间隔，供包络按**时间**推进
  final Stopwatch _bandClock = Stopwatch();
  int _lastBandTickUs = 0;

  @override
  void initState() {
    super.initState();
    _envelope = SpectrumBandEnvelope(bandCount: _barCount);
    _bandsNotifier = ValueNotifier<List<double>>(
      List<double>.filled(_barCount, 0.0),
    );
    _subscribeSpectrum();
    _updateBandBinding();
  }

  @override
  void didUpdateWidget(covariant SpectrumBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    // visible 控制背景层是否显示；隐藏后仍需推进到收敛，柱子才会平滑塌回
    if (oldWidget.visible != widget.visible) {
      _updateBandBinding();
    }
  }

  /// 订阅频谱数据流：重采样后**只登记目标值**，插值交给 60fps 节拍。
  ///
  /// 在此处插值会让回落量化成每秒约 20 个台阶（数据到达频率）。
  /// 重采样仍留在本 widget（包络只管包络，不管分段）。
  void _subscribeSpectrum() {
    _subscription?.cancel();
    _subscription = SpectrumService.instance.spectrumStream.listen((bands) {
      if (!mounted) return;
      // 将原生 40 段数据重采样到 _barCount 段
      _envelope.setTarget(_resample(bands, _barCount));
      _updateBandBinding();
    });
  }

  /// 包络 tick 的绑定条件：可见，或尚未收敛。
  void _updateBandBinding() {
    final need = widget.visible || !_envelope.isSettled;
    if (need == _bandDriverBound) return;
    if (need) {
      // 重新起算时间基线：Stopwatch 跨停/启会累积，直接 elapsed 会得到巨大 dt
      _bandClock
        ..reset()
        ..start();
      _lastBandTickUs = 0;
      PlayerFrameDriver.instance.addListener(_onBandTick);
    } else {
      _bandClock.stop();
      PlayerFrameDriver.instance.removeListener(_onBandTick);
    }
    _bandDriverBound = need;
  }

  /// 以真实帧间隔推进包络并驱动重绘。
  void _onBandTick() {
    if (!mounted) return;
    final nowUs = _bandClock.elapsedMicroseconds;
    final dtUs = nowUs - _lastBandTickUs;
    _lastBandTickUs = nowUs;
    if (dtUs <= 0) return;

    _envelope.advance(Duration(microseconds: dtUs));
    // 必须新建 List 实例：ValueNotifier<List> 用同一性比较
    _bandsNotifier.value = List.from(_envelope.values);

    _updateBandBinding();
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
    if (_bandDriverBound) {
      PlayerFrameDriver.instance.removeListener(_onBandTick);
      _bandDriverBound = false;
    }
    _bandClock.stop();
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
            // 柱数变化：同步重建包络与其缓冲，避免长度错位
            _envelope = SpectrumBandEnvelope(bandCount: _barCount);
            _bandsNotifier.value = List<double>.filled(_barCount, 0.0);
          }

          return Opacity(
            opacity: widget.opacity,
            // 频谱每帧重绘：独立 layer，避免脏区扩散到整个背景层
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _SpectrumBarsPainter(
                  bandsNotifier: _bandsNotifier,
                  color: widget.color,
                  barCount: _barCount,
                  heightRatio: widget.heightRatio,
                ),
                child: const SizedBox.expand(),
              ),
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
  }) : _paint = Paint()
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
