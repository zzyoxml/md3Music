import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../main.dart' show appNavigatorKey;
import '../../modules/player/full_player_route.dart' show openFullPlayer;
import '../../providers/player_provider.dart';
import '../platform_capabilities.dart';

/// 桌面「返回 / 前进」的路由出口。
///
/// **为什么用全局静态槽位**：键位收在本文件（挂在 `MaterialApp` 之外，见
/// [DesktopInputLayer]），而「哪一层被消费掉」的判定住在 `_MainLayout` 的根
/// `PopScope` 里（只有那里同时握着壳层句柄与 tab 状态）。`app.dart` 已 import
/// 本文件，反向 import 会成环——与 `core/layout/bottom_chrome_sink.dart`、
/// `PlayerZenBridge` 同一套「宿主注册回调、全局层询问」的模式。
///
/// 未注册（新手引导页、用户协议页、首帧前）时退化为根 Navigator 的 `maybePop`。
abstract final class DesktopInputRouter {
  DesktopInputRouter._();

  /// 宿主注册的「返回」。返回 true = 本次已被消费（弹层 / 二级页 / 收起播放页等）。
  static Future<bool> Function()? backHandler;

  /// 宿主注册的「前进」。返回 true = 前进历史里有东西并被重建。
  static bool Function()? forwardHandler;

  /// 后退一级（Esc / Alt+← / 鼠标侧键「后退」共用这一条链路）。
  ///
  /// 宿主已注册时**完全交给宿主**：宿主走到根路由会返回 false，此时本函数什么
  /// 都不做——桌面端 `Esc` 落到「再按一次退出」会经 `showToast` 弹出原生
  /// `MessageBoxW` 模态框（Windows 的 Toast 实现，见
  /// `windows/runner/flutter_window.cpp`），用户在输入框/菜单里按 Esc 绝不该
  /// 撞上模态框。只有宿主不在场（引导页 / 协议页）才回落根 Navigator。
  static Future<void> dispatchBack() async {
    final host = backHandler;
    if (host != null) {
      // ignore: discarded_futures
      await host();
      return;
    }
    // ignore: discarded_futures
    appNavigatorKey.currentState?.maybePop();
  }

  /// 前进一级（侧键「前进」/ Alt+→）。无前进历史时不动作。
  static void dispatchForward() {
    forwardHandler?.call();
  }
}

/// 焦点是否停在文本输入上（`EditableText` 及其任意祖先位置）。
///
/// 用焦点节点的 context 向上找 `EditableTextState`：实测（`tmp/f_probe2_test.dart`）
/// 文本框聚焦时 `primaryFocus.context` 是 `TextField` 内部挂焦点的 `Focus` 元素，
/// `findAncestorStateOfType<EditableTextState>()` 命中为 true，非文本焦点为 null。
bool get isTextEditingFocused {
  final BuildContext? context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  return context.findAncestorStateOfType<EditableTextState>() != null;
}

/// 当前按下的修饰键位掩码（`Ctrl / Alt / Shift / Meta` 各占一位）。
///
/// **Shift 必须计入**：框架 `SingleActivator` 的判等口径是「除声明的那个之外
/// 一个都不许按」（`shift` 默认要求 false）。若这里放过 Shift，
/// `Ctrl+Shift+←`（Windows 文本层是「扩选到词首」）与 `Shift+空格` 会被误当成
/// 应用快捷键 —— 相比旧外壳绑定属于凭空扩大命中面。
///
/// **对桌面其它快捷键层公开**（`core/widgets/desktop_playback_keys.dart` 的
/// 方向键层）：两层各写一套掩码迟早会在「Shift 算不算修饰键」上分叉，而分叉的
/// 表现是某个组合键忽然被抢，纯代码审查看不出来。
int desktopModifierMask(HardwareKeyboard kb) =>
    (kb.isControlPressed ? _kCtrlMask : 0) |
    (kb.isAltPressed ? _kAltMask : 0) |
    (kb.isShiftPressed ? _kShiftMask : 0) |
    (kb.isMetaPressed ? _kMetaMask : 0);

const int _kCtrlMask = 1;
const int _kAltMask = 2;
const int _kShiftMask = 4;
const int _kMetaMask = 8;

