import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../core/services/player_frame_driver.dart';

/// 正在播放频谱标识。
///
/// 用 Ticker 驱动 3 根粒度柱高度做 sin 波动，周期 800ms，
/// 三根柱相位错开 0 / 0.4 / 0.8，呈现类似 Apple Music / 网易云的「正在播放」装饰性动画。
///
/// 仅是装饰性动画（不订阅 amplitudeStream / 不需要任何权限），
/// 用来替代 [CircularProgressIndicator] loading 圈作为歌曲列表「正在播放」标识。
///
/// **性能优化 1**：用 [ValueNotifier] 驱动 [CustomPainter] 重绘，
/// 避免每帧 setState 触发 widget 重建。
///
/// **性能优化 2（驱动源）**：不使用 [Ticker]——Ticker 会每 vsync
/// scheduleFrame，120Hz 屏上即便本组件只是装饰性动画，也会让**整页**保持
/// 120fps（实测：正在播放行常驻于播放列表 tab，即使不可见也持续 tick，
/// 整页帧率由 60 被顶到 ~120，功耗近似翻倍）。
/// 改挂 [PlayerFrameDriver] 共享 60fps 节拍：与歌词/封面旋转同相位，
/// 整页回到 60fps，而本动画的更新率不变（仍 60fps）。
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
    with WidgetsBindingObserver {
  /// 是否已挂到共享 60fps 帧驱动上。
  bool _boundToDriver = false;

  /// [TickerMode] 是否被关闭（被不透明路由覆盖 / TabBarView 切走）。
  ///
  /// 本组件常驻于歌曲列表行（`song_list_item` / `player_playlist_view`），
  /// 而首页 tab 由 `ResponsiveShell` 的 `IndexedStack` 保活 —— `TickerMode`
  /// 关的是 Ticker，**关不住共享 Timer**，切走 tab 后仍会持续产帧（§10.4.3）。
  bool _tickerModeMuted = false;

  /// App 是否退到后台（引擎不产帧，Timer 空转纯属唤醒浪费）。
  bool _appSuspended = false;

  /// 时间累积通过 ValueNotifier 驱动 CustomPainter 重绘，
  /// 避免 _onTick 每帧 setState 触发 widget 重建
  final ValueNotifier<double> _tNotifier = ValueNotifier<double>(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _syncDriver();
  }

  /// 共享 `Timer` 不受 `TickerMode` 约束（§10.3），必须自行同步挂起。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool muted = !TickerMode.valuesOf(context).enabled;
    if (muted == _tickerModeMuted) return;
    _tickerModeMuted = muted;
    _syncDriver();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final bool suspended = state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached;
    if (suspended == _appSuspended) return;
    _appSuspended = suspended;
    _syncDriver();
  }

  @override
  void didUpdateWidget(covariant PlayingSpectrumIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    // isPlaying 变化时启停（保留最后一帧：解除订阅后 _tNotifier 不再更新）
    if (widget.isPlaying != oldWidget.isPlaying) {
      _syncDriver();
    }
  }

  /// 唯一收口：仅在「播放中 + 可见 + 前台」时挂共享 60fps 节拍（幂等）。
  void _syncDriver() {
    final bool shouldRun =
        widget.isPlaying && !_tickerModeMuted && !_appSuspended;
    if (shouldRun == _boundToDriver) return;
    if (shouldRun) {
      PlayerFrameDriver.instance.addListener(_onSharedTick);
    } else {
      PlayerFrameDriver.instance.removeListener(_onSharedTick);
    }
    _boundToDriver = shouldRun;
  }

  /// 共享节拍回调：固定 16ms 步进推进时间，通过 ValueNotifier 触发重绘
  /// （不 setState：painter 通过 _tNotifier 自动重绘）。
  void _onSharedTick() {
    _tNotifier.value += PlayerFrameDriver.step.inMicroseconds / 1000000.0;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_boundToDriver) {
      PlayerFrameDriver.instance.removeListener(_onSharedTick);
      _boundToDriver = false;
    }
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
