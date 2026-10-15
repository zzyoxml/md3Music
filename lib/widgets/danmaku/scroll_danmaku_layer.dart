import 'package:flutter/material.dart';

import '../../core/danmaku/danmaku_entry.dart';
import '../../core/services/player_frame_driver.dart';

/// 滚动弹幕绘制层（自绘，**不用 canvas_danmaku**）。
///
/// 为什么自绘：`canvas_danmaku` 的 `DanmakuScreen` 自带一个跟 vsync 跑的 `Ticker`
/// （`danmaku_screen.dart:76`），帧提交由它决定，外面无法钳制；而占空比式
/// pause/resume 又不可行 —— `Ticker.start()` 后首帧 `elapsed` 恒为 0
/// （`ticker.dart:277` 的 `_startTime ??= timeStamp`），每拍只放一帧的话位移永远不前进。
///
/// 本层把节拍交回调用方：飞行推进挂在共享 60fps 节拍 [PlayerFrameDriver] 上，
/// 场上没有弹幕时立刻解绑（一帧都不产）。重绘走 [ValueNotifier] + `repaint`，
/// 只脏化本层子树，不触发父级 setState（AGENTS §10.4.2）。
class ScrollDanmakuLayer extends StatefulWidget {
  const ScrollDanmakuLayer({
    super.key,
    required this.controller,
    this.areaRatio = 0.45,
    this.fontSize = 14,
    this.strokeWidth = 1.5,
    this.speed = 120,
    this.highlightColor = const Color(0xFFFFD54F),
  });

  /// 弹幕的投放/清空/运行态由外部通过它控制（与 `canvas_danmaku` 的
  /// `createdController` 同一形状，便于宿主两侧共用一套编排代码）。
  final ScrollDanmakuController controller;

  /// 只在容器顶部这个比例区域内滚动，避开封面下方的标题/歌词。
  final double areaRatio;

  /// 字号（会再乘 `MediaQuery.textScaler`）。
  final double fontSize;

  /// 描边宽度（保证压在封面上仍可读）。
  final double strokeWidth;

  /// 水平飞行速度（像素/秒）。
  final double speed;

  /// 自己发送的高亮色（由宿主传主题 token，不在本层硬编码语义色）。
  final Color highlightColor;

  @override
  State<ScrollDanmakuLayer> createState() => _ScrollDanmakuLayerState();
}

/// 一条弹幕的飞行状态。
class _FlyItem {
  _FlyItem({
    required this.fill,
    required this.stroke,
    required this.width,
    required this.lane,
    required double startX,
  }) : x = startX;

  /// 已布局好的正文与描边两个 painter：spawn 时 layout 一次，绘制期不再重算。
  final TextPainter fill;
  final TextPainter stroke;
  final double width;

  /// 占用的轨道下标。轨道数随容器高度变化（转屏），越界的会被重夹到最后一条轨道，
  /// 见 `_ensureLanes`。
  int lane;

  /// 左边缘横坐标（容器本地坐标）。
  double x;

  bool get offScreen => x + width < 0;
}

/// 滚动弹幕的命令句柄。绑定关系与 [ScrollDanmakuLayer] 的 State 同生命周期。
class ScrollDanmakuController {
  _ScrollDanmakuLayerState? _state;

  bool get _attached => _state != null;

  /// 投放一条弹幕。未 attach（弹层还没 build 出来）时静默丢弃——
  /// 弹幕是装饰性内容，丢一条不能影响播放。
  void spawn(DanmakuEntry entry) {
    if (!_attached) return;
    _state!._spawn(entry);
  }

  /// 清屏（向后 seek 时用）。
  void clear() {
    if (!_attached) return;
    _state!._clearScreen();
  }

  /// 是否在产帧（诊断/测试用）。
  bool get isFlying => _attached && _state!._bound;

  /// 场上还在飞的条数（诊断/测试用；未 attach 时为 0）。
  int get liveCount => _attached ? _state!._items.length : 0;

