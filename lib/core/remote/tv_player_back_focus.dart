import 'package:dpad/dpad.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// tv: 播放页「tab 内容区」作用域标记（列表 / 歌词 / 评论三个 tab 的内容）。
///
/// 由 `player_tab_pager.dart` 在 `kTvBuild` 分支包一层；非 TV 构建不挂。
///
/// **注意**：播放页返回键的裁决**不再单独依赖本作用域**——判据已改为「焦点不在
/// [TvPlayerChromeScope] 内即交还焦点」（见 [TvPlayerBackInterceptor]），因为
/// 2026-10-20 真机发现底部遥控 TabBar 在 pager 之外、不在本作用域内，返回键
/// 在那里会被直接放行成 pop 页面。本作用域保留：它是「右侧内容区」这一事实的
/// 唯一标记处，`focusNestedRegionBeyond` 一类后续跨区域逻辑仍会用到。
class TvPlayerTabContentScope extends InheritedWidget {
  const TvPlayerTabContentScope({super.key, required super.child});

  @override
  bool updateShouldNotify(TvPlayerTabContentScope oldWidget) => false;

  /// [node] 是否位于 tab 内容区子树内。
  static bool contains(FocusNode node) {
    final BuildContext? context = node.context;
    if (context == null) return false;
    return context.getElementForInheritedWidgetOfExactType<
            TvPlayerTabContentScope>() !=
        null;
  }
}

/// tv: 播放页「播放控制 chrome 区」作用域标记（与 [TvPlayerTabContentScope] 互补）。
///
/// 存在的理由：返回键要做**两层语义**——焦点在控制 chrome 区时放行（收起播放页），
/// 焦点在其余区域（tab 内容区 / 遥控 TabBar / 封面区）时先把焦点交回播放键。
///
/// 为什么标 chrome 而不是逐个枚举内容区：播放页右侧的焦点停点由各页面自建
/// （列表行 `TvReorderItem`、歌词行、评论行、M3E 列表槽位），拿不到全部句柄；
/// 而控制 chrome 的停点是有限且集中的（传输三键、播放模式、收藏、进度尺、
/// 音量行、顶栏各段、页签条之外的 chrome），包一层 inherited scope 即可穷尽。
///
/// 与 [TvPlayerTabContentScope] 的分界：**页签条（`TvPlayerTabBar`）不包本作用域** ——
/// 它正是返回键要救的对象（2026-10-20 真机：焦点停在 tab 栏段时按返回键直接
/// pop 页面，因为 tab 栏在 pager 之外、不在内容区作用域内）。
///
/// 由 `full_player.dart` / `full_player_am.dart` 在 `kTvBuild` 分支包一层；
/// 非 TV 构建不挂。
class TvPlayerChromeScope extends InheritedWidget {
  const TvPlayerChromeScope({super.key, required super.child});

  @override
  bool updateShouldNotify(TvPlayerChromeScope oldWidget) => false;

  /// [node] 是否位于播放控制 chrome 区子树内。
  static bool contains(FocusNode node) {
    final BuildContext? context = node.context;
    if (context == null) return false;
    return context.getElementForInheritedWidgetOfExactType<
            TvPlayerChromeScope>() !=
        null;
  }
}

/// tv: 播放页返回键的**全局兜底处理器**（在 `Dpad` 层咨询）。
///
/// ## 为什么还需要这一层
///
/// [TvPlayerBackInterceptor] 挂在播放页内容里，靠**焦点节点 → ancestors 向上**
/// 的按键传播接收返回键。只要焦点还在某个具体停点上（列表行 / 页签段 / 播放键），
/// 这条链就成立。
///
/// 但 2026-10-20 真机（SM-T870）实测到一种拦截器**收不到按键**的状态：焦点丢失，
/// `primaryFocus` 落回路由自己的 `_ModalScopeState Focus Scope`（不是 null，
/// 而是一个 [FocusScopeNode]）。此时它不在播放页内容的子树里，拦截器不是它的
/// 祖先 → 按键直接冒到 `Dpad.wrap(onBack: _handleTvBack)` → 播放页当场 pop，
/// 用户看到的就是「焦点在列表上按返回键，播放页直接关了」。
///
/// 本处理器由播放页在 `kTvBuild` 分支注册，`app.dart` 的 `_handleTvBack` 在
/// pop 之前**先咨询**它：能救焦点就消费这次返回，救不了（没有播放页 / 焦点已在
/// 控制 chrome 区 / 桥里没有可用播放键）才真正 pop。
///
/// 只做「播放页在场时」这一件事：不在播放页时 `requestPlayFocus()` 返回 false，
/// 主壳层行为完全不变。
class TvPlayerBackFallback {
  TvPlayerBackFallback._();

