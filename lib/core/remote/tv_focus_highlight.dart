import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../layout/ui_density.dart';
import 'tv_focus_frame_animation.dart';

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
/// ## 连贯移动 + 形变
///
/// 焦点切换时红框不再瞬移到新位置，而是**滑行插值**过去（并随目标形状伸缩、
/// 圆角半径自适应），按方向键时是一条连续拖尾的轨迹。核心判断（时长曲线、
/// 何时插值何时贴合、半径怎么算）全部在 `tv_focus_frame_animation.dart` 的
/// [TvFocusFrameMotion] 里，本文件只做接线：
///
/// - 焦点切到新节点 → 插值滑行（时长 120~420ms，随距离增长，见
///   [tvFocusFrameGlideFor]）；连发期间保留同一条时间轴，形成连续拖尾；
/// - 焦点没换、目标矩形却动了 → 元素自己在动（滚动 / 路由转场 / 布局重排）→
///   **立即贴合**。插值在这种场景只会让红框以 `速度 × 时长` 滞后成拖影
///   （快速 fling 的列表上可达数百 px）；
/// - 系统「减弱动态效果」→ 时长恒 0，逐帧落位（与 `PlayerCoverMorphLayer` /
///   `app.dart` 的 `didChangeDependencies` 同口径读 `disableAnimationsOf`）。
///
/// 「焦点是否真的换了停点」以 [FocusManager] 通知为准，不比节点 identity：
/// 重挂载 / rebuild 会换 `FocusNode` identity，那种抖动会让红框把「布局刷新」
/// 误判成「焦点在跳」，在滚动里反复起跑。
///
/// ## 跟随策略：事件驱动 + 变了才重绘
///
/// 焦点变化（监听 [FocusManager]）、窗口指标变化，或宿主经 [TvFocusHighlightState.wake]
/// 上报的「内容几何变化」（滚动 / 程序化自动定位）时唤醒 [Ticker]，逐帧比对
/// `localToGlobal` 得到的矩形，只有姿态真的动了才经 [ValueNotifier] 通知
/// painter 重绘；连续若干拍不动即把 Ticker 置 [Ticker.muted]，**静止时不再产帧**
/// （§10.4）。
///
/// 之所以保留 Ticker 而不是纯事件监听：滚动 / 动画期间焦点没变但矩形一直在动
/// （列表把焦点项滚进视野、路由转场、dpad 放大辉光），必须逐帧跟随。
/// 旧的「Ticker 常驻 + 每帧 setState」会让 TV 包在**任何静止画面**上持续产帧
/// （120Hz 盒子上整页被顶满，§10.1）。
///
/// 每帧不 `setState`（§10.4.2）：滑行每帧只更新 [ValueNotifier] 的姿态，
/// 由 [ValueListenableBuilder] 只重建最内层 [CustomPaint]，widget 树零重建。
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
  State<TvFocusHighlight> createState() => TvFocusHighlightState();
}

