import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../layout/bottom_chrome_sink.dart';
import '../services/windows_fullscreen.dart';
import '../services/windows_window_controls.dart';

/// 窗口系统按钮图形。
///
/// 自绘 1dp 细线矩形/斜线，而不是用 Material 图标字体 —— 与系统标题栏三键同
/// 一观感，也避免不同字号下线条粗细漂移。
enum WindowsCaptionGlyph { minimize, maximize, restore, close }

/// 单个 Windows 窗口按钮：46×32 平直命中区 + 悬停/按压反馈 + 键盘激活。
///
/// 从 `WindowsWindowFrame` 抽出来，让 32dp 标题栏与播放页顶栏共用同一套视觉、
/// 命中区与无障碍语义。
class WindowsCaptionButton extends StatefulWidget {
  const WindowsCaptionButton({
    super.key,
    required this.label,
    required this.glyph,
    required this.onPressed,
    this.foreground,
    this.closeHoverColor,
    this.height = 32,
    this.nativePointer,
  });

  final String label;
  final WindowsCaptionGlyph glyph;
  final VoidCallback onPressed;

  /// 图标颜色。null 时取 `ColorScheme.onSurface`；AM 播放页（黑底）传白色。
  final Color? foreground;

  /// 关闭键的悬停/按压底色。null 时取 `ColorScheme.error`。
  final Color? closeHoverColor;

  /// 命中区高度。标题栏用 32；播放页顶栏传 48，使按钮上下缘贴住行边缘
  /// （最大化 / 全屏时可以直接点屏幕角落，不必精准瞄准图形）。
  final double height;

  /// 原生回传的悬停/按压状态（Win11 snap 接管态）。该点已是父窗口非客户区、
  /// Flutter 收不到指针事件，高亮只能由外部驱动；null = 未被接管，走本地
  /// MouseRegion / 按压反馈。见 [WindowsCaptionPointerState]。
  final ValueListenable<WindowsCaptionPointerState>? nativePointer;

  @override
  State<WindowsCaptionButton> createState() => _WindowsCaptionButtonState();
}

class _WindowsCaptionButtonState extends State<WindowsCaptionButton> {
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;
  bool _nativeHovered = false;
  bool _nativePressed = false;

  @override
  void initState() {
    super.initState();
    widget.nativePointer?.addListener(_syncNativePointer);
    _syncNativePointer();
  }

