import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../core/services/player_frame_driver.dart';

import '../core/services/spectrum_band_envelope.dart';
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
/// - `isPlaying=true` → 60fps Timer 步进控制器值，**顺时针**（约 8s/圈）
/// - `isPlaying=false` → 停止，**保持当前角度静止**（不 reset，恢复播放时续转）
///
/// 帧率说明：不使用 `AnimationController.repeat()`——repeat 会让控制器 Ticker
/// 每帧 scheduleFrame，120Hz 屏上即便画面未变也保持 120fps 帧管线（与歌词省电
/// 模式相同的坑）。改用 16ms Timer 直接步进控制器值，帧生产被限制到 60fps。
///
/// 性能：环形频谱柱用 [ValueNotifier] + `super(repaint:)` 驱动重绘，
/// 旋转用 [AnimatedBuilder] 局部重建，避免每帧 setState。
/// 两层各自包 [RepaintBoundary]：频谱与旋转每帧都重绘，隔离后可避免脏区扩散。
///
/// 幅值插值由 [SpectrumBandEnvelope] 在共享 60fps 节拍上按真实 dt 推进
///（不是数据到达时推进一次）—— 数据只有约 20fps，逐到达插值会呈现台阶感。
///
/// 无数据（暂停/未播放/采集失败）时：环形柱为静止低柱，封面静止。
class SpectrumArtwork extends StatefulWidget {
  /// 环形频谱为外圈柱子预留的比例（单侧）：柱子最大长度 = 组件边长 × 本值，
  /// 圆形封面直径因此是边长的 `1 - 2 * barReserveRatio`。
  ///
  /// 公开为常量：播放页 Zen 长按提示层要按同一比例内缩，黑底才能正好裁在
  /// 封面那个圆上（各处各写一份 0.12 迟早会漂移）。
  static const double barReserveRatio = 0.12;

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

  /// 频谱整体透明度（0.0~1.0，默认 1.0 不透明）。
  /// 柱状图与曲线共用，由调用方按样式分开记忆后传入。
  final double opacity;

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
    this.opacity = 1.0,
    this.rotationDuration = const Duration(seconds: 8),
  });

  @override
  State<SpectrumArtwork> createState() => _SpectrumArtworkState();
}