class TvFocusHighlightState extends State<TvFocusHighlight>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final Ticker _ticker;

  /// 运动模型（滑行 / 贴合 / 半径形变的判断都在它里面）。
  final TvFocusFrameMotion _motion = TvFocusFrameMotion();

  /// 本帧姿态；`null` = 不画框。经 [ValueNotifier] 驱动 painter，不走 setState。
  final ValueNotifier<TvFocusFramePose?> _pose = ValueNotifier(null);

  /// 本 ticker 帧之前是否收到过 [FocusManager] 的焦点变化通知。
  ///
  /// 为什么不用「节点 identity 变了」当判据：重挂载 / rebuild 会换 `FocusNode`
  /// identity（`ValueKey`/`GlobalKey` 重建、列表项复用时都是常态），那种抖动会让
  /// 红框把「布局刷新」误判成「焦点在跳」，在滚动里反复起跑。`FocusManager` 的通知
  /// 只在焦点**真的**在节点间转移时发出——滚动、路由转场、布局变化都不触发它。
  bool _focusSwitched = false;

  /// 上一帧的 ticker 时间戳；`null` = 本帧是唤醒后的第一帧（dt 记 0）。
  Duration? _lastTickTime;

  /// 连续多少拍姿态未变化。达到阈值即静音 Ticker。
  int _stableTicks = 0;

  /// 静止判定阈值（拍）。留一点尾巴覆盖「动画中恰好一两拍位置相同」的情形
  /// （缓动折返点等），避免误停后焦点框卡死。
  static const int _stableTicksBeforeMute = 10;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    FocusManager.instance.addListener(_onFocusChanged);
    // 冷启动首帧：焦点可能在任何监听挂载之前就已存在（首屏 autofocus / 先前页面
    // 遗留）。此时按「已切换」处理，让红框直接落位而非从旧位置飞来。
    _focusSwitched = true;
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 系统「减弱动态效果」：滑行时长归零，逐帧贴合。与 app.dart 的
    // `_reduceMotion`、PlayerCoverMorphLayer 同一口径（都读 disableAnimationsOf）。
    _motion.reducedMotion = MediaQuery.disableAnimationsOf(context);
    // 显式依赖「显示大小」档位：换档会改 MediaQuery.size / devicePixelRatio
    // （DisplayScaleScope 重新 applyDisplayScale），但不是窗口 metrics 变化
    // （didChangeMetrics 不响），也不产生 FocusManager 通知。不订阅时 Ticker
    // 静音（§10.4.6 停帧）状态下换档，红框会冻结在旧档位的矩形上，直到下次
    // 焦点切换才恢复。这里唤醒逐帧跟随即可：静止后 10 拍自动重新停帧。
    MediaQuery.sizeOf(context);
    _wake();
  }

  /// 焦点变化 / 窗口指标变化：解除静音，重新进入逐帧跟随。
  void _wake() {
    _stableTicks = 0;
    // 唤醒后的第一帧不计 dt：后台回前台 / 长时间未产帧时 ticker 的 elapsed 跨度
    // 可能是数百 ms，直接累加会让滑行一步跳完。
    _lastTickTime = null;
    if (_ticker.muted) _ticker.muted = false;
  }

  /// [FocusManager] 通知焦点**真的换了停点**。置位后由最近一个 ticker 帧消费
  /// （读后即清），窗口指标变化不得置位。
  void _onFocusChanged() {
    _focusSwitched = true;
    _wake();
  }

  /// tv: 内容几何变化但焦点没变（滚动、播放列表「自动滚到当前曲」等程序化
  /// 定位）时由宿主调用，唤醒逐帧跟随。
  ///
  /// 与焦点变化**刻意不同**：[Ticker] 已在跑时什么都不做。滚动期间每帧都会
  /// 收到通知，若像 [_onFocusChanged] 那样每次都复位 [_lastTickTime]，正在
  /// 滑行的红框会因 dt 恒为 0 而冻住，直到滚动结束才继续动。
  void wake() {
    if (!_ticker.muted) return;
    _wake();
  }

  @override
  void didChangeMetrics() => _wake();

  void _onTick(Duration elapsed) {
    if (!mounted) return;
    final Duration dt = _lastTickTime == null
        ? Duration.zero
        : elapsed - _lastTickTime!;
    _lastTickTime = elapsed;
    _advance(dt);
  }

  /// 推进一帧：取目标 → 更新运动模型 → 必要时通知重绘 / 停帧。
  void _advance(Duration dt) {
    final Duration step = dt > kTvFocusFrameMaxTick ? kTvFocusFrameMaxTick : dt;
    final Rect? target = _currentRect();
    _motion.update(target: target, focusSwitched: _focusSwitched);
    _focusSwitched = false;
    _motion.tick(step);

    final TvFocusFramePose? pose = _motion.pose;
    if (pose != _pose.value) {
      _pose.value = pose;
      _stableTicks = 0;
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
    // 取当前焦点节点的矩形；焦点在 scope 上或不存在时无矩形可画。
    // （dpad 的 DpadMarks 未对外导出，这里用 Flutter 原生的 localToGlobal。）
    final node = FocusManager.instance.primaryFocus;
    if (node == null || node is FocusScopeNode) return null;
    final nodeContext = node.context;
    if (nodeContext == null || !nodeContext.mounted) return null;
    final box = nodeContext.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    // 量到 [DisplayScaleScope] 的设计像素锚点而非 RenderView 根：本组件挂在
    // 该 scope 的 FittedBox 之内，painter 与锚点同在设计像素空间；而
    // localToGlobal(Offset.zero) 返回根（窗口）坐标、已含 FittedBox 的 ×s，
    // 直接画会被再放大一次 → 落点 = 正确位置 × s（换「显示大小」档后红框
    // 向右下/左上偏、边框随之偏大偏小）。与封面形变探针、MiniPlayer 拖拽
    // 同一教训（见 display_space.dart）。锚点在 FittedBox 之下：焦点节点与
    // 锚点之间的路由转场 / 滚动 / 卡片缩放等内部变换仍如实包含。
    final anchor = DisplayScaleReference.anchorOf(context);
    final origin = anchor is RenderBox
        ? box.localToGlobal(Offset.zero, ancestor: anchor)
        : box.localToGlobal(Offset.zero); // 不在 scope 内（或单测裸挂载）时回退根空间
    final rect = origin & box.size;
    if (rect.isEmpty || !rect.isFinite) return null;
    return rect.inflate(2);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocusChanged);
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _pose.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ValueListenableBuilder<TvFocusFramePose?>(
        valueListenable: _pose,
        builder: (context, pose, _) {
          if (pose == null) return const SizedBox.shrink();
          return CustomPaint(
            size: Size.infinite,
            painter: TvFocusFramePainter(
              pose.rect,
              pose.radius,
              // 规格沿用 dpad 原生叠层（外扩 2px、线宽 2），仅把描边色从固定
              // red A400 换成主题主色——焦点指示属于应用视觉体系，应随动态取色
              // 变化。
              Theme.of(context).colorScheme.primary,
            ),
          );
        },
      ),
    );
  }
}

/// 焦点框描边：圆角矩形单描边。
///
/// 圆角半径随目标形状变化（圆形图标钮 → 正圆，长条形行 → 大圆角胶囊），
/// 取值见 [tvFocusFrameRadiusFor]。
class TvFocusFramePainter extends CustomPainter {
  const TvFocusFramePainter(this.rect, this.radius, this.color);

  final Rect rect;
  final double radius;

  /// 焦点框颜色：取主题 [ColorScheme.primary]（MD3 主色，随动态取色变化）。
  /// 深浅主题下 `primary` 都保证与背景有足够对比度（MD3 调色板即为此设计），
  /// 比固定色更符合"焦点指示属于应用视觉体系"的定位。
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = color;
    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(TvFocusFramePainter oldDelegate) =>
      oldDelegate.rect != rect ||
      oldDelegate.radius != radius ||
      oldDelegate.color != color;
}
