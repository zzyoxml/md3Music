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

/// 方向键动作：↑↓ 音量、←→ 进度。
enum _ArrowAction { volumeUp, volumeDown, seekForward, seekBack }

/// Windows 桌面「方向键播放控制」的唯一收口层。
///
/// 短按（< [DesktopPlaybackKeys.holdThreshold]）：
/// ↑ / ↓ 应用音量 ±5%，← / → 快退 / 快进 5 秒。
///
/// 长按（≥ [DesktopPlaybackKeys.holdThreshold]，每 [DesktopPlaybackKeys.holdTick] 一拍）：
/// ↑ / ↓ 连续调音量（松手一次性落盘）；→ 临时切到
/// [DesktopPlaybackKeys.holdPlaybackSpeed] 倍速，松手恢复长按前的倍速；
/// ← 暂停音频并以同一倍速连续回退进度，松手 seek 落定并恢复播放。
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
/// 1. **`KeyRepeatEvent` 不执行动作**：按住不放会持续来 `KeyRepeatEvent`，连发会把
///    音量 / 进度打飞。连续调节改由本层的 [holdTick] 定时器驱动，节奏可控且与系统
///    重复延迟无关。
/// 2. **带修饰键一律放行**：`Ctrl+←/→` 是切歌、`Alt+←/→` 是后退 / 前进（都在外层
///    [DesktopInputLayer] 里），`Shift+←/→` 是文本选择语义。掩码口径复用
///    [desktopModifierMask]，两层不各写一套「Shift 算不算」。
/// 3. **文本输入聚焦时放行**：[DefaultTextEditingShortcuts] 在 `WidgetsApp` 层、
///    **在本层之外**，所以本层若不先让位，输入框里的方向键会变成调音量 ——
///    光标移不动。判据复用 [isTextEditingFocused]。
/// 4. **视频页（MV / 场景音乐视频）让行**：见 [kVideoPlaybackActive]。
/// 5. **没有正在播放的歌 / 时长未知 / 音量不可交互**：不吞键，交回框架遍历 ——
///    此时方向键仍能当焦点导航用。
/// 6. **到 0% / 100% 边界仍算已消费**：与 [TvVolumeStepper] 同口径。否则按到底后
///    再按一下就会变成「焦点乱跳」，比「按了没反应」更让人困惑。
///
/// ## 短按与长按的判定
///
/// 按下时**不立即执行单步**，只起一个 [holdThreshold] 定时器：
/// - 定时器到点前抬起 → 在 `KeyUpEvent` 落定一次单步（= 原来的逐击语义）；
/// - 定时器到点后仍在按住 → 进入连续模式，抬起时收尾。
///
/// 这样长按 → 不会先跳 5 秒再加速、长按 ← 不会先跳 5 秒再回退，长按 ↑ 也不会先
/// 跳 5% 再匀速。代价只是单步落点从「按下」挪到「抬起」，人手按键的间隔远小于
/// 一帧的感知阈值。
///
/// ## 步长
///
/// 单步直接复用 TV 侧同一组常量（[TvVolumeStepper.defaultStep] /
/// [TvSeekStepper.defaultStepSeconds]），不另立一套，免得遥控和键盘的手感分叉。
/// 不复用那两个 *Stepper* 类本身：它们是「dpad 连发 + debounce 后一次性落定」的
/// 事件协议（`onBegin/onStep/onCommit/onAbort`，配可见滑块用），桌面键盘是离散
/// 按键，逐击立即下发才跟手。
class DesktopPlaybackKeys extends StatefulWidget {
  const DesktopPlaybackKeys({super.key, required this.child});

  final Widget child;

  /// 单次短按 ↑/↓ 的音量步进（0..1）。
  static const double volumeStep = TvVolumeStepper.defaultStep;

  /// 单次短按 ←/→ 的快进 / 快退秒数。
  static const int seekStepSeconds = TvSeekStepper.defaultStepSeconds;

