import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../modules/player/player_video_active.dart';
import '../../modules/player/player_volume_state.dart';
import '../../providers/player_provider.dart';
import '../platform_capabilities.dart';
import '../remote/tv_seek_math.dart' show tvSeekTarget;
import '../remote/tv_seek_stepper.dart' show TvSeekStepper;
import '../remote/tv_volume_stepper.dart' show TvVolumeStepper;
import '../utils/app_toast.dart' show showToast;
import 'desktop_input_layer.dart' show desktopModifierMask, isTextEditingFocused;
import 'empty_focus_fallback.dart' show EmptyFocusFallback;

/// Windows 桌面「方向键播放控制」的唯一收口层（↑↓ 应用音量、←→ 快进快退）。
///
/// ## 为什么**不能**像空格 / F / Esc 那样挂在 `MaterialApp` 之外
///
/// 按键从 `primaryFocus` 逐级向外冒泡，第一个返回非 `ignored` 的节点赢。裸方向键
/// 在框架里已经有主：`WidgetsApp.defaultShortcuts` 把它们绑成
/// `DirectionalFocusIntent`（焦点遍历），而那个 `Shortcuts` 挂在 `WidgetsApp`
/// 最外层（`widgets/app.dart`：`Shortcuts(... child: DefaultTextEditingShortcuts(
/// child: ... builder(context, routing) ...))`）—— **`MaterialApp.builder` 的产物在
/// 它里面**。所以：
/// - 挂在 builder **之外**（[DesktopInputLayer] 的位置）：方向键永远先被默认遍历
///   吃掉，本层一次都收不到；
/// - 挂在 builder **之内**（本层）：比默认遍历更靠近焦点，才能先拿到按键，同时
///   仍在 Navigator 之上 —— 全部路由（含对话框 / 底部弹层）都在覆盖范围内。
///
/// 因此本层的正确性**完全依赖挂载位置**，见 `app.dart::_MAppView.build` 的
/// `builder` 与 `test/core/widgets/desktop_playback_keys_test.dart` 的结构断言。
///
/// ## 优先级：页内控件 > 本层 > 框架焦点遍历
///
/// 本层是不可聚焦的祖先 `Focus`，只吃**没被别人接住**的方向键：
/// - 焦点停在自带方向键语义的控件上（M3E 滑块、`m3e_sort_sheet` 的字段、封面流
///   `CoverflowPage` 等）：它们的 `Focus` / `Shortcuts` 比本层更靠近 `primaryFocus`，
///   先消费，本层不介入；
/// - 焦点不在任何页内控件上时（`primaryFocus` 就是路由的 `FocusScope`），页内那些
///   `Focus` widget **不在祖先链上**、收不到按键 —— 此时本层接手。这是「全 App
///   生效」的必然结果：桌面端裸方向键不再执行焦点遍历（`Tab` / `Shift+Tab` 照旧）。
///
/// ## 空焦点兜底（见 [EmptyFocusFallback]）
///
/// 还有第三种更糟的状态：`primaryFocus` 变成 `null`（持焦控件的 widget 被卸载，
/// 框架不会自愈）。那时按键连 widget 树都进不来 —— 本层与外层的空格 / Esc 会
/// **一起**哑掉。因此本层在 `child` 之前挂了 [EmptyFocusFallback]，且它必须在
/// 本层**之内**：兜底节点持焦时，冒泡链只经过它的祖先。
///
/// ## 逐条让位规则（每条都别删，删哪条都会静默破坏一处输入）
///
/// 1. **只认 `KeyDownEvent`**：按住不放会持续来 `KeyRepeatEvent`，连发会把音量 / 进度
///    打飞（与 [DesktopInputLayer] 的空格口径一致）。键位语义是「一下一步」。
/// 2. **带修饰键一律放行**：`Ctrl+←/→` 是切歌、`Alt+←/→` 是后退 / 前进（都在外层
///    [DesktopInputLayer] 里），`Shift+←/→` 是文本选择语义。掩码口径复用
///    [desktopModifierMask]，两层不各写一套「Shift 算不算」。
/// 3. **文本输入聚焦时放行**：[DefaultTextEditingShortcuts] 在 `WidgetsApp` 层、
///    **在本层之外**，所以本层若不先让位，输入框里的方向键会变成调音量 ——
///    光标移不动。判据复用 [isTextEditingFocused]。
/// 4. **视频页（MV / 场景音乐视频）让行**：见 [kVideoPlaybackActive]。
/// 5. **没有正在播放的歌 / 时长未知 / 音量不可交互**：不吞键，交回框架遍历 ——
///    此时方向键仍能当焦点导航用。
/// 6. **到 0% / 100% 边界仍算已消费**：与 `TvVolumeStepper` 同口径。否则按到底后
///    再按一下就会变成「焦点乱跳」，比「按了没反应」更让人困惑。
///
/// ## 步长
///
/// 直接复用 TV 侧同一组常量（[TvVolumeStepper.defaultStep] /
/// [TvSeekStepper.defaultStepSeconds]），不另立一套，免得遥控和键盘的手感分叉。
/// 不复用那两个 *Stepper* 类本身：它们是「dpad 连发 + debounce 后一次性落定」的
/// 事件协议（`onBegin/onStep/onCommit/onAbort`，配可见滑块用），桌面键盘是离散
/// 按键，逐击立即下发才跟手。
class DesktopPlaybackKeys extends StatelessWidget {
  const DesktopPlaybackKeys({super.key, required this.child});

