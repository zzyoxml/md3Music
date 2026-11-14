import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui show Gradient;
import 'dart:ui' show FontFeature, lerpDouble;

import 'package:dpad/dpad.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';

import '../core/build_flags.dart';
import '../core/remote/tv_hint_bar.dart';
import '../core/remote/tv_seek_stepper.dart';
import '../core/services/player_frame_driver.dart';
import '../core/theme/app_dimens.dart';
/// 播放页进度条「波浪起伏」总开关（回退开关）。
///
/// 默认开启（= 2026-10-01 新增的 MD3 波浪样式）；关闭后进度条退回该改动之前的
/// 直线形态——几何与颜色逐像素不变，只是不再起伏，且不再订阅
/// [PlayerFrameDriver] 共享 60fps 节拍（AGENTS.md §10：不留空转帧提交）。
///
/// 用全局 [ValueNotifier] 而非 Provider：MD3 播放页（full_player.dart）把进度条
/// 挂在 `Listenable.merge` 上，读 `.value` 即可在开关切换的同一帧重建，不需要在
/// 播放页 State 里再存一份镜像状态（与 [kSecondaryPlayerEnabled] 同模式）。
/// 由设置页开关运行时写入，启动时由 `app.dart` 从持久化载入。
final ValueNotifier<bool> kSeekBarWaveEnabled = ValueNotifier<bool>(true);

/// 播放器进度条 —— 一条最细的轨道 + 下方一行时间。
///
/// 设计要点：
/// - 已播放段与剩余段**不叠加**：剩余段从播放点后 4px 起画（MD3 expressive
///   的间隙做法）。
/// - 已播放段末端没有手柄，只有轨道自身的圆头。
/// - 时间常显但压暗（50%），按下/拖动时提亮到全不透明并膨胀轨道；
///   数字固定占 14px 一行，不会被上方内容遮挡或截断。
/// - 已播放段**播放中才有颜色**：暂停时在 220ms 内褪成与未播放段相同的
///   [inactiveColor]（拖动中视为「有颜色」，便于看清落点）。
/// - **MD3 皮肤（md3Style）播放中画正弦波**：只在播放中起伏（相位挂
///   [PlayerFrameDriver] 共享 60fps 节拍，AGENTS.md §10），暂停/拖动时
///   波幅 250ms 收敛成直线；AM 皮肤全程纯细线。
///   [waveEnabled] 为 false 时不起伏（回退开关，见 [kSeekBarWaveEnabled]）。
/// - 位置**自驱动**：provider 的位置更新只有 ~200ms 一次（5fps），进度条内部
///   用 [Ticker] 以 30fps 自行累加时间，画面因此连续；每次收到上报就对齐一次
///   ([_rebase])，并做单调保护避免秒数回跳。倍速由 [speed] 参与推算。
/// - 拖动过程只更新本地画面与时间数字，**不下发 seek**（连续 seek 会把
///   音频层打满导致跟手卡顿），松手时才 seek 一次。
/// - [climaxStart]/[climaxEnd]（单位秒）非空时叠加高潮区间高亮：MD3 皮肤下
///   高潮段按**同一相位**加粗起伏——已播部分随波形掠过并在尾后渐隐消隐，
///   未播部分贴中线成粗带；AM 皮肤保持静态直带（只画未播段）。
///
/// 以下四项为横屏常驻控制带（`widgets/player_dock/`）准备，**默认全关**，
/// 关闭时行为与本文件未加这些参数时逐像素一致：
/// - [tickMarks]：按下/拖动时轨道上浮现时间刻线（每 15 秒短、每 60 秒高，不带字）。
/// - [showRemaining]：静止态右侧显示总时长，只有按下/拖动才切成「−剩余」。
/// - [onDoubleTapSkip]：双击左/右半区请求 ±15 秒平移（点按跳转随之延后
///   [PlayerSeekBar.tapCommitDelay] 让位给双击判定，见 [_settleTap]）。
class PlayerSeekBar extends StatefulWidget {
  /// 默认条高（含底部 14dp 的时间数字行）。提成公开常量，别再各处写 38。
  static const double defaultHeight = 38;

  /// 时间数字那一行的高度。
  ///
  /// 也是时间行中央提示胶囊的定高（见 [labelRowHints]）：胶囊与这一行等高，
  /// 提示出现/消失才不改变进度条总高，页面底部 chrome 不会上下抖。
  static const double labelRowHeight = 14;

  const PlayerSeekBar({
    super.key,
    required this.position,
    required this.duration,
    required this.activeColor,
    required this.inactiveColor,
    required this.labelColor,
    this.isPlaying = false,
    this.md3Style = false,
    this.waveEnabled = true,
    this.speed = 1.0,
    this.climaxStart,
    this.climaxEnd,
    this.height = defaultHeight,
    this.enabled = true,
    this.visible = true,
    this.tickMarks = false,
    this.showRemaining = false,
    this.labelRowBadge,
    this.labelRowHints,
    this.onDoubleTapSkip,
    this.onDisabledTap,
    this.onSeekStart,
    this.onSeekEnd,
  });

  final Duration position;
  final Duration duration;

  /// 已播放段颜色（仅播放中/拖动中生效，其余时候褪成 [inactiveColor]）
  final Color activeColor;

  /// 未播放段轨道颜色
  final Color inactiveColor;

  /// 时间数字颜色
  final Color labelColor;

  /// 是否正在播放（决定已播放段是否上色、以及自驱动 ticker 是否推进）
  final bool isPlaying;

  /// MD3 皮肤：轨道 3px + 末端 stop indicator 圆点；AM 皮肤为 2px 纯细线。
  final bool md3Style;

  /// 波浪起伏总开关（仅 [md3Style] 为真时有意义）。
  ///
  /// false = 回退形态：已播放段与高潮段一律走直线分支（与开启前逐像素一致），
  /// 且不再订阅 [PlayerFrameDriver] 共享节拍。默认 true（保留新增的波浪样式）。
  final bool waveEnabled;

  /// 播放倍速，用于自驱动推算位置（0.5x / 2x 时进度条不会走错速度）
  final double speed;