  /// 提示节流：连按方向键时原生 Toast 不逐个弹（Windows 侧是独立提示窗，
  /// 每击都重建一次会闪）。
  static const Duration feedbackThrottle = Duration(milliseconds: 400);

  /// 长按判定阈值：按住超过该时长才进入连续模式。
  static const Duration holdThreshold = Duration(milliseconds: 400);

  /// 连续模式的节拍（音量每拍一步、回退每拍 [rewindHoldStep]）。
  static const Duration holdTick = Duration(milliseconds: 100);

  /// 长按 → 的临时倍速；也是长按 ← 的回退速度（[rewindHoldStep] / [holdTick]）。
  static const double holdPlaybackSpeed = 2.0;

  /// 连续调音量时每拍的步进；与 [holdTick] 组合约 2 秒走完 0~100%。
  static const double volumeHoldStep = 0.05;

  /// 连续回退时每拍退掉的时长：200ms / 100ms = [holdPlaybackSpeed] 倍速。
  static const Duration rewindHoldStep = Duration(milliseconds: 200);

  static DateTime? _lastFeedbackAt;

  /// 测试用：清掉节流时间戳，避免用例之间互相吞提示。
  @visibleForTesting
  static void resetFeedbackThrottle() => _lastFeedbackAt = null;

  /// 步进后的音量（夹取 `0..1`）。[up] = ↑ 键。
  ///
  /// 用 `math.max/min` 而非 `double.clamp`：后者的静态返回类型是 `num`，
  /// 赋回 `double` 还要多一层转换（`tv_volume_stepper.dart` 同一教训）。
  static double steppedVolume(
    double current, {
    required bool up,
    double step = volumeStep,
  }) {
    final double base = current.clamp(0.0, 1.0);
    final double delta = up ? step : -step;
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
  State<DesktopPlaybackKeys> createState() => _DesktopPlaybackKeysState();
}

class _DesktopPlaybackKeysState extends State<DesktopPlaybackKeys>
    with WidgetsBindingObserver {
  /// 当前按住中的方向键（抬起 / 收尾后清空）。
  LogicalKeyboardKey? _pendingKey;

  /// 按住中的动作（音量 / 进度方向）。
  _ArrowAction? _pendingAction;

  /// 按下时捕获的播放器：连续模式与短按落定都作用在同一个实例上。
  PlayerProvider? _pendingPlayer;

  /// 长按阈值定时器。
  Timer? _holdTimer;

  /// 连续模式节拍定时器。
  Timer? _tickTimer;

  /// 是否已进入连续模式（阈值已到）。
  bool _holding = false;

  /// 长按 → 前的倍速快照，松手恢复。
  double? _speedBeforeHold;

  /// 连续调音量的本地目标值（避开 USB 音量的整数百分比换算抖动）。
  double _volumeTarget = 0;

  /// 连续回退的本地目标位置（不依赖平台位置回传，保证严格 2 倍速）。
  Duration _rewindTarget = Duration.zero;

  /// 长按 ← 开始时是否在播放：松手决定要不要续播。
  bool _rewindWasPlaying = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // 住层被销毁时若还在连续模式，恢复倍速 / 落盘音量，别把临时状态留给下一层。
    _finishHold();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 窗口失焦 / 最小化时松手收不到 KeyUp：主动收尾，避免卡在 2x 或持续回退。
    if (state != AppLifecycleState.resumed) _finishHold();
  }

  @override
  Widget build(BuildContext context) {
    // 门控与 [DesktopInputLayer] 同源：只有 Windows 桌面走这套键位。
    // TV（`kTvBuild`）的方向键是遥控焦点导航，Android 触摸端没有方向键入口。
    if (!isWindowsDesktop) return widget.child;
    return Focus(
      // 不参与遍历、不抢焦点：本层只做「祖先按键拦截」。
      canRequestFocus: false,
      skipTraversal: true,
      debugLabel: 'desktop/playback-keys',
      onKeyEvent: (node, event) => _onKeyEvent(event),
      // 空焦点兜底：必须在本层**之内**。焦点落在兜底节点上时，冒泡链只经过它的
      // 祖先 —— 兜底若挂在本层外面，方向键就永远到不了本层（见该类的四条铁律）。
      child: EmptyFocusFallback(child: widget.child),
    );
  }

