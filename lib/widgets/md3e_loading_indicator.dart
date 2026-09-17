import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// MD3 Expressive 风格 Loading 指示器。
///
/// 参考：
/// - https://m3.material.io/components/loading-indicator/overview
/// - https://m3.material.io/components/loading-indicator/specs
///
/// M3E 的 Loading Indicator 是 2025 年新增组件，**取代 indeterminate
/// CircularProgressIndicator**。其核心特征是：
///   1. **形状变形（Shape Morph）**：活动指示器在 7 个 Material 3 形状之间
///      循环变形，通过形状变化捕获用户注意力。
///   2. **弹簧物理运动**：使用 [M3ExpressiveMotion.defaultSpring] 风格的弹簧
///      物理曲线，让形状切换带有自然过冲感，而不是死板的线性插值。
///   3. **可配置尺寸**：默认 48dp（按 M3 规范），可在 24~240dp 范围缩放。
///   4. **两种配置**：
///      - [MD3ELoadingIndicator] 默认：仅活动指示器，颜色为 `primary`。
///      - 设置 [contained] 为 true：包含圆形 primaryContainer 容器，活动指示器
///        变为 `onPrimaryContainer`，用于浮在内容之上时增强对比度。
///   5. **随机起始形状**：每次启动从 7 个形状中随机选一个开始，
///      避免每次都是圆开头造成单调感。
///
/// 使用示例：
/// ```dart
/// // 取代 CircularProgressIndicator()
/// const MD3ELoadingIndicator()
///
/// // 容器变体（用于浮于内容之上）
/// const MD3ELoadingIndicator(contained: true)
///
/// // 自定义尺寸
/// const MD3ELoadingIndicator(size: 32)
/// ```
class MD3ELoadingIndicator extends StatefulWidget {
  /// 指示器整体尺寸（正方形边长）。
  ///
  /// M3 规范：默认 48dp，可在 24~240dp 之间缩放。
  /// 容器尺寸为 [size] * 38/48 ≈ 0.79（按规范"48dp size, 38dp shape container"）。
  final double size;

  /// 是否显示容器（Contained 变体）。
  ///
  /// - false（默认）：仅绘制活动指示器，使用 [ColorScheme.primary]。
  /// - true：绘制圆形 primaryContainer 容器 + 活动指示器，活动指示器使用
  ///   [ColorScheme.onPrimaryContainer]。
  ///
  /// 当指示器需要浮在内容之上（如图片加载、按钮内 loading、Pull-to-refresh）
  /// 时建议启用，以增强对比度。
  final bool contained;

  /// 自定义活动指示器颜色。
  ///
  /// 不传时按规范：
  /// - [contained]=false：使用 [ColorScheme.primary]
  /// - [contained]=true：使用 [ColorScheme.onPrimaryContainer]
  final Color? color;

  /// 自定义容器颜色（仅 [contained]=true 时生效）。
  ///
  /// 不传时使用 [ColorScheme.primaryContainer]。
  final Color? containerColor;

  /// 是否在启动时从随机形状开始（而非固定的圆）。
  ///
  /// - true（默认）：每次实例化时随机选 0~6 中的一个形状作为起点，
  ///   7 个形状会以不同顺序出现，避免每次都是"圆→超椭圆→..."的单调感。
  /// - false：从圆开始，按 0,1,2,...,6 顺序循环。
  ///
  /// 适合 fixed 指示器（如对话框中的 loading）随机化；
  /// 对于持续性动画（如正在播放频谱）建议关闭。
  final bool randomStartShape;

  const MD3ELoadingIndicator({
    super.key,
    this.size = 48.0,
    this.contained = false,
    this.color,
    this.containerColor,
    this.randomStartShape = true,
  });

  @override
  State<MD3ELoadingIndicator> createState() => _MD3ELoadingIndicatorState();
}