  /// 高潮区间起止（秒），任一为空则不画高亮
  final double? climaxStart;
  final double? climaxEnd;

  final double height;

  /// 是否允许点按/拖动跳转。
  ///
  /// false 时进度条退化为**只读指示器**：轨道、时间与自驱动照常刷新，但不响应
  /// 点按与拖动，也不会调用 [onSeekStart] / [onSeekEnd]。用于一起听听众端——
  /// 成员拖动会被远端纠偏立刻拉回，此时给不出「拖不动」的结果才是对的。
  final bool enabled;

  /// 当前这条进度条**是否真的在屏幕上**（chrome 被 Zen 淡出后传 false）。
  ///
  /// `Opacity(0)` / `Offstage` 都不会让本控件的自驱动与波浪节拍自己停下来，
  /// 而不可见时持续产帧正是 AGENTS §10.4 第 3/6 条点名的漏电点。
  /// false 时：不订阅 [PlayerFrameDriver] 共享节拍、2fps 自驱动 Timer 也停掉。
  final bool visible;

  /// 刻度尺：按下/拖动时在轨道上浮现时间刻线（每 15 秒一道短刻线、每 60 秒
  /// 一道高刻线，都不带字）。刻线随轨道膨胀一起淡入，松手即退。
  ///
  /// 默认 false = 旧观（轨道上没有任何刻线）。
  final bool tickMarks;

  /// 「−剩余」收成只在按下/拖动时出现：静止态右侧显示**总时长**。
  ///
  /// false（默认）= 右侧恒为「−剩余」（旧观）。
  final bool showRemaining;

  /// 与进度条两侧时间数字**同一行**的中央插槽（横屏放音质徽章）。
  ///
  /// 非空时时间行不再被强钳到 14px（徽章比数字高），也不套 `IgnorePointer`
  /// —— 插槽里的按钮必须点得到。为空时与改动前逐像素一致。
  final Widget? labelRowBadge;

  /// 与两侧时间数字同一行的中央状态提示（「缓冲中」/「音频过渡中」胶囊组），
  /// 与 [labelRowBadge] 共同组成中央组、整体居中于两个时间数字之间。
  ///
  /// **只在有提示时传非 null**：为空时时间行维持 14dp 定高 + `IgnorePointer`
  /// （提示不改变进度条总高）；非空时若仍无 [labelRowBadge]，同样维持 14dp
  /// 定高（胶囊与这一行等高，见 [labelRowHeight]），一旦有 [labelRowBadge]
  /// 就按徽章的自然高度排。
  ///
  /// 内容必须是非交互的（纯文案）：这一路没有素材会被点到，拖动/点按照旧交给
  /// 整条进度条的手势。组内若比可用宽度还宽，会整体等比缩小（同徽章的处理），
  /// 不会撑破车机窄面板或大字号。
  final Widget? labelRowHints;

  /// 双击左/右半区时请求平移播放头，回调参数为**秒数增量**（-15 / +15）；
  /// TalkBack 的滑条增减动作走同一出口。
  ///
  /// null（默认）= 不启用，点轨道任意处即时跳转（旧行为）。
  /// 启用后点按跳转会延后 [PlayerSeekBar.tapCommitDelay] 让位给双击判定，
  /// 拖动不受影响。平移的落地（seek / 触觉 / 暂停恢复）由调用方在这个回调里做。
  final ValueChanged<int>? onDoubleTapSkip;

  /// 双击判定窗口：两次点按起手间隔落在这么短的时间内算「双击平移」。
  static const Duration doubleTapWindow = Duration(milliseconds: 300);

  /// 启用 [onDoubleTapSkip] 后点按跳转的延后量（等双击判定尘埃落定）。
  static const Duration tapCommitDelay = Duration(milliseconds: 250);

  /// 双击平移步长（秒）：左半区 −15、右半区 +15。
  static const int skipSeconds = 15;

  /// 只读态（[enabled] 为 false）下被点按或起拖时的回调，用于说明为什么拖不动。
  final VoidCallback? onDisabledTap;

  /// 开始拖动（用于暂停播放避免与 seek 抢位）
  final VoidCallback? onSeekStart;

  /// 松手后的最终位置
  final ValueChanged<Duration>? onSeekEnd;
  @override
  State<PlayerSeekBar> createState() => _PlayerSeekBarState();
}