  KeyEventResult _onKeyEvent(KeyEvent event) {
    final LogicalKeyboardKey key = event.logicalKey;
    final _ArrowAction? action = _actionOf(key);

    // 连发不执行动作：连续调节由 _holdTimer / _tickTimer 驱动。
    if (event is KeyRepeatEvent) {
      return key == _pendingKey
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }

    if (event is KeyUpEvent) {
      if (key != _pendingKey) return KeyEventResult.ignored;
      final _ArrowAction? pendingAction = _pendingAction;
      final PlayerProvider? player = _pendingPlayer;
      final bool wasHolding = _holding;
      if (wasHolding) {
        _finishHold();
      } else {
        _cancelHoldTimer();
        if (pendingAction != null && player != null) {
          _applySingleStep(player, pendingAction);
        }
        _resetPress();
      }
      return KeyEventResult.handled;
    }

    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (action == null) return KeyEventResult.ignored;

    // 旧键还没抬起就按了新方向键：先把旧键按短按落定，再开始新的按压。
    if (_pendingKey != null) _finishHold(commitSingleStep: true);

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
    if (_isVolume(action) && !PlayerVolumeState.of(player).interactive) {
      return KeyEventResult.ignored;
    }
    if (_isSeek(action) && !_hasKnownDuration(player)) {
      return KeyEventResult.ignored;
    }

    _pendingKey = key;
    _pendingAction = action;
    _pendingPlayer = player;
    _holdTimer = Timer(DesktopPlaybackKeys.holdThreshold, _beginHold);
    return KeyEventResult.handled;
  }

  /// 阈值到点：确认仍按住后进入连续模式。
  void _beginHold() {
    _holdTimer = null;
    final LogicalKeyboardKey? key = _pendingKey;
    final _ArrowAction? action = _pendingAction;
    final PlayerProvider? player = _pendingPlayer;
    if (key == null || action == null || player == null) return;

    // 人手已松开（KeyUp 丢失）或守卫失效：按短按落定一次，别把按键吞掉。
    if (!HardwareKeyboard.instance.isLogicalKeyPressed(key) ||
        !_guardsStillValid(player, action)) {
      _finishHold(commitSingleStep: true);
      return;
    }

    _holding = true;
    switch (action) {
      case _ArrowAction.volumeUp:
      case _ArrowAction.volumeDown:
        _volumeTarget = PlayerVolumeState.of(player).value;
        // 阈值到点先落一步：否则按住 400~500ms 就松手会一步都没走（死区）。
        _stepVolumeHold(player, action);
      case _ArrowAction.seekForward:
        _speedBeforeHold = player.speed;
        if (player.speed != DesktopPlaybackKeys.holdPlaybackSpeed) {
          unawaited(player.setSpeed(DesktopPlaybackKeys.holdPlaybackSpeed));
        }
        _feedback('临时 2 倍速');
      case _ArrowAction.seekBack:
        _rewindWasPlaying = player.isPlaying;
        _rewindTarget = player.position;
        if (_rewindWasPlaying) unawaited(player.pauseForSeek());
        // 同音量的死区处理：阈值到点立即回退第一拍。
        _stepRewind(player);
    }
    _tickTimer = Timer.periodic(
      DesktopPlaybackKeys.holdTick,
      (_) => _onHoldTick(),
    );
  }