class _SpectrumArtworkState extends State<SpectrumArtwork>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _rotationController;
  late final Animation<double> _rotationAnimation;

  /// 封面旋转是否已挂在共享 60fps 帧驱动上（见 [PlayerFrameDriver]）。
  bool _rotationDriverBound = false;

  /// 频谱包络是否已挂在共享 60fps 帧驱动上。
  bool _bandDriverBound = false;

  /// 频谱幅值数组（0..1）。驱动 CustomPainter 重绘，不触发 setState。
  late final ValueNotifier<List<double>> _bandsNotifier;

  /// 频谱包络：瞬时上升 + 时基指数回落，由 60fps 共享节拍推进。
  late SpectrumBandEnvelope _envelope;

  /// 测量真实帧间隔，供包络按**时间**推进（而非按调用次数）。
  final Stopwatch _bandClock = Stopwatch();
  int _lastBandTickUs = 0;

  /// 频谱流订阅
  StreamSubscription<List<double>>? _subscription;

  /// [TickerMode] 是否被关闭（播放页被不透明路由覆盖 / TabBarView 切走）。
  bool _tickerModeMuted = false;

  /// App 是否退到后台（引擎不产帧，Timer 空转纯属唤醒浪费）。
  bool _appSuspended = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _rotationController = AnimationController(
      duration: widget.rotationDuration,
      vsync: this,
    );
    // 注意：Tween begin=0 end=2π（顺时针）；AnimatedBuilder 旋转角度从 0 递增
    _rotationAnimation = Tween<double>(
      begin: 0.0,
      end: 2 * math.pi,
    ).animate(_rotationController);

    _envelope = SpectrumBandEnvelope(bandCount: widget.bandCount);
    _bandsNotifier = ValueNotifier<List<double>>(
      List<double>.filled(widget.bandCount, 0.0),
    );

    _subscribeSpectrum();
    _syncFrameDriverBindings();
  }

  @override
  void didUpdateWidget(covariant SpectrumArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying != widget.isPlaying) {
      _syncFrameDriverBindings();
    }
    if (oldWidget.bandCount != widget.bandCount) {
      _envelope = SpectrumBandEnvelope(bandCount: widget.bandCount);
      _bandsNotifier.value = List<double>.filled(widget.bandCount, 0.0);
      _syncFrameDriverBindings();
    }
    if (oldWidget.rotationDuration != widget.rotationDuration) {
      _rotationController.duration = widget.rotationDuration;
    }
  }

  /// 帧生产是否被挂起：`TickerMode` 关闭（被不透明路由覆盖）或 App 退到后台。
  ///
  /// 共享 `Timer` 不受 `TickerMode` 约束（§10.3），必须自行同步挂起，
  /// 否则「组件不可见仍持续产帧」——本仓最常见的漏电点（§10.4.3）。
  bool get _framesSuspended => _tickerModeMuted || _appSuspended;

  /// 同步两个 60fps 订阅：封面旋转（仅播放时）与频谱包络（播放中**或**未收敛）。
  ///
  /// 用 Timer 直接步进控制器值而非 `repeat()`：控制器 Ticker 不会被启动，
  /// 帧生产由共享节拍限制到 60fps（repeat 会让 120Hz 屏保持 120fps）。
  ///
  /// 两者挂同一个 [PlayerFrameDriver]，因此**不增加任何帧生产**。
  void _syncFrameDriverBindings() {
    // ── 封面旋转 ──
    if (widget.isPlaying && !_framesSuspended) {
      if (!_rotationDriverBound) {
        // 与歌词共用同一个 60fps 节拍：两个独立 16ms Timer 相位错开会让
        // 120Hz 屏整页跑到 ~120fps（实测），合并后整页回到 60fps，
        // 而封面旋转本身的更新率不变（仍 60fps）。
        PlayerFrameDriver.instance.addListener(_onRotationTick);
        _rotationDriverBound = true;
      }
    } else if (_rotationDriverBound) {
      PlayerFrameDriver.instance.removeListener(_onRotationTick);
      _rotationDriverBound = false;
    }

    // ── 频谱包络 ──
    // 暂停后目标已被 SpectrumService 推成全 0，仍需继续推进直到收敛，
    // 柱子才会平滑塌回（而不是冻在高位再整体淡出）；收敛即解绑，不留空转订阅。
    _updateBandBinding();
  }

  /// 包络 tick 的绑定条件：可见，且（播放中或尚未收敛）。
  void _updateBandBinding() {
    final need =
        !_framesSuspended && (widget.isPlaying || !_envelope.isSettled);
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

  /// 共享 `Timer` 不受 `TickerMode` 约束（§10.3），必须自行同步挂起。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool muted = !TickerMode.valuesOf(context).enabled;
    if (muted == _tickerModeMuted) return;
    _tickerModeMuted = muted;
    _syncFrameDriverBindings();
  }

  /// 后台/熄屏时引擎不合成帧，两个订阅一并停掉（§10.4.3）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final bool suspended = state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached;
    if (suspended == _appSuspended) return;
    _appSuspended = suspended;
    _syncFrameDriverBindings();
  }

  /// 幂等退订两个共享节拍订阅（[deactivate] / [dispose] 共用）。
  void _unbindAll() {
    if (_rotationDriverBound) {
      PlayerFrameDriver.instance.removeListener(_onRotationTick);
      _rotationDriverBound = false;
    }
    if (_bandDriverBound) {
      PlayerFrameDriver.instance.removeListener(_onBandTick);
      _bandDriverBound = false;
    }
    _bandClock.stop();
  }

  /// widget 移出树时立即解绑：旋转经 `AnimatedBuilder` 的 setState 生效，
  /// 路由 dismiss 期间继续推进会让已 deactivate 的子树保持 dirty。
  @override
  void deactivate() {
    _unbindAll();
    super.deactivate();
  }

  /// 以 16ms 步进推进旋转角度（控制器值 0→1 循环，映射到 0→2π）。
  void _onRotationTick() {
    if (!mounted) return;
    // 每 16ms 推进的圈数比例：16ms / 转一圈时长
    final step = 16.0 / widget.rotationDuration.inMilliseconds;
    _rotationController.value = (_rotationController.value + step) % 1.0;
  }

  /// 以真实帧间隔推进频谱包络，并驱动 CustomPainter 重绘。
  void _onBandTick() {
    if (!mounted) return;
    final nowUs = _bandClock.elapsedMicroseconds;
    final dtUs = nowUs - _lastBandTickUs;
    _lastBandTickUs = nowUs;
    if (dtUs <= 0) return;

    _envelope.advance(Duration(microseconds: dtUs));
    // 必须新建 List 实例：ValueNotifier<List> 用同一性比较，
    // 赋同一个实例不会通知监听者，也就不会重绘。
    _bandsNotifier.value = List.from(_envelope.values);

    // 收敛后自行解绑（暂停塌回完成时走这条），避免空转
    _updateBandBinding();
  }

  /// 订阅 SpectrumService 数据流：**只登记目标值**，不做插值。
  ///
  /// 插值交给 [_onBandTick] 在共享 60fps 节拍上按真实 dt 推进。若在此处插值，
  /// 回落会被量化成每秒约 20 个台阶（数据到达频率），而同一屏的封面旋转是 60fps，
  /// 反差会非常明显 —— 这正是本次要修的问题。
  void _subscribeSpectrum() {
    _subscription?.cancel();
    _subscription = SpectrumService.instance.spectrumStream.listen((bands) {
      if (!mounted) return;
      _envelope.setTarget(bands);
      _updateBandBinding();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _unbindAll(); // 幂等解绑（deactivate 已解绑过则直接 return）
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
            : (constraints.maxHeight.isFinite ? constraints.maxHeight : 280.0);
        // 环形频谱预留外圈空间：柱最大长度 = size × barReserveRatio
        const barMaxLenRatio = SpectrumArtwork.barReserveRatio;
        final coverDiameter = size * (1.0 - 2 * barMaxLenRatio);
        final coverRadius = coverDiameter / 2;
        final center = Offset(size / 2, size / 2);

        return SizedBox(
          width: size,
          height: size,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // ── 1. 环形频谱层（柱状或曲线）：AnimatedOpacity 过渡，播放时淡入、暂停淡出 ──
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: widget.isPlaying ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 350),
                    curve: Curves.easeOut,
                    // 频谱每帧重绘：独立 layer，避免脏区扩散到播放页其余部分
                    child: RepaintBoundary(
                      child: CustomPaint(
                        painter: widget.style == 1
                            ? _SpectrumCurvePainter(
                                bandsNotifier: _bandsNotifier,
                                center: center,
                                coverRadius: coverRadius,
                                barMaxLen: size * barMaxLenRatio,
                                color: barColor,
                                bandCount: widget.bandCount,
                                opacity: widget.opacity,
                              )
                            : _SpectrumRingPainter(
                                bandsNotifier: _bandsNotifier,
                                center: center,
                                coverRadius: coverRadius,
                                barMaxLen: size * barMaxLenRatio,
                                color: barColor,
                                bandCount: widget.bandCount,
                                opacity: widget.opacity,
                              ),
                      ),
                    ),
                  ),
                ),
              ),
              // ── 2. 圆形旋转封面层 ──
              Positioned(
                left: center.dx - coverRadius,
                top: center.dy - coverRadius,
                width: coverDiameter,
                height: coverDiameter,
                // 旋转每帧重绘：与频谱层分开隔离，两者频率与内容都不同
                child: RepaintBoundary(
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
  final double opacity;

  _SpectrumRingPainter({
    required this.bandsNotifier,
    required this.center,
    required this.coverRadius,
    required this.barMaxLen,
    required this.color,
    required this.bandCount,
    required this.opacity,
  }) : _cosTable = List<double>.generate(
         bandCount,
         (i) => math.cos(-math.pi / 2 + i * 2 * math.pi / bandCount),
       ),
       _sinTable = List<double>.generate(
         bandCount,
         (i) => math.sin(-math.pi / 2 + i * 2 * math.pi / bandCount),
       ),
       _barWidth = bandCount > 0
           ? (2 * math.pi * (coverRadius + barMaxLen / 2) / bandCount) * 0.78
           : 0.0,
       super(repaint: bandsNotifier) {
    _paint.color = color.withValues(alpha: color.a * opacity);
    _paint.strokeWidth = _barWidth;
  }

  /// 预计算的三角函数表（构造时一次算出，避免每帧重复 sin/cos）
  final List<double> _cosTable;
  final List<double> _sinTable;

  /// 柱宽度：根据柱数等分圆周，间距小（0.78 = 柱占78%、间距22%）
  final double _barWidth;

  /// 复用的 Path 与 Paint：每帧 reset 后重建，避免每帧分配对象
  final Path _path = Path();
  final Paint _paint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.butt; // 顶部不圆角，且不延伸

  @override
  void paint(Canvas canvas, Size size) {
    final bands = bandsNotifier.value;
    final n = bandCount;
    if (n <= 0) return;

    // 基准高度：无数据时显示静止低柱（视觉上不空）
    final baseLen = barMaxLen * 0.12;

    // 从 12 点方向（-π/2）起顺时针，角度用预计算表查表
    final path = _path..reset();
    for (int i = 0; i < n; i++) {
      final cosA = _cosTable[i];
      final sinA = _sinTable[i];
      final v = (i < bands.length) ? bands[i].clamp(0.0, 1.0) : 0.0;
      final len = baseLen + barMaxLen * v;

      // 柱起点：紧贴圆形封面外缘（无空隙）；终点：向外辐射
      path
        ..moveTo(center.dx + coverRadius * cosA, center.dy + coverRadius * sinA)
        ..lineTo(
          center.dx + (coverRadius + len) * cosA,
          center.dy + (coverRadius + len) * sinA,
        );
    }
    // 40 根柱合并为一条路径一次绘制，替代 40 次 drawLine
    canvas.drawPath(path, _paint);
  }

  @override
  bool shouldRepaint(covariant _SpectrumRingPainter oldDelegate) {
    // bands 变化由 Listenable (super(repaint:)) 自动驱动重绘，
    // 这里只检查不变参数
    return oldDelegate.center != center ||
        oldDelegate.coverRadius != coverRadius ||
        oldDelegate.barMaxLen != barMaxLen ||
        oldDelegate.color != color ||
        oldDelegate.bandCount != bandCount ||
        oldDelegate.opacity != opacity;
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
  final double opacity;

  _SpectrumCurvePainter({
    required this.bandsNotifier,
    required this.center,
    required this.coverRadius,
    required this.barMaxLen,
    required this.color,
    required this.bandCount,
    required this.opacity,
  }) : _cosTable = List<double>.generate(
         bandCount,
         (i) => math.cos(-math.pi / 2 + i * 2 * math.pi / bandCount),
       ),
       _sinTable = List<double>.generate(
         bandCount,
         (i) => math.sin(-math.pi / 2 + i * 2 * math.pi / bandCount),
       ),
       _fillPaint = Paint()
         ..color = color.withValues(alpha: color.a * opacity * 0.15)
         ..style = PaintingStyle.fill,
       _strokePaint = Paint()
         ..color = color.withValues(alpha: color.a * opacity)
         ..style = PaintingStyle.stroke
         ..strokeWidth = 2.0
         ..strokeJoin = StrokeJoin.round
         ..strokeCap = StrokeCap.round,
       super(repaint: bandsNotifier);

  /// 预计算的三角函数表（构造时一次算出，避免每帧重复 sin/cos）
  final List<double> _cosTable;
  final List<double> _sinTable;

  /// 半透明填充与描边画笔（构造时一次创建）
  final Paint _fillPaint;
  final Paint _strokePaint;

  /// 复用的 Path 与坐标缓冲：每帧 reset 后重建，避免每帧分配对象
  final Path _path = Path();
  final List<Offset> _points = <Offset>[];

  @override
  void paint(Canvas canvas, Size size) {
    final bands = bandsNotifier.value;
    final n = bandCount;
    if (n < 3) return;

    // 基准高度：无数据时紧贴封面外缘
    final baseLen = barMaxLen * 0.05;

    // 计算每个频点的坐标（复用缓冲，避免每帧分配 List<Offset>）
    final points = _points..clear();
    for (int i = 0; i < n; i++) {
      final v = (i < bands.length) ? bands[i].clamp(0.0, 1.0) : 0.0;
      final r = coverRadius + baseLen + barMaxLen * v;
      points.add(
        Offset(center.dx + r * _cosTable[i], center.dy + r * _sinTable[i]),
      );
    }

    // 用平滑闭合曲线连接所有点（quadraticBezierTo，控制点=当前点，终点=相邻两点中点）
    final path = _path..reset();
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

    // 半透明填充 + 描边
    canvas.drawPath(path, _fillPaint);
    canvas.drawPath(path, _strokePaint);
  }

  @override
  bool shouldRepaint(covariant _SpectrumCurvePainter oldDelegate) {
    return oldDelegate.center != center ||
        oldDelegate.coverRadius != coverRadius ||
        oldDelegate.barMaxLen != barMaxLen ||
        oldDelegate.color != color ||
        oldDelegate.bandCount != bandCount ||
        oldDelegate.opacity != opacity;
  }
}