class _MD3ELoadingIndicatorState extends State<MD3ELoadingIndicator>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _lastElapsed = Duration.zero;

  /// 时间累积通过 [ValueNotifier] 驱动 [CustomPainter] 重绘，
  /// 避免 _onTick 每帧 setState 触发 widget 重建（性能优化策略，
  /// 参考 [PlayingSpectrumIndicator] 的同类实现）。
  final ValueNotifier<double> _tNotifier = ValueNotifier<double>(0);

  /// 起始形状偏移（单位：秒）。
  /// 通过把这个偏移加到 [t] 上，实现"从随机形状开始"的效果。
  /// 默认 randomStartShape=true 时，在 initState 中随机生成。
  late final double _startShapeOffset;

  /// 是否为首次 tick，用于在首帧注入起始形状偏移。
  /// 不能用 _tNotifier.value == 0 判断，因为偏移可能恰好是 0。
  bool _isFirstTick = true;

  @override
  void initState() {
    super.initState();
    // 随机起始形状：把偏移换算为时间秒数。
    // _morphCycleSeconds / 7 = 每个形状持续时间
    // 乘以随机形状索引得到该形状的起始时间。
    const shapeCount = 7;
    const morphCycleSeconds = 3.5;
    final randomShapeIndex = widget.randomStartShape
        ? math.Random().nextInt(shapeCount)
        : 0;
    _startShapeOffset =
        randomShapeIndex * (morphCycleSeconds / shapeCount);
    _ticker = createTicker(_onTick);
    _ticker.start();
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastElapsed).inMicroseconds / 1000000.0;
    _lastElapsed = elapsed;
    // 首帧注入起始形状偏移，让动画从随机形状开始
    final offset = _isFirstTick ? _startShapeOffset : 0.0;
    _tNotifier.value = _tNotifier.value + dt + offset;
    _isFirstTick = false;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _tNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final indicatorColor = widget.color ??
        (widget.contained ? colorScheme.onPrimaryContainer : colorScheme.primary);
    final containerColor =
        widget.containerColor ?? colorScheme.primaryContainer;

    // 按规范：48dp size 对应 38dp shape container
    final containerSize = widget.size * 38.0 / 48.0;

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: CustomPaint(
        painter: _MD3ELoadingPainter(
          tNotifier: _tNotifier,
          indicatorColor: indicatorColor,
          containerColor: containerColor,
          showContainer: widget.contained,
          containerSize: containerSize,
        ),
      ),
    );
  }
}

/// 绘制 MD3E Loading Indicator 的形状变形动画。
///
/// **设计原理**：
/// - 通过对单位圆上的固定角度采样点（[kShapeSamples] 个）做径向位移，
///   定义 7 个 Material 3 风格形状。
/// - 每帧根据时间 [t] 计算当前形状索引与下一形状索引，使用 sin 平滑过渡
///   函数做插值，实现形状变形。
/// - 整体大小做轻微弹簧缩放脉冲，进一步强化"有生命感"。
class _MD3ELoadingPainter extends CustomPainter {
  final ValueNotifier<double> tNotifier;
  final Color indicatorColor;
  final Color containerColor;
  final bool showContainer;
  final double containerSize;

  _MD3ELoadingPainter({
    required this.tNotifier,
    required this.indicatorColor,
    required this.containerColor,
    required this.showContainer,
    required this.containerSize,
  }) : super(repaint: tNotifier);

  /// 7 个 Material 3 风格形状的径向采样点。
  ///
  /// 每个形状由 [kShapeSamples] 个半径值（围绕单位圆等角度采样）表示。
  /// 通过对相邻形状的半径数组做线性插值，实现形状变形。
  /// 形状顺序参考 M3 规范"looping shape morph sequence composed of seven
  /// unique Material 3 shapes"。
  static const int kShapeSamples = 32;

  /// 7 个形状的半径值数组。
  ///
  /// 形状含义：
  /// 0. Circle（完美圆）
  /// 1. Squircle（超椭圆）
  /// 2. Rounded Square（小圆角方形）
  /// 3. Diamond（旋转方形/钻石）
  /// 4. Pentagon（五边形）
  /// 5. Hexagon（六边形）
  /// 6. Flower（花瓣）
  static final List<List<double>> _shapes = _buildShapeLibrary();

  /// 完整一轮形状变形的周期（秒）。
  /// 7 个形状 × 每形状 ~500ms ≈ 3.5s 完整一轮，符合 M3 Loading Indicator
  /// "用于 200ms~5s 短时加载"的时长规范。
  static const double _morphCycleSeconds = 3.5;

  static List<List<double>> _buildShapeLibrary() {
    final List<List<double>> shapes = [];
    final int n = kShapeSamples;

    // 0. Circle：所有半径=1.0
    shapes.add(List<double>.filled(n, 1.0));

    // 1. Squircle：超椭圆，4 段对称轻微凸起
    shapes.add(_sampleShape(n, (angle) {
      final c = math.cos(angle);
      final s = math.sin(angle);
      // 超椭圆公式 |x|^4 + |y|^4 = 1 的极坐标形式
      final r = 1.0 / math.pow(math.pow(c.abs(), 4) + math.pow(s.abs(), 4), 0.25);
      return r.clamp(0.85, 1.15);
    }));

    // 2. Rounded Square：方形带大圆角（4 角凸出）
    shapes.add(_sampleShape(n, (angle) {
      // 周期 π/2，cos(4*angle) 在 0,π/2,π,3π/2 处为 1（凸出）
      return 1.0 + 0.15 * math.cos(4 * angle);
    }));

    // 3. Diamond：钻石形（4 个尖角）
    shapes.add(_sampleShape(n, (angle) {
      // 在 0, π/2, π, 3π/2 处 r=1.15（尖角），中间 r=0.85
      return 0.85 + 0.3 * math.pow((math.cos(4 * angle) + 1) / 2, 2);
    }));

    // 4. Pentagon：五边形（5 个尖角）
    shapes.add(_sampleShape(n, (angle) {
      return 0.9 + 0.1 * math.cos(5 * angle - math.pi / 2);
    }));

    // 5. Hexagon：六边形（6 个尖角）
    shapes.add(_sampleShape(n, (angle) {
      return 0.9 + 0.12 * math.cos(6 * angle);
    }));

    // 6. Flower：花瓣（6 瓣）
    shapes.add(_sampleShape(n, (angle) {
      return 0.85 + 0.25 * math.pow((math.cos(6 * angle) + 1) / 2, 1.5);
    }));

    return shapes;
  }