  void _onHoldTick() {
    final LogicalKeyboardKey? key = _pendingKey;
    final _ArrowAction? action = _pendingAction;
    final PlayerProvider? player = _pendingPlayer;
    if (!_holding || key == null || action == null || player == null) {
      _finishHold();
      return;
    }
    // 看门狗：KeyUp 丢失 / 守卫失效时立即收尾（切窗口、页面抢焦点、视频起播）。
    if (!HardwareKeyboard.instance.isLogicalKeyPressed(key) ||
        !_guardsStillValid(player, action)) {
      _finishHold();
      return;
    }

    switch (action) {
      case _ArrowAction.volumeUp:
      case _ArrowAction.volumeDown:
        _stepVolumeHold(player, action);
      case _ArrowAction.seekForward:
        // 2 倍速由播放器自己推进，tick 只负责看门狗。
        break;
      case _ArrowAction.seekBack:
        _stepRewind(player);
    }
  }

  /// 连续调音量的一拍：本地累加目标值，`persist: false` 不写盘（W5.8）。
  void _stepVolumeHold(PlayerProvider player, _ArrowAction action) {
    final double next = DesktopPlaybackKeys.steppedVolume(
      _volumeTarget,
      up: action == _ArrowAction.volumeUp,
      step: DesktopPlaybackKeys.volumeHoldStep,
    );
    if (next == _volumeTarget) {
      // 到边界：不重复下发，但仍保持占键（与短按边界口径一致）。
      _feedback('音量 ${(_volumeTarget * 100).round()}%');
      return;
    }
    _volumeTarget = next;
    unawaited(
      PlayerVolumeState.of(player).apply(player, next, persist: false),
    );
    _feedback('音量 ${(next * 100).round()}%');
  }

  /// 连续回退的一拍：按本地目标值退 [DesktopPlaybackKeys.rewindHoldStep]。
  void _stepRewind(PlayerProvider player) {
    final Duration next =
        _rewindTarget - DesktopPlaybackKeys.rewindHoldStep;
    _rewindTarget = next < Duration.zero ? Duration.zero : next;
    unawaited(player.seek(_rewindTarget));
    _feedback('已快退到 ${DesktopPlaybackKeys.formatPosition(_rewindTarget)}');
  }

  /// 收尾：取消定时器、恢复临时状态、清空按压。可重复调用。
  ///
  /// [commitSingleStep]：还没进入连续模式就被打断（新键按下 / 看门狗发现已松开 /
  /// 守卫失效）时，把这次按压按短按落定，避免「按了没反应」。
  void _finishHold({bool commitSingleStep = false}) {
    _cancelHoldTimer();
    _tickTimer?.cancel();
    _tickTimer = null;

    final bool wasHolding = _holding;
    final _ArrowAction? action = _pendingAction;
    final PlayerProvider? player = _pendingPlayer;
    final double? speedBefore = _speedBeforeHold;
    final double volumeTarget = _volumeTarget;
    final Duration rewindTarget = _rewindTarget;
    final bool rewindWasPlaying = _rewindWasPlaying;

    _holding = false;
    _speedBeforeHold = null;
    _resetPress();

    if (player == null || action == null) return;
    if (!wasHolding) {
      if (commitSingleStep) _applySingleStep(player, action);
      return;
    }

    switch (action) {
      case _ArrowAction.volumeUp:
      case _ArrowAction.volumeDown:
        // 松手一次性落盘（连调期间一直是 persist:false）。
        unawaited(
          PlayerVolumeState.of(
            player,
          ).apply(player, volumeTarget, persist: true),
        );
      case _ArrowAction.seekForward:
        if (speedBefore != null && player.speed != speedBefore) {
          unawaited(player.setSpeed(speedBefore));
        }
      case _ArrowAction.seekBack:
        unawaited(_finishRewind(player, rewindTarget, rewindWasPlaying));
    }
  }

  /// 回退落定：先 seek（用户显式操作，一起听必须感知），再按需续播。
  /// 与播放页拖拽「暂停 → seek → 恢复」同一口径。
  Future<void> _finishRewind(
    PlayerProvider player,
    Duration target,
    bool wasPlaying,
  ) async {
    await player.seek(target, forceNotify: true);
    if (wasPlaying) await player.resume();
  }