/// Windows 桌面键鼠输入的唯一收口层（空格播放/暂停、F 播放页、Esc 返回、
/// 鼠标侧键前进后退）。
///
/// **唯一**指「除裸方向键以外」的桌面键位：方向键的音量 / 进度是
/// `core/widgets/desktop_playback_keys.dart`（`DesktopPlaybackKeys`），**不能**并到
/// 本层 —— 裸方向键在框架里已被 `WidgetsApp.defaultShortcuts` 绑成
/// `DirectionalFocusIntent`，那个 `Shortcuts` 在 `MaterialApp` 之内，本层挂在外面
/// 永远收不到（详见那边的类注释与 docs/agents/windows-desktop.md W6.1）。
///
/// ## 为什么必须挂在 `MaterialApp` **之外**
///
/// 按键从 `primaryFocus` 由内向外冒泡，第一个「消费或截停」的节点赢。框架自带
/// 两层绑定在 Navigator **之内**：
/// 1. `WidgetsApp.defaultShortcuts`：`space → ActivateIntent`（激活聚焦按钮）、
///    `escape → DismissIntent`（关 `barrierDismissible` 的弹层）；
/// 2. `DefaultTextEditingShortcuts`：文本框聚焦时 `space`/`enter`/方向键 →
///    `DoNothingAndStopPropagationTextIntent`（把键交给 IME）。
///
/// 两者的 Action 都返回 `handled` 或 `skipRemainingHandlers`，**都会终止冒泡**
/// （`focus_manager.dart` 的祖先遍历遇到非 `ignored` 即 break）。所以：
/// - 本层挂在它们**之外**：按钮上按空格先激活按钮、输入框里按空格先打出空格，
///   两者都没消费时才轮到「播放/暂停」——「键盘能控制按钮」与新快捷键同时成立
///   只有这一种姿势；
/// - 若像旧版 `DesktopShell` 那样挂在页面**内部**（更靠近焦点），反而抢在框架
///   之前：`桌面布局` 开启后搜索框里打不出空格（旧缺陷，本层顺带修掉）。
///
/// 对照 F11：它挂在 `HardwareKeyboard`（全局、早于 widget 管线，见
/// `core/services/windows_fullscreen.dart`），因为全屏不该被焦点左右。空格/字母
/// 恰恰**必须**被焦点左右（让位给按钮与输入框），所以走 widget 管线。
///
/// ## 裸字母必须条件消费
///
/// 引擎侧 `keyboard_manager.cc` 会把「框架已处理」的按键对应的 `WM_CHAR` 丢弃
/// （注释 `// dispatch the OnText if the key down event is not handled`），而
/// Windows 的文本层**没有**裸字母绑定（不像 space/enter 有保护）。所以 `F` 若在
/// 输入框聚焦时也返回 handled，用户就打不出字母 `f` —— 见 [isTextEditingFocused]。
///
/// ## 鼠标侧键不是键盘键
///
/// Windows embedder 把 `XBUTTON1/XBUTTON2` 映射成指针按钮位
/// （`flutter_window.cc` → `kFlutterPointerButtonMouseBack/Forward`），Dart 侧即
/// [kBackMouseButton]/[kForwardMouseButton]，所以走 [Listener] 而非按键管线，
/// 无需任何原生改动。`TapGestureRecognizer` 默认不接受这两个按钮位
/// （`gestures/tap.dart` 的 `isPointerAllowed`），不会被既有点击手势误吞或误触。
///
/// ## 门控
///
/// 只在 Windows 桌面生效：Android / TV 原样返回 child，键位链路（TV 的媒体键、
/// 菜单键在 `app.dart::_tvMediaKeyFallback` 与 `TvMenuKeyShortcuts`）零变化。
/// 判据用 [isWindowsDesktop]（`defaultTargetPlatform` 口径）而非
/// `Platform.isWindows`——后者在 Windows 宿主上跑 `flutter test` 同样为 true，
/// 会把宿主平台泄漏进本该跑 Android 语义的测试（与 `WindowsFullscreen.supported`
/// 同一教训）。mac/linux 不纳入：本仓库只有 Windows runner 实现了配套的窗口能力。
class DesktopInputLayer extends StatelessWidget {
  const DesktopInputLayer({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!isWindowsDesktop) return child;
    return Listener(
      // 侧键的按下点可能落在没有任何手势识别器的空白处；translucent 让本层
      // 自身参与命中测试，才能在整窗范围内收到侧键事件。
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (node, event) => _onKeyEvent(context, event),
        child: child,
      ),
    );
  }

  void _onPointerDown(PointerDownEvent event) {
    if ((event.buttons & kBackMouseButton) != 0) {
      // ignore: discarded_futures
      DesktopInputRouter.dispatchBack();
      return;
    }
    if ((event.buttons & kForwardMouseButton) != 0) {
      DesktopInputRouter.dispatchForward();
    }
  }

  KeyEventResult _onKeyEvent(BuildContext context, KeyEvent event) {
    // 只认按下：按住不放会持续来 KeyRepeatEvent，播放切换与切歌都不能连发。
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final LogicalKeyboardKey key = event.logicalKey;

    // 媒体键无修饰键语义，先单独判掉。
    if (key == LogicalKeyboardKey.mediaPlayPause) {
      return _togglePlay(context)
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.mediaTrackNext) {
      return _skip(context, next: true)
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.mediaTrackPrevious) {
      return _skip(context, next: false)
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }

    final HardwareKeyboard kb = HardwareKeyboard.instance;
    final int mods = desktopModifierMask(kb);
    if (key == LogicalKeyboardKey.escape) {
      // ignore: discarded_futures
      DesktopInputRouter.dispatchBack();
      // 恒消费：走到这里说明弹层与页面都没接住 Esc，绝不能再落到
      // 「双击返回退出」那条 Android 语义上（见 DesktopInputRouter.dispatchBack）。
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.space && mods == 0) {
      return _togglePlay(context)
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.keyF && mods == 0) {
      // 输入框聚焦时放行：返回 handled 会让引擎丢掉这次按键的 WM_CHAR，
      // 搜索框就打不出字母 f（见类注释「裸字母必须条件消费」）。
      if (isTextEditingFocused) return KeyEventResult.ignored;
      _openFullPlayer();
      return KeyEventResult.handled;
    }
    // Ctrl+←/→ 切歌（与旧桌面外壳的 SingleActivator 同口径：只允许按着 Ctrl）。
    if (mods == _kCtrlMask && key == LogicalKeyboardKey.arrowLeft) {
      return _skip(context, next: false)
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    if (mods == _kCtrlMask && key == LogicalKeyboardKey.arrowRight) {
      return _skip(context, next: true)
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    // Alt+←/→ 后退 / 前进（与鼠标侧键同一对语义）。
    if (mods == _kAltMask && key == LogicalKeyboardKey.arrowLeft) {
      // ignore: discarded_futures
      DesktopInputRouter.dispatchBack();
      return KeyEventResult.handled;
    }
    if (mods == _kAltMask && key == LogicalKeyboardKey.arrowRight) {
      DesktopInputRouter.dispatchForward();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 空格 / 媒体播放键：切换播放暂停。返回 false = 无可操作歌曲，不吞键。
  bool _togglePlay(BuildContext context) {
    final PlayerProvider? player = _playerOf(context);
    if (player == null || player.currentSong == null) return false;
    // ignore: discarded_futures
    player.isPlaying ? player.pause() : player.resume();
    return true;
  }

  /// Ctrl+方向键 / 媒体上下曲键：切歌。返回 false = 播放器不可用，不吞键。
  bool _skip(BuildContext context, {required bool next}) {
    final PlayerProvider? player = _playerOf(context);
    if (player == null || player.currentSong == null) return false;
    // ignore: discarded_futures
    next ? player.next() : player.previous();
    return true;
  }

  /// F：打开完整播放页。
  ///
  /// 走 `openFullPlayer` 而不是自己 push：它统一防重复入栈（栈顶已有播放页时
  /// 不动作、被别的页面盖住时回退到它），否则路由栈里会并存多个播放页实例、
  /// 各自驱动歌词动画（见 `full_player_route.dart` 的说明）。
  void _openFullPlayer() {
    final BuildContext? navContext = appNavigatorKey.currentContext;
    if (navContext == null) return;
    openFullPlayer(navContext);
  }

  PlayerProvider? _playerOf(BuildContext context) {
    try {
      return context.read<PlayerProvider>();
    } on ProviderNotFoundException {
      // 本层挂在 MultiProvider 之内，生产不会走到；测试里可单独挂载。
      return null;
    }
  }
}