  /// 当前被占用的轨道数（诊断/测试用）：同屏连发多条应各占一条轨道，不叠字。
  int get lanesInUse =>
      _attached ? _state!._items.map((item) => item.lane).toSet().length : 0;

  /// 暂停/恢复飞行。**暂停只停帧，不清空**：已上屏的弹幕冻在原地。
  void setFlying(bool flying) {
    if (!_attached) return;
    _state!._syncBinding(flying);
  }
}

class _ScrollDanmakuLayerState extends State<ScrollDanmakuLayer> {
  final List<_FlyItem> _items = <_FlyItem>[];

  /// 每条轨道「上一条弹幕的右边缘」，用于决定新条目能否进这条轨道。
  final List<double> _laneRightEdge = <double>[];

  final ValueNotifier<int> _frame = ValueNotifier<int>(0);

  bool _bound = false;
  Size _lastSize = Size.zero;

  @override
  void initState() {
    super.initState();
    widget.controller._state = this;
  }

  @override
  void dispose() {
    _unbind();
    if (identical(widget.controller._state, this)) {
      widget.controller._state = null;
    }
    _frame.dispose();
    for (final item in _items) {
      item.fill.dispose();
      item.stroke.dispose();
    }
    _items.clear();
    super.dispose();
  }

  // ── 轨道几何 ──

  double get _lineHeight => widget.fontSize * 1.4;

  int _laneCountFor(double height) =>
      (height * widget.areaRatio / _lineHeight).floor().clamp(1, 12);

  void _ensureLanes(double height) {
    final want = _laneCountFor(height);
    if (_laneCount == want) return;
    _laneCount = want;
    _laneRightEdge
      ..clear()
      ..addAll(List<double>.filled(want, double.negativeInfinity));
    // 转屏/切布局会让轨道数变化，在飞条目的 lane 可能越界 → 重夹到最后一条轨道，
    // 不清屏（清屏会让正在飞的弹幕整批闪掉）。
    for (final item in _items) {
      if (item.lane >= want) item.lane = want - 1;
    }
  }

  int _laneCount = 0;

  /// 选轨道：优先完全空出来的（右边缘已进屏），否则选最早让出位置的那条，
  /// 新条目就排在那条队尾之后（被容器边缘裁掉，滑进来才可见）。
  int _pickLane(double width, double viewWidth, double height) {
    var best = 0;
    var bestEdge = double.infinity;
    for (var lane = 0; lane < _laneCount; lane++) {
      final edge = _laneRightEdge[lane];
      if (viewWidth - edge >= width) {
        return lane;
      }
      if (edge < bestEdge) {
        bestEdge = edge;
        best = lane;
      }
    }
    return best;
  }