class _PlayerSeekBarState extends State<PlayerSeekBar>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  /// 时间行高度（[PlayerSeekBar.height] 减去它就是轨道区高度）
  static const double _labelHeight = PlayerSeekBar.labelRowHeight;

  /// 自驱动帧间隔：2fps（超过这个间隔才重绘进度条与两侧时间，
  /// 由 120Hz 屏幕节流到低频，只在校对/拖动时才高频）。
  static const int _frameIntervalMs = 500;

  /// 上报位置与推算位置差值超过这个阈值就认为发生了 seek / 切歌，硬重置
  static const int _resyncThresholdMs = 1000;

  /// 轨道膨胀动画：0 = 常态细轨道，1 = 拖动态粗轨道
  late final AnimationController _expand;

  /// 已播放段上色动画：1 = activeColor（播放中/拖动中），0 = inactiveColor
  late final AnimationController _tint;

  /// 波幅系数：1 = 完整起伏，0 = 直线。暂停/拖动时 250ms 收敛成直线。
  /// 这是瞬态动画（只在状态切换的 250ms 内跑 Ticker），不违反 §10 的常驻限帧。
  late final AnimationController _waveAmp;

  /// 波浪相位（0~1 循环）。由 PlayerFrameDriver 共享 60fps 节拍推进，
  /// 经 ValueNotifier 只重绘画布，不 setState、不自建 Timer（AGENTS.md §10.3）。
  final ValueNotifier<double> _wavePhase = ValueNotifier(0);

  /// 是否已订阅共享节拍。绑定条件与解绑条件必须双向齐全
  /// （didUpdateWidget / 拖动 / 收敛 / dispose 四处收口）。
  bool _waveBound = false;

  /// 相位用单调秒表累加真实 dt：掉帧/后台回来时相位跟得上，不会走慢
  final Stopwatch _waveClock = Stopwatch()..start();
  int _lastWaveTickMs = 0;

  /// 波形相位周期（3s 一循环），与旧波浪版节奏一致
  static const int _wavePeriodMs = 3000;

  /// 2fps 自驱动定时器（进度条与两侧时间按此低频推进）
  Timer? _timerFrame;

  /// 自驱动帧计数：每帧 +1，驱动画布与时间数字重绘（不走 setState）
  final ValueNotifier<int> _frame = ValueNotifier(0);

  /// 拖动中的进度比例。用 ValueNotifier 而不是 setState：
  /// 跟手时每帧只重绘画布与时间数字，不重建整个 widget 子树（避免拖动卡顿）。
  final ValueNotifier<double> _dragFraction = ValueNotifier(0);

  /// 当前展示的位置（毫秒）—— 由定时器每帧间隔累加、由上报位置定期校准
  int _displayMs = 0;

  bool _dragging = false;
  double _trackWidth = 0;

  /// 按下是否只是「预览」：视觉与拖动一致（轨道膨胀、播放头跟到落点），但既不
  /// 下发 [PlayerSeekBar.onSeekStart] 也不 seek，等双击判定出结果再定性。
  bool _previewing = false;

  /// 待落定的点按跳转（启用 [PlayerSeekBar.onDoubleTapSkip] 时才有）
  Timer? _tapCommitTimer;

  /// 上一次点按**松手**时刻（单调毫秒，null = 没有待配对的点按）与按下落在哪半区。
  ///
  /// 必须可空：用 0 起算会让挂载后的第一次点按落进「与上次间隔 <窗口」的分支，
  /// 直接被当成双击。
  int? _lastTapUpMs;
  bool _tapInLeftHalf = false;

  /// 点按判定用单调时钟：不用 DateTime.now，系统改时间会让判定窗口失真
  final Stopwatch _tapClock = Stopwatch()..start();

  /// [TickerMode] 是否被关闭（被不透明路由覆盖 / TabBarView 切走）。
  bool _tickerModeMuted = false;

  /// App 是否退到后台（引擎不产帧，自驱动 Timer 空转纯属唤醒浪费）。
  bool _appSuspended = false;

  /// 帧生产是否被挂起：`TickerMode` 关闭或 App 退到后台。
  ///
  /// 共享节拍与 2fps 自驱动都靠它收口：两者都是 `Timer`，不受 `TickerMode`
  /// 约束（§10.3），不显式挂起就是「画面看不见、帧照产」（§10.4.3）。
  bool get _framesSuspended => _tickerModeMuted || _appSuspended;

  /// tv: 遥控调节状态机（懒建，普通构建永不实例化）。
  TvSeekStepper? _tvStepper;

  /// tv: 把状态机接到本控件：四个回调全部走触屏同一条既有出口，
  /// 不新增第二套 seek 逻辑。
  TvSeekStepper get _tvAdjust => _tvStepper ??= TvSeekStepper(
    onBegin: () {
      // 第一次按下才暂停 + 进膨胀态（与触屏「按下即 onSeekStart」同一时序）
      _cancelPendingTap();
      _enterAdjust(_fraction, previewing: false);
      widget.onSeekStart?.call();
    },
    onStep: (fraction) => _dragFraction.value = fraction,
    onCommit: _endDrag,
    onAbort: () {
      if (_dragging) _releasePress();
    },
    // tv: 连按升级步长（5→15→30s），精调与粗调兼得。
    escalation: const [5, 15, 30],
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _expand = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    _tint = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      value: widget.isPlaying ? 1 : 0,
    );
    _displayMs = widget.position.inMilliseconds;
    _waveAmp = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
      value: widget.md3Style && widget.waveEnabled && widget.isPlaying
          ? 1.0
          : 0.0,
    );
    // 波幅收敛到 0 之后再解绑共享节拍：先让波形平滑压平，再停掉帧来源
    _waveAmp.addStatusListener((status) {
      if (status == AnimationStatus.dismissed) _unbindWaveDriver();
    });
    _syncTicker();
    _syncWave();
  }

  @override
  void didUpdateWidget(covariant PlayerSeekBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.position != widget.position ||
        oldWidget.isPlaying != widget.isPlaying ||
        oldWidget.duration != widget.duration) {
      _rebase();
    }
    if (oldWidget.isPlaying != widget.isPlaying) {
      _syncTint();
    }
    // 起波的三个输入（播放中 / MD3 皮肤 / 波浪开关）任一变化都要重算：
    // 只在 isPlaying 变化时同步的话，播放中切开关会一直停在旧形态。
    if (oldWidget.isPlaying != widget.isPlaying ||
        oldWidget.md3Style != widget.md3Style ||
        oldWidget.waveEnabled != widget.waveEnabled) {
      _syncWave();
    }
    // duration 也要参与：切歌时常是 isPlaying 先变 true、durationStream 稍后才
    // 送来时长，若只在 isPlaying 变化时同步，ticker 的「时长已知」条件那一轮不
    // 满足就再无机会启动 → 该首歌全程退化成 200ms 上报驱动（5fps）。
    if (oldWidget.isPlaying != widget.isPlaying ||
        (oldWidget.duration > Duration.zero) !=
            (widget.duration > Duration.zero)) {
      _syncTicker();
    }
    // chrome 淡出/唤出：可见性变了要同时收/放自驱动与共享节拍，
    // 漏一处就是「界面看不见但帧照产」（AGENTS §10.4 第 3 条）。
    if (oldWidget.visible != widget.visible) {
      _syncTicker();
      _syncWave();
    }
    // tv: 切歌/时长归零/chrome 淡出/被设为只读 —— 立即收摊但**不 seek**：
    // 拿旧歌曲的比例去落点会 seek 到新歌的错误位置；淡出后留个不可见的调节态
    // 也是「看不见但状态还在」的漏电。
    if (kTvBuild &&
        (oldWidget.duration != widget.duration ||
            oldWidget.visible != widget.visible ||
            oldWidget.enabled != widget.enabled)) {
      _tvStepper?.cancel();
    }
  }

  /// 共享 `Timer`（2fps 自驱动 + 60fps 波浪节拍）不受 `TickerMode` 约束（§10.3），
  /// 必须自行同步挂起。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool muted = !TickerMode.valuesOf(context).enabled;
    if (muted == _tickerModeMuted) return;
    _tickerModeMuted = muted;
    _syncFrameGates();
  }

  /// 后台/熄屏时两个 Timer 一并停掉（§10.4.3）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final bool suspended = state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached;
    if (suspended == _appSuspended) return;
    _appSuspended = suspended;
    _syncFrameGates();
  }

  void _syncFrameGates() {
    _syncTicker();
    _syncWave();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timerFrame?.cancel();
    _tapCommitTimer?.cancel();
    // tv: 状态机的 debounce Timer 同属「任何 Timer 都必须在 dispose 里 cancel」
    // （AGENTS §10.4 第 7 条）；控件都没了，不再补 seek，只取消定时。
    _tvStepper?.dispose();
    _tapClock.stop();
    _unbindWaveDriver();
    _expand.dispose();
    _tint.dispose();
    _waveAmp.dispose();
    _wavePhase.dispose();
    _frame.dispose();
    _dragFraction.dispose();
    super.dispose();
  }

  /// 已播放段是否上色：播放中，或正在拖动（拖动会先 pause，但此时仍要看清落点）
  void _syncTint() {
    if (widget.isPlaying || _dragging) {
      _tint.forward();
    } else {
      _tint.reverse();
    }
  }

  /// 只在「MD3 皮肤 + 播放中 + 未拖动 + 可见 + 前台」时起伏；其余状态把波幅
  /// 动画回 0（压平后再解绑，见 _waveAmp 的 statusListener）。
  void _syncWave() {
    final shouldWave =
        widget.md3Style &&
        widget.waveEnabled &&
        widget.isPlaying &&
        widget.visible &&
        !_dragging &&
        !_framesSuspended;
    if (shouldWave) {
      _bindWaveDriver();
      _waveAmp.forward();
    } else {
      _waveAmp.reverse();
    }
  }

  void _bindWaveDriver() {
    if (_waveBound) return;
    PlayerFrameDriver.instance.addListener(_onWaveTick);
    _waveBound = true;
    _lastWaveTickMs = _waveClock.elapsedMilliseconds;
  }

  void _unbindWaveDriver() {
    if (!_waveBound) return;
    PlayerFrameDriver.instance.removeListener(_onWaveTick);
    _waveBound = false;
  }

  /// 共享节拍回调（60fps）：按真实流逝时间推进相位，只通知画布重绘。
  void _onWaveTick() {
    final now = _waveClock.elapsedMilliseconds;
    final dt = now - _lastWaveTickMs;
    _lastWaveTickMs = now;
    _wavePhase.value = (_wavePhase.value + dt / _wavePeriodMs) % 1.0;
  }

  /// 只在「播放中 + 未拖动 + 可见 + 前台 + 时长已知」时跑 2fps Timer，
  /// 其余状态停住省电
  void _syncTicker() {
    final shouldRun =
        widget.isPlaying &&
        !_dragging &&
        widget.visible &&
        widget.duration > Duration.zero &&
        !_framesSuspended;
    if (shouldRun) {
      // 2fps 自驱动：Timer 周期性累加位置并重绘；暂停/拖动时取消以省电
      _timerFrame ??= Timer.periodic(
        Duration(milliseconds: _frameIntervalMs),
        (_) => _advanceFrame(),
      );
    } else {
      _timerFrame?.cancel();
      _timerFrame = null;
    }
  }

  /// 2fps 自驱动推进：每帧间隔累加一次播放位置，触发画布与两侧时间重绘。
  void _advanceFrame() {
    final total = widget.duration.inMilliseconds;
    var next = _displayMs + (_frameIntervalMs * widget.speed).round();
    if (next < 0) next = 0;
    if (total > 0 && next > total) next = total;
    if (next == _displayMs) return;
    _displayMs = next;
    _frame.value++;
  }

  /// 收到新的上报位置：与自驱动的展示位置对齐。
  ///
  /// 单调保护：上报值略小于展示值（音频层上报抖动）且差距在
  /// [_resyncThresholdMs] 以内时保留展示值，避免时间数字来回跳；
  /// 差距过大（seek / 切歌）或已暂停则直接采用上报值。
  void _rebase() {
    final reported = widget.position.inMilliseconds;
    final drift = _displayMs - reported;
    if (widget.isPlaying &&
        !_dragging &&
        drift > 0 &&
        drift < _resyncThresholdMs) {
      return;
    }
    _displayMs = reported;
  }

  /// 当前绘制用的进度比例：拖动中用手指位置，否则用自驱动的展示位置
  double get _fraction {
    if (_dragging) return _dragFraction.value;
    final total = widget.duration.inMilliseconds;
    if (total <= 0) return 0;
    return (_displayMs / total).clamp(0.0, 1.0);
  }

  Duration _durationAt(double fraction) => Duration(
    milliseconds: (widget.duration.inMilliseconds * fraction).round(),
  );

  double _fractionFromDx(double dx) =>
      _trackWidth <= 0 ? 0 : (dx / _trackWidth).clamp(0.0, 1.0);

  /// 进入「调节态」：落位比例、膨胀轨道，并把褪色/波浪/自驱动三处帧来源收口。
  ///
  /// 触屏（[_startDrag]）与 TV 方向键（[TvSeekStepper.onBegin]）共用这一个入口：
  /// 限帧的绑定/解绑一律经 `_syncTint` / `_syncWave` / `_syncTicker` 收口，不因为
  /// 多了一个驱动源就多出一条路径（AGENTS.md §10）。
  void _enterAdjust(double startFraction, {required bool previewing}) {
    _dragFraction.value = startFraction;
    setState(() {
      _dragging = true;
      _previewing = previewing;
    });
    _expand.forward();
    _syncTint();
    _syncWave();
    _syncTicker();
  }

  /// 按下轨道。[previewing] = true 时只进视觉预览（见 [_previewing]）：不暂停、
  /// 不 seek，松手交给 [_settleTap] 判单击还是双击。
  void _startDrag(double dx, {required bool previewing}) {
    if (widget.duration.inMilliseconds <= 0) return;
    if (previewing) _cancelPendingTap();
    _tapInLeftHalf = dx < _trackWidth / 2;
    _enterAdjust(_fractionFromDx(dx), previewing: previewing);
    if (!previewing) widget.onSeekStart?.call();
  }

  /// 跟手：只更新本地比例（画布与数字跟着 ValueNotifier 重绘），
  /// 不下发 seek —— 每帧 seek 会把音频层打满，表现为拖动发卡。
  void _updateDrag(double dx) {
    if (!_dragging) return;
    _dragFraction.value = _fractionFromDx(dx);
  }

  /// 拖拽起手：可能接在一次预览按下之后，必须把这次手势定性成**真拖动**——
  /// 取消待落定的点按跳转，补发 onSeekStart，松手才 seek。
  void _handleDragStart(double dx) {
    if (_previewing) {
      _cancelPendingTap();
      _lastTapUpMs = null;
    }
    _startDrag(dx, previewing: false);
  }

  /// 松手：预览态交给 [_settleTap] 判定，真拖动照旧一次性 seek 到落点。
  void _endDrag() {
    if (!_dragging) return;
    if (_previewing) {
      _settleTap();
      return;
    }
    final target = _durationAt(_dragFraction.value);
    _releasePress();
    _applySeek(target);
  }

  /// 点按被系统手势抢走：预览态直接收视觉、不 seek；真拖动沿用旧的落点语义。
  void _handleTapCancel() {
    if (_previewing) {
      _releasePress();
      return;
    }
    _endDrag();
  }

  /// 退出按下态：轨道收细、褪色、恢复自驱动，不改展示位置。
  void _releasePress() {
    setState(() {
      _dragging = false;
      _previewing = false;
    });
    _expand.reverse();
    _syncTint();
    _syncWave();
    _syncTicker();
  }

  /// 落点生效：立即以落点为新的展示位置（seek 回调是异步的，等上报会先闪回旧位置）
  void _applySeek(Duration target) {
    _displayMs = target.inMilliseconds;
    _frame.value++;
    widget.onSeekEnd?.call(target);
  }

  /// 点按落点与「±15 秒」的仲裁（仅在 [PlayerSeekBar.onDoubleTapSkip] 启用时）。
  ///
  /// 点轨道即跳转与双击平移共用同一片轨道，手势竞争器区分不出「第一次点按」和
  /// 「双击的第一下」，所以第一次点按只预览、延后 [PlayerSeekBar.tapCommitDelay]
  /// 才 seek；窗口内再来一次点按就取消落点跳转，改成以**当前位置**平移 ——
  /// 平移的落地（seek / 触觉 / 暂停恢复）归调用方，本控件只决定时机与增量。
  void _settleTap() {
    final target = _durationAt(_dragFraction.value);
    final now = _tapClock.elapsedMilliseconds;
    final previous = _lastTapUpMs;
    final isSecondTap =
        previous != null &&
        now - previous <= PlayerSeekBar.doubleTapWindow.inMilliseconds;
    _releasePress();
    if (isSecondTap) {
      _lastTapUpMs = null;
      _cancelPendingTap();
      widget.onDoubleTapSkip?.call(
        _tapInLeftHalf ? -PlayerSeekBar.skipSeconds : PlayerSeekBar.skipSeconds,
      );
      return;
    }
    _lastTapUpMs = now;
    _tapCommitTimer = Timer(PlayerSeekBar.tapCommitDelay, () {
      _tapCommitTimer = null;
      widget.onSeekStart?.call();
      _applySeek(target);
    });
  }

  void _cancelPendingTap() {
    _tapCommitTimer?.cancel();
    _tapCommitTimer = null;
  }

  static String _format(Duration d) {
    final seconds = d.inSeconds < 0 ? 0 : d.inSeconds;
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    // 等宽数字：拖动时秒数跳动不会让标签左右抖动
    final labelStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: widget.labelColor,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    final bar = LayoutBuilder(
      builder: (context, constraints) {
        _trackWidth = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          // 只读态：不接任何跳转手势，改为把点按/起拖转成提示回调，
          // 否则用户只会看到「这条不能拖」而不知道原因（详见 [enabled]）。
          // 点按轨道任意位置即跳转（按下就进入膨胀态，松手落定）
          onTapDown: widget.enabled
              ? (d) => _startDrag(
                  d.localPosition.dx,
                  previewing: widget.onDoubleTapSkip != null,
                )
              : null,
          onTapUp: widget.enabled ? (_) => _endDrag() : null,
          onTapCancel: widget.enabled ? _handleTapCancel : null,
          onHorizontalDragStart: widget.enabled
              ? (d) => _handleDragStart(d.localPosition.dx)
              : (_) => widget.onDisabledTap?.call(),
          onHorizontalDragUpdate: widget.enabled
              ? (d) => _updateDrag(d.localPosition.dx)
              : null,
          onHorizontalDragEnd: widget.enabled ? (_) => _endDrag() : null,
          onHorizontalDragCancel: widget.enabled ? _endDrag : null,
          onTap: widget.enabled ? null : widget.onDisabledTap,
          child: ConstrainedBox(
            // 至少 [PlayerSeekBar.height]；时间行内容更高时（中央插槽放了徽章、
            // 或大字号）整条按内容长高，而不是把内容挤出去。
            constraints: BoxConstraints(minHeight: widget.height),
            child: RepaintBoundary(
              // 一个 AnimatedBuilder 同时驱动画布与时间数字：自驱动每帧与跟手
              // 都只重建这棵小子树（不走 setState），拖动才跟得上手指
              child: AnimatedBuilder(
                animation: Listenable.merge([
                  _expand,
                  _tint,
                  _frame,
                  _dragFraction,
                  _waveAmp,
                  _wavePhase,
                ]),
                builder: (context, _) {
                  final fraction = _fraction;
                  final elapsed = _durationAt(fraction);
                  final remaining = widget.duration - elapsed;
                  final trackColor =
                      Color.lerp(
                        widget.inactiveColor,
                        widget.activeColor,
                        Curves.easeOut.transform(_tint.value),
                      )!;
                  final totalMs = widget.duration.inMilliseconds;
                  // showRemaining：静止态右侧给总时长，按下/拖动才切成「−剩余」
                  final rightLabel =
                      widget.showRemaining && !_dragging
                          ? _format(widget.duration)
                          : '-${_format(remaining)}';
                  return Semantics(
                    slider: true,
                    value: '${_format(elapsed)} / ${_format(widget.duration)}',
                    // 双击平移的无障碍出口：TalkBack 的滑条增减动作走同一对增量，
                    // 与触摸双击语义一致（不在界面上加任何文字，见计划 §2.6）。
                    // tv: D-pad 不调语义动作，走 DpadFocusable.onDirection；这里保持接
                    // ±15s 双击平移，两套通道口径不同不合并。
                    increasedValue: widget.onDoubleTapSkip == null
                        ? null
                        : '快进 ${PlayerSeekBar.skipSeconds} 秒',
                    decreasedValue: widget.onDoubleTapSkip == null
                        ? null
                        : '快退 ${PlayerSeekBar.skipSeconds} 秒',
                    onIncrease: widget.onDoubleTapSkip == null
                        ? null
                        : () => widget.onDoubleTapSkip?.call(
                            PlayerSeekBar.skipSeconds,
                          ),
                    onDecrease: widget.onDoubleTapSkip == null
                        ? null
                        : () => widget.onDoubleTapSkip?.call(
                            -PlayerSeekBar.skipSeconds,
                          ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 轨道区给**定高**而不是 Expanded：时间行的实际高度由内容决定
                        // （中央插槽塞了音质徽章后比 14px 高得多），用 Expanded 时
                        // 两者抢 [PlayerSeekBar.height] 那点预算，大字号下直接溢出。
                        // 整条进度条因此按内容自然长高，各皮肤观感不变。
                        SizedBox(
                          height: _trackAreaHeight,
                          child: CustomPaint(
                            // 必须显式给 Size.infinite：CustomPaint 无 child 时默认
                            // size 是 Size.zero，在 Column 里横向是松约束 → 宽度会被
                            // 约束成 0，画布拿到 0 宽，轨道就完全画不出来（但手势
                            // 仍在，表现为「看不见却能拖」）。
                            size: Size.infinite,
                            painter: _SeekBarPainter(
                              fraction: fraction,
                              expandT: Curves.easeOut.transform(_expand.value),
                              trackColor: trackColor,
                              inactiveColor: widget.inactiveColor,
                              climaxColor: widget.activeColor.withValues(
                                alpha: 0.45,
                              ),
                              md3Style: widget.md3Style,
                              climaxRange: _climaxRange,
                              phase: _wavePhase.value,
                              waveT: Curves.easeOut.transform(_waveAmp.value),
                              tickMarks: widget.tickMarks,
                              durationMs: totalMs.toDouble(),
                              tickColor: widget.labelColor,
                            ),
                          ),
                        ),
                        // 时间：常显但压暗，拖动时提亮到全不透明
                        _buildLabelRow(elapsed, rightLabel, labelStyle),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );

    // tv: 进度条原本是纯手势控件（GestureDetector 点按/横拖），TV 上**根本不是焦点停点**。
    // 这里给它一个停点：左右 ±5s（按住连发）、OK/失焦即落定、600ms 静默合并成一次 seek；
    // 上/下键放行，焦点能正常移出（AGENTS §12.4）。自绘形态（波浪/高潮区间/两侧时间数字）
    // 一律保留，不换成 RemoteSlider。
    if (kTvBuild) {
      return DpadFocusable(
        debugLabel: 'tv/player-seek-bar',
        // 只读态（一起听听众端 enabled=false）不设停点：TV 也绝不允许它 seek
        enabled: widget.enabled,
        // 不自动滚进视野：进度条要么在屏内要么整块 chrome 已淡出，而 dpad 的
        // DpadScroll.ensureVisible 会遍历**所有**祖先 Scrollable（含 TabBarView/PageView），
        // 聚焦反而可能带动切页。
        autoScroll: false,
        // 混设备（TV 包装在带触屏的盒子/平板）把点区让给子树自己的手势，
        // 不与本控件的 onTapDown/onHorizontalDrag 抢手势竞技场。
        tapToSelect: false,
        // OK 的语义取「确认当前落点」＝立即落定；本控件没有天然的「点击=播放/暂停」
        // （那是传输行独立钮的职责），不凭空加功能。
        onSelect: () => _tvStepper?.flush(),
        onDirection: (direction) => _tvAdjust.handleDirection(
          direction,
          currentMs: _displayMs,
          durationMs: widget.visible && widget.enabled
              ? widget.duration.inMilliseconds
              : 0, // chrome 淡出/只读 → 不消费、不调节，按键交回焦点遍历
        ),
        onFocusChange: (focused) {
          // 失焦（上下键移出/路由切换）立即落定，不留「看不见还在膨胀」的待落点
          if (focused) {
            TvHintBarScope.show('左右键 5/15/30 秒调整 · OK 立即跳转');
          } else {
            _tvStepper?.flush();
            TvHintBarScope.clear();
          }
        },
        child: bar,
      );
    }
    return bar;
  }

  /// 轨道区高度 = 条高减掉标注行的标称高度（标注行实际更高时整条会长高）。
  double get _trackAreaHeight =>
      (widget.height - _labelHeight).clamp(0.0, double.infinity);

  /// 时间行：左「已播」右「总时长/剩余」，中间是 [PlayerSeekBar.labelRowBadge]
  /// 与 [PlayerSeekBar.labelRowHints] 组成的中央组。
  ///
  /// 压暗只作用在**两个时间数字**上，各自包一层 `AnimatedOpacity`；徽章与提示胶囊
  /// 不跟着叠 —— `Opacity` 是整块合成，把 `primaryContainer` 半透明后压在深色封面上
  /// 会变灰变暗，看着像被禁用，那是「暗化」不是「淡化」。徽章要淡由它自己的配色决定
  /// （宿主传 `faded` 形态），本控件不替它压暗。
  ///
  /// 中央组套 `Expanded` + `FittedBox`：占住两侧时间数字之间的整份宽度并在其中居中
  /// （「居中于这两个数字」，而不是居中于整条进度条），2 倍字/窄面板下按可用宽度
  /// 缩着放，而不是把时间行顶出横向溢出（实测不处理会溢 47px）。
  ///
  /// 行高纪律：没有徽章时保持原来的 14px 定高 + `IgnorePointer`（时间只是标注，
  /// 不吃点击；提示胶囊与这一行等高，传了也不改变行高）；有徽章时按徽章自身高度排，
  /// 且去掉 `IgnorePointer`，否则徽章点不动。
  Widget _buildLabelRow(
    Duration elapsed,
    String rightLabel,
    TextStyle? labelStyle,
  ) {
    final badge = widget.labelRowBadge;
    final hints = widget.labelRowHints;
    Widget dim(Widget child) => AnimatedOpacity(
      opacity: _dragging ? 1 : 0.5,
      duration: const Duration(milliseconds: 150),
      child: child,
    );
    final centerItems = <Widget>[?hints, ?badge];
    final row = Row(
      children: [
        dim(Text(_format(elapsed), style: labelStyle)),
        if (centerItems.isEmpty)
          const Spacer()
        else
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.center,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < centerItems.length; i++) ...[
                    if (i > 0) const SizedBox(width: AppSpacing.xs),
                    centerItems[i],
                  ],
                ],
              ),
            ),
          ),
        dim(Text(rightLabel, style: labelStyle)),
      ],
    );
    if (badge == null) {
      return SizedBox(
        height: _labelHeight,
        child: IgnorePointer(child: row),
      );
    }
    return row;
  }

  /// 高潮区间归一化到 0~1；缺少数据或时长未知时返回 null。
  List<double>? get _climaxRange {
    final start = widget.climaxStart;
    final end = widget.climaxEnd;
    final totalMs = widget.duration.inMilliseconds;
    if (start == null || end == null || totalMs <= 0 || end <= start) {
      return null;
    }
    return [
      (start * 1000 / totalMs).clamp(0.0, 1.0),
      (end * 1000 / totalMs).clamp(0.0, 1.0),
    ];
  }
}

/// 轨道绘制：未播放段 → 高潮高亮（只画未播放的那截）→ 已播放段 → stop indicator
class _SeekBarPainter extends CustomPainter {
  _SeekBarPainter({
    required this.fraction,
    required this.expandT,
    required this.trackColor,
    required this.inactiveColor,
    required this.climaxColor,
    required this.md3Style,
    required this.climaxRange,
    required this.phase,
    required this.waveT,
    required this.tickMarks,
    required this.durationMs,
    required this.tickColor,
  });

  final double fraction;
  final double expandT;

  /// 已播放段颜色（播放中为强调色，暂停时已褪成 [inactiveColor]）
  final Color trackColor;
  final Color inactiveColor;
  final Color climaxColor;
  final bool md3Style;
  final List<double>? climaxRange;

  /// 波浪相位（0~1），播放中由共享 60fps 节拍连续推进
  final double phase;

  /// 波幅系数（0=直线，1=完整起伏）；暂停/拖动时 250ms 内收敛到 0
  final double waveT;

  /// 是否绘制时间刻线（只在按下/拖动时随 [expandT] 淡入）
  final bool tickMarks;

  /// 总时长（毫秒），刻线间距按它换算；<=0 时不画刻线
  final double durationMs;

  /// 刻线基色（取时间标注同色，保证非文字 UI 也过 3:1）
  final Color tickColor;


  /// 常态轨道高度：进度条是整个底部区里最细的元素。
  static const double _idleMd3Height = 3;
  static const double _idleFlatHeight = 2;

  /// 拖动态轨道高度
  static const double _dragHeight = 10;

  /// 已播放段与剩余段之间的间隙（MD3 expressive 的做法）
  static const double _segmentGap = 4;

  /// 刻线高度：每 15 秒一道短刻线、每 60 秒一道高刻线（都不带字）
  static const double _tickMinorHeight = 6;
  static const double _tickMajorHeight = 10;

  /// 短刻线密集到这个间距以下就只留高刻线，否则糊成一片灰反而读不出位置
  static const double _tickMinorMinSpacing = 8;


  /// 波长与波峰振幅（px）——与旧波浪版同几何，2px 振幅在 3px 轨道上
  /// 视觉上「只体现细微差异」，不会喧宾夺主
  static const double _waveLength = 26;
  static const double _waveAmplitude = 2;

  /// 高潮段被播放头掠过后，尾部的消隐拖尾长度（px）
  static const double _climaxFadeLength = 40;

  /// 波形末端/高潮「带→波」过渡的收拢窗口（px）
  static const double _taperLength = 14;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    if (w <= 0) return;
    final cy = size.height / 2 + 2;
    final trackH = lerpDouble(
      md3Style ? _idleMd3Height : _idleFlatHeight,
      _dragHeight,
      expandT,
    )!;
    final r = trackH / 2;
    // 已播放段的末端：进度为 0 时也画一小段圆头，避免轨道左端空一块
    final activeEnd = math.max((w * fraction).clamp(0.0, w), trackH);
    final fx = activeEnd;
    // 剩余段起点 = 已播放段末端 + 间隙，两段互不叠加
    final remainStart = math.min(activeEnd + _segmentGap, w);

    // 总波幅：非 MD3 皮肤或暂停/拖动收敛后为 0（一切退回直线现状）
    final amp = md3Style ? _waveAmplitude * waveT : 0.0;

    // 1. 剩余段：只画播放点之后的部分
    if (remainStart < w) {
      canvas.drawRRect(
        RRect.fromLTRBR(remainStart, cy - r, w, cy + r, Radius.circular(r)),
        Paint()..color = inactiveColor,
      );
    }

    // 2. 高潮区间：MD3 皮肤画「同相位加粗波浪」——
    //    已播部分沿波形起伏、随播放头掠过在尾后 40px 渐变消隐；
    //    未播部分贴中线成粗带（波形 0 幅即现状样式）；
    //    播放头掠过时自然从「带」过渡成「波浪」（14px 收拢窗口内插）。
    //    AM 皮肤（md3Style=false）维持原「只画未播段直带」不变，作回归对照。
    final climax = climaxRange;
    if (climax != null) {
      final xa = w * climax[0];
      final xb = w * climax[1];
      final ch = math.max(trackH * 0.7, 1.5); // 与旧直带等厚：描边宽 = 2*ch
      if (xb > xa) {
        if (md3Style && amp >= 0.2) {
          final path = Path();
          bool first = true;
          for (double x = xa; x <= xb; x += 2) {
            final waveOn = ((fx - x) / _taperLength).clamp(0.0, 1.0);
            final y =
                cy +
                amp * waveOn * math.sin((x / _waveLength + phase) * 2 * math.pi);
            if (first) {
              path.moveTo(x, y);
              first = false;
            } else {
              path.lineTo(x, y);
            }
          }
          // 渐变锚定播放头：头前为完整高潮色，头后 40px 内淡出；
          // x > fx 一律钳到后一色（未播段常亮），x < fx-40 钳到透明（已掠走）
          // 必须用 ui.Gradient：material_ui 也导出 painting.Gradient（无 linear 工厂），
          // 不前缀会被遮蔽而报 "Member not found: 'Gradient.linear'"
          canvas.drawPath(
            path,
            Paint()
              ..shader = ui.Gradient.linear(
                Offset(fx - _climaxFadeLength, 0),
                Offset(fx, 0),
                [climaxColor.withValues(alpha: 0), climaxColor],
              )
              ..style = PaintingStyle.stroke
              ..strokeWidth = ch * 2
              ..strokeCap = StrokeCap.round
              ..strokeJoin = StrokeJoin.round,
          );
        } else {
          // 收敛回退（amp≈0，即暂停/拖动/AM 皮肤）：画回原来的直线粗带，
          // 暂停态视觉与改动前逐像素一致
          final left = math.max(xa, remainStart);
          if (xb > left) {
            canvas.drawRRect(
              RRect.fromLTRBR(
                left,
                cy - ch,
                xb,
                cy + ch,
                Radius.circular(ch),
              ),
              Paint()..color = climaxColor,
            );
          }
        }
      }
    }

    // 3. 已播放段：播放中沿同一条正弦曲线起伏（暂停/拖动时 amp→0 收敛为
    //    直线）；颜色仍由 trackColor 决定（暂停时与未播放段同色）。
    //    末端 14px 窗口内把波幅收拢为 0，让波形平滑接回轨道中线，
    //    与 remainStart 后的间隙衔接不出现折角。
    final activePaint = Paint()..color = trackColor;
    if (amp < 0.2 || fx < trackH * 2) {
      canvas.drawRRect(
        RRect.fromLTRBR(0, cy - r, fx, cy + r, Radius.circular(r)),
        activePaint,
      );
    } else {
      final path = Path();
      bool first = true;
      for (double x = 0; x <= fx; x += 2) {
        final taper = ((fx - x) / _taperLength).clamp(0.0, 1.0);
        final y =
            cy +
            amp * taper * math.sin((x / _waveLength + phase) * 2 * math.pi);
        if (first) {
          path.moveTo(x, y);
          first = false;
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = trackColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = trackH
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }

    // 4. 时间刻线：只在按下/拖动时随轨道膨胀一起淡入（expandT 兼作不透明度）。
    //    刻线一律不带数字 —— 拖动时只浮落点那一个时间，由下方标注行承担。
    if (tickMarks && expandT > 0.01 && durationMs > 0 && w > 0) {
      const minorEveryMs = 15000.0;
      const majorEveryMs = 60000.0;
      final tickPaint = Paint()
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.butt;
      // 短刻线密到看不清间距就整档跳过，只留每分钟的高刻线
      final drawMinor = w * (minorEveryMs / durationMs) >= _tickMinorMinSpacing;
      if (drawMinor) {
        for (double ms = minorEveryMs; ms < durationMs; ms += minorEveryMs) {
          if (ms % majorEveryMs == 0) continue;
          _paintTick(
            canvas,
            x: w * (ms / durationMs),
            cy: cy,
            height: _tickMinorHeight,
            paint: tickPaint,
            color: tickColor.withValues(alpha: 0.45 * expandT),
          );
        }
      }
      for (double ms = majorEveryMs; ms < durationMs; ms += majorEveryMs) {
        _paintTick(
          canvas,
          x: w * (ms / durationMs),
          cy: cy,
          height: _tickMajorHeight,
          paint: tickPaint,
          color: tickColor.withValues(alpha: 0.85 * expandT),
        );
      }
    }

    // 5. MD3 stop indicator：轨道末端的小圆点，进度接近末端时隐藏
    if (md3Style && fx < w - trackH * 3) {
      canvas.drawCircle(Offset(w - r, cy), math.max(1.5, r), activePaint);
    }
  }

  /// 画一道以 [cy] 为中心、高 [height] 的刻线。
  void _paintTick(
    Canvas canvas, {
    required double x,
    required double cy,
    required double height,
    required Paint paint,
    required Color color,
  }) {
    paint.color = color;
    canvas.drawLine(Offset(x, cy - height / 2), Offset(x, cy + height / 2), paint);
  }

  @override
  bool shouldRepaint(covariant _SeekBarPainter old) =>
      old.fraction != fraction ||
      old.expandT != expandT ||
      old.trackColor != trackColor ||
      old.inactiveColor != inactiveColor ||
      old.climaxColor != climaxColor ||
      old.md3Style != md3Style ||
      old.climaxRange?[0] != climaxRange?[0] ||
      old.climaxRange?[1] != climaxRange?[1] ||
      old.phase != phase ||
      old.waveT != waveT ||
      old.tickMarks != tickMarks ||
      old.durationMs != durationMs ||
      old.tickColor != tickColor;
}