  static final TvPlayerBackFallback instance = TvPlayerBackFallback._();

  /// 已注册的播放页「能否救焦点」判定器（播放页 State 自己持有）。
  ///
  /// 返回 true = 已把焦点交还播放键并**消费**这次返回；false = 没救，放行 pop。
  ///
  /// 用列表而非单个引用：拖拽覆盖层实例与路由实例可能短暂并存（见
  /// `full_player.dart` 的 `_isDragOverlay` 说明），取**最后注册**的那个 =
  /// 视觉最上层，与 [TvPlayerPlayFocusBridge] 同一口径。
  final List<bool Function()> _handlers = <bool Function()>[];

  void register(bool Function() handler) {
    if (!_handlers.contains(handler)) _handlers.add(handler);
  }

  void unregister(bool Function() handler) {
    _handlers.remove(handler);
  }

  /// 询问最上层的播放页：这次返回键能否被它消费（救焦点）。
  ///
  /// 由 `app.dart::_handleTvBack` 在 `navigator.pop()` **之前**调用。
  bool requestPlayFocus() {
    for (final bool Function() handler in _handlers.reversed) {
      if (handler()) return true;
    }
    return false;
  }

  /// 当前是否有播放页注册（诊断用）。
  bool get hasHandlers => _handlers.isNotEmpty;
}

/// tv: → 传输行「播放 / 暂停」键的焦点移交桥（返回键把焦点交回播放键用）。
///
/// ## 为什么是节点池
///
/// 播放页可能有多个实例同时挂载（拖拽覆盖层实例 + 被接管的页面路由实例，
/// 见 `full_player.dart` 的 `_isDragOverlay` 说明），每实例的传输行各自登记
/// 自己的播放键节点。取**最后登记的可用节点**＝视觉最上层那个，与
/// `tv_player_bar_focus_bridge.dart` 同一口径。
///
/// 节点由各传输控件（`MD3ETransportRow` / `AMTransportControls`）**自持**并随
/// 其 State 销毁，本桥只存引用、不做 dispose（误 dispose 会崩在焦点系统里）。
///
/// 仅 TV 构建使用（调用点均在 `kTvBuild` 分支内）。
class TvPlayerPlayFocusBridge {
  TvPlayerPlayFocusBridge._();

  static final TvPlayerPlayFocusBridge instance = TvPlayerPlayFocusBridge._();

  final List<FocusNode> _nodes = <FocusNode>[];

  /// 登记播放键节点。重复登记幂等（`FocusNode` 的 `==` 是恒等）。
  void register(FocusNode node) {
    if (!_nodes.contains(node)) _nodes.add(node);
  }

  /// 撤销登记（控件 State 销毁时调用）。
  void unregister(FocusNode node) {
    _nodes.remove(node);
  }

  /// 把焦点交给最上层可用的播放键。返回是否成功发出移交请求。
  ///
  /// [FocusNode.requestFocus] 异步生效，故只表示「请求已发出」。
  bool focusPlay() {
    for (final FocusNode node in _nodes.reversed) {
      if (!node.canRequestFocus) continue;
      if (node.hasFocus) return true;
      node.requestFocus();
      return true;
    }
    return false;
  }

  /// 当前是否已有登记的播放键节点（诊断用）。
  bool get hasNodes => _nodes.isNotEmpty;
}