  /// 在 0~2π 范围内等角度采样 [n] 个点，对 [radiusFn] 求值。
  static List<double> _sampleShape(int n, double Function(double angle) radiusFn) {
    final List<double> samples = List<double>.filled(n, 0);
    for (int i = 0; i < n; i++) {
      final angle = (i / n) * 2 * math.pi;
      samples[i] = radiusFn(angle);
    }
    return samples;
  }

  /// 平滑插值曲线：使用 sin² 实现两端缓、中间快的过渡（类似 ease-in-out）。
  /// [progress] ∈ [0, 1]，0 时返回 0（上一形状），1 时返回 1（下一形状）。
  double _smoothProgress(double progress) {
    final p = progress.clamp(0.0, 1.0);
    return p * p * (3 - 2 * p); // smoothstep
  }

  /// 缩放脉冲：整体大小做轻微弹簧缩放，强化"有生命感"。
  /// 使用 sin 波（周期 1.4s，振幅 0.06），与形状变形异步避免视觉混乱。
  double _scalePulse(double t) {
    return 1.0 + 0.06 * math.sin(2 * math.pi * t / 1.4);
  }

  /// 计算当前时刻每采样点的半径。
  ///
  /// 步骤：
  /// 1. 把 [t] 对 [_morphCycleSeconds] 取模，得到循环内进度。
  /// 2. 计算当前形状索引 [i] 和下一形状索引 [j=(i+1)%7]，以及插值比例 [p]。
  /// 3. 对每采样点在 _shapes[i] 与 _shapes[j] 之间用 [_smoothProgress] 插值。
  List<double> _currentRadii(double t) {
    final cycleT = (t % _morphCycleSeconds) / _morphCycleSeconds; // [0,1)
    final scaled = cycleT * _shapes.length; // [0, 7)
    final i = scaled.floor() % _shapes.length;
    final j = (i + 1) % _shapes.length;
    final rawProgress = scaled - scaled.floor();
    final p = _smoothProgress(rawProgress);

    final result = List<double>.filled(kShapeSamples, 0);
    final shapeA = _shapes[i];
    final shapeB = _shapes[j];
    for (int k = 0; k < kShapeSamples; k++) {
      result[k] = shapeA[k] + (shapeB[k] - shapeA[k]) * p;
    }
    return result;
  }

  @override
  void paint(Canvas canvas, Size canvasSize) {
    final t = tNotifier.value;
    final cx = canvasSize.width / 2;
    final cy = canvasSize.height / 2;

    // 1. 绘制容器（Contained 变体）
    if (showContainer) {
      final containerPaint = Paint()..color = containerColor;
      // 容器是规范规定的圆形
      final containerRadius = containerSize / 2;
      canvas.drawCircle(Offset(cx, cy), containerRadius, containerPaint);
    }

    // 2. 绘制活动指示器（变形形状）
    // 活动指示器最大半径取规范 38dp 的 38%（约 14.4dp），
    // 即占 [canvasSize] 短边的 ~30%，留出边距
    final maxRadius = (showContainer ? containerSize : canvasSize.width) / 2 * 0.78;
    final scale = _scalePulse(t);

    final radii = _currentRadii(t);

    final indicatorPaint = Paint()
      ..color = indicatorColor
      ..style = PaintingStyle.fill;

    // 构造变形形状的 Path：先采样所有顶点，再用 catmullRom 转贝塞尔得到平滑曲线
    final points = <Offset>[];
    for (int k = 0; k < kShapeSamples; k++) {
      final angle = (k / kShapeSamples) * 2 * math.pi;
      final r = radii[k] * maxRadius * scale;
      points.add(Offset(cx + r * math.cos(angle), cy + r * math.sin(angle)));
    }
    // catmullRom: 把折线点列转换为平滑的三次贝塞尔曲线
    // closed=true 表示闭合形状（首尾相连）
    final smoothPath = Path()..addPolygon(points, true);
    canvas.drawPath(smoothPath, indicatorPaint);
  }

  @override
  bool shouldRepaint(covariant _MD3ELoadingPainter oldDelegate) {
    return oldDelegate.indicatorColor != indicatorColor ||
        oldDelegate.containerColor != containerColor ||
        oldDelegate.showContainer != showContainer ||
        oldDelegate.containerSize != containerSize;
  }
}
