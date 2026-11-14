import 'dart:async';

import 'package:flutter/widgets.dart';

import '../platform_capabilities.dart';

/// 空焦点兜底：保证「焦点链上永远有一个 widget」，让键位收口层不至于整层哑掉。
///
/// ## 它修的是什么
///
/// 框架的按键分发（`FocusManager.handleKeyMessage`）只有两条路：
/// `primaryFocus == null` 时**直接返回 false**（事件丢弃）；否则从 `primaryFocus`
/// 沿 `ancestors` 逐级向外调用 `onKeyEvent`。只要**焦点链上一个 widget 都没有**，
/// 挂在 `Focus` 上的键位层就收不到按键，而且**不会自愈** —— 直到用户再点到某个
/// 可聚焦控件。判据就是 `primaryFocus == null || primaryFocus.context == null`
/// （`context == null` 意味着焦点停在 `rootScope`：它不是 widget）。
///
/// 这不是理论状态，两条真实路径：
/// 1. **app 退到后台期间原焦点被销毁**（切窗口时恰好切了 tab / 关了弹层）：
///    `FocusManager` 在 `inactive` 时把原焦点存进 `_suspendedNode` 并把
///    primaryFocus 挪到 `rootScope`；原节点被卸载时 `_markDetached` 顺手清掉
///    `_suspendedNode`，回前台就「无人可还原」，焦点永久停在 `rootScope`。
/// 2. **前台卸载持焦控件，且它的父 scope 也不可聚焦**：框架本来会让父
///    `FocusScope` 自己接手（`FocusScopeNode._doRequestFocus`），但转场 / 拖拽
///    手势进行中 `_ModalScopeState` 会把该 scope 的 `canRequestFocus` 置 false，
///    `applyFocusChangesIfNeeded` 找不到候选，于是退回 `rootScope`。
///
/// 反过来说清楚**不需要**它的情形：前台正常卸载持焦控件时，父 scope 会接手，
/// `primaryFocus` 退回路由的 `FocusScope`（有真实 context），按键本来冒得出去，
/// 兜底此时插进来反而会把用户焦点顶掉 —— 这正是下面铁律 1 的由来。
///
/// ## 为什么是「补一个 focusable 节点」而不是改键位
///
/// 键位层（`desktop_input_layer.dart` / `desktop_playback_keys.dart`）挂在
/// `Focus` 上，只能被动等事件冒泡。空焦点时事件根本不会进入 widget 树，改键位表、
/// 改判定顺序都无用。补一个**不自作主张**的可聚焦节点，让冒泡链重新有落脚点，
/// 两条链路（外层空格/Esc、内层方向键）一次性恢复。
///
/// ## 抢焦点的四条铁律（改动前逐条核对）
///
/// 1. **只在「焦点链上没有任何 widget」时补**：判据是
///    `primaryFocus == null || primaryFocus.context == null`。注意**不能**把
///    「primaryFocus 是路由的 `FocusScope`」也算成空 —— 那个 scope 是挂在
///    `_ModalScopeState` 上的真实 widget，键位本来收得到，此时插进来只会把用户
///    的原焦点顶掉。
/// 2. **app 不在前台时不补**：`FocusManager` 在后台期间把原焦点存在 `_suspendedNode`
///    里，回前台再还原。我们若在此期间抢到焦点，还原就被吞掉（用户回到窗口发现
///    搜索框 / 按钮全失焦）。判据用 `WidgetsBinding.instance.lifecycleState`。
/// 3. **不能在 `FocusManager` 的监听回调里同步改焦点**：那会把
///    `applyFocusChangesIfNeeded` 变成重入。统一挪到微任务里，并且进入微任务后
///    **重新判定一次**（这中间框架可能已经自己还原了焦点）。
/// 4. **只在 Windows 桌面生效**：Android / TV 的焦点语义由 dpad 引擎与遥控焦点
///    状态机接管，多一个可聚焦节点会改变遍历与返回键行为。与键位层同一门控
///    （`isWindowsDesktop`），非 Windows 原样返回 child。
///
/// ## 挂载位置
///
/// 必须挂在**所有桌面键位层之内**：`desktop_playback_keys.dart` 的
/// `DesktopPlaybackKeys` 里、`child` 之前。挂在键位层之外（例如
/// `MaterialApp` 外面）就白补了 —— 焦点落在兜底节点上时，冒泡链只经过它的祖先，
/// 键位层若在它下面则完全不在链上。
class EmptyFocusFallback extends StatefulWidget {
  const EmptyFocusFallback({super.key, required this.child});

  /// 兜底节点在焦点树里的 debug 标签（测试与 `tv_focus_debug.dart` 的日志口径）。
  static const String debugLabel = 'desktop/empty-focus-fallback';

  final Widget child;

  @override
  State<EmptyFocusFallback> createState() => _EmptyFocusFallbackState();
}

class _EmptyFocusFallbackState extends State<EmptyFocusFallback>
    with WidgetsBindingObserver {
  final FocusNode _node = FocusNode(
    debugLabel: EmptyFocusFallback.debugLabel,
    skipTraversal: true,
  );

  /// 已排了一次补位微任务（FocusManager 的通知很密集，不合并会连排几十个）。
  bool _claimScheduled = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_onFocusChanged);
    WidgetsBinding.instance.addObserver(this);
    // 首帧前可能就没有任何 widget 持焦（冷启动、直接进二级页）：先补一次。
    _scheduleClaimIfNeeded();
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocusChanged);
    WidgetsBinding.instance.removeObserver(this);
    _node.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 回前台再给一次机会：若挂起的原节点已被销毁，FocusManager 不会产生焦点变化，
    // 光靠 FocusManager 监听会永远停在 rootScope 上。
    if (state == AppLifecycleState.resumed) _scheduleClaimIfNeeded();
  }

  void _onFocusChanged() => _scheduleClaimIfNeeded();

  /// 当前是否属于「焦点链上没有任何 widget」。
  bool get _needsClaim {
    if (!isWindowsDesktop) return false;
    // 铁律 2：后台期间不抢（此刻 primaryFocus 已被框架临时挪到 rootScope）。
    final AppLifecycleState? state = WidgetsBinding.instance.lifecycleState;
    if (state != null && state != AppLifecycleState.resumed) return false;
    final FocusNode? primary = FocusManager.instance.primaryFocus;
    // 铁律 1：链上还有 widget（哪怕只是路由的 FocusScope）就不补。
    return primary == null || primary.context == null;
  }

  void _scheduleClaimIfNeeded() {
    if (_claimScheduled) return;
    if (!mounted || !_needsClaim) return;
    _claimScheduled = true;
    // 铁律 3：不在监听回调里同步改焦点。
    scheduleMicrotask(_claimNow);
  }

  void _claimNow() {
    _claimScheduled = false;
    // 微任务里重新判定：这中间框架可能已经自己把焦点还原了（后台 → 前台）。
    if (!mounted || !_needsClaim) return;
    _node.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    if (!isWindowsDesktop) return widget.child;
    return Focus(
      focusNode: _node,
      // 可聚焦但**不参与遍历**：Tab / 方向键遍历都不该停在兜底节点上，
      // 用户看不见它，停在它上面等于焦点消失了。
      canRequestFocus: true,
      skipTraversal: true,
      child: widget.child,
    );
  }
}