/// tv: 返回键的统一裁决 —— 是否应把焦点交还播放键并消费这次返回。
///
/// 两个调用点共用这一份判据，避免三处漂移：
/// - `full_player*.dart` 的 `PopScope.onPopInvokedWithResult`（**真机实际收口点**）；
/// - `app.dart::_handleTvBack`（焦点丢到路由 FocusScope 时的全局兜底）；
/// - [TvPlayerBackInterceptor]（焦点节点是它的后代时的按键传播路径）。
///
/// 返回 true = 已交还焦点、调用方应消费这次返回；
/// false = 没救（焦点在控制 chrome 区 / 桥里无可用播放键），调用方放行。
bool tvPlayerTryFocusPlay() {
  final FocusNode? primary = FocusManager.instance.primaryFocus;
  // 焦点已在控制 chrome 区：放行（退出播放页）。
  // 注意 `primary` 可能是一个 FocusScopeNode（焦点丢失时的兜底落点）：它不属于
  // chrome 作用域，故落到下面的「交还」分支——这正是真机漏网场景需要的。
  if (primary != null && TvPlayerChromeScope.contains(primary)) {
    return false;
  }
  return TvPlayerPlayFocusBridge.instance.focusPlay();
}

/// tv: 播放页返回键拦截层（仅 TV 构建挂载，见 `full_player*.dart`）。
///
/// ## 为什么要拦在页内
///
/// TV 的返回键由 `Dpad.wrap(onBack: _handleTvBack)`（`app.dart`）处理，而
/// `_handleTvBack` 直接 `navigator.pop()` —— 它**绕过**播放页自身的
/// `PopScope(canPop:false)`（那是给系统返回/`maybePop` 用的）。于是焦点还在
/// 列表/评论 tab 里时按一下返回，播放页当场被 pop 掉，没有「先退回焦点」这一步
/// （用户 2026-10-18 真机实测）。
///
/// 本层挂在播放页内、`Dpad` 之下、tab 内容之上：按键从焦点节点向上冒泡，
/// 会**先**经过这里。命中规则：
/// - 焦点**不在** [TvPlayerChromeScope] 内 → 把焦点交回播放键并**消费**按键；
/// - 焦点已在控制 chrome 区（传输键 / 模式 / 收藏 / 进度尺 / 音量 / 顶栏）→
///   返回 `ignored`，放行给 `_handleTvBack`，于是「再按一次」才退出播放页。
///
/// ## 为什么判据是「非 chrome」而不是「在内容区」
///
/// 2026-10-20 真机实测：焦点停在**底部遥控 TabBar**（`TvPlayerTabBar`，位于
/// `_buildChromeBottom`、是 pager 的兄弟节点）上时按返回键，页面直接被 pop ——
/// 因为 tab 栏不在 `TvPlayerTabContentScope`（只包 pager）内，旧判据在这里放行。
/// 播放页右侧的焦点停点由各页面自建、拿不到全部句柄，而控制 chrome 是有限
/// 且集中的，故反过来标 chrome：**非 chrome 即交还焦点**。Tab 栏由此进入
/// 交还范围，内容区（列表/歌词/评论）也依旧在内。
///
/// 键码：走 dpad 的 [DpadKeySet.isBack]（含 `escape` / `goBack` /
/// `gameButtonB`，dpad `key_set.dart:70-74`），与遍历引擎同一口径——手柄 B 键
/// 当年漏认，某类遥控器/键盘的返回穿不进来。
///
/// 接线照 `tv_key_repeat.dart`：`canRequestFocus: false` + `skipTraversal: true`
/// 的 `Focus`，只挂在按键传播路径上，自身不是焦点停点、不参与遍历。
class TvPlayerBackInterceptor extends StatelessWidget {
  const TvPlayerBackInterceptor({super.key, required this.child});

  final Widget child;

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    // 只在 KeyDown 判定：KeyUp 放行（dpad 的返回动作只在按下时触发）。
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    // 键码口径与 dpad 引擎一致（escape / goBack / gameButtonB）。
    if (!Dpad.keySetOf(node.context!).isBack(event.logicalKey)) {
      return KeyEventResult.ignored;
    }
    final FocusNode? primary = FocusManager.instance.primaryFocus;
    if (primary == null) return KeyEventResult.ignored;
    // 焦点已在控制 chrome 区：放行给 dpad 的返回处理（退出播放页）。
    if (TvPlayerChromeScope.contains(primary)) {
      return KeyEventResult.ignored;
    }
    // 其余一切（tab 内容区 / 遥控 TabBar / 封面区）：交回播放键。桥里没有可用
    // 节点时也不吞按键（宁可退出，也不要出现「按了没反应」的死键）。
    if (!tvPlayerTryFocusPlay()) {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _handleKeyEvent,
      child: child,
    );
  }
}
