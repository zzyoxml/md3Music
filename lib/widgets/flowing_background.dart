import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
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
    with TickerProviderStateMixin, WidgetsBindingObserver {
  Ticker? _ticker;
  // 时间累积通过 ValueNotifier 驱动 CustomPainter 重绘，避免每帧 setState
  // 触发 widget 重建
  final ValueNotifier<double> _timeNotifier = ValueNotifier<double>(0);
  // 帧率节流累积器：dt 累积到 >= _frameInterval 才更新 _timeNotifier
  double _accumulatedDt = 0;
  // 目标帧间隔：1/24 秒（约 41.7ms）。
  // 24fps 是电影工业标准帧率，对人眼缓慢色彩流动足够流畅；
  // 相比 60fps 减少 60% 帧数，CPU/GPU 工作量同步下降。
  static const double _frameInterval = 1 / 24;
  Duration _lastElapsed = Duration.zero;
  List<Color> _colors = const [Colors.deepPurple, Colors.indigo, Colors.teal];
  String? _lastArtworkUrl;
  // dispose 标志：用于取消 _extractColors 异步任务，
  // 避免 setState 在 widget 销毁后被调用
  bool _disposed = false;
  // Ticker 真实运行状态跟踪，用于幂等保护 start/stop 调用
  // （Ticker.start() 在 Flutter 3.44+ 重复调用会断言失败）
  bool _isRunning = false;

  /// 幂等地启动/停止 Ticker。
  ///
  /// Flutter 3.44 起 `Ticker.start()` 不允许重复调用，
  /// 必须用单一状态变量跟踪当前运行状态：
  /// - 已运行时再 start → 直接 return
  /// - 已停止时再 stop → 直接 return
  /// - 状态切换时才真正调用 start/stop
  void _setRunning(bool running) {
    if (running == _isRunning) return;
    _isRunning = running;
    if (running) {
      _lastElapsed = Duration.zero;
      _accumulatedDt = 0;
      _ticker?.start();
    } else {
      _ticker?.stop();
    }
  }

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    // 注册生命周期监听：后台时停止 Ticker，前台时按 isPlaying 决定是否恢复
    WidgetsBinding.instance.addObserver(this);
    // 根据初始 isPlaying 决定是否启动 Ticker
    // （避免 didUpdateWidget 后再次 start 触发 "started twice" 断言）
    _setRunning(widget.isPlaying);
    _extractColors();
  }

  @override
  void didUpdateWidget(covariant FlowingBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artworkUrl != widget.artworkUrl) {
      _extractColors();
    }
    // 播放状态变化时切换 Ticker（_setRunning 内部做幂等保护）
    if (oldWidget.isPlaying != widget.isPlaying) {
      _setRunning(widget.isPlaying);
    }
  }

  /// 响应 App 生命周期：后台时停止 Ticker 节省功耗。
  ///
  /// 不依赖 Flutter TickerMode 的原因：部分 Android ROM 在后台仍触发 vsync，
  /// 导致 Ticker 持续运行。显式停止 Ticker 可确保后台零功耗。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _setRunning(false);
    } else if (state == AppLifecycleState.resumed) {
      // 重置 _lastElapsed 避免 resumed 后 dt 跳变（累积后台时间）
      _lastElapsed = Duration.zero;
      _accumulatedDt = 0;
      _setRunning(widget.isPlaying);
    }
  }

  /// widget 从树中移除时（如路由收起）立即停止 Ticker。
  ///
  /// 关键修复：路由 dismiss 时 removeRoute 会触发子树 deactivate，
  /// 若 Ticker 仍在持续触发 setState，子树会保持 dirty 状态，
  /// 导致 InheritedElement.debugDeactivated 中的
  /// `_dependents.isEmpty` 断言失败（dependent 还未清理）。
  /// 在 deactivate 中提前停止 Ticker 可避免此竞态。
  @override
  void deactivate() {
    _setRunning(false);
    super.deactivate();
  }

  void _onTick(Duration elapsed) {
    // 防御性检查：widget 已销毁或不活跃时跳过
    if (!mounted || _disposed) return;
    // _lastElapsed 在 start/resume 时重置为 zero，首帧 dt 会被跳过
    if (_lastElapsed == Duration.zero) {
      _lastElapsed = elapsed;
      return;
    }
    final dt = (elapsed - _lastElapsed).inMicroseconds / 1000000.0;
    _lastElapsed = elapsed;
    // 累积时间，达到 _frameInterval 才推进 _time 并触发重绘
    _accumulatedDt += dt;
    if (_accumulatedDt >= _frameInterval) {
      // 与原实现一致：_time += dt * 0.5（0.5 倍速，4秒一个周期）
      // 这里用累积的 dt 计算，保持视觉速度不变
      _timeNotifier.value = _timeNotifier.value + _accumulatedDt * 0.5;
      _accumulatedDt = 0;
      // 不需要 setState：CustomPainter 通过 _timeNotifier 自动重绘
    }
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
      // 双重检查：mounted（widget 还在树中）+ _disposed（State 未销毁）
      if (!mounted || _disposed) return;
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
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _setRunning(false); // 幂等停止（deactivate 已停过则直接 return）
    _ticker?.dispose();
    _timeNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _FlowingGradientPainter(
          colors: _colors,
          timeNotifier: _timeNotifier,
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
  final ValueNotifier<double> timeNotifier;

  _FlowingGradientPainter({
    required this.colors,
    required this.timeNotifier,
  }) : super(repaint: timeNotifier);

  @override
  void paint(Canvas canvas, Size size) {
    if (colors.isEmpty) return;

    // 从 ValueNotifier 读取当前时间（由 _onTick 节流后更新）
    final time = timeNotifier.value;

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
    // time 变化由 Listenable (super(repaint: timeNotifier)) 自动驱动重绘，
    // 这里只需检查 colors 是否变化以触发 painter 重建（_extractColors 后）
    // 用 listEquals 避免逐元素比较的样板代码
    return !listEquals(colors, oldDelegate.colors);
  }
}