  void _cancelHoldTimer() {
    _holdTimer?.cancel();
    _holdTimer = null;
  }

  void _resetPress() {
    _pendingKey = null;
    _pendingAction = null;
    _pendingPlayer = null;
  }

  /// 短按单步：与原 `_onVolumeKey` / `_onSeekKey` 完全同源。
  void _applySingleStep(PlayerProvider player, _ArrowAction action) {
    switch (action) {
      case _ArrowAction.volumeUp:
      case _ArrowAction.volumeDown:
        // 三态判据与音量弹窗 / 常驻音量条同源：USB 独占走 DAC 音量，
        // unity 锁定档不可交互。
        final PlayerVolumeState state = PlayerVolumeState.of(player);
        if (!state.interactive) return;
        final double target = DesktopPlaybackKeys.steppedVolume(
          state.value,
          up: action == _ArrowAction.volumeUp,
        );
        // 边界处 target 不变：不重复下发（尤其别重复写盘），但仍消费这次按键。
        if (target != state.value) {
          unawaited(state.apply(player, target));
        }
        _feedback('音量 ${(target * 100).round()}%');
      case _ArrowAction.seekForward:
      case _ArrowAction.seekBack:
        final Duration? duration = player.duration;
        // 时长未知：一条看不出进度的轨道不该吃掉方向键。
        if (duration == null || duration <= Duration.zero) return;
        final Duration target = DesktopPlaybackKeys.steppedPosition(
          player.position,
          duration: duration,
          forward: action == _ArrowAction.seekForward,
        );
        // forceNotify：键盘 seek 与「拖进度条松手」同属用户显式操作，
        // 一起听房间必须感知（否则被远端纠偏静默拉回）。
        unawaited(player.seek(target, forceNotify: true));
        _feedback(
          action == _ArrowAction.seekForward
              ? '已快进到 ${DesktopPlaybackKeys.formatPosition(target)}'
              : '已快退到 ${DesktopPlaybackKeys.formatPosition(target)}',
        );
    }
  }

  /// 连续模式每拍 / 阈值到点的守卫复检。
  bool _guardsStillValid(PlayerProvider player, _ArrowAction action) {
    if (isTextEditingFocused) return false;
    if (kVideoPlaybackActive.value) return false;
    if (player.currentSong == null) return false;
    if (_isVolume(action) && !PlayerVolumeState.of(player).interactive) {
      return false;
    }
    if (_isSeek(action) && !_hasKnownDuration(player)) return false;
    return true;
  }

  static bool _isVolume(_ArrowAction action) =>
      action == _ArrowAction.volumeUp || action == _ArrowAction.volumeDown;

  static bool _isSeek(_ArrowAction action) =>
      action == _ArrowAction.seekForward || action == _ArrowAction.seekBack;

  static bool _hasKnownDuration(PlayerProvider player) {
    final Duration? duration = player.duration;
    return duration != null && duration > Duration.zero;
  }

  static _ArrowAction? _actionOf(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.arrowUp) return _ArrowAction.volumeUp;
    if (key == LogicalKeyboardKey.arrowDown) return _ArrowAction.volumeDown;
    if (key == LogicalKeyboardKey.arrowRight) return _ArrowAction.seekForward;
    if (key == LogicalKeyboardKey.arrowLeft) return _ArrowAction.seekBack;
    return null;
  }

  /// 节流后的操作提示（只用原生 `showToast`，见 AGENTS 通知口径）。
  void _feedback(String message) {
    final DateTime now = DateTime.now();
    final DateTime? last = DesktopPlaybackKeys._lastFeedbackAt;
    if (last != null && now.difference(last) < DesktopPlaybackKeys.feedbackThrottle) {
      return;
    }
    DesktopPlaybackKeys._lastFeedbackAt = now;
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