  final Widget child;

  /// 单次 ↑/↓ 的音量步进（0..1）。
  static const double volumeStep = TvVolumeStepper.defaultStep;

  /// 单次 ←/→ 的快进 / 快退秒数。
  static const int seekStepSeconds = TvSeekStepper.defaultStepSeconds;

  /// 提示节流：连按方向键时原生 Toast 不逐个弹（Windows 侧是独立提示窗，
  /// 每击都重建一次会闪）。
  static const Duration feedbackThrottle = Duration(milliseconds: 400);

  static DateTime? _lastFeedbackAt;

  /// 测试用：清掉节流时间戳，避免用例之间互相吞提示。
  @visibleForTesting
  static void resetFeedbackThrottle() => _lastFeedbackAt = null;

  /// 步进后的音量（夹取 `0..1`）。[up] = ↑ 键。
  ///
  /// 用 `math.max/min` 而非 `double.clamp`：后者的静态返回类型是 `num`，
  /// 赋回 `double` 还要多一层转换（`tv_volume_stepper.dart` 同一教训）。
  static double steppedVolume(double current, {required bool up}) {
    final double base = current.clamp(0.0, 1.0);
    final double delta = up ? volumeStep : -volumeStep;
    return math.max(0.0, math.min(1.0, base + delta));
  }

  /// 步进后的播放位置（夹取 `[0, duration]`）。[forward] = → 键。
  ///
  /// 夹取与 MV / 刷刷竖屏流共用 [tvSeekTarget]：同一份「不许越界」口径。
  static Duration steppedPosition(
    Duration current, {
    required Duration duration,
    required bool forward,
  }) => tvSeekTarget(
    current,
    duration,
    forward ? seekStepSeconds : -seekStepSeconds,
  );

  /// `m:ss`（超过一小时按总分钟数显示，与进度条口径一致）。
  static String formatPosition(Duration position) {
    final int seconds = position.inSeconds < 0 ? 0 : position.inSeconds;
    final String ss = (seconds % 60).toString().padLeft(2, '0');
    return '${seconds ~/ 60}:$ss';
  }