  void _spawn(DanmakuEntry entry) {
    final text = entry.text.trim();
    if (text.isEmpty || _lastSize.width <= 0) return;

    final scaler = MediaQuery.textScalerOf(context);
    final fontSize = scaler.scale(widget.fontSize);
    final color = entry.selfSend ? widget.highlightColor : entry.color;
    final style = TextStyle(
      fontSize: fontSize,
      fontWeight: FontWeight.w500,
      color: color,
    );
    final span = TextSpan(text: text, style: style);
    final fill = TextPainter(
      text: span,
      textDirection: TextDirection.ltr,
    )..layout();
    final stroke = TextPainter(
      text: TextSpan(
        text: text,
        style: style.copyWith(
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = widget.strokeWidth
            ..color = Colors.black.withValues(alpha: 0.55),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    _ensureLanes(_lastSize.height);
    final lane = _pickLane(fill.width, _lastSize.width, _lastSize.height);
    // 右边缘尚未让够位置的轨道：新条目接在那条队尾后面（起点可 > 容器宽，被裁掉）。
    final queueBehind = _laneRightEdge[lane];
    final startX = queueBehind.isFinite
        ? (queueBehind + 12 > _lastSize.width ? _lastSize.width : queueBehind + 12)
        : _lastSize.width;
    _laneRightEdge[lane] = startX + fill.width;

    _items.add(_FlyItem(
      fill: fill,
      stroke: stroke,
      width: fill.width,
      lane: lane,
      startX: startX,
    ));
    _syncBinding(_flyingWanted);
    _frame.value++;
  }

  void _clearScreen() {
    for (final item in _items) {
      item.fill.dispose();
      item.stroke.dispose();
    }
    _items.clear();
    _laneRightEdge
      ..clear()
      ..addAll(List<double>.filled(_laneCount, double.negativeInfinity));
    _unbind();
    _frame.value++;
  }

  /// 调用方期望的飞行态（播放中才飞）。默认跟随上一次设置，避免
  /// 宿主在渲染器创建前就调用 setFlying 时丢状态。
  bool _flyingWanted = true;

  /// 帧驱动的唯一收口：有内容且调用方要求飞行才订阅共享节拍。
  /// 场上清空后必须解绑 —— 不可见/无内容仍在产帧是 §10.4.3 的漏电点。
  void _syncBinding(bool flying) {
    _flyingWanted = flying;
    final shouldRun = flying && _items.isNotEmpty;
    if (shouldRun && !_bound) {
      PlayerFrameDriver.instance.addListener(_onBeat);
      _bound = true;
    } else if (!shouldRun && _bound) {
      _unbind();
    }
  }

  void _unbind() {
    if (!_bound) return;
    PlayerFrameDriver.instance.removeListener(_onBeat);
    _bound = false;
  }

  /// 每拍固定推进共享节拍的标称步长（16ms）。
  ///
  /// 刻意不用 `Stopwatch` 求真实 dt：装饰性滚动要的是**恒定步进**，而 `Timer.periodic`
  /// 的实际间隔只会 ≥ 标称值，用标称值最坏只让弹幕慢半拍，肉眼无感；换来的收益是
  /// 帧步进可被 `tester.pump(Duration)` 确定性验证（真实 dt 在假时钟下恒为 0，测不出东西）。
  void _onBeat() {
    final dtSeconds = PlayerFrameDriver.step.inMicroseconds / 1000000.0;
    final dx = widget.speed * dtSeconds;
    for (final item in _items) {
      item.x -= dx;
    }
    _reapAndReleaseLanes();
    if (_items.isEmpty) {
      _unbind();
      return;
    }
    _frame.value++;
  }

  /// 出屏即移除，并把让空的轨道重置成「右边缘未占用」。
  void _reapAndReleaseLanes() {
    _items.removeWhere((item) {
      if (!item.offScreen) return false;
      item.fill.dispose();
      item.stroke.dispose();
      return true;
    });
    for (var lane = 0; lane < _laneCount; lane++) {
      final occupied = _items.any((item) => item.lane == lane);
      if (!occupied) _laneRightEdge[lane] = double.negativeInfinity;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _lastSize = constraints.biggest;
        _ensureLanes(_lastSize.height);
        return ClipRect(
          child: CustomPaint(
            painter: _ScrollDanmakuPainter(
              items: _items,
              frame: _frame,
              lineHeight: _lineHeight,
            ),
            size: _lastSize,
          ),
        );
      },
    );
  }
}

class _ScrollDanmakuPainter extends CustomPainter {
  _ScrollDanmakuPainter({
    required this.items,
    required ValueNotifier<int> frame,
    required this.lineHeight,
  }) : super(repaint: frame);

  final List<_FlyItem> items;
  final double lineHeight;

  @override
  void paint(Canvas canvas, Size size) {
    for (final item in items) {
      if (item.x > size.width) continue;
      final offset = Offset(item.x, item.lane * lineHeight);
      // 先描边再正文：压在封面图上仍可读（与 canvas_danmaku 同一观感）。
      item.stroke.paint(canvas, offset);
      item.fill.paint(canvas, offset);
    }
  }

  /// 条目列表是同一个可变实例，只能靠 `repaint` 通知器驱动重绘；
  /// 这里恒返回 false，避免父级重建时白白重画一次。
  @override
  bool shouldRepaint(covariant _ScrollDanmakuPainter oldDelegate) => false;
}