  @override
  void didUpdateWidget(covariant WindowsCaptionButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.nativePointer != widget.nativePointer) {
      oldWidget.nativePointer?.removeListener(_syncNativePointer);
      widget.nativePointer?.addListener(_syncNativePointer);
      _syncNativePointer();
    }
  }

  @override
  void dispose() {
    widget.nativePointer?.removeListener(_syncNativePointer);
    super.dispose();
  }

  void _syncNativePointer() {
    final pointer = widget.nativePointer;
    final state = pointer?.value ?? const WindowsCaptionPointerState();
    if (!mounted ||
        (_nativeHovered == state.hovered && _nativePressed == state.pressed)) {
      return;
    }
    setState(() {
      _nativeHovered = state.hovered;
      _nativePressed = state.pressed;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final glyphColor = widget.foreground ?? colors.onSurface;
    final tone = widget.glyph == WindowsCaptionGlyph.close
        ? (widget.closeHoverColor ?? colors.error)
        : glyphColor;
    final active =
        _hovered || _focused || _pressed || _nativeHovered || _nativePressed;
    final button = SizedBox(
      width: 46,
      height: widget.height,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: FocusableActionDetector(
          mouseCursor: SystemMouseCursors.basic,
          onShowFocusHighlight: (value) => setState(() => _focused = value),
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          },
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onPressed();
                return null;
              },
            ),
          },
          child: Semantics(
            button: true,
            label: widget.label,
            onTap: widget.onPressed,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              excludeFromSemantics: true,
              onTap: widget.onPressed,
              onTapDown: (_) => setState(() => _pressed = true),
              onTapUp: (_) => setState(() => _pressed = false),
              onTapCancel: () => setState(() => _pressed = false),
              // 不把反馈绘制到共用 Material 墨水层，避免透明/缩放下越界。
              child: RepaintBoundary(
                child: ClipRect(
                  child: ColoredBox(
                    color: tone.withValues(
                      alpha: active ? (_pressed || _nativePressed ? .18 : .12) : 0,
                    ),
                    child: Center(
                      child: CustomPaint(
                        size: const Size(12, 12),
                        painter: _CaptionGlyphPainter(widget.glyph, glyphColor),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // 接管态（返回 HTMAXBUTTON）下该点是非客户区，Flutter 的 Tooltip 触发
    // 定时器收不到鼠标事件、永不弹出——留着只会让读屏与视觉不一致。
    if (widget.nativePointer != null) return button;
    return Tooltip(message: widget.label, excludeFromSemantics: true, child: button);
  }
}


/// 最小化 / 最大化-还原 / 关闭三键组。
///
/// 自带窗口状态（最大化 / 全屏），通过 `md3music/window_tray` 通道查询与操作：
/// - 初始化、窗口尺寸变化（最大化/还原）时刷新「最大化」；
/// - 订阅 [WindowsFullscreen.active]，全屏时最大化键语义切为「退出全屏」；
/// - [keyPrefix] 用来区分多处挂载（标题栏 `windows`、播放页 `player_window`）。
class WindowsCaptionButtonRow extends StatefulWidget {
  const WindowsCaptionButtonRow({
    super.key,
    this.keyPrefix = 'windows',
    this.foreground,
    this.closeHoverColor,
    this.height = 32,
  });

  final String keyPrefix;
  final Color? foreground;
  final Color? closeHoverColor;

  /// 三键命中区高度。默认 32（标题栏）；播放页顶栏传 48（与中段拖动区同高）。
  final double height;

  @override
  State<WindowsCaptionButtonRow> createState() =>
      _WindowsCaptionButtonRowState();
}

class _WindowsCaptionButtonRowState extends State<WindowsCaptionButtonRow>
    with WidgetsBindingObserver {
  static const MethodChannel _channel = MethodChannel('md3music/window_tray');

  /// 行登记 id 的进程内序号：每行实例拿到唯一值，转场并存互不干扰。
  static int _nextRowSerial = 0;

  bool _maximized = false;

  /// 原生全屏镜像：全屏时没有窗口边框，最大化键是鼠标用户唯一的退出入口。
  bool _fullscreen = WindowsFullscreen.active.value;

  /// 本行是否处于 snap 接管态：**唯一事实源是原生广播**
  /// [WindowsWindowControls.maxButtonOwner]（单槽、后来者覆盖，被覆盖的
  /// 行退回纯 Flutter 命中路径，Tooltip 也随之恢复）。
  bool get _takenOver =>
      !_fullscreen && WindowsWindowControls.maxButtonOwner.value == _registerId;

  /// 本行是否已向原生登记过矩形（决定 dispose / 进全屏时要不要撤销；
  /// 撤销按 id 匹配，被覆盖后撤销自己是空操作，安全）。
  bool _registered = false;

  /// 上一次**成功**登记的逻辑矩形：几何没变就不重复发通道调用。
  ///
  /// 去重而不是"只在特定事件上报"：播放页整页位于 `Transform.translate` 内
  /// （展开动画逐帧改 `dy`），`localToGlobal` 会吃到这个偏移 —— 只按
  /// initState/metrics 报一次的实现在拖拽上滑进入时会把**动画中途**的坐标
  /// 固化下来（真机实测：登记 y=60..99、真实按钮 y=69..99，上沿 9px 落在区外，
  /// 表现为「按钮上半部悬停无反应、下半部正常」）。改成"算出来的真值变了就
  /// 报"，任何一次后续触发都会把错位纠正回来。
  Rect? _lastReportedRect;

  /// 展开动画期间的合并节流：逐帧变化只落一次上报，避免 400ms 动画发几十次通道。
  Timer? _reportDebounce;

  /// 帧驱动校验是否在进行中（动画期间逐帧比几何，结束后自动停）。
  bool _watchingFrames = false;

  /// 上报在途标记：避免帧回调与异步上报叠加成并发（通道调用有 await）。
  bool _reporting = false;

  late final String _registerId;

  @override
  void initState() {
    super.initState();
    _registerId = 'caption_row_${++_nextRowSerial}';
    WindowsWindowControls.maxButtonOwner.addListener(_onOwnerChanged);
    WidgetsBinding.instance.addObserver(this);
    WindowsFullscreen.active.addListener(_onFullscreenChanged);
    // 播放页展开进度是几何真值的唯一来源（手势逐帧与路由转场每帧都写它）：
    // 监听它可同时覆盖拖拽进入 / 点击进入 / F 键 / Zen peek / 收起回落，
    // 不必逐条枚举路由生命周期。
    PlayerPanelSignal.expansion.addListener(_onExpansionChanged);
    _refreshMaximized();
    _scheduleRectReport();
  }

  void _onOwnerChanged() {
    if (mounted) setState(() {});
  }

  /// 展开进度变化：动画期间几何逐帧在动，进入帧观察（有变化才发通道）。
  ///
  /// **为什么不能只靠监听 expansion 再 schedule 一次**：真机实测，
  /// 拖拽上滑进入播放页时播放页行的首帧登记发生在 `Transform.translate`
  /// 偏移尚未归零的那一帧（登记 y 比按钮真值低 9px），而动画结束后几何虽已
  /// 落到终点，却没有任何事件再触发一次上报 —— 错位被固化，表现为「最大化键
  /// 上半部落在外，悬停无反应、下半部正常」。`AnimatedBuilder` 只重建自己的
  /// 子树，不会重建本行，因此「等下一个回调」这条路不成立；必须在帧上比对。
  void _onExpansionChanged() {
    if (!mounted) return;
    if (_watchingFrames) return;
    _watchingFrames = true;
    WidgetsBinding.instance.addPersistentFrameCallback(_onFrameCheck);
    // 兜底：动画结束若没有后续帧，用一次 post-frame 收尾并停表。
    _reportDebounce?.cancel();
    _reportDebounce = Timer(const Duration(milliseconds: 400), _stopWatch);
  }

  /// 每帧比对几何：变了才走通道（[`_reportRectNow`] 内部再去重一次）。
  void _onFrameCheck(Duration _) {
    if (!mounted) {
      _watchingFrames = false;
      return;
    }
    if (!_reporting) {
      _reporting = true;
      _reportRectNow().whenComplete(() => _reporting = false);
    }
  }

  void _stopWatch() {
    _reportDebounce?.cancel();
    _reportDebounce = null;
    _watchingFrames = false;
  }

  @override
  void dispose() {
    WindowsWindowControls.maxButtonOwner.removeListener(_onOwnerChanged);
    PlayerPanelSignal.expansion.removeListener(_onExpansionChanged);
    _stopWatch();
    if (_registered) {
      _registered = false;
      // dispose 后不 await；原生按行 id 撤销，迟到的撤销只撤自己那条。
      WindowsWindowControls.clearMaxButtonRect(_registerId);
    }
    WindowsFullscreen.active.removeListener(_onFullscreenChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    _refreshMaximized();
    // 窗口尺寸/DPI 变化都会改物理像素坐标，矩形必须重报。
    _scheduleRectReport();
  }

  void _onFullscreenChanged() {
    if (!mounted || _fullscreen == WindowsFullscreen.active.value) return;
    setState(() => _fullscreen = WindowsFullscreen.active.value);
    // 全屏 = 退出接管（该键回到纯 Flutter 命中，Tooltip/点击照旧）；
    // 退出全屏 = 重新登记本行矩形。
    _scheduleRectReport();
  }

  /// 布局完成后上报最大化键矩形。用 `findRenderObject`（回调都在 layout
  /// 之后）而不是 LayoutBuilder——W12.3 实测后者在播放页双封面/离屏取子树
  /// 时会「没有 layout 就被 paint」导致整窗卡死。
  void _scheduleRectReport() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _reportRectNow());
  }

  Future<void> _reportRectNow() async {
    if (!mounted) return;
    if (_fullscreen) {
      // 全屏 = 退出接管：撤销本行登记（原生随即广播易主/清空，本行与其余
      // 行的 _takenOver 派生值自动复原）。
      if (_registered) {
        _registered = false;
        _lastReportedRect = null;
        await WindowsWindowControls.clearMaxButtonRect(_registerId);
      }
      return;
    }
    // 最大化键是三键行（46+46+46）的中列：从本组件（Row）几何推导，不挂
    // GlobalKey（多处同时挂载会撞重复键；key 留给 ValueKey('前缀_toggleMaximize')，
    // 既有测试与源码结构断言都按它定位）。回调在 layout 之后，仍守卫 hasSize
    // （W12.3 口径）。
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final rowRect = box.localToGlobal(Offset.zero) & box.size;
    final rect = Rect.fromLTWH(
        rowRect.left + 46, rowRect.top, 46, rowRect.height);
    // 几何真值没变就不发通道：动画逐帧触发的检查绝大多数落在这里。
    if (_registered && _lastReportedRect == rect) return;
    // dpr 必须取 **view 真实 devicePixelRatio**：localToGlobal 的输出就处于
    // view 逻辑像素空间；而 MediaQuery.devicePixelRatioOf 被 ui_density 的
    // 设计像素缩放改写（真机实测 1.25 → 1.357），用它换算会把矩形放大 ~8.6%、
    // 右缘越出窗口、按钮中心落到缩放边（snap 面板不出现、点击变拖窗口）。
    final dpr =
        WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
    final accepted =
        await WindowsWindowControls.reportMaxButtonRect(_registerId, rect, dpr);
    if (!mounted) return;
    // 接管态显示走 maxButtonOwner 广播订阅；这里只记录「登记过、撤销时要
    // 喊一嗓子」。accepted=false（全屏竞态窗口）= 原生没登记，不必撤销。
    _registered = accepted;
    _lastReportedRect = accepted ? rect : null;
  }

  Future<void> _refreshMaximized() async {
    try {
      final value = await _channel.invokeMethod<bool>('isMaximized');
      if (mounted && value != null) setState(() => _maximized = value);
    } on MissingPluginException {
      // Widget 测试没有原生 runner；实际运行须使用同一构建中的 Dart 与 runner。
    } on PlatformException catch (error) {
      debugPrint('Windows window control isMaximized failed: $error');
    }
  }

  Future<void> _invoke(String method) async {
    try {
      final value = await _channel.invokeMethod<bool>(method);
      // 原生 toggleMaximize 返回操作后的 IsZoomed，可直接回填按钮形态。
      if (mounted && value != null && method == 'toggleMaximize') {
        setState(() => _maximized = value);
      }
    } on MissingPluginException {
      // 同上：无原生实现时静默降级。
    } on PlatformException catch (error) {
      debugPrint('Windows window control $method failed: $error');
    }
  }

  Widget _button(String suffix, String label, WindowsCaptionGlyph glyph,
      String method,
      {ValueListenable<WindowsCaptionPointerState>? nativePointer}) {
    return WindowsCaptionButton(
      key: ValueKey('${widget.keyPrefix}_$suffix'),
      label: label,
      glyph: glyph,
      height: widget.height,
      foreground: widget.foreground,
      closeHoverColor: widget.closeHoverColor,
      nativePointer: nativePointer,
      onPressed: () => _invoke(method),
    );
  }

  @override
  Widget build(BuildContext context) {
    // snap 接管态（= 本行是原生广播的活动登记方）：原生对该点返回
    // HTMAXBUTTON，悬停高亮由原生回传驱动、Tooltip 不再触发；全屏或本行
    // 被更晚登记的行覆盖时，最大化键回到纯 Flutter 命中，「退出全屏 /
    // 最大化」Tooltip 与点击语义照旧。
    final bool takenOver = _takenOver;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _button('minimize', '最小化', WindowsCaptionGlyph.minimize, 'minimize'),
        _button(
          'toggleMaximize',
          _fullscreen ? '退出全屏' : (_maximized ? '还原' : '最大化'),
          _maximized || _fullscreen
              ? WindowsCaptionGlyph.restore
              : WindowsCaptionGlyph.maximize,
          'toggleMaximize',
          nativePointer: takenOver
              ? WindowsWindowControls.maxButtonPointer
              : null,
        ),
        _button('closeWindow', '关闭', WindowsCaptionGlyph.close, 'closeWindow'),
      ],
    );
  }
}

class _CaptionGlyphPainter extends CustomPainter {
  const _CaptionGlyphPainter(this.glyph, this.color);

  final WindowsCaptionGlyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final pen = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    if (glyph == WindowsCaptionGlyph.minimize) {
      canvas.drawLine(const Offset(1, 6), const Offset(11, 6), pen);
    } else if (glyph == WindowsCaptionGlyph.maximize) {
      canvas.drawRect(const Rect.fromLTWH(1, 1, 10, 10), pen);
    } else if (glyph == WindowsCaptionGlyph.restore) {
      canvas.drawPath(
        Path()
          ..moveTo(3, 3)
          ..lineTo(3, 1)
          ..lineTo(11, 1)
          ..lineTo(11, 9)
          ..lineTo(9, 9),
        pen,
      );
      canvas.drawRect(const Rect.fromLTWH(1, 3, 8, 8), pen);
    } else {
      canvas.drawLine(const Offset(1, 1), const Offset(11, 11), pen);
      canvas.drawLine(const Offset(11, 1), const Offset(1, 11), pen);
    }
  }

  @override
  bool shouldRepaint(covariant _CaptionGlyphPainter oldDelegate) =>
      oldDelegate.glyph != glyph || oldDelegate.color != color;
}