  @override
  Widget build(BuildContext context) {
    // 门控与 [DesktopInputLayer] 同源：只有 Windows 桌面走这套键位。
    // TV（`kTvBuild`）的方向键是遥控焦点导航，Android 触摸端没有方向键入口。
    if (!isWindowsDesktop) return child;
    return Focus(
      // 不参与遍历、不抢焦点：本层只做「祖先按键拦截」。
      canRequestFocus: false,
      skipTraversal: true,
      debugLabel: 'desktop/playback-keys',
      onKeyEvent: (node, event) => _onKeyEvent(context, event),
      // 空焦点兜底：必须在本层**之内**。焦点落在兜底节点上时，冒泡链只经过它的
      // 祖先 —— 兜底若挂在本层外面，方向键就永远到不了本层（见该类的四条铁律）。
      child: EmptyFocusFallback(child: child),
    );
  }

  KeyEventResult _onKeyEvent(BuildContext context, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final LogicalKeyboardKey key = event.logicalKey;
    final bool isUp = key == LogicalKeyboardKey.arrowUp;
    final bool isDown = key == LogicalKeyboardKey.arrowDown;
    final bool isLeft = key == LogicalKeyboardKey.arrowLeft;
    final bool isRight = key == LogicalKeyboardKey.arrowRight;
    if (!isUp && !isDown && !isLeft && !isRight) {
      return KeyEventResult.ignored;
    }
    // 让位 2：带任何修饰键都不是「播放控制」（Ctrl+←/→ 切歌在更外层）。
    if (desktopModifierMask(HardwareKeyboard.instance) != 0) {
      return KeyEventResult.ignored;
    }
    // 让位 3：文本输入里方向键是光标移动。
    if (isTextEditingFocused) return KeyEventResult.ignored;
    // 让位 4：视频页正在前台，方向键归视频页自己。
    if (kVideoPlaybackActive.value) return KeyEventResult.ignored;

    final PlayerProvider? player = _playerOf(context);
    // 让位 5：没有歌可操作时不吞键。
    if (player == null || player.currentSong == null) {
      return KeyEventResult.ignored;
    }

    if (isUp || isDown) return _onVolumeKey(player, up: isUp);
    return _onSeekKey(player, forward: isRight);
  }

  KeyEventResult _onVolumeKey(PlayerProvider player, {required bool up}) {
    // 三态判据与音量弹窗 / 常驻音量条同源：USB 独占走 DAC 音量，
    // unity 锁定档不可交互（此时按键放行，别占着键什么也不做）。
    final PlayerVolumeState state = PlayerVolumeState.of(player);
    if (!state.interactive) return KeyEventResult.ignored;
    final double target = steppedVolume(state.value, up: up);
    // 边界处 target 不变：不重复下发（尤其别重复写盘），但仍消费这次按键。
    if (target != state.value) {
      unawaited(state.apply(player, target));
    }
    _feedback('音量 ${(target * 100).round()}%');
    return KeyEventResult.handled;
  }

  KeyEventResult _onSeekKey(PlayerProvider player, {required bool forward}) {
    final Duration? duration = player.duration;
    // 时长未知：一条看不出进度的轨道不该吃掉方向键。
    if (duration == null || duration <= Duration.zero) {
      return KeyEventResult.ignored;
    }
    final Duration target = steppedPosition(
      player.position,
      duration: duration,
      forward: forward,
    );
    // forceNotify：键盘 seek 与「拖进度条松手」同属用户显式操作，
    // 一起听房间必须感知（否则被远端纠偏静默拉回）。
    unawaited(player.seek(target, forceNotify: true));
    _feedback(
      forward
          ? '已快进到 ${formatPosition(target)}'
          : '已快退到 ${formatPosition(target)}',
    );
    return KeyEventResult.handled;
  }

  /// 节流后的操作提示（只用原生 `showToast`，见 AGENTS 通知口径）。
  void _feedback(String message) {
    final DateTime now = DateTime.now();
    final DateTime? last = _lastFeedbackAt;
    if (last != null && now.difference(last) < feedbackThrottle) return;
    _lastFeedbackAt = now;
    showToast(message);
  }

  PlayerProvider? _playerOf(BuildContext context) {
    try {
      return context.read<PlayerProvider>();
    } on ProviderNotFoundException {
      // 生产不会走到（本层在 MultiProvider 之内）；测试里可单独挂载。
      return null;
    }
  }
}
