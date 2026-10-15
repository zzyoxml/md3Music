import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// tv: 遥控焦点指示框（红框），**不带**调试标签。
///
/// ## 为什么不用 dpad 自带的 `debugOverlay`
///
/// dpad 的 `Dpad.wrap(debugOverlay: true)` 是一个整体开关
/// （dpad `root.dart:57`），开启后 `_DpadDebugOverlay`
/// （`root.dart:444+`）每帧绘制两样东西：
/// 1. 焦点节点的描边框（dpad 原色为 red A400 `0xFFFF1744`，圆角 6，线宽 2）
///    ——边框本身正是我们要的；
/// 2. 焦点下方一块半透明黑底标签，写着 `debugLabel` / `region: …` / `宽×高`
///    （`root.dart:499-518`）——调试信息，正式包不该出现在用户屏幕上。
///
/// 开关是整体的，无法只关标签。本组件按同一视觉规格自绘红框，替代 dpad 的
/// 叠层：保留「当前焦点在哪」这一 TV 必需的视觉反馈，去掉调试标签。
///
/// 跟随策略：**事件驱动 + 变了才重绘**。
///
/// 焦点变化（监听 [FocusManager]）或窗口指标变化时唤醒 [Ticker]，逐帧比对
/// `localToGlobal` 得到的矩形，只有真的动了才 `setState`；连续若干拍不动即把
/// Ticker 置 [Ticker.muted]，**静止时不再产帧**（§10.4）。
///
/// 之所以保留 Ticker 而不是纯事件监听：滚动/动画期间焦点没变但矩形一直在动
/// （列表把焦点项滚进视野、路由转场、dpad 放大辉光），必须逐帧跟随。
/// 旧的「Ticker 常驻 + 每帧 setState」会让 TV 包在**任何静止画面**上持续产帧
/// （120Hz 盒子上整页被顶满，§10.1）。
///
/// 显隐：**始终画**（本组件只在 kTvBuild 分支被挂载，见 app.dart 的
/// `_tvContentScope`）。不要按 [RemoteControlProvider.enabled] 开关——那是
/// 「设备是否为 TV」的三态运行时开关，在平板/手机上判定为 false，而 TV 包
/// 装在这些设备上调试时仍需要焦点框（2026-10-04 实测踩过：绑 enabled 导致
/// release 包在平板上完全不显示焦点框）。
///
/// 用法：`MaterialApp.builder` 的最外层 `Positioned.fill`（见 app.dart 的
/// `_tvContentScope`）。
class TvFocusHighlight extends StatefulWidget {
  const TvFocusHighlight({super.key});

  @override
  State<TvFocusHighlight> createState() => _TvFocusHighlightState();
}

class _TvFocusHighlightState extends State<TvFocusHighlight>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final Ticker _ticker;

  /// 上一次绘制过的焦点矩形（已外扩），用于判断「这一拍是否真的动了」。
  Rect? _lastRect;

  /// 连续多少拍矩形未变化。达到阈值即静音 Ticker。
  int _stableTicks = 0;

  /// 静止判定阈值（拍）。留一点尾巴覆盖「动画中恰好一两拍位置相同」的情形
  /// （缓动折返点等），避免误停后焦点框卡死。
  static const int _stableTicksBeforeMute = 10;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    FocusManager.instance.addListener(_wake);
    _ticker = createTicker(_onTick)..start();
  }

  /// 焦点变化 / 窗口指标变化：解除静音，重新进入逐帧跟随。
  void _wake() {
    _stableTicks = 0;
    if (_ticker.muted) _ticker.muted = false;
  }

  @override
  void didChangeMetrics() => _wake();

  void _onTick(Duration _) {
    if (!mounted) return;
    final rect = _currentRect();
    if (rect != _lastRect) {
      _lastRect = rect;
      _stableTicks = 0;
      setState(() {});
      return;
    }
    if (_stableTicks < _stableTicksBeforeMute &&
        ++_stableTicks >= _stableTicksBeforeMute) {
      // 画面已静止：静音 Ticker，不再排帧（§10.4.6「画面静止必须停帧」）
      _ticker.muted = true;
    }
  }

  /// 当前焦点节点的屏幕矩形（外扩 2px 后的绘制矩形）；无可画焦点时返回 null。
  Rect? _currentRect() {
    // 取当前焦点节点的屏幕矩形；焦点在 scope 上或不存在时无矩形可画。
    // （dpad 的 DpadMarks 未对外导出，这里用 Flutter 原生的 localToGlobal。）
    final node = FocusManager.instance.primaryFocus;
    if (node == null || node is FocusScopeNode) return null;
    final nodeContext = node.context;
    if (nodeContext == null || !nodeContext.mounted) return null;
    final box = nodeContext.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    if (rect.isEmpty) return null;
    return rect.inflate(2);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_wake);
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rect = _currentRect();
    if (rect == null) return const SizedBox.shrink();

    return IgnorePointer(
      // 规格沿用 dpad 原生叠层（外扩 2px、圆角 6、线宽 2），仅把描边色从固定
      // red A400 换成主题主色——焦点指示属于应用视觉体系，应随动态取色变化。
      child: CustomPaint(
        size: Size.infinite,
        painter: _FocusFramePainter(
          rect,
          Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

class _FocusFramePainter extends CustomPainter {
  final Rect rect;

  /// 焦点框颜色：取主题 [ColorScheme.primary]（MD3 主色，随动态取色变化）。
  /// 深浅主题下 `primary` 都保证与背景有足够对比度（MD3 调色板即为此设计），
  /// 比固定色更符合"焦点指示属于应用视觉体系"的定位。
  final Color color;

  const _FocusFramePainter(this.rect, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      rect,
      const Radius.circular(6),
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = color;
    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(_FocusFramePainter oldDelegate) =>
      oldDelegate.rect != rect || oldDelegate.color != color;
}
