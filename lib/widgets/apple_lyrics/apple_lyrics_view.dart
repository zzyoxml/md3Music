/// Apple Music 风格歌词主组件
///
/// 参照 spec.md "Requirement: 点击跳转" 与 tasks.md Task 17 实现。
/// 接收已解析的 [LyricLine] 列表与播放状态，集成所有渲染器与控制器，
/// 通过 [CustomPainter] 绘制 Apple Music 风格的逐字 / 整行歌词。
///
/// 设计要点：
/// - 解析由调用方完成（[LyricParserChain.parse]），本组件只接收 [lines]
/// - 用 [Ticker] + [SingleTickerProviderStateMixin] 每帧推进
///   所有控制器与渲染器，触发 [setState] 重绘
/// - 每行独立的 renderer 实例（按行索引缓存），避免多行共用导致状态混乱
/// - 每行独立的 scale 弹簧（_tickPerLineScales）：进场放大 / 离场缩小均连贯
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';

import '../../core/utils/app_haptics.dart';
import 'package:flutter/widgets.dart';

import '../../core/build_flags.dart';
import '../../core/services/player_frame_driver.dart';
import '../../core/utils/lyric_wrap_plan.dart';
import 'controllers/lyric_scroll_controller.dart';
import 'animation/spring.dart';
import 'layout/duet_layout.dart';
import 'layout/lyric_aux_scope.dart';
import 'layout/lyric_layout.dart';
import 'layout/lyric_preferences.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import 'package:md3music/widgets/apple_lyrics/models/aux_text_image.dart';
import 'renderers/emphasize_effect.dart';
import 'renderers/interlude_dots.dart';
import 'renderers/line_renderer.dart';
import 'renderers/word_renderer.dart';
import 'utils/lyric_line_color.dart';

/// 行形变 scale 的可读下限，保证 `fontSize × scale` 不跌破字重对应的字号下限。
double _minLegibleLineScale(double fontSize) {
  // 传 0 即取该字重的下限本身（fontSize 已被钳过，再钳会原样返回）
  final floor = LyricLayout.clampReadableFontSize(0);
  if (fontSize <= 0 || floor >= fontSize) return 1.0;
  return floor / fontSize;
}

/// Apple Music 风格歌词主组件。
///
/// 调用方负责通过 [LyricParserChain.parse] 解析得到 [lines]，本组件不再解析。
/// 内部用 [Ticker] + [SingleTickerProviderStateMixin] 驱动每帧
/// [tick] 推进所有控制器与渲染器，调用 [setState] 触发重绘。
class AppleLyricsView extends StatefulWidget {
  /// 已解析的歌词行列表（由调用方通过 LyricParserChain.parse 得到）
  final List<LyricLine> lines;

  /// 当前播放时间（毫秒）
  final int currentTimeMs;

  /// 是否正在播放
  final bool isPlaying;

  /// 播放流未就绪（切歌 loading / 音频缓冲 buffering）。
  /// 未就绪期间逐字动画时钟冻结在权威位置（语义对齐暂停），避免
  /// "帧时钟前进 300ms → 兜底回吸"的锯齿循环造成字内渐变来回抽搐；
  /// 强调波浪随 renderer 的 isPlaying=false 一并冻结。
  final bool playbackNotReady;

  /// 用户点击某行后回调（调用方应调用 just_audio.seek）
  final void Function(int timeMs)? onSeek;

  /// 是否启用缩放（默认 true）
  final bool enableScale;

  /// 是否强制使用深色背景的歌词颜色（白色文字）。
  ///
  /// AM 风格播放器背景始终为深色（Colors.black + 模糊封面），
  /// 即使 app 处于浅色主题也应使用白色歌词。
  /// 非 AM 播放器背景跟随主题，浅色主题用黑色歌词。
  final bool forceDarkBackground;

  /// 是否启用间奏点（节奏点）动画。
  ///
  /// 设为 false 时跳过间奏检测，歌词行之间不会出现节奏点小圆点动画。
  /// 适用于本地歌曲且歌词为 LRC 逐行格式的场景：LRC 没有逐字时间戳，
  /// 行间的节奏点与真实节拍不易对齐，禁用后体验更干净。
  /// 默认 true，保持原有视觉。
  final bool enableInterludeDots;

  /// 是否启用双击跳转（开启后单击不跳转，双击才跳转播放位置）
  final bool doubleTapToJump;

  /// 专辑封面提取色（动态字体颜色用，仅 AM 播放器传入）。
  ///
  /// 非 null 且 [LyricPreferences.useDynamicLyricColor] 开启且 [forceDarkBackground]
  /// 为 true 时，当前行歌词颜色按「白色 + 提取色 ×
  /// [LyricPreferences.dynamicColorMixRatio]」混色（默认 15% 提取色）；
  /// 非当前行保持默认歌词色，除非 [LyricPreferences.useAboveLinesPlayedColor] 开启。
  final Color? accentColor;

  /// 歌曲 BPM（节拍/分钟），可空。
  ///
  /// 用于按快慢歌区分辉光触发阈值：非空时优先使用（BPM>=100 快歌→500ms，
  /// 否则慢歌→1000ms）；为空则回落 KRC 歌词字长统计推断（见
  /// [EmphasizeEffect.resolveThresholdMs]）。
  final int? songBpm;

  /// 播放位置 listenable：提供后组件内部订阅位置更新，动画驱动直接消费
  /// 内部权威时间 [_AppleLyricsViewState._authorityTimeMs]，外层不再需要
  /// 每 ~200ms 用新 [currentTimeMs] 重建本组件（性能解耦）。
  final ValueListenable<Duration>? positionListenable;

  /// 对 [positionListenable] 的原始位置做二次校正并返回毫秒
  /// （如在线歌词时间偏移：渲染位置 = 播放位置 - 偏移），可为 null。
  final int Function(Duration)? adaptTimeMs;

  const AppleLyricsView({
    super.key,
    required this.lines,
    required this.currentTimeMs,
    this.isPlaying = false,
    this.playbackNotReady = false,
    this.onSeek,
    this.enableScale = true,
    this.forceDarkBackground = false,
    this.enableInterludeDots = true,
    this.doubleTapToJump = false,
    this.accentColor,
    this.songBpm,
    this.positionListenable,
    this.adaptTimeMs,
  });

  /// 找到当前应高亮的行索引：最后一个 `startTime <= currentTimeMs` 的行。
  ///
  /// 抽象为静态方法便于单元测试。空列表返回 -1；时间早于第一行返回 0。
  @visibleForTesting
  static int findCurrentLineIndex(List<LyricLine> lines, int currentTimeMs) {
    if (lines.isEmpty) return -1;
    // 性能优化：二分查找替代线性遍历，O(log N) 替代 O(N)
    // lines 按 startTime 升序排列，找最后一个 startTime <= currentTimeMs 的行
    int lo = 0, hi = lines.length;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (lines[mid].startTime <= currentTimeMs) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    // lo - 1 是最后一个 startTime <= currentTimeMs 的行索引
    // lo == 0 表示所有 startTime > currentTimeMs，返回 0（时间早于第一行）
    return lo > 0 ? lo - 1 : 0;
  }

  /// 计算行的"人声实际结束时间"（毫秒），用于间奏 gap 判定与激活窗口。
  ///
  /// - 无逐字行（LRC/纯文本）：直接返回 [LyricLine.endTime]
  ///   （LRC duration 为 0，endTime = startTime，两行间隔即 startTime 之差）。
  /// - 逐字行（KRC）：KRC 行级 duration 常覆盖尾音/空白，甚至延伸到下一行，
  ///   若直接用 endTime = startTime + duration，gap 被压缩为负或 < 阈值，
  ///   导致间奏点从源头识别不到。取「行 duration 结束」与「最后一个字结束」
  ///   的较小值作为人声实际结束，更贴近演唱真实空档。
  @visibleForTesting
  static int effectiveLineEndTime(LyricLine line) {
    final int lineEnd = line.endTime;
    if (line.words.isEmpty) return lineEnd;
    final LyricWord lastWord = line.words.last;
    final int wordEnd = lastWord.startTime + lastWord.duration;
    return math.min(lineEnd, wordEnd);
  }

  @override
  State<AppleLyricsView> createState() => _AppleLyricsViewState();
}

class _AppleLyricsViewState extends State<AppleLyricsView>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  // ============== 动画驱动 ==============
  //
  // 使用 Ticker（而非 AnimationController.addListener + DateTime.now()）驱动每帧，
  // 因为 Ticker 的回调参数 [Duration elapsed] 基于调度器时钟（测试中为模拟时间），
  // 保证单元测试中 pump(Duration) 能正确推进弹簧动画。
  // AnimationController.addListener + DateTime.now() 在测试中会用真实墙钟时间，
  // 导致弹簧几乎不推进，测试无法验证动画行为。

  late final Ticker _ticker;
  Duration _lastElapsed = Duration.zero;

  /// v3 优化：Ticker 当前运行状态，用于幂等保护 start/stop 调用。
  bool _isTickerRunning = false;

  /// v3 优化：上次重绘时的关键动画值，用于判断本帧是否需要重绘。
  /// 检测阈值 0.5px / 0.001 远低于人眼感知，无视觉差异。
  double _lastRepaintPosY = 0;
  double _lastRepaintBlurFade = 0;
  double _lastRepaintEntryBlur = -1;
  double _lastRepaintInterludeProgress = 0;
  /// 上次重绘时的副行进度代次：逐行副行进度任一变化即 +1。
  int _lastRepaintAuxGeneration = -1;
  int _lastRepaintCurrentLineIndex = -1;

  // P1-1 分层：其余行层靠「焦点行索引」决定跳过哪一行。焦点行提前/滞后切换
  // （等待期、预启动）时，即使 _currentLineIndex 没变也必须重绘该层，
  // 否则旧位图跳过的是旧焦点行、当前行层又画了新焦点行 → 两行同时可见（重影）。
  int _lastRepaintFocusIndex = -2;
  bool _lastRepaintVisualHold = false;
  int _lastRepaintLinesGeneration = -1;
  int _lastRepaintLineHeightsGeneration = -1;
  int _lastRepaintLineTopsGeneration = -1;

  // ============== 控制器与效果 ==============

  final LyricScrollController _scrollController = LyricScrollController();
  final InterludeDots _interludeDots = InterludeDots();
  final EmphasizeEffect _emphasizeEffect = EmphasizeEffect();

  /// 每行独立的 scale 弹簧（行索引 → Spring）。
  ///
  /// 相比旧的单实例 LineScaleController 只服务当前行，这里每行都有自己的弹簧：
  /// 离场行（当前行 → 非当前行）从 1.0 缩到 [LyricLayout.inactiveScale]、
  /// 进场行从 inactiveScale 平滑放大到 1.0——两侧都有连贯动画，补上"缩小时硬切"。
  final Map<int, Spring> _perLineScaleSprings = {};

  /// 每行 scale 弹簧位置的复用列表（每帧 [_tickPerLineScales] 填充，传给 painter）。
  List<double> _reusedPerLineScales = const <double>[];

  /// 当前歌曲的辉光触发阈值（ms）：500=快歌，1000=慢歌。
  ///
  /// 由歌曲 BPM / KRC 歌词字长推断（[EmphasizeEffect.resolveThresholdMs]），
  /// 切歌（lines / songBpm 变化）时重算，并同步到每个 [WordRenderer]。
  int _glowThresholdMs = 500;

  /// 每行独立的 [WordRenderer] 缓存（按行索引）。
  ///
  /// WordRenderer 内部检测 line 切换并维护 alpha map，多行共用会导致状态混乱，
  /// 故每行独占一个实例。首次访问时懒创建。
  final Map<int, WordRenderer> _wordRenderers = <int, WordRenderer>{};

  /// 每行独立的 [LineRenderer] 缓存（按行索引）。
  final Map<int, LineRenderer> _lineRenderers = <int, LineRenderer>{};

  // ============== 当前状态 ==============

  int _currentLineIndex = -1;

  /// 预换行等待期的目标行；-1 = 不在等待期（开关关闭时恒 -1）。
  int _earlySwitchTarget = -1;
  /// 缓存分支算出的「按真实时间」的行索引（避免每帧重复二分）。
  int _earlyTimedLine = -1;
  /// 进入等待期时的权威时间快照：作废判据以它为基准判断「是否回退」。
  ///
  /// 不能用 `targetStart − 1000` 这类与目标行的绝对距离：长间奏提前量超过
  /// 1s 时，进入等待的那一帧该条件恒成立 → 每帧作废再重建 → 逐帧闪烁。
  int _earlySwitchAnchorMs = -1;

  /// 等待期内冻结「视觉激活」：清晰层 / 字内渐变 / 缩放放大都不提前，
  /// 下一行到位但仍保持模糊层与 inactiveScale。
  bool get _visualHold => _earlySwitchTarget >= 0;

  /// 本次入场模糊层的淡出**时长上限**（ms）。
  ///
  /// 正常切行取「模糊等级渐变时长」滑块；提前换行激活取「模糊褪去时长」
  /// 滑块（[_entryBlurFadeMs]）。实际淡出取「时长上限」与「该行演唱进度」
  /// 中较快者（见 [_onTick] 的入场推进）：前者保证不拖到整行唱完，后者保证
  /// 不比清晰层慢（不退成重影）。
  double _entryFadeDurationMs = 500.0;

  /// 「逐字唱完」到开唱的最小提前量（ms）：短于此值不提前换行。
  ///
  /// 一次换行由 posY 弹簧完成，收敛约 300–400ms。提前量短于它时弹簧跑不完
  /// 就撞上开唱（目标推进 + 视觉激活 + 缩放同时发生），观感比硬切更差，
  /// 表现为「抽一下」。
  static const int _earlyMinLeadMs = 420;

  /// 上次重建模糊等级缓存时的视觉冻结状态：激活帧解除冻结但
  /// _currentLineIndex 不变，必须靠它触发缓存重算，否则当前行模糊
  /// 等级残留、与刚亮起的字内渐变叠成重影。
  bool _lastBlurVisualHold = false;

  @visibleForTesting
  Map<int, int> get blurLevelsForTest => _cachedBlurLevels;

  @visibleForTesting
  int get earlySwitchTargetForTest => _earlySwitchTarget;

  @visibleForTesting
  bool get visualHoldForTest => _visualHold;

  @visibleForTesting
  int get currentLineIndexForTest => _currentLineIndex;
  Offset? _tapDownPosition;

  // P0: 当前行查找结果缓存：currentTimeMs 与 lines 引用都未变化时，
  // _onTick 每帧跳过 findCurrentLineIndex 二分查找（O(log N) → 0 次）
  int _currentTimeMsCache = -1;
  Object? _linesCacheRef;

  /// 权威播放时间（ms）：listenable 模式由 [_onExternalPosition] 更新；
  /// 静态模式等于 widget.currentTimeMs。替代原先所有 widget.currentTimeMs 消费。
  int _authorityTimeMs = 0;

  /// 仅测试用：当前生效的权威时间
  @visibleForTesting
  int get authorityTimeMsForTest => _authorityTimeMs;

  // P0: 逐字动画时间平滑。positionStream 默认 ~200ms（5fps）才更新一次，
  // 直接用 widget.currentTimeMs 驱动上浮/字内渐变会让动画每 200ms 才推进一次
  // （120Hz 下"动 ~80ms + 冻结 ~120ms"）→ 肉眼卡顿。
  // 播放中用帧时钟每帧推进 [_smoothPosMs]，收到权威位置时对齐校正；
  // seek / 暂停恢复 / 切歌等大跳变直接吸附。仅用于逐字动画（maskX/上浮），
  // 行定位 / 间奏检测仍用权威 widget.currentTimeMs，保证与音频严格同步。
  double _smoothPosMs = 0;
  int _lastAuthorityPosMs = -1;

  /// 仅测试用：当前逐字动画平滑时钟（ms）。
  @visibleForTesting
  double get smoothPosMsForTest => _smoothPosMs;

  /// 逐字动画平滑时间的权威位置校正：
  ///
  /// - [_smoothPosSeekJumpMs]：权威位置跳变超过此值视为 seek/大跳变，直接吸附。
  /// - [_smoothPosCorrRate]：正常 position 更新时平滑逼近权威位置的速率（指数衰减系数）。
  ///   平滑逼近而非硬跳，避免音频时钟与帧时钟漂移导致权威位置硬跳跨过逐字边界、
  ///   字切换来回抖动（英文歌字短、边界密集时更明显，表现为"下一个字闪一下"）。
  static const int _smoothPosSeekJumpMs = 500;
  static const double _smoothPosCorrRate = 20.0;

  /// 平滑时钟的「小幅回退死区」（ms）。
  ///
  /// positionStream 约 200ms 采样一次，[_smoothPosMs] 按帧时钟在此间隔内先行推进，
  /// 收到权威位置时权威值往往略小于当前平滑值（采样相位差）。若按指数校正无条件
  /// 逼近，字内渐变 / 扫光进度会被周期性往回拉；暂停瞬间的硬吸附同理会倒退一截。
  /// 回退幅度不超过该死区时保持已推进的进度，只在真实回退（seek / 换源）超过
  /// 死区时才回拉。
  static const double _smoothPosRewindToleranceMs = 200.0;

  // ============== 歌词省电模式（60fps 限帧，默认关闭） ==============
  // 开启后歌词渲染推进锁定 60fps，用户上下滑动歌词（拖动/惯性/自动回弹动画）时
  // 解锁为最高刷新率；滚动视觉静止后自动重新锁定。
  //
  // **为什么必须停 Ticker 换 Timer**：仅在 _onTick 内节流跳过计算无法降低实际
  // 渲染帧率——Ticker 每帧都会 scheduleFrame()，引擎每帧 compositeFrame 提交
  // 场景，120Hz 屏上即便内容不变仍保持 120fps 刷新（CPU/GPU 白耗，这正是
  // "开了开关仍锁不住 60fps"的根因）。因此 eco 锁定时停掉 Ticker、改用
  // 16.67ms Timer 驱动 _onTick，帧生产被真正限制到 60fps；解锁/关闭 eco 时
  // 切回 Ticker 满帧。

  /// eco 锁定时是否挂在共享 60fps 帧驱动上（真正的帧率限制驱动源）。
  ///
  /// 与封面旋转/频谱共用 [PlayerFrameDriver] 的同一节拍：两者独立起 16ms
  /// Timer 时相位错开，会让 120Hz 屏整页跑到 ~120fps（功耗翻倍）。
  bool _ecoDriverBound = false;

  /// Ticker 帧间隔跳变阈值（秒）。
  ///
  /// 超过此值视为 Ticker 曾被 mute（TabBarView 切走 / App 退后台 /
  /// 主线程长时间卡顿）：mute 期间帧回调冻结，间奏点动画时钟（帧 dt 累积）
  /// 会停留在切走前的位置，而歌曲继续播放 → 切回后"跟不上进度"。
  /// 此时需把间奏点动画时钟重新对齐到真实窗口进度（O(1) 检测，无额外功耗）。
  static const double _tickerGapResumeThreshold = 0.5;

  /// 省电模式是否被用户滚动解锁（true = Ticker 满帧推进）。
  bool _ecoUnlocked = false;

  /// 省电模式是否处于解锁状态（仅测试用，避免 widget 测试无法观测限帧状态）。
  @visibleForTesting
  bool get ecoUnlockedForTest => _ecoUnlocked;

  /// 当前驱动源是否为 60fps eco Timer（eco Timer 在跑且满帧 Ticker 未跑）。
  /// 仅测试用：验证挂载即确定性建立 eco 限帧、不依赖 Ticker 的 _onTick 自我纠正。
  @visibleForTesting
  bool get ecoDriverIsTimerForTest => _ecoDriverBound && !_isTickerRunning;

  /// eco Timer 是否存活（仅测试用：验证 P0-A 挂起/恢复语义）。
  @visibleForTesting
  bool get ecoTimerActiveForTest => _ecoDriverBound;

  /// 滚动控制器（仅测试用：验证鼠标滚轮滚动与 5s 自动回弹）。
  @visibleForTesting
  LyricScrollController get scrollControllerForTest => _scrollController;

  // P0-A：驱动源可见性门控状态。
  //
  // Ticker 由 TickerMode/引擎自动 mute，但 eco Timer 不受任何可见性约束——
  // TabBarView 切走 / App 退后台后仍会以 16ms 周期驱动 _onTick 产生离屏重绘。
  // 两个标志任一为 true 时，[_syncEcoDriver] 挂起全部驱动源。

  /// App 处于后台（hidden/paused/detached）。
  bool _lifecycleSuspended = false;

  /// TickerMode 关闭（歌词 tab 被切走，与 Ticker mute 同源）。
  bool _tickerModeMuted = false;

  /// 从挂起恢复后的首个 _onTick 按"gap 恢复"处理（Timer 路径 dt 恒 16ms，
  /// 自身检测不到挂起时长缺口，需此标记对齐间奏点等帧时钟动画）。
  bool _resumeGapPending = false;

  /// 间奏点是否仍处于激活（需要绘制）状态。仅测试用：验证跳转离开间奏后
  /// 圆点已自动清除，不会悬浮残留在原 anchor 行（穿帮回归护栏）。
  @visibleForTesting
  bool get interludeDotsActiveForTest => _interludeDots.shouldRender;

  /// 间奏点是否已进入消失动画阶段（末 750ms）。仅测试用：验证"跳转离开"
  /// 与"自然结束"两条路径被正确区分。
  @visibleForTesting
  bool get interludeDotsInExitPhaseForTest => _interludeDots.isInExitPhase;

  /// 间奏点动画时钟（ms）。仅测试用：验证收起阶段圆点逐帧推进（省电模式
  /// 名义步长下曾出现每 3 帧才推进一次的台阶卡顿）与收尾补帧不瞬灭。
  @visibleForTesting
  double get interludeDotsAnimationMsForTest => _interludeDots.animationTimeMs;

  /// 间奏占位展开进度（0=完全收起，1=完全展开）。仅测试用。
  @visibleForTesting
  double get interludeExpandProgressForTest => _interludeExpandProgress;

  /// 最后激活的间奏 anchor 行索引（-2 = 从未激活，-1 = 首行之前的头部间奏）。
  /// 仅测试用：校验「首行之前」的头部间奏把占位放在第一行上方，而不是被推到
  /// 第一行下面。
  @visibleForTesting
  int get interludeAnchorIndexForTest => _lastActiveAnchorIdx;

  /// 第 i 行上方的间奏占位偏移。仅测试用：头部间奏必须让**首行**也让位
  /// （`> 0`），普通行间间奏的首行偏移恒为 0。
  @visibleForTesting
  double interludeOffsetBeforeForTest(int i) => _interludeOffsetBefore(i);

  /// 渲染口径的焦点行（-1 = 头部间奏占位占据焦点，没有行激活）。仅测试用。
  @visibleForTesting
  int get focusLineIndexForTest => _focusLineIndex;

  /// 第 i 行的模糊等级（0 = 不模糊，当前行豁免）。仅测试用：头部间奏期间
  /// 首行必须参与模糊（不再被当作当前行豁免）。
  @visibleForTesting
  int blurLevelForTest(int i) => _computeLineBlurRaw(i);

  /// 间奏占位完全展开后的行高。仅测试用：校验头部间奏的滚动目标把占位行
  /// 对准「当前行位置」偏好。
  @visibleForTesting
  double get interludePlaceholderHeightForTest => _interludePlaceholderHeight;

  /// 间奏占位行在内容坐标里的顶部 y。仅测试用：校验滚动目标确实对准占位行
  /// （`scrollTarget + slotTop + 占位行高/2 = 视口高 × alignPosition`）。
  @visibleForTesting
  double interludeSlotTopForTest(int anchorIdx) => _interludeSlotTop(anchorIdx);

  /// 第 i 行的副行预留高度（已含副行过长换行的行数）。仅测试用：
  /// 验证副行换行后行距预留随视觉行数增长（否则换行副行压到下一行）。
  @visibleForTesting
  double auxSubHeightForTest(int i) => _auxSubHeightOf(i);

  /// 第 i 行当前的形变 scale(与 painter `perLineScales` 同口径)。仅测试用:
  /// 验证 tick 窗口外的行被钉在稳态 inactive(滚动到远处不出现未缩小行)。
  /// 列表尚未建立(首帧 tick 前)返回 NaN。
  @visibleForTesting
  double lineScaleForTest(int i) =>
      i >= 0 && i < _reusedPerLineScales.length
          ? _reusedPerLineScales[i]
          : double.nan;

  /// 当前滚动弹簧位置。仅测试用：验证快速连切兜底把 posY 直接瞬移到目标。
  @visibleForTesting
  double get scrollPosYForTest => _scrollController.posY;

  /// 当前滚动弹簧目标。仅测试用：与 [scrollPosYForTest] 相等即代表已直接到位。
  @visibleForTesting
  double get scrollTargetForTest => _scrollController.currentTarget;

  /// 第 i 行当前屏幕 y（与 painter 定位同口径，含级联偏移）。仅测试用：
  /// 验证级联释放帧的屏幕速度连续（不得整块瞬跳）。
  @visibleForTesting
  double lineScreenYForTest(int i) {
    final double fs = _cachedFontSize > 0 ? _cachedFontSize : 0;
    final double mainH = fs * LyricLayout.lineHeight;
    final double top =
        (i < _lineTops.length ? _lineTops[i] : i * mainH) +
        _interludeOffsetBefore(i) +
        _transDeltaBefore(i);
    return top + _scrollController.posY + _effectiveLineOffset(i);
  }

  /// 最近一次切行是否走了快速兜底。仅测试用。
  @visibleForTesting
  bool get lastSwitchWasFastForTest => _lastSwitchWasFast;

  /// 本轮级联牵引起点（限幅后的视口顶部可见行）。仅测试用：
  /// 验证关闭「错峰从当前行上方开始」时的当前行延迟补偿量推导。
  @visibleForTesting
  int get cascadeTopLineForTest => _cascadeTopLine;

  /// 第 i 行级联延迟是否仍在等待期（未被释放）。仅测试用：
  /// `true` = 仍被「按住等错峰」，`false` = 已释放交给弹簧回弹。
  @visibleForTesting
  bool cascadeLineHeldForTest(int i) => (_delayStartTimes[i] ?? -1) >= 0;

  /// 给定锚行的确定性级联起点。仅测试用：验证同一 anchor 恒定映射到同一行
  /// （「上拉起始行不一致」的回归护栏）。
  @visibleForTesting
  int cascadeStartLineForTest(int anchorLine) => _cascadeStartLineFor(anchorLine);

  /// 当前是否存在未走完的级联轮次。仅测试用：验证轮次收口不会跨轮残留。
  @visibleForTesting
  bool get cascadeRoundActiveForTest => _cascadeRound != null;

  /// 第 i 行副行当前展开进度（0 = 收起，1 = 展开）。仅测试用。
  @visibleForTesting
  double auxProgressForTest(int i) => _auxProgressAt(i);

  /// 第 i 行副行目标进度（由「副行显示范围」决定）。仅测试用。
  @visibleForTesting
  double auxTargetForTest(int i) => _auxTargetAt(i);

  /// 第 i 行上方副行高度累计（前缀和口径）。仅测试用：
  /// 断言 `auxDeltaBeforeForTest(k) == Σ_{i<k} auxExtraForTest(i)` 这条
  /// 「行 top 与行高同源」不变量（写歪会让点击跳行命中错行）。
  @visibleForTesting
  double auxDeltaBeforeForTest(int i) => _transDeltaBefore(i);

  /// 第 i 行副行带来的额外高度。仅测试用。
  @visibleForTesting
  double auxExtraForTest(int i) => _transExtraHeightFor(i);

  /// 本帧是否仍有副行进度在推进（空 = 已收敛）。仅测试用。
  @visibleForTesting
  bool get auxAnimatingForTest => _auxAnimating.isNotEmpty;

  /// 第 i 行 WordRenderer 上一次绘制算出的 sweep（扫光）前端位置（行内坐标）。
  ///
  /// 仅测试用：验证 [LyricFillMode.sweep] 下前端非负且随播放进度向右推进。
  /// 该行尚无渲染器（未绘制/非逐字行）时返回 NaN。
  @visibleForTesting
  double sweepFrontForTest(int i) =>
      // ignore: invalid_use_of_visible_for_testing_member
      _wordRenderers[i]?.sweepFrontDebug ?? double.nan;

  /// P1-C：上次间奏检测时的权威播放时间（毫秒）。
  ///
  /// 间奏检测只依赖 currentTimeMs（positionStream 约 200ms 更新一次），
  /// 时间未变且占位动画已收敛时，跳过每帧 O(间奏数) 的线性遍历。
  /// 同时用于检测时间回退（seek/跳转）：currentTimeMs < 上次值时说明
  /// 播放位置回跳，需强制重置间奏点动画时钟（见 [_updateInterlude]）。
  int _lastInterludeCheckTimeMs = -1;

  // ============== 动态字体颜色（仅 AM 播放器，默认关闭） ==============
  // 开启后当前行歌词颜色按「白色 + 封面提取色 × 混色比例」混色，
  // 非当前行保持默认歌词色（除非「上方行使用已播颜色」开关开启）。
  // 颜色由 build 根据 accentColor 计算一次，_onTick 与 painter 每帧读取，
  // 避免每帧 Color.lerp 分配。

  /// 当前行动态字体颜色（ARGB int），null 表示不使用（回退默认歌词色）。
  int? _activeLineColorValue;

  /// 上方行使用的颜色覆盖值（ARGB int），null 表示不覆盖。
  ///
  /// 仅当「上方行使用已播颜色」开关开启且 [_activeLineColorValue] 非空时
  /// 等于 [_activeLineColorValue]，否则为 null（上方行沿用默认歌词色）。
  int? _aboveLineColorValue;

  // overscan 视口缓冲行数：pad 端 15、手机端 10。在 build 中根据最短边更新
  int _overscan = 10;

  /// 模糊渐隐系数（1.0=正常模糊，0.0=无模糊）。
  /// 用户滚动时淡出到0，松手等待期间保持0，回弹开始后淡入到1。
  double _blurFade = 1.0;

  /// 清晰层（主行 + 翻译副行）使用的模糊淡出系数。
  ///
  /// 对 [_blurFade] 做「清晰字快速退场」整形 `1-(1-f)²`：模糊图淡入期间，
  /// 清晰字必须比模糊层更快退场。同样 alpha 下清晰字形的峰值亮度远高于模糊图
  /// （模糊把 alpha 摊开），若按线性交叉淡入，前段必然是「先更白、过一会儿
  /// 才落到透明度偏好对应的正常色」（用户持续反馈的淡入颜色跳变）。
  double get _clearLayerBlurFade {
    final double f = _blurFade.clamp(0.0, 1.0);
    return 1.0 - (1.0 - f) * (1.0 - f);
  }

  /// 模糊等级交叉淡入淡出进度：1.0 = 无过渡（开关关闭时的恒定值）。
  ///
  /// 只在 [LyricPreferences.blurLevelCrossfade] 开启、且某行 blurLevel
  /// 变化导致模糊图被替换时从 0 起步；复用 [_onTick] 的帧时钟推进，
  /// 不新增 Ticker / Timer 驱动源。
  double _blurLevelFade = 1.0;

  /// 过渡时长由「动画细节」页滑块提供（LyricPreferences.blurLevelFadeMs），
  /// 默认 500ms、上限 1000ms；运行时读取，拖滑块即时生效。

  /// 上次重绘时的模糊等级过渡进度（差分门控，见 _onTick）。
  double _lastRepaintBlurLevelFade = 1.0;

  /// 入场模糊淡出进度：0 = 完全显示（新当前行下方叠加它的旧模糊图），1 = 完全隐藏。
  ///
  /// 行切换时对**新当前行**复位为 0，随后按该行的演唱进度推进（见
  /// [_clearAlphaOf]：逐字行与字内渐变同一时间轴、与清晰层互补；LRC 行走
  /// [_entryFadeDurationMs] 时间兜底）。入场有"模糊层淡出 + 跟随该行从
  /// inactiveScale 放大到 activeScale"的过渡，与离场对称。
  double _entryBlurProgress = 1.0;

  /// 模糊级别缓存：只在当前行变化时重算
  int _cachedBlurLineIndex = -1;

  /// 模糊级别缓存键：上次重算时「头部间奏占位是否占据焦点槽位」。
  ///
  /// 头部间奏激活前后 `_currentLineIndex` 不变（都是首行），但首行会从"当前行
  /// 豁免模糊"变成"距离 1 的模糊行"，必须单独作为缓存失效条件。
  bool _cachedBlurHeadSlot = false;
  Map<int, int> _cachedBlurLevels = const {};

  /// Per-Line 模糊缓存：行索引 → (模糊图, 渲染输入签名)。
  ///
  /// 签名覆盖 blurLevel / fontSize / 视口宽 / enableScale / inactiveScale /
  /// fontFamily / fontWeight，任一变化即判定过期并重渲染（修掉字号与非当前行
  /// 缩放变化后旧模糊图长期不刷新的问题）。
  final Map<int, (ui.Image image, String signature)> _lineBlurImages = {};

  /// Per-Line 副行模糊缓存：行索引 → (副行模糊图, 渲染输入签名)。
  ///
  /// **为什么与主行分开一张图**：副行的显隐是逐行动画（进度 0→1），若把副行
  /// 烘焙进主行图，进度每变化一点就得重烘焙整行——那是逐帧离屏渲染。拆成独立
  /// 图后，进度只影响合成期的 top 偏移与 Opacity（与清晰层副行同一位移公式
  /// `subH × (progress - 1)`），**零重烘焙**即可让模糊副行跟着清晰副行一起
  /// 长出 / 收起。代价是每行多一张小图（高 ≈ 副行高 + 2×padding）。
  final Map<int, (ui.Image image, String signature)> _auxBlurImages = {};

  // 每次异步请求独占令牌，防止切歌/几何变化后旧纹理覆盖新缓存。
  final Map<int, (Object token, String signature)> _lineBlurPending = {};
  final Map<int, (Object token, String signature)> _auxBlurPending = {};

  /// 副行**清晰图**缓存：行索引 → 预栅格化副行文字（白字、不透明白）。
  ///
  /// 用途：副行「日历翻转」会给画布施加带透视的矩阵，而 Skia 对含透视的矩阵
  /// 会放弃字形图集、退回字形路径逐帧渲染（中文副行每行数十个复杂字形）——
  /// 那是切行掉帧的直接来源。翻转期间改画这张图（透视落在 GPU 纹理四边形上），
  /// 就位后仍走原来的文字直绘，观感不变。
  ///
  /// 只保留当前行邻近几行（见 [_syncAuxTextImages]）：签名不含进度/alpha，
  /// 因此显隐动画期间零重烘焙。
  final Map<int, AuxTextImage> _auxTextImages = {};
  final Map<int, String> _auxTextSignatures = {};
  final Map<int, (Object token, String signature)> _auxTextPending = {};

  /// 上次预热过的当前行索引（-1 = 需要重新预热）。
  int _auxTextImageFocus = -1;

  /// 交叉淡入淡出期间保留的旧模糊图：行索引 → (旧图, 旧 blurLevel)。
  ///
  /// 旧 blurLevel 用于按旧几何定位，避免 BoxFit.fill 把 padding 不同的
  /// 旧图纵向拉伸。任意时刻最多一批：新一批切行、出视口、切歌、dispose
  /// 都会释放，不会随切行次数累积。
  final Map<int, ({ui.Image image, int blurLevel})> _lineBlurFading = {};
  final Map<int, ({ui.Image image, int blurLevel})> _auxBlurFading = {};

  /// 交叉淡入淡出时旧层的权重。
  ///
  /// 模糊图按固定 alpha 烘焙（主行 0.5 / 副行 0.25），两层 source-over
  /// 叠加时若简单取 (1-p)/p，旧层会被新层遮掉一部分，过渡中出现亮度凹陷。
  /// 解 `p + w - A*p*w = 1`（A = 基础 opacity × 烘焙 alpha）得
  /// `w = (1-p)/(1-A*p)`，使合成后的有效 alpha 逐像素恒等于单层。
  double _crossfadeOldWeight(
      double p, double baseOpacity, double bakedAlpha) {
    final double a = (baseOpacity * bakedAlpha).clamp(0.0, 1.0);
    final double denom = 1.0 - a * p;
    return denom <= 0.0 ? 0.0 : (1.0 - p) / denom;
  }

  void _disposeFadingBlurs() {
    for (final entry in _lineBlurFading.values) {
      entry.image.dispose();
    }
    _lineBlurFading.clear();
    for (final entry in _auxBlurFading.values) {
      entry.image.dispose();
    }
    _auxBlurFading.clear();
  }

  /// 过渡收敛：先把进度推到 1（本帧起不再绘制旧层），帧末再释放位图，
  /// 避免本帧合成的 Picture 仍引用已 dispose 的 ui.Image。
  void _finishBlurLevelFade() {
    _blurLevelFade = 1.0;
    // 收敛帧的差分可能小于 0.001 门限；强制让本帧重绘一次，
    // 之后才在帧末释放旧位图。
    _lastRepaintBlurLevelFade = -1.0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _disposeFadingBlurs();
    });
  }

  /// 把即将被替换的旧模糊图暂存为交叉淡入淡出的下层。
  ///
  /// 关闭开关、几何口径已变（字号/视口/缩放等，旧图定位会错）或首次建图时
  /// 走原有的立即 dispose 分支，行为与改造前逐像素一致。
  void _stashFadingBlur({
    required Map<int, ({ui.Image image, int blurLevel})> fading,
    required int lineIndex,
    required (ui.Image, String)? old,
  }) {
    if (old == null) return;
    final String geomSig = _blurGeometrySig();
    final int? oldLevel = LyricPreferences.instance.blurLevelCrossfade &&
            old.$2.startsWith('$geomSig|')
        ? int.tryParse(old.$2.split('|').last)
        : null;
    if (oldLevel == null || oldLevel <= 0) {
      old.$1.dispose();
      return;
    }
    // 同一行在过渡未结束时再次换图（快速连切 / 拖强度）：先释放上一份。
    fading[lineIndex]?.image.dispose();
    fading[lineIndex] = (image: old.$1, blurLevel: oldLevel);
    if (_blurLevelFade >= 1.0) {
      _blurLevelFade = 0.0;
      // 稳态（非逐字歌词）下驱动可能已停；只唤醒既有驱动源，
      // 不新建 Ticker / Timer，避免把整页顶到满帧。
      if (!_isTickerRunning && !_ecoDriverBound) _syncEcoDriver();
    }
  }

  @visibleForTesting
  double get blurLevelFadeForTest => _blurLevelFade;

  @visibleForTesting
  double get entryBlurProgressForTest => _entryBlurProgress;

  @visibleForTesting
  bool get hasFadingBlurForTest =>
      _lineBlurFading.isNotEmpty || _auxBlurFading.isNotEmpty;

  @visibleForTesting
  Future<ui.Image?> Function(int, int, DuetAlignment)? lineBlurRendererForTest;

  @visibleForTesting
  Future<ui.Image?> Function(int, int, DuetAlignment)? auxBlurRendererForTest;

  /// 副行清晰图烘焙的测试注入点（默认走真实 TextPainter + toImage）。
  @visibleForTesting
  Future<AuxTextImage?> Function(int lineIndex)? auxTextRendererForTest;

  /// 当前已缓存的副行清晰图（按行索引，仅测试用）。
  @visibleForTesting
  Map<int, AuxTextImage> get auxTextImagesForTest => _auxTextImages;

  /// 手动触发副行清晰图预热（仅测试用）。
  @visibleForTesting
  void syncAuxTextImagesForTest(int focus) => _syncAuxTextImages(focus);

  /// 仅测试：最近一次模糊层合成中每张图的 (tint, opacity)。
  ///
  /// 模糊层已改为画布绘制，无法再从 widget 树（ColorFiltered/Opacity）断言，
  /// 测试注入一个列表即可观察染色与不透明度。
  @visibleForTesting
  List<({int? tint, double opacity})>? debugBlurDraws;

  @visibleForTesting
  void updateLineBlurCacheForTest(Map<int, int> levels) =>
      _updateLineBlurCache(levels);

  @visibleForTesting
  ui.Image? lineBlurImageForTest(int index) => _lineBlurImages[index]?.$1;

  @visibleForTesting
  ui.Image? auxBlurImageForTest(int index) => _auxBlurImages[index]?.$1;

  /// 预换行状态机：把「布局/滚动」的换行点提前，但保留视觉激活时机。
  ///
  /// 提前点 = 当前行「逐字唱完」时刻（[effectiveLineEndTime]）：人声一停就把
  /// 下一行滚到中心，视觉激活（清晰字 / 放大 / 字内渐变）仍冻结到
  /// `next.startTime`。提前量必须够一次换行走完，否则 posY 弹簧只跑一半就被
  /// 开唱打断 —— 观感是「抽一下」，比不改更差（250ms 提前量实测即此症状）。
  /// 仅 KRC 逐字行生效（LRC 无逐字完成时刻，保持原行为）。
  void _updateEarlySwitch() {
    final bool switchOn = LyricPreferences.instance.earlyLineSwitch;

    // 等待期已建立：**维持条件必须与建立条件分离**。
    //
    // 旧实现把 isPlaying / playbackNotReady 也算进前置条件：播放中只要
    // buffering 抖一帧就作废等待、下一帧又重新建立，_currentLineIndex 于是
    // 在原行与下一行之间来回跳 —— 真机表现即「来回闪烁切回原来的行」。
    // 同理，旧作废判据 `_smoothPosMs < targetStart − 1000` 在长间奏（提前量
    // 超过 1s）时**进入等待的那一帧就成立**，同一帧内作废 → 下一帧重建 →
    // 再作废，形成逐帧闪烁。
    if (_earlySwitchTarget >= 0) {
      final int target = _earlySwitchTarget;
      final int targetStart =
          target < widget.lines.length ? widget.lines[target].startTime : -1;
      if (!switchOn ||
          targetStart < 0 ||
          _scrollController.isUserScrolling ||
          _scrollController.isWaitingForAutoReturn) {
        _earlySwitchTarget = -1;
        return;
      }
      if (_authorityTimeMs >= targetStart) {
        _onEarlySwitchActivated();
        _earlySwitchTarget = -1;
        return;
      }
      // seek / 跳行：真实行已不再是目标行的前一行，或权威时间倒退离开窗口。
      // 两者都以「相对进入等待时的锚点」判定，不再用与 targetStart 的绝对
      // 距离 —— 那个距离在长间奏里恒成立。
      if (_earlyTimedLine != target - 1 ||
          _authorityTimeMs < _earlySwitchAnchorMs - 1000) {
        _earlySwitchTarget = -1;
        return;
      }
      return;
    }

    final bool eligible = switchOn &&
        widget.isPlaying &&
        !widget.playbackNotReady &&
        !_scrollController.isUserScrolling &&
        !_scrollController.isWaitingForAutoReturn &&
        _cachedHasTimestamps &&
        widget.lines.isNotEmpty;
    if (!eligible) return;
    final int timed = _earlyTimedLine;
    if (timed < 0 || timed >= widget.lines.length - 1) return;
    final current = widget.lines[timed];
    final next = widget.lines[timed + 1];
    // LRC / 无逐字时间戳没有「逐字完成」时刻，保持原行为。
    if (!current.hasWordTiming) return;
    // 「逐字唱完」即刻换行。不再固定 250ms —— 那是「圆点开始收起」的时刻，
    // 距开唱不足一次滚动的收敛时间，弹簧跑一半就被截断。
    final int vocalEnd = AppleLyricsView.effectiveLineEndTime(current);
    // 提前量不足一次换行走完：不提前。提前了也只会被开唱打断，白抖一下。
    if (next.startTime - vocalEnd < _earlyMinLeadMs) return;
    if (_authorityTimeMs < vocalEnd) return;
    _earlySwitchAnchorMs = _authorityTimeMs;
    _earlySwitchTarget = timed + 1;
    // 间奏占位与圆点**保留**：提前换行只是把布局/滚动提前，空档本身还在
    // （当前行虽已就位，它上方到上一行之间仍是间奏）。占位照常在 gap 起点
    // 展开、在 gap 末（next − 250ms）收起，圆点动画不受影响。
    //
    // 已记录的「圆点向上飞很高」只发生在**预启动把滚动目标推进到下一行**
    // 那条路径上：那里窗口在 next−250 附近才进入，滚动位移与占位收起同段。
    // 提前换行发生在 vocalEnd，滚动在 ~400ms 内就收敛完，与 250ms 后才开始
    // 的占位收起不重叠，因此不需要撤销占位。
  }

  /// 等待期结束（真实音频边界）：补发本该在切行帧发生的入场模糊层。
  ///
  /// 不依赖「模糊等级渐变切换」开关——避免模糊与字内渐变重叠属于
  /// 功能正确性，不是可选的装饰效果。淡出进度随后由该行演唱进度驱动
  /// （见 [_clearAlphaOf]），不用「模糊等级渐变时长」滑块，也不用固定
  /// 短时长：那两者都会让模糊在字亮起前撤完或压在已亮的字上。
  void _onEarlySwitchActivated() {
    if (LyricPreferences.instance.useGaussianBlur &&
            _currentLineIndex >= 0 &&
            _currentLineIndex < widget.lines.length) {
      _entryFadeDurationMs = LyricPreferences.instance.entryBlurFadeMs;
      _entryBlurProgress = 0.0;
    }
  }

  /// 指定行清晰层「当前已亮起」的程度（0..1）。
  ///
  /// 用「该行已演唱时长 / 该行有效时长」而非 renderer 的 alpha：逐字渐变
  /// 与字内渐变共用这条时间轴，而 `averageWordAlpha` 对未播行返回的是基础
  /// 暗度（非 0），会让模糊层在激活帧就直接撤完。
  ///
  /// 入场模糊层的淡出由它驱动，与清晰层互补 —— 固定时长只能在「字还没亮
  /// 就撤掉模糊（整行暗一下）」与「模糊压在已亮的字上（重影）」之间二选一。
  double _clearAlphaOf(int index) {
    if (index < 0 || index >= widget.lines.length) return 1.0;
    final line = widget.lines[index];
    final int end = AppleLyricsView.effectiveLineEndTime(line);
    final int span = math.max(1, end - line.startTime);
    return ((_authorityTimeMs - line.startTime) / span).clamp(0.0, 1.0);
  }

  void _clearLineBlurCache() {
    _blurBakeQueue.clear();
    _blurBakeTimer?.cancel();
    _blurBakeTimer = null;
    _disposeFadingBlurs();
    _blurLevelFade = 1.0;
    _lineBlurPending.clear();
    for (final entry in _lineBlurImages.values) {
      entry.$1.dispose();
    }
    _lineBlurImages.clear();
    _auxBlurPending.clear();
    for (final entry in _auxBlurImages.values) {
      entry.$1.dispose();
    }
    _auxBlurImages.clear();
    _clearAuxTextImages();
  }

  /// 上次构建模糊层时的几何签名，用于字号/缩放/视口变化时强制重算 levels。
  String _lastBlurGeometrySig = '';
  double _viewportWidth = 0;

  // 歌词边界渐隐 shader 缓存（模糊层绘制期使用；清晰层在 _LyricsPainter 内
  // 按行做同样的离屏遮罩）。渐隐参数仅依赖视口尺寸，尺寸不变时复用。
  final _FadeShaderCache _fadeShaderCache = _FadeShaderCache();

  // ============== 男女对唱歌词处理 ==============
  //
  // 当 [LyricPreferences.useDuetLayout] 开启时，对 widget.lines 做一次预处理：
  // 剔除「男：/女：/合：」前缀，并生成每行的对齐方式（左/右/居中）。
  // 处理结果缓存到 [_cleanedLines] / [_duetAlignments]，供行高测量、模糊渲染、
  // painter 使用。时间戳保持不变，故 onSeek / 当前行定位 / 间奏检测不受影响。
  List<LyricLine> _cleanedLines = const <LyricLine>[];
  List<DuetAlignment> _duetAlignments = const <DuetAlignment>[];

  /// 上次处理对唱时所基于的 lines 引用（用于缓存命中判断）。
  Object? _cachedDuetLinesRef;

  /// 上次处理对唱时的 useDuetLayout 值。
  bool _cachedUseDuetLayout = false;

  /// 缓存的 hasTimestamps 结果（避免每帧 O(N) 遍历所有 lines）。
  /// 在 _recomputeDuetIfNeeded 中随 lines 引用变化时更新。
  bool _cachedHasTimestamps = false;

  /// 缓存的"是否含逐字行"结果（避免每帧 O(N) 遍历所有 lines）。
  ///
  /// 逐字行 = words 非空（KRC、字级 LRC，含本地/云盘音乐的 LRC 逐字）。
  /// P0-A 只对「整首歌都无逐字」的歌词（LRC 逐行 / 纯文本）启用
  /// 播放中停 Ticker 的静止省电模式；任何逐字行都必须保持 Ticker
  /// 持续推进逐字渐变/上浮/辉光动画。
  bool _cachedHasAnyWordTiming = false;

  /// 重算对唱预处理结果（若 lines 引用或开关变化）。
  void _recomputeDuetIfNeeded() {
    final useDuet = LyricPreferences.instance.useDuetLayout;
    if (useDuet == _cachedUseDuetLayout &&
        identical(widget.lines, _cachedDuetLinesRef) &&
        _cleanedLines.length == widget.lines.length) {
      return;
    }
    _cachedUseDuetLayout = useDuet;
    _cachedDuetLinesRef = widget.lines;
    // 缓存 hasTimestamps 结果，避免每帧 O(N) 遍历
    _cachedHasTimestamps = widget.lines.any((l) => l.startTime > 0);
    // 缓存"是否含逐字行"（KRC / 字级 LRC 的 words 非空），P0-A 静止省电
    // 模式仅对整首歌无逐字（LRC 逐行 / 纯文本）生效
    _cachedHasAnyWordTiming = widget.lines.any((l) => l.words.isNotEmpty);
    final result = DuetLayout.process(widget.lines, useDuet);
    _cleanedLines = result.cleanedLines;
    _duetAlignments = result.alignments;
    // 失效行高缓存，让 _recomputeLineHeightsIfNeeded 用新的 _cleanedLines 重算
    _cachedLinesRef = null;
    // 歌词内容变化：旧行索引不再适用于新歌词，副行进度缓冲整体作废
    // （长度 / 目标在 _recomputeLineHeightsIfNeeded 末尾按新行数重建）
    _resetAuxProgressBuffers();
    // 失效模糊图片缓存：对齐/文本变化后旧模糊图位置与内容均不再匹配
    _clearLineBlurCache();
    _cachedBlurLineIndex = -1;
  }

  // ============== 级联错峰延迟 ==============

  /// 每行偏移弹簧（行索引 → Spring）。
  ///
  /// 行释放（延迟到期）后，弹簧从「残留偏移 + 当时的滚动抵消量」弹回 0，
  /// 形成逐级延迟上拉效果。等待期内弹簧不被 tick，其值即残留基数。
  final Map<int, Spring> _perLineSprings = {};

  /// 每行延迟状态（行索引 → 毫秒）。
  ///
  /// 值 `>= 0` = 仍在延迟等待期（held），起始时刻为该值；
  /// 值 `-1`   = 已释放，交给弹簧回弹；
  /// 键不存在 = 不参与本轮级联。
  final Map<int, double> _delayStartTimes = {};

  /// 上一次行切换瞬间的全局 posY，作为"抵消滚动"的基准。
  ///
  /// 等待期内该行的偏移 = 本值 − 当前 posY，即精确停在切换瞬间的位置；
  /// 切换帧两者相等 → 偏移为 0，结构上不存在瞬时位移（这是消除瞬移的关键）。
  double _cascadePosY = 0;

  /// 上一帧的 posY，仅用于检测单帧不连续跳变（seek / 拖动）。
  /// null 表示首帧尚未取样，不参与判定。
  double? _lastFramePosY;

  /// 上一帧的滚动弹簧目标，用于识别「目标一次跳多行」的真实 seek。
  ///
  /// 不能用 posY 判定：预启动窗口内 posY 会随弹簧连续移动，一次长帧
  /// （dt 抖动）就可能超过一行高，从而被误判成 seek 并整块释放等待行。
  double? _lastFrameTargetY;

  /// 上一帧的当前行索引，用于检测行切换。
  int _previousLineIndex = -1;

  /// 级联牵引起点（限幅后的视口顶部可见行）。行切换时计算一次并缓存。
  int _cascadeTopLine = 0;

  /// 级联瀑布向上覆盖的可见行上限：起点不低于 currentLineIndex - K，
  /// 避免极端滚动/切歌跳变时起点过低拖出全屏。
  static const int _cascadeTopLimit = 8;

  /// 关闭「错峰从当前行上方开始」时的回落预算（步长倍数 K）。
  ///
  /// 只服务**回落路径**：预启动未建立（短行间隔 / seek / 暂停 / 快连切）
  /// 时，把锚行滞后钉在 K×步长以内、锚行以上行等比压进 `[0, K×步长]`
  /// 窗口（保持自上而下剥离顺序）。预启动成功时由剩余提前量推出更小的
  /// 压缩系数，不用此固定预算。
  static const double _staggerCompWindowSteps = 3.0;

  // ============== 关闭模式的级联轮次（预启动 / 回落共用一条时间线） ==============

  /// 当前活跃的级联轮次。null = 没有未走完的轮次。
  ///
  /// 预启动与固定窗口回落补偿统一到同一对象：两者只有 `anchorLine`、
  /// `scale`、`clockMs` 不同，释放判定走同一套公式，不再有跨轮的
  /// 「本轮是否由预启动建立」开关。
  _CascadeRound? _cascadeRound;

  /// 下一次预热的行索引（去重：同一目标只排一次 post-frame 回调）。
  int _prewarmTarget = -1;

  // ============== 快速连切兜底 ==============

  /// 当前行切换间隔小于该值（ms）时视为一次快速切行。
  ///
  /// 单次快速切行仍走弹簧（快歌偶发的密集行不应硬切）；只有**连续两次及以上**
  /// 快速切行才启动兜底。级联延迟（60~750ms）在连续快速切行时永远等不到释放，
  /// 等待行被抵消量一直钉住，表现为整块歌词「卡住」；此时直接瞬移到新行位置。
  static const double _fastSwitchThresholdMs = 300;

  /// 连续快速切行次数（间隔 < [_fastSwitchThresholdMs]）。
  ///
  /// 每次切行按当前间隔递增或清零；>= 2 时才走快速兜底。
  int _consecutiveFastSwitches = 0;

  /// 上一次检测到当前行索引变化的单调帧时钟（ms），-1 表示尚未记录。
  double _lastLineSwitchFrameMs = -1;

  /// 独立于 Ticker 生命周期的单调帧时钟（ms）。
  ///
  /// `Ticker` 停止后重启会把 `elapsed` 归零（[_startTickerIfNeeded] 同步重置
  /// `_lastElapsed`），直接用它测切行间隔会在非逐字歌词「停帧省电」场景
  /// 失效；本值每帧累加 dt，跨 Ticker 重启保持单调。
  double _frameClockMs = 0;

  /// 最近一次切行是否走了快速兜底（仅测试用）。
  bool _lastSwitchWasFast = false;

  /// 缩放弹簧上一帧覆盖的窗口 [_scaleWindowStart, _scaleWindowEnd)。
  ///
  /// 窗口外行在离开窗口时已被钉到稳态，后续帧只需处理「本帧离开窗口」的行，
  /// 不必每帧遍历全部歌词行。
  int _scaleWindowStart = 0;
  int _scaleWindowEnd = 0;

  /// 上一帧的缩放稳态值，用于检测 steady 变化（字体大小 / enableScale）。
  double _lastScaleSteady = double.nan;

  /// 预计算每行实际高度（含自动换行）。
  ///
  /// **性能优化**：只在 lines/fontSize/viewportWidth 变化时重算，
  /// 不再每帧重算（之前每帧 build 都跑 N 次 TextPainter.layout 是 CPU 杀手）。
  /// [_recomputeLineHeightsIfNeeded] 负责缓存命中判断。
  List<double> _lineHeights = const <double>[];

  /// 每行的换行计划（主歌词），索引与 `_cleanedLines` 对齐。
  ///
  /// 生产一次、四处消费：行高测量 / WordRenderer / LineRenderer / 模糊层。
  /// 断点只在这里算，任何消费方不得再自行数行（本仓重叠教训）。
  List<LyricWrapPlan> _wrapPlans = const <LyricWrapPlan>[];

  /// 每行副行（翻译/罗马音）的换行计划，索引同上；无副行文本时为空计划。
  List<LyricWrapPlan> _auxWrapPlans = const <LyricWrapPlan>[];

  /// 无副行文本时的占位计划（单行空文本），避免 `_auxWrapPlans` 出现 null 空洞。
  static final LyricWrapPlan _emptyPlan = LyricWrapPlan(
    rowStarts: const <int>[0],
    rowTexts: const <String>[''],
    rowWidths: const <double>[0],
    unitSpace: LyricUnitSpace.painterWrap,
  );

  List<double> _lineTops = const <double>[];

  /// 哪些行索引后面有间奏（gap >= thresholdMs）。
  ///
  /// 用于检测当前是否进入间奏时段（_activeInterludeAfterIndex）。
  /// 注意：只有激活间奏才占位高度（动态展开/收起），非激活间奏占位 = 0。
  ///
  /// 槽位值 = 间奏窗口**之前最后一行**的索引，占位落在该行之后。
  /// 首行之前的头部间奏没有"前一行"，用 [_interludeIntroIndex] 标记。
  List<int> _interludeAfterIndices = const <int>[];

  /// 头部间奏槽位标记：间奏窗口为 `[0, 首行起点 - 提前量)`，占位落在**首行之前**。
  ///
  /// 为什么需要："隐藏歌词作者信息"会把开头的制作名单行整块移除（见
  /// [LyricCreditFilter]），原本充当 gap 锚点的名单行（如 `[00:02]作词：…`）
  /// 随之消失，首行起点直接跳到 intro 之后，相邻行检测再也发现不了开头这段
  /// 空档 —— 表现为"开启开关后歌曲开头没有间奏点"。
  ///
  /// 它与普通槽位的区别：普通槽位是"占位在该行之后"，本槽位是"占位在所有行
  /// 之前"，因此 `_interludeOffsetBefore` 对**包括首行在内**的所有行返回占位
  /// 高度，圆点画在首行上方（首行在屏幕上保持居中不动，圆点自上方向其顶边收起）。
  static const int _interludeIntroIndex = -1;

  /// "从未激活间奏"的哨兵值（不能与 [_interludeIntroIndex] 的 -1 共用）。
  static const int _noInterludeAnchor = -2;

  // v3 优化：generation counter，列表内容变化时 +1。
  // shouldRepaint 用 counter 比较替代 listEquals O(n) 比较。
  int _linesGeneration = 0;
  int _lineHeightsGeneration = 0;
  int _lineTopsGeneration = 0;
  int _interludeAfterIndicesGeneration = 0;
  int _perLineOffsetsGeneration = 0;

  /// v3 优化：复用的 perLineOffsets 列表实例。
  /// _buildPerLineOffsets 不再 List.generate 创建新 List，而是更新此实例的内容。
  /// 减少 GC 压力 + 让 generation counter 准确反映内容变化。
  List<double> _reusedPerLineOffsets = const <double>[];

  /// 上一帧 [_buildPerLineOffsets] 实际写入的窗口 [start, end)。
  /// 用于在窗口滑动时清零落出窗口的残留偏移。
  int _offsetsWindowStart = 0;
  int _offsetsWindowEnd = 0;

  /// 持久化 painter 实例。
  /// 通过 [_textRepaint] 驱动重绘，避免每帧 setState + build 的 widget tree 开销。
  _LyricsPainter? _painter;

  /// 当前行层 painter（只画焦点行，逐字帧每帧重绘）。
  _LyricsPainter? _currentPainter;

  /// 模糊层画布合成器。
  ///
  /// 模糊层按行缓存烘焙图，位置 / 不透明度 / 副行进度全部逐帧变化；用 widget
  /// 表达每次变化都要重建 Stack，改成画布绘制后只重画纹理。
  _BlurLayersPainter? _blurPainter;

  /// 模糊图合成复用的 Paint（避免每帧新建对象）。
  final Paint _blurImagePaint = Paint()
    ..filterQuality = FilterQuality.medium;

  /// 文字层重绘信号源。
  ///
  /// 与模糊层分开：逐字 alpha 每帧变化只应重绘文字层，模糊层的输入在稳态
  /// 完全静止，不能跟着一起重画（那是每帧十几张全宽纹理 + 整屏合成）。
  final _RepaintNotifier _textRepaint = _RepaintNotifier();

  /// 文字层重绘信号源（仅当前行层，逐字帧每帧触发）。
  ///
  /// P1-1：文字层按「当前行 / 其余行」拆成两个 CustomPaint。逐字帧只重绘
  /// 当前行层，非当前行层保持静态位图，不再每帧重排、重栅格几十行。
  final _RepaintNotifier _currentTextRepaint = _RepaintNotifier();

  /// 模糊层重绘信号源（仅在模糊几何/透明度/图集变化时触发）。
  final _RepaintNotifier _blurRepaint = _RepaintNotifier();

  /// 模糊图烘焙队列（帧预算摊开，避免切行帧集中录制十余张全宽 Picture）。
  final List<({int lineIndex, int blurLevel, bool aux})> _blurBakeQueue =
      <({int lineIndex, int blurLevel, bool aux})>[];
  Timer? _blurBakeTimer;

  /// 每个 16ms 节拍最多发起的烘焙数。录制本身是同步的，必须限预算。
  static const int _blurBakeBudgetPerTick = 2;

  // 模糊层重绘门控的上次快照：只有这些值变化才需要重画模糊纹理。
  // 逐字 alpha / 文字 renderer 的变化不进这里。
  int _lastBlurRepaintLine = -1;
  bool _lastBlurRepaintVisualHold = false;
  bool _lastBlurRepaintHeadSlot = false;
  double _lastBlurRepaintPosY = double.nan;
  double _lastBlurRepaintBlurFade = double.nan;
  double _lastBlurRepaintEntryBlur = double.nan;
  double _lastBlurRepaintLevelFade = double.nan;
  double _lastBlurRepaintInterlude = double.nan;
  int _lastBlurRepaintAuxGeneration = -1;
  int _lastBlurRepaintActiveInterlude = 1;
  int _lastBlurRepaintAnchor = -999;

  /// 当前激活的间奏在 _interludeAfterIndices 中的索引（-1 表示无激活）。
  ///
  /// 严格 AMLL 逻辑：只有 currentTime 真正进入间奏时段
  /// （gapStart < now < gapEnd）才激活占位。
  /// 一激活就开始 spring 展开 0 → totalHeight，
  /// 间奏结束（now >= gapEnd）就 spring 收起 totalHeight → 0。
  int _activeInterludeIdx = -1;

  /// 最后激活的间奏 anchor 行索引。
  ///
  /// - `>= 0`：占位落在该行之后（普通行间间奏）；
  /// - [_interludeIntroIndex]（-1）：占位落在**首行之前**（头部间奏）；
  /// - [_noInterludeAnchor]（-2）：从未激活过。
  ///
  /// 用于间奏结束后 progress 收起期间继续计算占位偏移，
  /// 避免 `_interludeOffsetBefore` 在间奏一结束就立即返回 0 导致 targetY 突变。
  /// 当 `_interludeExpandProgress` 收起到 0 后重置为 [_noInterludeAnchor]。
  ///
  /// **为什么"从未激活"不能用 -1**：-1 现在是头部间奏的合法 anchor（占位在首行
  /// 之前），两者若共用同一个值，未激活时会把整屏行偏移一个占位高度。
  int _lastActiveAnchorIdx = _noInterludeAnchor;

  /// 间奏占位 spring 进度（0 = 完全收起，1 = 完全展开）。
  ///
  /// 用指数衰减逼近目标值，目标由 _activeInterludeIdx 决定：
  /// - 激活：target = 1.0
  /// - 未激活：target = 0.0
  /// 每帧 _onTick 中推进：progress += (target - progress) * (1 - exp(-speed * dt))
  /// speed = 18（300ms 内基本到位）
  double _interludeExpandProgress = 0;

  /// 逐行副行展开进度（0 = 完全收起，1 = 完全展开），索引与 [_cleanedLines] 对齐。
  ///
  /// 引入「副行显示范围」前本状态是单值（只有当前行有副行）。泛化为逐行数组后：
  /// - 目标值由 [resolveAuxTarget] 按 [LyricAuxScope] 给出（见 [_auxTargets]）；
  /// - 「收起余量 + 展开量 ≡ 预留总量」不变量由「下行行与上行行共用同一速率」维持，
  ///   于是稳态切行时当前行以下的行零位移（与原单值实现同一性质）；
  /// - 高度消费统一走 [_transExtraHeightFor] / [_transDeltaBefore]，两者都是
  ///   O(1)（后者用前缀和），所以主绘制循环 / 二分查找 / 间奏锚点零结构改动。
  Float64List _auxProgress = Float64List(0);

  /// 逐行副行目标进度，与 [_auxProgress] 同长度。
  ///
  /// 只在「当前行 / 范围 / 副行开关 / 显示模式 / 行数」变化时整体重算
  /// （[_auxTargetsSignature] 命中即跳过），稳态帧不产生任何目标计算。
  Float64List _auxTargets = Float64List(0);

  /// 尚未到达目标的行索引队列（只推进这些行，稳态为空 → 零成本）。
  final List<int> _auxAnimating = <int>[];

  /// 逐行副行高度前缀和：`_auxTopsPrefix[i] = Σ_{k<i} 副行高度 × 进度`。
  ///
  /// [_transDeltaBefore] 是主绘制循环里每行都要调用的热点（N 行 × 每帧），
  /// 逐行遍历会退化为 O(N²)；前缀和把查询压到 O(1)，脏标记保证每帧至多重算一次。
  Float64List _auxTopsPrefix = Float64List(1);
  bool _auxPrefixDirty = true;

  /// 逐行进度数值代次：任何行进度变化 +1，用于重绘与模糊层重建门控。
  int _auxProgressGeneration = 0;

  /// [_auxTargets] 的输入签名，用于检测是否需要重算目标。
  int _auxTargetsSignature = 0;

  /// 判定「已到位」的误差阈值（与原单值实现的 0.001 同口径）。
  static const double _auxSettleEpsilon = 0.001;

  /// 当前切行过渡的副行动画时长（ms），切行时按退场行时长捕获
  /// （[_auxTransitionMsForLine]：快歌短、慢歌最多 1s），收起与展开共用。
  ///
  /// 副行过渡用「固定时长 + smoothstep」而不是逐帧指数插值：指数插值首帧
  /// 就会跳出 10%~40% 的副行高度（速率越高跳得越多），把下方所有行整体
  /// 拽动一截——这是「上拉到位时速度突变、有翻译副行更明显」的直接来源。
  /// smoothstep 两端速度为 0，且收起/展开同时开始同一时长 → 两者进度之和
  /// 恒为 1，「收起余量 + 展开量 ≡ 预留总量」的下方行零位移不变量仍成立。
  double _auxSwitchDurationMs = 400.0;

  /// 逐行副行过渡的起点进度 / 起始帧时钟 / 时长（与 [_auxProgress] 同长度）。
  Float64List _auxTransFrom = Float64List(0);
  Float64List _auxTransStartMs = Float64List(0);
  Float64List _auxTransDurMs = Float64List(0);

  /// 间奏占位完全展开后的总高度（含上下 0.4em 边距，跟随 fontSize 缩放）。
  double _interludePlaceholderHeight = 0;

  // 缓存命中判断字段
  double _cachedFontSize = -1;
  double _cachedViewportWidth = -1;

  /// 行高系数缓存（`LyricLayout.lineHeight`，由字号与行间距共同决定）。
  ///
  /// 必须进缓存键：`lineHeight = (fontSize / defaultFontSize) * lineSpacing`，
  /// 只调行间距时 fontSize 不变，若不比较本值则缓存命中、行高/行顶不重算，
  /// 表现为"调行间距不刷新，必须再调一次字号才生效"。
  double _cachedLineHeight = -1;
  int _cachedLinesLength = -1;
  Object? _cachedLinesRef;
  // 字体缓存：字体变化时强制重算行高 + 失效所有模糊图片缓存
  // （TextPainter 用 fontFamily 测量，旧缓存会与新字体渲染尺寸不一致）
  String? _cachedFontFamily;
  // 字重缓存：字重变化时同样需强制重算行高 + 失效模糊图片缓存
  int _cachedFontWeight = -1;
  // 副行布局缓存：displayMode 切换也需重算（虽副行高度不变，但需触发重绘）
  LyricDisplayMode _cachedDisplayMode = LyricDisplayMode.translation;
  bool _cachedLineBalance = true;

  /// 返回指定行索引上方所有激活间奏占位的累计高度。
  ///
  /// **progress 驱动**：只要 `_interludeExpandProgress > 0` 就返回占位高度，
  /// 不依赖 `_activeInterludeIdx`。这样间奏结束后 progress 缓慢收起到 0 期间，
  /// 占位偏移也跟随平滑收起，posY target 不会突变。
  ///
  /// 使用 `_lastActiveAnchorIdx` 记录最后激活的间奏 anchor，
  /// 避免影响其他未激活间奏的占位。anchor 为 [_interludeIntroIndex]（-1，
  /// 头部间奏：占位在首行之前）时，**所有行**（含首行）都让位一个占位高度。
  ///
  /// 高度 = _interludePlaceholderHeight × _interludeExpandProgress
  double _interludeOffsetBefore(int lineIndex) {
    if (_interludeExpandProgress <= 0) return 0;
    final int anchorIdx = _lastActiveAnchorIdx;
    // -1（首行之前）< 任何合法 lineIndex → 落到下面的通用分支返回占位高度
    if (anchorIdx == _noInterludeAnchor || anchorIdx >= lineIndex) return 0;
    return _interludePlaceholderHeight * _interludeExpandProgress;
  }

  /// 头部间奏（首行之前）是否正在占据「焦点槽位」。
  ///
  /// 成立期间**没有任何歌词行处于激活态**：焦点是间奏圆点，首行按「尚未唱到的
  /// 下行」渲染（暗态 + 模糊）。否则首行会在圆点下方保持高亮清晰、不参与模糊，
  /// 看起来像"已经开唱"——与未过滤时首行位于名单行下方（模糊暗态）不一致。
  bool get _introInterludeOwnsSlot =>
      _activeInterludeIdx >= 0 &&
      _activeInterludeIdx < _interludeAfterIndices.length &&
      _interludeAfterIndices[_activeInterludeIdx] == _interludeIntroIndex;

  /// 渲染口径的焦点行索引：-1 = 焦点由头部间奏占位占据（没有行激活）。
  ///
  /// 只在「谁是当前行」的渲染判定（激活态 / 缩放 / 模糊等级 / 副行目标）里替换
  /// `_currentLineIndex`；滚动目标仍用 `_currentLineIndex`（首行居中、圆点在上方），
  /// 避免引入"无当前行"导致滚动停摆。
  int get _focusLineIndex =>
      _introInterludeOwnsSlot ? _interludeIntroIndex : _currentLineIndex;

  /// 间奏占位行是否仍在屏幕上（展开中 / 完全展开 / 收缩中）。
  ///
  /// 与「是否处于激活窗口内」的区别：窗口结束后占位还要花 ~750ms 收缩，
  /// 这段时间 anchor 仍在、progress > 0，**滚动目标必须继续按占位行计算**，
  /// 否则收缩中途目标跳回歌词行，圆点会横向漂一段。
  ///
  /// 头部间奏（anchor = -1）与歌曲中间的间奏（anchor >= 0）一视同仁：
  /// 占位行就是"当前行"——圆点落在「当前行位置」偏好上，前后歌词分别在
  /// 其上下（见 [_interludeSlotTop]）。
  bool get _interludeSlotVisible =>
      _lastActiveAnchorIdx != _noInterludeAnchor && _interludeExpandProgress > 0;

  /// 间奏占位行在内容坐标里的顶部 y。
  ///
  /// - 头部间奏（anchor = -1，占位在所有行之前）：内容原点 0；
  /// - 行间间奏：anchor 行底部（含 anchor 行上方的副行动画高度与间奏偏移）。
  ///
  /// 与 painter 画点的 `anchorBottomY` 同口径，保证"滚动目标对准的占位行"
  /// 与"圆点实际画进的那一行"是同一行。
  double _interludeSlotTop(int anchorIdx) {
    if (anchorIdx < 0 || anchorIdx >= _lineTops.length) return 0;
    final double anchorHeight = anchorIdx < _lineHeights.length
        ? _lineHeights[anchorIdx]
        : 0;
    return _lineTops[anchorIdx] +
        anchorHeight +
        _transDeltaBefore(anchorIdx) +
        _interludeOffsetBefore(anchorIdx);
  }

  /// 每行副行（翻译/罗马音）预留高度（含过长换行），索引与 [_cleanedLines] 对齐。
  ///
  /// 公式见 [LyricLayout.auxSubHeight]：`rows × transFontSize × 1.5 + 0.3em 间隙`，
  /// rows 为该行副行在可用宽度内的实际视觉行数。行高缓存恒按纯主行测量，
  /// 副行占位由本值 × 动画进度每帧动态叠加。
  /// **逐行取值**：不同行的副行行数不同（有的一行、有的换行成 2~3 行），
  /// 用单一"单行高度"会让换行副行压到下一行歌词上（行距未调整）。
  List<double> _auxSubHeights = const <double>[];

  /// 第 i 行的副行预留高度（无副行文本/越界 → 0）。
  double _auxSubHeightOf(int i) =>
      (i >= 0 && i < _auxSubHeights.length) ? _auxSubHeights[i] : 0;

  /// 指定行是否有副行文本（翻译或罗马音，按 displayMode）。
  bool _lineHasAuxText(int i) {
    if (i < 0 || i >= _cleanedLines.length) return false;
    final line = _cleanedLines[i];
    final String? aux =
        LyricPreferences.instance.displayMode == LyricDisplayMode.roma
        ? line.roma
        : line.translation;
    return aux != null && aux.isNotEmpty;
  }

  /// 第 i 行的副行当前展开进度（越界 → 0）。
  double _auxProgressAt(int i) =>
      (i >= 0 && i < _auxProgress.length) ? _auxProgress[i] : 0.0;

  /// 第 i 行的副行目标进度（越界 → 0）。
  double _auxTargetAt(int i) =>
      (i >= 0 && i < _auxTargets.length) ? _auxTargets[i] : 0.0;

  /// 第 i 行的副行是否正在收起（目标 < 当前进度）。
  ///
  /// 收起期间副行模糊图的块几何 / 翻转锚点与清晰副行不同步（用户实测错位），
  /// 因此收起中的副行一律不画模糊图，由清晰层跟随收起。
  bool _auxExitingAt(int i) => _auxTargetAt(i) < _auxProgressAt(i) - 1e-4;

  /// 第 i 行的副行模糊图是否应参与烘焙/绘制：有可见进度且不在收起中。
  /// 仅测试用：验证收起中的副行不占用模糊渲染。
  @visibleForTesting
  bool auxBlurVisibleForTest(int i) => _auxBlurVisibleAt(i);

  /// 第 i 行的副行模糊图是否应参与烘焙/绘制：有可见进度且不在收起中。
  bool _auxBlurVisibleAt(int i) =>
      _auxProgressAt(i) > 0.001 && !_auxExitingAt(i);

  /// 第 i 行因副行动画产生的额外高度（行高消费点叠加）。
  ///
  /// 每行独立使用**该行自身的**副行预留高度（[_auxSubHeightOf]，已含换行行数），
  /// 乘该行当前进度——「所有行」与「已播行除外」都靠这一条公式自然成立，
  /// 不存在静态预留导致的切行跳位。
  ///
  /// **不读 showTranslation 做立即短路**：关闭副行时目标变 0、进度指数衰减到 0，
  /// 高度跟随动画平滑收起；若在此短路，关闭瞬间高度会直接塌缩。
  double _transExtraHeightFor(int i) {
    return _auxSubHeightOf(i) * _auxProgressAt(i);
  }

  /// 第 i 行上方所有副行动画高度之和（行 top 消费点叠加）。
  ///
  /// 逐行进度下改为前缀和查询（O(1)），见 [_auxTopsPrefix]。
  /// **不读 showTranslation 短路**（理由同 [_transExtraHeightFor]）。
  double _transDeltaBefore(int i) {
    if (i <= 0) return 0;
    _ensureAuxPrefix();
    final int last = _auxTopsPrefix.length - 1;
    if (last <= 0) return 0;
    return _auxTopsPrefix[i < last ? i : last];
  }

  /// 惰性重建副行高度前缀和（O(N)，仅在进度/副行高度变化后首次查询时执行）。
  void _ensureAuxPrefix() {
    if (!_auxPrefixDirty) return;
    final int n = _auxSubHeights.length;
    if (_auxTopsPrefix.length != n + 1) {
      _auxTopsPrefix = Float64List(n + 1);
    }
    double acc = 0;
    _auxTopsPrefix[0] = 0;
    for (int i = 0; i < n; i++) {
      acc += _auxSubHeightOf(i) * _auxProgressAt(i);
      _auxTopsPrefix[i + 1] = acc;
    }
    _auxPrefixDirty = false;
  }

  /// 按副行显示范围重算逐行目标值（只在签名变化时调用）。
  void _rebuildAuxTargets() {
    final int n = _cleanedLines.length;
    if (_auxTargets.length != n) _auxTargets = Float64List(n);
    if (_auxProgress.length != n) {
      final Float64List next = Float64List(n);
      final int copy = math.min(n, _auxProgress.length);
      for (int i = 0; i < copy; i++) {
        next[i] = _auxProgress[i];
      }
      _auxProgress = next;
    }
    if (_auxTransFrom.length != n) _auxTransFrom = Float64List(n);
    if (_auxTransStartMs.length != n) _auxTransStartMs = Float64List(n);
    if (_auxTransDurMs.length != n) _auxTransDurMs = Float64List(n);
    final prefs = LyricPreferences.instance;
    final LyricAuxScope scope = prefs.auxScope;
    final bool enabled = prefs.showTranslation;
    final int current = _focusLineIndex;
    _auxAnimating.clear();
    for (int i = 0; i < n; i++) {
      final double t = resolveAuxTarget(
        scope: scope,
        enabled: enabled,
        hasAuxText: _lineHasAuxText(i),
        lineIndex: i,
        currentLineIndex: current,
      );
      // 目标变化：以当前进度为起点、本帧为时间锚，重新计时一段过渡。
      // 收起与展开在同一帧改目标 → 共用同一时长，进度之和恒为 1。
      if ((t - _auxTargets[i]).abs() > 1e-6) {
        _auxTransFrom[i] = _auxProgress[i];
        _auxTransStartMs[i] = _frameClockMs;
        _auxTransDurMs[i] = _auxSwitchDurationMs;
      }
      _auxTargets[i] = t;
      if ((t - _auxProgress[i]).abs() > _auxSettleEpsilon) {
        _auxAnimating.add(i);
      }
    }
    _auxPrefixDirty = true;
  }

  /// 目标计算的输入签名：任一变化都会改变逐行目标，需要整体重算。
  int _auxTargetsSignatureNow() {
    final prefs = LyricPreferences.instance;
    return Object.hash(
      _focusLineIndex,
      prefs.auxScope,
      prefs.showTranslation,
      prefs.displayMode,
      _cleanedLines.length,
      _auxSubHeights.length,
    );
  }

  /// 行数 / 歌词变化后重建进度缓冲：初值直接吸附到目标，不播放入场动画
  /// （切歌或改字号时整屏副行不应「再长一遍」）。
  void _resetAuxProgressBuffers() {
    final int n = _cleanedLines.length;
    _auxProgress = Float64List(n);
    _auxTargets = Float64List(n);
    _auxTopsPrefix = Float64List(n + 1);
    _auxTransFrom = Float64List(n);
    _auxTransStartMs = Float64List(n);
    _auxTransDurMs = Float64List(n);
    _auxAnimating.clear();
    _auxPrefixDirty = true;
    _auxTargetsSignature = 0;
    _rebuildAuxTargets();
    for (int i = 0; i < n; i++) {
      _auxProgress[i] = _auxTargets[i];
    }
    _auxAnimating.clear();
    _auxPrefixDirty = true;
    _auxProgressGeneration++;
  }

  /// 把所有行直接吸附到目标（快速连切 / seek 大跳兜底，不播放过渡）。
  void _snapAuxProgressToTargets() {
    bool changed = false;
    for (int i = 0; i < _auxProgress.length; i++) {
      final double t = _auxTargetAt(i);
      if (_auxProgress[i] != t) {
        _auxProgress[i] = t;
        changed = true;
      }
    }
    _auxAnimating.clear();
    if (changed) {
      _auxPrefixDirty = true;
      _auxProgressGeneration++;
    }
  }

  /// 推进逐行副行进度（步骤 7.5）。
  ///
  /// 过渡 = 固定时长 + smoothstep（时间锚与目标改动在同一帧写入）：
  /// - 两端速度为 0：切行首帧不会像指数插值那样一次跳出 10%~40% 的副行
  ///   高度，下方行不会被整体拽动（「上拉到位速度突变」的根因）；
  /// - 收起/展开共用同一时长与时间锚 → 两者进度之和恒为 1，
  ///   「收起余量 + 展开量 ≡ 预留总量」的下方行零位移不变量仍成立；
  /// - 暂停时照常推进（切范围是用户主动操作，不是播放驱动），收敛后由门控
  ///   停 Ticker，不产生持续重绘。
  void _advanceAuxProgress(double dt, {required bool fastLineSwitch}) {
    final int sig = _auxTargetsSignatureNow();
    if (sig != _auxTargetsSignature) {
      _auxTargetsSignature = sig;
      _rebuildAuxTargets();
    }
    if (_auxAnimating.isEmpty) return;
    if (fastLineSwitch) {
      _snapAuxProgressToTargets();
      return;
    }
    final double now = _frameClockMs;
    bool changed = false;
    for (int k = _auxAnimating.length - 1; k >= 0; k--) {
      final int i = _auxAnimating[k];
      final double t = _auxTargetAt(i);
      final double dur = _auxTransDurMs[i];
      final double x = dur <= 0.001
          ? 1.0
          : ((now - _auxTransStartMs[i]) / dur).clamp(0.0, 1.0);
      // smoothstep：3x²−2x³，两端一阶导为 0。
      final double e = x * x * (3 - 2 * x);
      final double p = _auxTransFrom[i] + (t - _auxTransFrom[i]) * e;
      final double next = x >= 1.0 ? t : p;
      if (x >= 1.0) {
        _auxAnimating.removeAt(k);
      }
      final double old = _auxProgress[i];
      if (next != old) {
        _auxProgress[i] = next;
        changed = true;
      }
    }
    if (changed) {
      _auxPrefixDirty = true;
      _auxProgressGeneration++;
    }
  }

  /// 副行收起/展开的过渡时长（ms）：行时长的 40%，夹在 [60, 1000]。
  double _auxTransitionMsForLine(int lineDurationMs) {
    double ms = lineDurationMs > 0 ? lineDurationMs * 0.4 : 1000.0;
    if (ms > 1000) ms = 1000;
    if (ms < 60) ms = 60;
    return ms;
  }

  /// 根据 fontSize/viewportWidth/lines 变化判断是否需要重算 lineHeights/lineTops。
  ///
  /// 命中缓存时直接 return，避免每帧 N 次 TextPainter.layout（N=歌词行数）。
  /// 50 行歌词 × 60fps = 每秒 3000 次 layout → 缓存后降为 0 次/帧。
  ///
  /// 同时检测相邻行间隔 >= [LyricLayout.interludeThresholdMs] 的位置，
  /// 记录到 [_interludeAfterIndices]。占位高度动态展开/收起（不在这里固定）。
  void _recomputeLineHeightsIfNeeded(double fontSize, double viewportWidth) {
    final identitySame = identical(_cleanedLines, _cachedLinesRef);
    final currentFontFamily = LyricLayout.fontFamily;
    final currentFontWeight = LyricLayout.fontWeight.value;
    final currentLineHeight = LyricLayout.lineHeight;
    final currentDisplayMode = LyricPreferences.instance.displayMode;
    final currentLineBalance = LyricPreferences.instance.lineBalance;
    if (currentDisplayMode != _cachedDisplayMode) {
      debugPrint(
        '[RomaToggle] AppleLyricsView displayMode 变化: $_cachedDisplayMode -> $currentDisplayMode',
      );
    }
    if (fontSize == _cachedFontSize &&
        viewportWidth == _cachedViewportWidth &&
        currentLineHeight == _cachedLineHeight &&
        _cleanedLines.length == _cachedLinesLength &&
        identitySame &&
        _lineHeights.length == _cleanedLines.length &&
        currentFontFamily == _cachedFontFamily &&
        currentFontWeight == _cachedFontWeight &&
        currentDisplayMode == _cachedDisplayMode &&
        currentLineBalance == _cachedLineBalance) {
      return; // 缓存命中
    }
    _cachedFontSize = fontSize;
    _cachedViewportWidth = viewportWidth;
    _cachedLineHeight = currentLineHeight;
    _cachedLinesLength = _cleanedLines.length;
    _cachedLinesRef = _cleanedLines;
    _cachedFontFamily = currentFontFamily;
    _cachedFontWeight = currentFontWeight;
    _cachedDisplayMode = currentDisplayMode;
    _cachedLineBalance = currentLineBalance;

    // v3 优化：列表内容变化时递增 generation counter。
    // lines 用 identical 比较，只有引用变化才递增；
    // lineHeights/lineTops/interludeAfterIndices 每次重算都递增。
    if (!identitySame) {
      _linesGeneration++;
    }
    _lineHeightsGeneration++;
    _lineTopsGeneration++;
    _interludeAfterIndicesGeneration++;
    // 行集 / 字号 / 视口 / 字体 / 副行模式任一变化都会让已烘焙的副行清晰图
    // 口径失效（文本、换行、行高都可能变）：整体释放，下一帧重新预热。
    _clearAuxTextImages();

    final maxLineWidth = LyricLayout.maxLineWidth(viewportWidth, fontSize);
    final mainLineHeight = fontSize * LyricLayout.lineHeight;
    // 间奏占位总高度 = 点高度 + 上下 0.4em 边距
    // 点高度约 2 * dotRadius = 2 * fontSize * 0.08 = 0.16em
    // 边距 = 0.8em
    // 总高度约 0.96em，约等于 1 倍主行高
    _interludePlaceholderHeight = mainLineHeight * 1.0;
    final List<double> heights = <double>[];
    final List<double> tops = <double>[];
    final List<int> interludeIndices = <int>[];
    // 头部间奏（首行之前）：首行起点距歌曲开头超过阈值时补一个间奏槽位。
    // 「隐藏歌词作者信息」移除开头名单行后，相邻行检测只剩"行与行之间"的
    // gap，开头的空档没有锚点 → 歌曲开头没有间奏点（见 [_interludeIntroIndex]）。
    // 未过滤 / 无名单行的歌词同样适用：长前奏本就该有节奏点。
    if (widget.enableInterludeDots &&
        _cleanedLines.isNotEmpty &&
        _cleanedLines.first.startTime >= LyricLayout.interludeThresholdMs) {
      interludeIndices.add(_interludeIntroIndex);
    }
    final List<LyricWrapPlan> plans = <LyricWrapPlan>[];
    final TextStyle mainStyle = LyricLayout.mainStyle(fontSize);
    double acc = 0;
    for (int i = 0; i < _cleanedLines.length; i++) {
      final line = _cleanedLines[i];
      // 行高恒按"纯主行"测量：翻译副行预留不再进静态缓存，改由
      // _transExtraHeightFor（展开/收起进度）每帧动态叠加。副行占位随动画
      // 平滑增长/回落，消除行切换时高度瞬间换位导致的位置闪现。
      // 行数取自换行计划；同一份计划还会被逐字 / 整行 / 模糊三条绘制路径消费，
      // 于是「测量的行数 == 画出的行数」由结构保证（本仓重叠教训）。
      final LyricWrapPlan plan = LyricWrapPlanner.forLine(
        line,
        mainStyle,
        maxLineWidth,
        balanced: currentLineBalance,
      );
      plans.add(plan);
      heights.add(LyricLayout.lineHeightForRows(mainLineHeight, plan.rowCount));
      tops.add(acc);
      acc += heights.last;
      // 检测当前行与下一行之间是否有间奏（最后一行后面无间奏）
      // 间奏点关闭时跳过检测，_interludeAfterIndices 保持为空，
      // _updateInterlude 自然不会激活任何间奏，节奏点不会出现。
      if (widget.enableInterludeDots && i < _cleanedLines.length - 1) {
        final next = _cleanedLines[i + 1];
        // 用"人声实际结束时间"而非 endTime（KRC 行 duration 常覆盖尾音/空白，
        // 会把真实 gap 压缩导致间奏点识别不到，见 effectiveLineEndTime）
        final gap = next.startTime - AppleLyricsView.effectiveLineEndTime(line);
        if (gap >= LyricLayout.interludeThresholdMs) {
          interludeIndices.add(i);
        }
      }
    }
    _wrapPlans = plans;
    _lineHeights = heights;
    _lineTops = tops;
    _interludeAfterIndices = interludeIndices;
    // 逐行副行预留高度（含过长换行）：按 displayMode 取翻译或罗马音，
    // 用实际视觉行数 × 副行行高 + 0.3em 间隙。仅在副行文本非空时测量，
    // 无翻译/罗马音的歌零额外开销。此值在动画中按进度逐行叠加（见
    // [_transExtraHeightFor]），也是 renderer 副行"长出"位移的取值来源。
    final List<double> auxHeights = List<double>.filled(
      _cleanedLines.length,
      0,
    );
    final List<LyricWrapPlan> auxPlans = List<LyricWrapPlan>.filled(
      _cleanedLines.length,
      _emptyPlan,
    );
    final TextStyle auxStyle = LyricLayout.auxStyle(fontSize);
    for (int i = 0; i < _cleanedLines.length; i++) {
      final line = _cleanedLines[i];
      final String? auxText = currentDisplayMode == LyricDisplayMode.roma
          ? line.roma
          : line.translation;
      if (auxText == null || auxText.isEmpty) continue;
      final LyricWrapPlan auxPlan = LyricWrapPlanner.forText(
        auxText,
        auxStyle,
        maxLineWidth,
        balanced: currentLineBalance,
      );
      auxPlans[i] = auxPlan;
      auxHeights[i] = LyricLayout.auxSubHeight(fontSize, auxPlan.rowCount);
    }
    _auxSubHeights = auxHeights;
    _auxWrapPlans = auxPlans;
    // 副行预留高度重算 → 前缀和必然失效。行数变化时整体重建进度缓冲
    // （旧行索引不再对应新歌词）；仅字号/行距变化时保留现有进度，
    // 避免调滑块时整屏副行「重新长一遍」。
    _auxPrefixDirty = true;
    if (_auxProgress.length != _cleanedLines.length) {
      _resetAuxProgressBuffers();
    }
    // 重置激活间奏（lines 变化时）
    _activeInterludeIdx = -1;
    _lastActiveAnchorIdx = _noInterludeAnchor;
    _interludeExpandProgress = 0;
  }

  @override
  void initState() {
    super.initState();
    // 初值：按歌曲 BPM / 歌词字长解析辉光触发阈值（切歌时 didUpdateWidget 重算）
    _glowThresholdMs = EmphasizeEffect.resolveThresholdMs(
      lines: widget.lines,
      songBpm: widget.songBpm,
    );
    // createTicker 由 SingleTickerProviderStateMixin 提供，
    // 在 widget 不可见时自动暂停（muted），节省 CPU。
    _ticker = createTicker(_onTick);
    // 帧时钟基准：必须在启动驱动源前归零，避免 eco Timer 首帧读到未初始化值。
    _lastElapsed = Duration.zero;
    // 省电模式：挂载即按当前 eco 偏好确定性建立驱动源——eco 开且锁定 → 直接起
    // 不依赖 vsync 的 60fps eco Timer；eco 关 → 起满帧 Ticker。不再裸调
    // _startTickerIfNeeded()：否则在无 Surface 的 headless 引擎（升级后常见拉起路径）
    // 里 Ticker 被 mute、_onTick 从不触发，限帧自我纠正失效，页面停在 120Hz，
    // 必须拨动开关才恢复。改走 _syncEcoDriver() 与拨动开关走同一条路径。
    _syncEcoDriver();
    // P0-A：监听 App 生命周期——退后台挂起驱动源、回前台恢复（见 _syncEcoDriver）
    WidgetsBinding.instance.addObserver(this);
    // 自动回弹触发时恢复模糊（由 _computeLineBlur 自动处理）
    _scrollController.onAutoReturn = () {};
    // 解耦：初始化权威时间；提供 positionListenable 时内部订阅位置更新
    _authorityTimeMs = widget.currentTimeMs;
    final listenable = widget.positionListenable;
    if (listenable != null) {
      _readAuthorityFrom(listenable);
      listenable.addListener(_onExternalPosition);
    }
    // 监听字号/行间距偏好变化，实时刷新（设置页滑块、长按菜单调节后立即生效）
    LyricPreferences.instance.addListener(_onPreferencesChanged);
    // 加固：首帧后再确认一次驱动源，覆盖 headless 挂载 → 前台 attach 过渡期
    // 可能出现的驱动源漂移（如 attach 后 TickerMode 变化意外拉起 Ticker）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncEcoDriver();
    });
  }

  /// P0-A：跟踪 TickerMode（TabBarView 切走时 Ticker 自动 mute，Timer 需同步挂起）。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool muted = !TickerMode.of(context);
    if (muted != _tickerModeMuted) {
      _tickerModeMuted = muted;
      _syncEcoDriver();
    }
  }

  /// P0-A：App 退后台挂起驱动源，回前台恢复（见 _syncEcoDriver）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final bool suspended =
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached;
    if (suspended == _lifecycleSuspended) return;
    _lifecycleSuspended = suspended;
    _syncEcoDriver();
  }

  /// v3 优化：幂等启动 Ticker。
  /// 在恢复播放、用户交互、lines 变化等场景调用。
  void _startTickerIfNeeded() {
    if (_isTickerRunning) return;
    _isTickerRunning = true;
    _lastElapsed = Duration.zero;
    _ticker.start();
  }

  /// v3 优化：幂等停止 Ticker。
  /// 在暂停且所有动画收敛后调用，节省 CPU。
  void _stopTickerIfNeeded() {
    if (!_isTickerRunning) return;
    _isTickerRunning = false;
    _ticker.stop();
  }

  /// 从 listenable 读取并校正权威时间。
  void _readAuthorityFrom(ValueListenable<Duration> listenable) {
    final raw = listenable.value;
    _authorityTimeMs = widget.adaptTimeMs?.call(raw) ?? raw.inMilliseconds;
  }

  /// positionNotifier 每 ~200ms 回调：仅更新权威时间并唤醒驱动源，
  /// 不触发 setState（视觉更新由 _onTick → repaintNotifier 快路径完成）。
  /// 唤醒语义对齐原 didUpdateWidget 的 currentTimeMs 分支（含 eco 锁定判断）。
  void _onExternalPosition() {
    final listenable = widget.positionListenable;
    if (listenable == null || !mounted) return;
    final prev = _authorityTimeMs;
    _readAuthorityFrom(listenable);
    if (_authorityTimeMs == prev) return;
    // 无驱动源产帧时（非逐字歌词播放中「收敛停帧」省电：Ticker 已停、eco Timer
    // 未绑定）帧时钟不推进，[_onTick] 里的平滑校正拿不到 dt（重启后的首帧
    // dt=0）→ [_smoothPosMs] 会长时间冻结（实测可滞后数秒），而预启动窗口按
    // `leadMs = nextStart − smoothPos` 判定，冻结会让窗口**永不开启**：预启动
    // 完全失效、每个边界退化为回落路径把视口行重新按住 → 换行"打断错峰"
    // （真机实录 QQ20261107-230339；此时 smoothPos 实测可滞后数秒）。
    // 此刻没有任何帧在渲染，平滑（为逐字边界防抖而设）没有意义：对齐权威，
    // 保证唤醒出帧时时钟就是真实播放位置（小幅回退不采纳，见下方分支）。
    if (!_isTickerRunning && !_ecoDriverBound) {
      // 无驱动源时平滑没有意义：权威值前进或真实回退超出大跳变阈值时对齐；
      // 死区内的小幅回退不采纳，避免暂停收敛停帧把字内渐变往回拉。
      if (_authorityTimeMs >= _smoothPosMs ||
          _smoothPosMs - _authorityTimeMs > _smoothPosSeekJumpMs) {
        _smoothPosMs = _authorityTimeMs.toDouble();
      }
      _lastAuthorityPosMs = _authorityTimeMs;
    }
    if (widget.isPlaying) {
      // 统一走 _syncEcoDriver：锁定 → 确保 60fps Timer；解锁/关闭 → Ticker 满帧
      _syncEcoDriver();
    }
  }

  /// 省电模式驱动源同步：在 Ticker（满帧）与 60fps Timer 之间切换。
  ///
  /// - 页面不可见（TabBarView 切走 / App 退后台）→ 挂起全部驱动源（P0-A）
  /// - eco 开启且锁定 → 停 Ticker，用 16.67ms Timer 驱动 _onTick，
  ///   把实际帧生产限制到 60fps（Ticker 每帧 scheduleFrame 会让 120Hz 屏
  ///   始终 120fps，仅节流 _onTick 计算省不掉帧）。
  /// - 解锁 / eco 关闭 → 取消 Timer，恢复 Ticker 满帧。
  ///
  /// 所有"唤醒驱动"的路径一律走本方法，保证任意时刻至多一个驱动源：
  /// 裸调 _startTickerIfNeeded 会出现 Ticker + Timer 并存，而 Ticker 被
  /// TickerMode mute 时 _onEcoTimerTick 会因 _isTickerRunning 持续早退，
  /// 驱动源实质失效（"切歌后省电模式失效、须重新开关"的一类根因）。
  void _syncEcoDriver() {
    // P0-A：不可见时挂起。Ticker 此刻本就被 TickerMode/引擎 mute（不回调、
    // 不产帧），Timer 则不受任何可见性约束，必须显式取消——否则逐字播放中
    // （恒不收敛）切走 tab / 退后台后仍以 60Hz 驱动 _onTick → 离屏重绘。
    if (_lifecycleSuspended || _tickerModeMuted) {
      _resumeGapPending = true;
      if (_ecoDriverBound) {
        PlayerFrameDriver.instance.removeListener(_onEcoFrameTick);
        _ecoDriverBound = false;
      }
      _blurBakeTimer?.cancel();
      _blurBakeTimer = null;
      return;
    }
    final bool wantTimer = LyricPreferences.instance.ecoMode && !_ecoUnlocked;
    if (wantTimer) {
      if (_isTickerRunning) {
        _stopTickerIfNeeded();
      }
      if (!_ecoDriverBound) {
        // 挂在共享节拍上：与封面旋转/频谱同相位，避免两个独立 16ms Timer
        // 交错产帧把整页推到 120fps（各组件更新率仍为 60fps，无视觉降级）。
        PlayerFrameDriver.instance.addListener(_onEcoFrameTick);
        _ecoDriverBound = true;
      }
    } else {
      if (_ecoDriverBound) {
        PlayerFrameDriver.instance.removeListener(_onEcoFrameTick);
        _ecoDriverBound = false;
      }
      if (!_isTickerRunning) {
        // 复用幂等启动：Ticker 重启后首帧回调传 elapsed=0，必须重置 _lastElapsed
        // 使首帧 dt=0，否则会算出负 dt（blurFade 指数爆炸超出 [0,1]）。
        _startTickerIfNeeded();
      }
    }
    // 回前台 / 切回本 tab：继续抽干挂起的烘焙队列。
    if (_blurBakeQueue.isNotEmpty) _pumpBlurBakeQueue();
  }

  /// eco 锁定态下由共享 60fps 帧驱动推进：以 16ms 步进推进帧时钟，调用 [_onTick]。
  void _onEcoFrameTick() {
    if (!mounted) return;
    if (_isTickerRunning) {
      // Ticker 与 Timer 并存：Timer 被 _isTickerRunning 阻塞，本帧不驱动。
      return;
    }
    // 用 _lastElapsed + 16ms 作为本帧时间：_onTick 内 dt 即 16ms，动画按真实时间推进
    _onTick(_lastElapsed + PlayerFrameDriver.step);
  }

  /// v3 优化：检测所有 perLine 偏移弹簧是否已收敛。
  /// P0 修复：只检查视口范围内的弹簧（与 _onTick 的 tick 范围一致，±15 行）。
  /// 此前遍历所有 _perLineSprings：行切换时为当前行下方所有行创建弹簧，
  /// 但视口外的弹簧从不被 tick → 永远 isSettled=false →
  /// 收敛检测恒 false → 暂停后 Ticker 永不停止 → 每帧重绘 → 功耗降不下来。
  bool _arePerLineSpringsConverged() {
    final int overscan = _overscan;
    final int startI = _cascadeTopLine;
    final int endI = math.min(
      widget.lines.length,
      _currentLineIndex + overscan,
    );
    for (int i = startI; i < endI; i++) {
      // 等待期内弹簧不被 tick、值恒定，但有效偏移非 0（抵消量在变），
      // 必须计入未收敛，否则 Ticker 会在级联中途停掉、歌词卡在抵消位。
      final start = _delayStartTimes[i];
      if (start != null && start >= 0) return false;
      final spring = _perLineSprings[i];
      if (spring != null && !spring.isSettled) return false;
    }
    return true;
  }

  /// 所有行的 scale 弹簧是否已收敛（供停 Ticker 判定）。
  ///
  /// 每行独立持有 scale 弹簧后，离场/进场的缩放动画未收敛前不能停 Ticker。
  /// 只检查当前行 ± overscan 窗口：窗口外弹簧在离开窗口时已被钉到稳态，
  /// 无需每帧遍历全表（长歌词 200+ 行时是纯白耗）。
  bool _arePerLineScalesConverged() {
    final int len = widget.lines.length;
    final int startI = math.max(0, _currentLineIndex - _overscan);
    final int endI = math.min(len, _currentLineIndex + _overscan);
    for (int i = startI; i < endI; i++) {
      final Spring? s = _perLineScaleSprings[i];
      if (s != null && !s.isSettled) return false;
    }
    return true;
  }

  /// 推进每行独立的 scale 弹簧，并填充 [_reusedPerLineScales]。
  ///
  /// 返回是否有任一行仍在运动（供重绘门控与收敛判定）。
  ///
  /// 相比旧的单实例 LineScaleController 只服务当前行，这里每行都有自己的弹簧：
  /// - 进场行（非当前 0.850 → 当前）：target 变 activeScale，从 0.850 平滑放大到 1.0；
  /// - 离场行（当前 1.0 → 非当前）：target 变 inactiveScale，从 1.0 平滑缩到 0.850，
  ///   补上原来"当前行缩小时硬切"的连贯动画。
  /// 只推进当前行 ± overscan 窗口内的行（与 renderer/偏移同范围）；
  /// 窗口外的行钉在稳态 inactive——绘制按视口裁剪，与当前行无关，用户手动
  /// 滚动到远处时窗口外行不能停留在建表初始值 1.0（否则出现"没缩小"的行）。
  ///
  /// [snap] 为 true（快速连切兜底）时不做弹簧推进，窗口内直接瞬变到目标。
  bool _tickPerLineScales(double dt, {bool snap = false}) {
    final int len = widget.lines.length;
    final double active = LyricLayout.activeScale;
    final double inactive = widget.enableScale
        ? LyricLayout.inactiveScale
        : active;
    // 清晰层 canvas.scale 与 AM 模糊层 Transform.scale 共用本数组，钳在写入处即两层同尺
    final double minLegible = _minLegibleLineScale(
      _cachedFontSize > 0 ? _cachedFontSize : LyricLayout.fontSize(context),
    );
    // 窗口外行的稳态值：非当前行恒为 inactive（钳可读下限）。
    final double steady = math.max(inactive, minLegible);
    if (_reusedPerLineScales.length != len) {
      _reusedPerLineScales = List<double>.filled(len, steady);
      _scaleWindowStart = 0;
      _scaleWindowEnd = 0;
    }
    final int overscan = _overscan;
    final int startI = math.max(0, _currentLineIndex - overscan);
    final int endI = math.min(len, _currentLineIndex + overscan);
    bool anyChanged = false;
    for (int i = startI; i < endI; i++) {
      final double target = (!_visualHold && i == _focusLineIndex)
          ? active
          : inactive;
      final Spring spring = _perLineScaleSprings[i] ??= Spring(
        mass: LyricLayout.scaleSpringMass,
        damping: LyricLayout.scaleSpringDamping,
        stiffness: LyricLayout.scaleSpringStiffness,
        // 首次创建直接落在目标，避免从默认 1.0 一路动画到目标造成"飘"
        initialPosition: target,
      );
      if (snap) {
        // 快速连切兜底：跳过弹簧，直接落在目标
        spring.setPosition(target, 0);
      } else {
        // 目标变化时 setTarget：行切换触发放大/缩小的连贯过渡
        if (spring.target != target) {
          spring.setTarget(target);
        }
        if (!spring.isSettled) {
          spring.tick(dt);
          anyChanged = true;
        }
      }
      final double display = math.max(spring.position, minLegible);
      if (_reusedPerLineScales[i] != display) {
        _reusedPerLineScales[i] = display;
        anyChanged = true;
      }
    }
    // 窗口外的行钉在稳态 inactive。窗口只覆盖当前行 ± overscan，绘制却按
    // 视口裁剪——用户手动滚动到远离当前行的区域（或大屏/小字号使视口超出
    // 窗口）时，窗口外行不会被上面的窗口循环写入，会保持建表初始值
    // activeScale(1.0)，显示成"没缩小"的行。
    // 同时把窗口外已存在的弹簧瞬移到稳态（setPosition），否则该行重新进入
    // 窗口时会从旧位置（如曾作为当前行的 1.0）先弹回再缩，硬切穿帮。
    //
    // 性能：只处理「上一帧窗口内、本帧已离开窗口」的行（O(离开行数)），
    // 不再每帧遍历全部歌词行；steady 变化（字体大小 / enableScale）时整表兜底。
    if (steady != _lastScaleSteady) {
      _lastScaleSteady = steady;
      for (int i = 0; i < len; i++) {
        if (i >= startI && i < endI) continue;
        if (_pinLineScaleToSteady(i, steady)) anyChanged = true;
      }
    } else {
      for (int i = _scaleWindowStart; i < _scaleWindowEnd && i < len; i++) {
        if (i >= startI && i < endI) continue;
        if (_pinLineScaleToSteady(i, steady)) anyChanged = true;
      }
    }
    _scaleWindowStart = startI;
    _scaleWindowEnd = endI;
    return anyChanged;
  }

  /// 把窗口外第 i 行钉到稳态 scale：显示值写入复用列表，弹簧（若存在）
  /// 瞬移到稳态（position = target = steady、速度 0、settled）。
  /// 返回显示值是否发生变化（供重绘门控；幂等钉住返回 false）。
  bool _pinLineScaleToSteady(int i, double steady) {
    if (i < 0 || i >= _reusedPerLineScales.length) return false;
    bool changed = false;
    final Spring? spring = _perLineScaleSprings[i];
    if (spring != null && (spring.target != steady || !spring.isSettled)) {
      spring.setPosition(steady, 0);
    }
    if (_reusedPerLineScales[i] != steady) {
      _reusedPerLineScales[i] = steady;
      changed = true;
    }
    return changed;
  }

  /// v3 优化：检测视口附近 renderer 是否已收敛。
  /// 检查当前行的 WordRenderer + 视口内 LineRenderer 的 isConverged。
  bool _areRenderersConverged() {
    final currentRenderer = _wordRenderers[_currentLineIndex];
    if (currentRenderer != null && !currentRenderer.isConverged) {
      return false;
    }
    final int overscan = _overscan;
    final int startIdx = math.max(0, _currentLineIndex - overscan);
    final int endIdx = math.min(
      widget.lines.length,
      _currentLineIndex + overscan,
    );
    for (int i = startIdx; i < endIdx; i++) {
      final renderer = _lineRenderers[i];
      if (renderer != null && !renderer.isConverged) {
        return false;
      }
    }
    return true;
  }

  /// 按歌词行时长计算"入场/退场模糊淡出"速率（/s）。
  ///
  /// 时长 = `clamp(行时长 × 40%, 60ms, 1000ms)`：快歌（每行短）更快淡完、
  /// 慢歌最多 1s；行时长为 0/未知时按 1s 处理。
  /// 假定量从 ~1 指数衰减到 alpha 阈值 0.001，故 rate = ln(1000) / 时长(秒)。
  double _fadeRateForMs(int lineDurationMs) {
    double ms = lineDurationMs > 0 ? lineDurationMs * 0.4 : 1000.0;
    if (ms > 1000) ms = 1000;
    if (ms < 60) ms = 60; // 绝对下限，避免瞬时淡出或除零
    return math.log(1000.0) / (ms / 1000.0);
  }

  /// 偏好变化时触发重绘。
  ///
  /// **始终 setState**：偏好变化（如 useDuetLayout 切换）需要触发 build，
  /// 让 _recomputeDuetIfNeeded 重新处理歌词。若仅依赖 _onTick 末尾的
  /// hasVisualChange 判断，在播放中但当前行未切换时 hasVisualChange 为 false，
  /// 不会 setState，导致 _cleanedLines/_duetAlignments 不更新，对齐不生效。
  ///
  /// **字体变化时的特殊处理**：失效所有缓存，强制下帧重算：
  /// - 行高缓存：让 `_recomputeLineHeightsIfNeeded` 重测所有行高度
  ///   （TextPainter 用新 fontFamily layout，行高/换行可能变化）
  /// - 模糊图片缓存：dispose 所有缓存的 ui.Image 并清空 Map，
  ///   `_updateLineBlurCache` 会用新 fontFamily 重新渲染模糊图片
  /// - WordRenderer/LineRenderer 内部绑定：清空 _wordRenderers/_lineRenderers,
  ///   让它们用新字体重新测量 word 宽度（_ensureBound）并重置 alpha 状态
  void _onPreferencesChanged() {
    // 关闭开关时立即收敛正在进行的过渡（旧层由帧末回调释放）。
    if (!LyricPreferences.instance.blurLevelCrossfade &&
        _blurLevelFade < 1.0) {
      _finishBlurLevelFade();
    }
    // 辉光触发阈值随偏好即时重算（判定方式 / 固定时长 / 系数变化后立即生效，
    // 无需等切歌；resolveThresholdMs 为纯计算，成本可忽略）
    final int newGlowThresholdMs = EmphasizeEffect.resolveThresholdMs(
      lines: widget.lines,
      songBpm: widget.songBpm,
    );
    if (newGlowThresholdMs != _glowThresholdMs) {
      _glowThresholdMs = newGlowThresholdMs;
    }
    // 字体/字重变化时失效所有依赖字体测量的缓存
    final currentFontFamily = LyricLayout.fontFamily;
    final currentFontWeight = LyricLayout.fontWeight.value;
    if (currentFontFamily != _cachedFontFamily ||
        currentFontWeight != _cachedFontWeight) {
      // 失效行高缓存（让 _recomputeLineHeightsIfNeeded 重算）
      _cachedFontFamily = null;
      _cachedFontWeight = -1;
      // 失效模糊图片缓存（dispose 图片资源 + 清空 Map）
      _clearLineBlurCache();
      _cachedBlurLineIndex = -1;
      _cachedBlurLevels = const {};
      // 失效 WordRenderer/LineRenderer 内部绑定（清空后下次 paint 会重新创建 +
      // 重新 _ensureBound 测量 word 宽度，避免用旧字体宽度做换行判断）
      _releaseRendererCaches();
    }
    // 统一走 _syncEcoDriver 确定驱动源（eco 开关变化：锁定 → 60fps Timer；
    // 解锁/关闭 → Ticker 满帧），并确保偏好变化（如 useDuetLayout）触发重建
    _syncEcoDriver();
    // 间奏点自定义参数（水平位置/圆点大小/间距）由 painter 在 paint 时即时读取，
    // 但暂停冻结期间没有帧驱动重绘；这里主动补一次 repaint，
    // 保证拖动「歌词动画」页滑块时正在显示的间奏点即时跟随。
    _textRepaint.fireRepaint();
    _currentTextRepaint.fireRepaint();
    _blurRepaint.fireRepaint();
    setState(() {});
  }

  @override
  void didUpdateWidget(covariant AppleLyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // lines 列表缩短时，清理不再存在的行索引对应的 renderer 缓存，避免内存泄漏
    _wordRenderers.removeWhere((key, renderer) {
      if (key < widget.lines.length) return false;
      renderer.dispose();
      return true;
    });
    _lineRenderers.removeWhere((key, renderer) {
      if (key < widget.lines.length) return false;
      renderer.dispose();
      return true;
    });
    // v3 优化：恢复播放或切歌时立即重启驱动（停止态恢复）。
    //
    // **省电模式关键**：统一走 [_syncEcoDriver] 决策——eco 开启且锁定 →
    // 确保 60fps Timer 在跑（绝不能裸起 Ticker，否则每 ~200ms position 更新
    // 都会以 120Hz 重启一帧，破坏"锁 60fps"）；解锁/关闭 eco → Ticker 满帧。
    // 任意时刻至多一个驱动源，由本方法集中保证。
    if (oldWidget.isPlaying != widget.isPlaying && widget.isPlaying) {
      _syncEcoDriver();
    }
    // v3 优化：切歌（lines 引用变化）时重启驱动，重新推进新行的 renderer
    if (!identical(oldWidget.lines, widget.lines) ||
        oldWidget.songBpm != widget.songBpm) {
      // P0-A: 切歌即释放旧歌词绑定的 native 位图（每行模糊图 + 字形图/辉光）。
      // 这些 ui.Image 不受 ImageCache LRU 管辖，此前只在 dispose / 字体变化时
      // 释放；桌面端长会话切歌会持续创建新歌的位图，是引擎侧内存峰值来源之一。
      // 必须在下面的弹簧/驱动状态重置之前完成，避免下一帧复用已释放的纹理。
      if (!identical(oldWidget.lines, widget.lines)) {
        _clearLineBlurCache();
        _cachedBlurLineIndex = -1;
        _cachedBlurLevels = const {};
        _releaseRendererCaches();
      }
      // 快慢歌辉光阈值随歌曲变化：重算并同步到渲染器（renderer 在渲染循环设置）
      _glowThresholdMs = EmphasizeEffect.resolveThresholdMs(
        lines: widget.lines,
        songBpm: widget.songBpm,
      );
      // P2-K: 清理按行索引缓存的弹簧与延迟记录——它们只增不减，
      // 长歌曲 + 多次切歌会持续累积内存（Spring 对象虽小但按行数增长）。
      // 新歌行数不同，旧索引无意义，直接整体清空。
      _perLineSprings.clear();
      _delayStartTimes.clear();
      // 切歌后旧行号失效：级联轮次一并作废（目标行按新歌词重评）。
      _cascadeRound = null;
      _lastFrameTargetY = null;
      _prewarmTarget = -1;
      // 切歌后首次定位直接瞬移到新歌当前行（避免从旧歌曲的长距离滚动）
      _scrollController.resetInitialJump();
      // 切歌诊断日志：定位"切歌后省电模式失效须重新开关"问题用（低频事件）
      _syncEcoDriver();
    }
    // P0-A: 非逐字歌词在播放中可能已停 Ticker（静止省电）。position 更新
    //（约 200ms，经 ListenableBuilder 重建本 widget）时唤醒一帧：若确实
    // 发生行切换 / 滚动回弹 / 间奏等动画则继续跑，否则下一帧再次收敛停止。
    // **省电模式锁定态**：由 60fps Timer 持续驱动，无需（也不应）重启 Ticker。
    if (oldWidget.currentTimeMs != widget.currentTimeMs && widget.isPlaying) {
      _syncEcoDriver();
    }
    // 解耦：positionListenable 实例变化时重新挂载订阅
    // （切歌时若宿主换了 notifier 实例，旧订阅失效 → position 永久静默 →
    //  停帧后无法唤醒，表现为"省电模式失效"，故此处的切换必须可观测）
    if (oldWidget.positionListenable != widget.positionListenable) {
      oldWidget.positionListenable?.removeListener(_onExternalPosition);
      final listenable = widget.positionListenable;
      if (listenable != null) {
        _readAuthorityFrom(listenable);
        listenable.addListener(_onExternalPosition);
      } else {
        _authorityTimeMs = widget.currentTimeMs;
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.positionListenable?.removeListener(_onExternalPosition);
    if (_ecoDriverBound) {
      PlayerFrameDriver.instance.removeListener(_onEcoFrameTick);
      _ecoDriverBound = false;
    }
    _ticker.dispose();
    _scrollController.dispose();
    _blurBakeTimer?.cancel();
    _blurBakeTimer = null;
    _textRepaint.dispose();
    _currentTextRepaint.dispose();
    _blurRepaint.dispose();
    _clearLineBlurCache();
    _releaseRendererCaches();
    LyricPreferences.instance.removeListener(_onPreferencesChanged);
    super.dispose();
  }

  /// 释放行渲染器持有的 TextPainter 与 ui.Image，再清空按行缓存。
  void _releaseRendererCaches() {
    for (final renderer in _wordRenderers.values) {
      renderer.dispose();
    }
    for (final renderer in _lineRenderers.values) {
      renderer.dispose();
    }
    _wordRenderers.clear();
    _lineRenderers.clear();
  }

  /// 仅测试用：当前按行渲染器缓存条目数（WordRenderer + LineRenderer）。
  @visibleForTesting
  int get rendererCacheSizeForTest =>
      _wordRenderers.length + _lineRenderers.length;

  /// 视口缓冲行数之外的保留余量：覆盖行切换离场动画与预启动窗口，
  /// 避免清理掉仍在参与动画的行导致 renderer 被重建、alpha 状态跳变。
  static const int _rendererCacheMargin = 8;

  /// P0-A: 按当前行裁剪渲染器缓存。
  ///
  /// renderer 内部持有字形图/辉光等 [ui.Image]（native 内存，不受 ImageCache
  /// LRU 管辖），长歌曲随可见窗口推进会单调累积。仅在缓存规模超过窗口上限时
  /// 遍历，避免每行渲染都做 O(N) 扫描；越界条目先 dispose 再移除。
  void _pruneRendererCaches() {
    final radius = _overscan + _rendererCacheMargin;
    final maxEntries = radius * 2 + 1;
    if (_wordRenderers.length <= maxEntries &&
        _lineRenderers.length <= maxEntries) {
      return;
    }
    final center = _currentLineIndex < 0 ? 0 : _currentLineIndex;
    final minIdx = center - radius;
    final maxIdx = center + radius;
    _wordRenderers.removeWhere((key, renderer) {
      if (key >= minIdx && key <= maxIdx) return false;
      renderer.dispose();
      return true;
    });
    _lineRenderers.removeWhere((key, renderer) {
      if (key >= minIdx && key <= maxIdx) return false;
      renderer.dispose();
      return true;
    });
  }

  // ============== 工具方法 ==============

  /// 获取或创建指定行的 [WordRenderer]。
  WordRenderer _wordRendererFor(int index) {
    _pruneRendererCaches();
    return _wordRenderers.putIfAbsent(index, () => WordRenderer());
  }

  /// 获取或创建指定行的 [LineRenderer]。
  LineRenderer _lineRendererFor(int index) {
    _pruneRendererCaches();
    return _lineRenderers.putIfAbsent(index, () {
      final LineRenderer renderer = LineRenderer();
      // 整行预栅格图（P1-2）需要屏幕像素比与「图就绪」重绘回调。
      renderer.devicePixelRatio =
          ui.PlatformDispatcher.instance.implicitView?.devicePixelRatio ?? 1.0;
      renderer.onStaticImageReady = _textRepaint.fireRepaint;
      return renderer;
    });
  }

  /// 获取或创建指定行的偏移弹簧。
  Spring _perLineSpringFor(int index) => _perLineSprings.putIfAbsent(
    index,
    () =>
        Spring(mass: 1.0, damping: 15.0, stiffness: 100.0, initialPosition: 0),
  );

  /// 建立（或接管）一轮级联错峰。
  ///
  /// 预启动与回落补偿走同一入口，区别只在参数：
  /// - [preStarted] = true：锚行 = 下一行，[leadMs] 为当前帧距音频边界的
  ///   剩余时间，时间线按剩余量等比压缩，锚行恰在边界释放（零滞后）；
  /// - [preStarted] = false：切行帧调用，[leadMs] 忽略，锚行延迟钉在
  ///   `K×步长` 预算内。
  ///
  /// 接管旧轮次时只对「仍按住」的行结算抵消量（视觉位置不变）。预启动接管
  /// 不重按正在回弹途中的行（冻结在半空会「一阵一顿」）；回落路径在切行帧
  /// 建立，所有行都按新时间线重新按住（与历史行为一致）。
  void _startCascadeRound({
    required int anchorLine,
    required bool preStarted,
    double leadMs = 0,
  }) {
    final double step = LyricPreferences.instance.cascadeBaseStepMs;
    final int start = _cascadeStartLineFor(anchorLine);
    final double rawNeed = math.max(0, anchorLine - start) * step;
    // 期望锚行延迟：预启动 = 剩余提前量；回落 = K×步长预算。
    final double desired = preStarted
        ? leadMs.clamp(0.0, rawNeed)
        : math.min(rawNeed, _staggerCompWindowSteps * step);
    final double scale = rawNeed > 0.01
        ? (desired / rawNeed).clamp(0.0, 1.0)
        : 1.0;
    // 抵消基准：新时间线从当前 posY 起算，先按旧基准结算等待行残留，
    // 保证接管瞬间有效偏移连续（不产生瞬时位移）。
    final double pendingHold = _cascadePosY - _scrollController.posY;
    if (pendingHold.abs() > 0.01) {
      for (final k in _delayStartTimes.keys) {
        if ((_delayStartTimes[k] ?? -1) >= 0) {
          final s = _perLineSpringFor(k);
          s.setPosition(s.position + pendingHold, 0);
          s.setTarget(0);
        }
      }
    }
    _cascadePosY = _scrollController.posY;
    final double now = _frameClockMs;
    final int end = math.min(widget.lines.length, anchorLine + _overscan);
    for (int i = start; i < end; i++) {
      // **整段无条件按住**：包括仍在回弹途中的行。
      // 旧实现跳过「弹簧未收敛」的行，导致同一窗口里有的行被钉住、有的行
      // 跟着预滚上移——行距被压扁/重叠，且每轮被跳过的行不同，观感即
      // 「上拉起始位置异常、每次不一致」（真机日志实证：start 行自身
      // held=false 而相邻行 held=true）。
      // 冻结正在回弹的行不会产生跳变：按住前后有效偏移都等于该行当前的
      // 屏幕位置，释放时再从这里继续弹回；速度归零只表现为随大部队一起
      // 停在原处等待，与其它等待行一致。
      _delayStartTimes[i] = now;
    }
    _delayStartTimes.removeWhere((k, _) => k < start);
    _cascadeTopLine = start;
    _cascadeRound = _CascadeRound(
      anchorLine: anchorLine,
      startLine: start,
      clockMs: now,
      scale: scale,
    );
  }

  /// 结束当前轮次；[releaseHeld] 为 true 时把等待行按当前抵消量立即交还弹簧。
  ///
  /// 用于 seek / 用户拖动 / 快连切 / 开关切回开启：这些场景的时间线已不可信，
  /// 必须显式释放，避免「永不释放」的残留。
  void _endCascadeRound({required bool releaseHeld}) {
    if (_cascadeRound == null && _delayStartTimes.isEmpty) return;
    if (releaseHeld) {
      final double holdOffset = _cascadePosY - _scrollController.posY;
      for (final k in _delayStartTimes.keys) {
        if ((_delayStartTimes[k] ?? -1) >= 0) {
          final s = _perLineSpringFor(k);
          s.setPosition(s.position + holdOffset, 0);
          s.setTarget(0);
          _delayStartTimes[k] = -1;
        }
      }
    }
    _cascadeRound = null;
  }

  /// 指定行本帧的有效偏移 = 弹簧残留 + （等待期内的滚动抵消量）。
  ///
  /// 抵消量 = [_cascadePosY] − 当前 posY：切换帧为 0，之后随全局滚动连续增长，
  /// 使该行"停在切换瞬间的位置不动"，等延迟到期再交给弹簧追回来。
  /// 供每帧推进循环与 [_buildPerLineOffsets] 共用，避免两处口径不一致。
  double _effectiveLineOffset(int i) {
    final base = _perLineSprings[i]?.position ?? 0.0;
    final start = _delayStartTimes[i];
    if (start != null && start >= 0) {
      return base + (_cascadePosY - _scrollController.posY);
    }
    return base;
  }

  /// 计算级联起点：限幅后的视口顶部可见行。
  ///
  /// **确定性口径**：用 [anchorLine]「到位后」的目标 posY 求视口顶行，而不是
  /// 当前瞬时弹簧 posY。瞬时值会随帧相位（预启动入口帧 / 回落切行帧 /
  /// 上一轮未收敛）变化，导致同一行边界算出的起点行每次不同——这正是
  /// 「上拉起始行不一致」的根因。目标 posY 只由 anchor 与布局决定，同一
  /// anchor 恒定映射到同一行。
  ///
  /// 二分判定与 [_LyricsPainter] 定位一致；再与
  /// `anchorLine - _cascadeTopLimit` 取较大值（限幅）。painter 未就绪
  /// （视口高度未知 / 行表为空）时退化为限幅值。
  int _cascadeStartLineFor(int anchorLine) {
    final int len = widget.lines.length;
    if (len == 0) return 0;
    final double viewportH =
        _scrollController.viewportHeight > 0
        ? _scrollController.viewportHeight
        : (_painter?.viewportHeight ?? 0);
    final int floor = math.max(0, anchorLine - _cascadeTopLimit);
    if (viewportH <= 0 || _lineTops.isEmpty) return floor;
    // 字号提到循环外：二分内逐次调 LyricLayout.fontSize(context) 会重复查
    // MediaQuery，且结果恒定。
    final double fs = _cachedFontSize > 0
        ? _cachedFontSize
        : LyricLayout.fontSize(context);
    final double mainLineHeight = fs * LyricLayout.lineHeight;
    final double anchorTop =
        (anchorLine < _lineTops.length
            ? _lineTops[anchorLine]
            : anchorLine * mainLineHeight) +
        _interludeOffsetBefore(anchorLine) +
        _transDeltaBefore(anchorLine);
    final double anchorHeight =
        (anchorLine < _lineHeights.length
            ? _lineHeights[anchorLine]
            : mainLineHeight) +
        _transExtraHeightFor(anchorLine);
    // 与 LyricScrollController.targetYForLine 同式：锚行中心落在锚位上。
    final double targetPosY = -(
      anchorTop +
      anchorHeight / 2 -
      viewportH * LyricLayout.alignPosition
    );
    int l = 0, h = len;
    while (l < h) {
      final int mid = (l + h) ~/ 2;
      final double top = mid < _lineTops.length
          ? _lineTops[mid]
          : mid * mainLineHeight;
      final double lineH = mid < _lineHeights.length
          ? _lineHeights[mid]
          : mainLineHeight;
      final double y =
          top + targetPosY + _interludeOffsetBefore(mid) + _transDeltaBefore(mid);
      if (y + lineH < -LyricLayout.overscanPx) {
        l = mid + 1;
      } else {
        h = mid;
      }
    }
    final int lo = l.clamp(0, len - 1);
    return (lo > floor) ? lo : floor;
  }

  /// 当前行的级联起点（[_cascadeStartLineFor] 的薄包装）。
  int _computeCascadeTopLine() => _cascadeStartLineFor(_currentLineIndex);

  /// 构建每行的偏移量列表，传给 _LyricsPainter。
  ///
  /// v3 优化：复用 List 实例，仅更新内容。
  /// lines 长度变化时重新分配 List，否则原地 []= 更新。
  /// 同时递增 _perLineOffsetsGeneration，让 shouldRepaint 通过 counter 检测变化。
  List<double> _buildPerLineOffsets() {
    final int len = widget.lines.length;
    if (_reusedPerLineOffsets.length != len) {
      _reusedPerLineOffsets = List<double>.filled(len, 0.0);
      _offsetsWindowStart = 0;
      _offsetsWindowEnd = 0;
    }
    // 性能优化：perLineOffsets 仅被 _buildBlurLayers 消费（只遍历视口内 _cachedBlurLevels），
    // 故填充只需覆盖 [_cascadeTopLine, currentLineIndex + overscan]。
    // 起点以下（< _cascadeTopLine）不参与级联（不可见或超出限幅），保持 0。
    final int startI = _cascadeTopLine;
    final int endI = math.min(len, _currentLineIndex + _overscan);
    // 先把上一帧覆盖过的窗口整体清零：列表是复用实例，只写新窗口会让
    // 滑出窗口的行永久停在上次的偏移上（级联偏移启用后才会暴露）。
    for (
      int i = _offsetsWindowStart;
      i < _offsetsWindowEnd && i < _reusedPerLineOffsets.length;
      i++
    ) {
      _reusedPerLineOffsets[i] = 0.0;
    }
    for (int i = startI; i < endI; i++) {
      _reusedPerLineOffsets[i] = _effectiveLineOffset(i);
    }
    _offsetsWindowStart = startI;
    _offsetsWindowEnd = endI;
    _perLineOffsetsGeneration++;
    return _reusedPerLineOffsets;
  }

  // ============== 动画推进 ==============

  void _onTick(Duration elapsed) {
    // 使用 Ticker 的调度器时钟（测试中为模拟时间）计算 dt，
    // 避免 DateTime.now() 在测试中返回真实墙钟时间导致弹簧不推进。
    double dt = (elapsed - _lastElapsed).inMicroseconds / 1000000.0;
    _lastElapsed = elapsed;
    // 单调帧时钟：跨 Ticker 重启保持连续（见字段注释）
    _frameClockMs += dt * 1000;

    // 检测 Ticker 曾被 mute（TabBarView 切走 / App 退后台 / 长时间卡顿）：
    // 恢复后首帧 dt 会等于切走时长（远大于正常帧间隔）。mute 期间
    // 间奏点动画时钟（帧 dt 累积）冻结而歌曲继续播放，需在本帧把时钟
    // 对齐到真实窗口进度（见 _updateInterlude 的 alignDotsToRealTime）。
    // 该检测为 O(1) 比较，不增加每帧开销。
    // P0-A：挂起恢复（Timer 路径 dt 恒为 16ms，检测不到 gap）后的首帧
    // 也按 gap 恢复处理，对齐间奏点等帧时钟动画到真实进度。
    final bool tickerGapResume =
        dt > _tickerGapResumeThreshold || _resumeGapPending;
    _resumeGapPending = false;

    // ============== 歌词省电模式：锁定 60fps ==============
    // 解锁（120Hz 满帧）仅限"用户驱动"的滚动：
    //   1. 手指正按住拖动（isUserScrolling）
    //   2. 松手后惯性仍在滑行（isWaitingForAutoReturn 且弹簧未静止）——惯性速度高，
    //      60fps 会明显发卡，必须保持满帧顺滑
    // 其余一律保持 60fps：
    //   - 惯性已停、仅等待自动回弹倒计时（画面静止）→ 锁 60fps（这正是"拖动后要锁回"的原始 bug）
    //   - 自动回弹动画 / 播放行切换的自动滚动 → 60fps 足够顺滑
    // **真正限帧由 [_syncEcoDriver] 切换 Ticker/Timer 实现**：锁定 → 停 Ticker、
    // 用 60fps Timer 驱动 _onTick（限制实际帧生产）；解锁/关闭 eco → Ticker 满帧。
    if (LyricPreferences.instance.ecoMode) {
      final bool wasUnlocked = _ecoUnlocked;
      _ecoUnlocked =
          _scrollController.isUserScrolling ||
          (_scrollController.isWaitingForAutoReturn &&
              !_scrollController.isPosYSpringSettled);
      _syncEcoDriver();
    }

    // P0: 推进逐字动画平滑时间（上浮/字内渐变的进度来源）。
    // positionStream 每 ~200ms 才给一个权威位置，播放中若直接用它会
    // 造成动画"追到旧目标后冻结 ~120ms"的卡顿；这里用帧时钟每帧推进，
    // 收到新权威位置时对齐校正。
    //
    // 校正策略：正常 position 更新用**平滑逼近**而非硬跳。音频时钟与帧时钟
    // 存在漂移，若权威位置硬跳跨过逐字边界，字切换会来回抖动（英文歌字短、
    // 边界密集时更明显，表现为"下一个字闪一下"）。seek/切歌等大跳变仍直接吸附。
    // 暂停时冻结在**已推进到**的位置（不向下吸附权威值，避免回退一截）。
    // 播放流未就绪（切歌 loading / 缓冲 buffering）同样走冻结分支：期间
    // positionStream 静默、权威值冻结，若仍按帧时钟推进会反复触发兜底回吸，
    // 形成"前进→跳回"锯齿，字内渐变随之来回抽搐。
    if (widget.isPlaying && !widget.playbackNotReady) {
      _smoothPosMs += dt * 1000;
      if (_authorityTimeMs != _lastAuthorityPosMs) {
        final int jump = (_authorityTimeMs - _lastAuthorityPosMs).abs();
        _lastAuthorityPosMs = _authorityTimeMs;
        if (jump > _smoothPosSeekJumpMs) {
          // seek/大跳变：直接吸附，避免平滑拖尾
          _smoothPosMs = _authorityTimeMs.toDouble();
        } else if (_authorityTimeMs >= _smoothPosMs ||
            _smoothPosMs - _authorityTimeMs > _smoothPosRewindToleranceMs) {
          // 向前校正；或真实回退超死区时回拉（换源 / 清唱偏移变化）
          final double corr = 1.0 - math.exp(-_smoothPosCorrRate * dt);
          _smoothPosMs += (_authorityTimeMs - _smoothPosMs) * corr;
        }
        // 死区内的小幅回退（采样相位差 / 缓冲边界轻微回跳）：忽略，
        // 保持已推进的字内渐变进度，不回退。
      } else if (_smoothPosMs - _lastAuthorityPosMs >
          _smoothPosRewindToleranceMs) {
        // 兜底：权威位置长时间不更新（缓冲等）时防止平滑值漂移过大。
        // 只裁掉超出死区的部分，不吸回权威值，避免"前进→跳回"锯齿。
        _smoothPosMs = _lastAuthorityPosMs + _smoothPosRewindToleranceMs;
      }
    } else {
      // 暂停 / 播放未就绪：停在**已推进到**的位置，而不是下沉吸附权威值。
      // 权威值前进或真实回退（seek/切歌）超阈值时才对齐。
      if (_authorityTimeMs >= _smoothPosMs ||
          _smoothPosMs - _authorityTimeMs > _smoothPosSeekJumpMs) {
        _smoothPosMs = _authorityTimeMs.toDouble();
      }
      _lastAuthorityPosMs = _authorityTimeMs;
    }

    // 1. 找当前行
    // 纯文本歌词（无时间轴）不高亮、不滚动、不模糊，直接平铺显示
    // 性能优化：缓存 hasTimestamps 结果，避免每帧 O(N) 遍历所有 lines
    final bool hasTimestamps = _cachedHasTimestamps;
    // P0: 缓存行查找结果：currentTimeMs 与 lines 引用都未变化时跳过二分查找。
    // （暂停时 currentTimeMs 不变，播放中每帧 200ms 才有一次变化，绝大多数帧直接命中）
    if (_currentTimeMsCache != _authorityTimeMs ||
        !identical(_linesCacheRef, widget.lines)) {
      _currentTimeMsCache = _authorityTimeMs;
      _linesCacheRef = widget.lines;
      _currentLineIndex = hasTimestamps
          ? AppleLyricsView.findCurrentLineIndex(widget.lines, _authorityTimeMs)
          : -1;
      _earlyTimedLine = _currentLineIndex;
    }
    // 预换行：逻辑行提前到下一行，视觉激活仍冻结到真实音频边界。
    _updateEarlySwitch();
    if (_earlySwitchTarget >= 0) {
      _currentLineIndex = _earlySwitchTarget;
    } else if (_currentLineIndex != _earlyTimedLine) {
      // 缓存命中时 _currentLineIndex 会停在上一帧的预换行目标上；
      // 等待期结束后必须回到按真实时间算出的行，否则会卡在下一行。
      _currentLineIndex = _earlyTimedLine;
    }
    // 副行清晰图预热：只在当前行变化时做（内部守卫），让「旧行退场翻转 /
    // 新行入场翻转」开始时图已就绪，避免翻转帧回退到文字透视路径。
    _syncAuxTextImages(_currentLineIndex);
    // 模糊等级 / 烘焙不依赖 widget 重建：当前行或激活态变化时在这里同步一次
    //（滚动中由 _syncBlurLevels 内部延后，与旧行为一致）。
    if (_cachedFontSize > 0 &&
        _viewportWidth > 0 &&
        LyricPreferences.instance.useGaussianBlur &&
        (_currentLineIndex != _cachedBlurLineIndex ||
            _visualHold != _lastBlurVisualHold ||
            _introInterludeOwnsSlot != _cachedBlurHeadSlot)) {
      _syncBlurLevels(
        _painter?.viewportHeight ?? 0,
        _cachedFontSize * LyricLayout.lineHeight,
      );
    }

    // 1.5 行切换副行交接 + 收起推进（必须在下方 renderer 注入与滚动目标
    // 计算之前执行，保证本帧渲染用的就是交接后的进度，切换帧视觉与上一帧
    // 严格连续，不存在"旧副行闪一帧再消失"的中间态）。
    //
    // 快速连切兜底判定：连续两次及以上「切换间隔 < 300ms」才跳过弹簧直接到位。
    // 单次快速切行仍走弹簧，避免正常快歌的个别密集行被硬切；连续快速切行时
    // 级联延迟 60~750ms 永远等不到释放，等待行被抵消量一直钉住 → 整块歌词卡住。
    bool fastLineSwitch = false;
    if (_currentLineIndex != _previousLineIndex) {
      final double nowMs = _frameClockMs;
      final double lastMs = _lastLineSwitchFrameMs;
      final bool quickGap =
          lastMs >= 0 && nowMs - lastMs >= 0 &&
          nowMs - lastMs < _fastSwitchThresholdMs;
      _consecutiveFastSwitches = quickGap ? _consecutiveFastSwitches + 1 : 0;
      // 首次切行（lastMs < 0）计数为 0；连续 >= 2 次才启用兜底
      fastLineSwitch = _consecutiveFastSwitches >= 2;
      _lastLineSwitchFrameMs = nowMs;
      _lastSwitchWasFast = fastLineSwitch;
    }
    if (_currentLineIndex != _previousLineIndex) {
      // 过渡时长 = 退场行时长 × 40%（夹 [60, 1000]ms，[_auxTransitionMsForLine]）：
      // 快歌短、慢歌最多 1s。逐行副行进度里「收起」与「展开」共用这一时长
      // 与同一时间锚，于是稳态切行（旧行 1→0、新行 0→1）时两者进度之和恒为
      // 1 —— 当前行以下的行零位移，与原单值实现同一不变量。
      // 边界防御：切歌等 lines 整体替换场景下，outgoingIdx 可能超出新歌词
      // 行数（_previousLineIndex 尚未随新行更新）。越界访问会让 _onTick 每帧
      // 抛异常、歌词永久冻结（外观与"省电模式失效"一致），故显式钳制。
      final int outgoingIdx = _previousLineIndex;
      _auxSwitchDurationMs = outgoingIdx >= 0 && outgoingIdx < widget.lines.length
          ? _auxTransitionMsForLine(widget.lines[outgoingIdx].duration)
          : (_currentLineIndex >= 0 && _currentLineIndex < widget.lines.length
                ? _auxTransitionMsForLine(widget.lines[_currentLineIndex].duration)
                : 400.0);
      // 逐行目标值不在这里改：[_advanceAuxProgress] 每帧比对签名（含当前行
      // 索引），变化即整体重算。切入行此前若正在收起，从当前进度自然续升；
      // 快速连切由 [_advanceAuxProgress] 直接吸附到目标。
    }

    // 2. 推进滚动控制器（需要 lineHeight 与 intervalMs 计算目标 posY）
    if (_currentLineIndex >= 0) {
      // 不每帧查 MediaQuery：字号在 build 时缓存到 _cachedFontSize，
      // 偏好变更会走 build 更新缓存，逻辑像素与偏好一致。
      final fontSize = _cachedFontSize > 0
          ? _cachedFontSize
          : LyricLayout.fontSize(context);
      final mainLineHeight = fontSize * LyricLayout.lineHeight;
      // 间奏占位行可见时，焦点是**占位行本身**而不是任何歌词行：
      // 滚动目标对准占位行（内容坐标 [占位顶, 占位顶 + 占位行高]），于是圆点
      // 正好落在「当前行位置」偏好（LyricLayout.alignPosition）上，前一行在
      // 其上方、后一行在其下方。占位行高 = 单行行高，占位收缩到 0 后
      // 「当前行居中」的目标与它数值相等，所以间奏结束不会跳位。
      // 头部间奏（首行之前）anchor = -1，[ _interludeSlotTop ] 归到内容原点。
      final bool slotFocus = _interludeSlotVisible;
      // 当前行实际高度（含换行）：用预计算 _lineHeights，无则降级 mainLineHeight；
      // 副行动画高度动态叠加（展开中增长 / 收起中回落）
      final currentLineHeight = slotFocus
          ? _interludePlaceholderHeight
          : (_currentLineIndex < _lineHeights.length
                    ? _lineHeights[_currentLineIndex]
                    : mainLineHeight) +
                _transExtraHeightFor(_currentLineIndex);
      // 当前行顶部 y（前面所有行高度的累加 + 间奏占位偏移 + 上方副行动画高度）
      final currentLineRawTop = slotFocus
          ? _interludeSlotTop(_lastActiveAnchorIdx)
          : (_currentLineIndex < _lineTops.length
                ? _lineTops[_currentLineIndex]
                : _currentLineIndex * mainLineHeight);
      final currentLineTop = slotFocus
          ? currentLineRawTop
          : (currentLineRawTop +
                _interludeOffsetBefore(_currentLineIndex) +
                _transDeltaBefore(_currentLineIndex));
      // intervalMs = 下一行 startTime - 当前行 endTime，用于动态 stiffness
      int intervalMs = 0;
      if (_currentLineIndex < widget.lines.length - 1) {
        final current = widget.lines[_currentLineIndex];
        final next = widget.lines[_currentLineIndex + 1];
        intervalMs = next.startTime - current.endTime;
      }
      // 预启动窗口活跃时跳过本帧的 setCurrentLine：步骤 2.5 已把滚动目标
      // 推进到下一行（参数同款、幂等），此处再按当前行设置会每帧把目标
      // 拽回旧位置——弹簧目标以 60fps 在两行间翻转（posY 振荡 ±一行距），
      // 并连锁触发 seek 跳变保护，表现为错峰动画"一阵一顿"的拉面条观感
      // （真机实录见 QQ20261107-201300）。边界切行后轮次锚点变为当前行，
      // 本条件自然失效，步骤 2 恢复接管（参数与预启动一致，无跳变）。
      final bool preStartTargetActive =
          _cascadeRound?.anchorLine == _currentLineIndex + 1;
      if (!preStartTargetActive) {
        _scrollController.setCurrentLine(
          _currentLineIndex,
          // 暂停时视为 seeking 模式（固定弹簧参数），播放时用动态参数
          isSeeking: !widget.isPlaying,
          lineHeight: currentLineHeight,
          intervalMs: intervalMs,
          lineTop: currentLineTop,
          // 间奏激活或占位还在收起时都用柔和 spring（stiffness=40, damping=10），
          // 让歌词跟随占位收起时有阻尼感而非瞬移
          isInterludeActive: _interludeExpandProgress > 0.01,
          // 快速连切兜底：直接切到新行位置，不做弹簧过渡
          snap: fastLineSwitch,
        );
      }
    }

    // 2.5 关闭「错峰从当前行上方开始」时的预启动（仅播放中、关闭模式、
    // 非切行帧、非用户滚动）。
    //
    // 下一行 startTime 已知：在剩余提前量 `lead` 恰好放得下「视口顶行到
    // 下一行的原始累加」时建立轮次（`_CascadeRound`），时间线锚定此刻，
    // 锚行（下一行）恰在音频边界释放。迟到进窗（剩余不足）时**不再放弃**，
    // 而是把锚行以上行等比压缩进剩余时间——预启动与回落从此共用一套公式，
    // 不再有「窗口没赶上就整轮退化成回落」的冲突。
    // 切行帧整体跳过：本行的消费 / 回落判定在步骤 8。
    if (_currentLineIndex == _previousLineIndex &&
        _currentLineIndex >= 0 &&
        widget.isPlaying &&
        !fastLineSwitch &&
        !_scrollController.isUserScrolling &&
        !_scrollController.isWaitingForAutoReturn) {
      final bool staggerOff =
          !LyricPreferences.instance.staggerFromCurrentLine;
      final int nextLine = _currentLineIndex + 1;
      // 间奏占位展开/收起期间不预启动：占位（≈1 行）到音频边界前 250ms 才开始
      // 收起，而布局此刻正由"下方行上移补位"收缩；此时若预先把滚动目标推到
      // 下一行，会在收起动作之外额外叠加一整行的上移 —— 观感即间奏点结束动画
      // 「向上飞很高才收起」（真机 QQ20261107）。该边界的位移由占位收起动画
      // 主导（~750ms，与圆点消失同步），不需要预滚动补偿。
      if (staggerOff &&
          _interludeExpandProgress <= 0.01 &&
          nextLine < widget.lines.length) {
        final int nextStartMs = widget.lines[nextLine].startTime;
        final int leadMs = nextStartMs - _smoothPosMs.round();
        // 真机手感微调：级联比音频边界再提前这么多毫秒，给当前行弹簧留出
        // 收敛时间（弹簧到位 ≠ 收敛，边界时刻可能还在收敛尾巴上）。
        final int biasMs = LyricPreferences.instance.preStartBiasMs.round();
        final double step = LyricPreferences.instance.cascadeBaseStepMs;
        // 粘住：本轮锚点已是下一行时无条件保持，不再逐帧判定阈值。
        // 权威翻行比平滑时钟晚最多 ~200ms，逐帧 lead 会在阈值附近抖动；
        // 旧实现每抖动一次就作废窗口，导致目标反复回拉（真机 QQ20261107-230339）。
        final bool sticky = _cascadeRound?.anchorLine == nextLine;
        // 廉价预过滤：起点最多向上 8 行，剩余提前量超过 8×步长必然进不了窗，
        // 跳过 O(log N) 的起点计算。
        final double maxRawNeed = _cascadeTopLimit * step;
        if (leadMs > biasMs && (sticky || leadMs - biasMs <= maxRawNeed)) {
          if (!sticky) {
            final int start = _cascadeStartLineFor(nextLine);
            final double rawNeed = math.max(0, nextLine - start) * step;
            // 锚行延迟不得超过错峰上限，否则会被上限截断而提前释放；
            // 剩余时间放得下「min(原始累加, 上限)」才开窗。
            final double entryLimit = math.min(
              rawNeed,
              LyricPreferences.instance.cascadeMaxDelayMs,
            );
            if (leadMs - biasMs <= entryLimit) {
              _startCascadeRound(
                anchorLine: nextLine,
                preStarted: true,
                leadMs: (leadMs - biasMs).toDouble(),
              );
              // 切行帧减负：把新当前行的逐字测量 / 副行图烘焙提前到这里。
              _prewarmLine(nextLine);
            }
          }
          if (sticky || _cascadeRound?.anchorLine == nextLine) {
            // 提前推进滚动目标（幂等：setCurrentLine 同参重入无副作用），
            // 弹簧参数用「下一行的 intervalMs」才能拿到正确的动态 stiffness。
            final double fontSizePre = _cachedFontSize > 0
                ? _cachedFontSize
                : LyricLayout.fontSize(context);
            final double mainLineHeightPre =
                fontSizePre * LyricLayout.lineHeight;
            final int nextIntervalMs;
            if (nextLine < widget.lines.length - 1) {
              nextIntervalMs =
                  widget.lines[nextLine + 1].startTime -
                  widget.lines[nextLine].endTime;
            } else {
              nextIntervalMs = 0;
            }
            _scrollController.setCurrentLine(
              nextLine,
              isSeeking: false,
              lineHeight:
                  (nextLine < _lineHeights.length
                      ? _lineHeights[nextLine]
                      : mainLineHeightPre) +
                  _transExtraHeightFor(nextLine),
              intervalMs: nextIntervalMs,
              lineTop:
                  (nextLine < _lineTops.length
                      ? _lineTops[nextLine]
                      : nextLine * mainLineHeightPre) +
                  _interludeOffsetBefore(nextLine) +
                  _transDeltaBefore(nextLine),
              // 预启动推进不用柔和间奏参数：占位收起期间恰逢预启动时，
              // 用动态参数保证边界时刻弹簧状态与正常切行一致。
              isInterludeActive: false,
              snap: false,
            );
          }
        }
      } else if (!staggerOff && _cascadeRound != null) {
        // 开关切回开启：旧轮次的时间线口径已不适用，立即收口，避免
        // 步骤 8 的开启模式登记与残留轮次叠加。
        _endCascadeRound(releaseHeld: true);
      }
    }
    _scrollController.tick(dt);

    // 3. 推进每行独立的 scale 弹簧（离场缩 0.850 / 进场放 1.0，均连贯）
    // 返回是否有缩放动画仍在进行，供下方重绘门控与收敛判定使用。
    // 快速连切帧直接瞬变到目标，不做弹簧推进。
    final bool anyScaleChanged = _tickPerLineScales(dt, snap: fastLineSwitch);

    // 4. 推进每行的 renderer
    // 性能优化：只 tick 视口附近的行（前后各 15 行），避免 200+ 行全量 tick。
    // 当前行用 WordRenderer（逐字 alpha + 上浮），其他行用 LineRenderer。
    final int overscan = _overscan;
    final int startIdx = math.max(0, _currentLineIndex - overscan);
    final int endIdx = math.min(
      widget.lines.length,
      _currentLineIndex + overscan,
    );
    // P1-G: 顺带聚合"是否有 renderer 仍在动画"，替代 _hasRendererAlphaChanged
    // 的二次 O(±10 行) 遍历（hasVisualChange 与收敛判断复用）。
    bool anyRendererAnimating = false;
    // P1-1：分层重绘需要区分「当前行在动」与「其余行在动」。
    bool anyActiveRendererAnimating = false;
    bool anyNonActiveRendererAnimating = false;
    for (int i = startIdx; i < endIdx; i++) {
      final line = widget.lines[i];
      final isActive = !_visualHold && i == _focusLineIndex;
      // 文字层不再使用 scale 弹簧，当前行瞬移到 activeScale
      final scale = isActive
          ? LyricLayout.activeScale
          : (widget.enableScale
                ? LyricLayout.inactiveScale
                : LyricLayout.activeScale);
      final bool useWordRenderer = isActive && line.hasWordTiming;
      // 行级文字颜色覆盖：当前行用高亮色；上方已播行由独立开关决定
      // （开关关闭时 [_aboveLineColorValue] 为 null，不覆盖）。两个渲染器
      // 都只在需要覆盖时才拿到非 null 值（LineRenderer 不再自行按 isActive 门控）。
      final int? lineColorValue = lineColorOverrideValue(
        activeLineColorValue: _activeLineColorValue,
        aboveLineColorValue: _aboveLineColorValue,
        isActive: isActive,
        isAboveCurrent: i < _currentLineIndex,
      );
      // 纯文本歌词无时间轴时强制关闭高斯模糊
      final bool blurActive =
          hasTimestamps && LyricPreferences.instance.useGaussianBlur;
      if (useWordRenderer) {
        final renderer = _wordRendererFor(i);
        renderer.emphasizeEffect = _emphasizeEffect;
        // 快慢歌辉光阈值（切歌时重算），行绑定时据此判定强调字
        renderer.thresholdMs = _glowThresholdMs;
        // 翻译副行浮出/渐显进度（逐行进度数组，当前行在本行窗口内取自身值）。
        // alpha 与位置共用展开进度，淡入淡出贯穿整个过渡。
        // 当前行恒为入场：副行绕底边从下翻转出现（方向标记必须无条件赋值，
        // 字段跨帧保留，漏设会让副行残留在上一行的出场方向上）。
        // 注：painter.paint 会在真正绘制前用同一份数组再赋一次值（按绘制行号，
        // 不受本 ±overscan 窗口限制），这里是 tick 阶段的口径对齐。
        renderer.translationExpand = _auxProgressAt(i);
        renderer.translationFade = _auxProgressAt(i);
        renderer.translationExiting = false;
        renderer.setLineState(
          isActive: true,
          scale: scale,
          blurFade: _clearLayerBlurFade,
          blurActive: blurActive,
          activeColorValue: lineColorValue,
        );
        // 用平滑时间驱动逐字动画（上浮/字内渐变），避免 positionStream 5fps 卡顿
        // isPlaying 用于冻结自驱动波浪：暂停/未就绪时波浪不推进，防止辉光持续
        // 闪烁；未就绪时 smoothPos 也冻结，重锚检测两侧输入静止，波浪不会反复重锚
        renderer.tick(
          dt,
          _smoothPosMs.round(),
          isPlaying: widget.isPlaying && !widget.playbackNotReady,
        );
        if (!renderer.isConverged) {
          anyRendererAnimating = true;
          anyActiveRendererAnimating = true;
        }
      } else {
        final renderer = _lineRendererFor(i);
        // 副行动画注入（必须无条件赋值——renderer 字段跨帧保留，漏设会残留
        // 旧值画出幽灵副行）：直接取该行自己的进度，与「副行显示范围」无关——
        // 当前行 / 未播行 / 已播行都可能是同一个数组里的不同行。
        // 方向标记按「目标 < 当前」判定：下行 = 出场（绕顶边向上翻走），
        // 上行 = 入场（绕底边从下翻出）。
        final double auxP = _auxProgressAt(i);
        renderer.translationExpand = auxP;
        renderer.translationFade = auxP;
        renderer.translationExiting = _auxTargetAt(i) < auxP - 1e-4;
        renderer.setLineState(
          isActive: isActive,
          scale: scale,
          blurFade: _clearLayerBlurFade,
          blurActive: blurActive,
          activeColorValue: lineColorValue,
          // 仅当上方行确实拿到已播色时才提高清晰层 alpha：无覆盖色时保持
          // 原暗态层次，避免开关打开但没有可用颜色时整屏变亮。
          isAboveCurrent: _aboveLineColorValue != null && i < _currentLineIndex,
        );
        renderer.tick(dt);
        if (!renderer.isConverged) {
          anyRendererAnimating = true;
          if (isActive) {
            anyActiveRendererAnimating = true;
          } else {
            anyNonActiveRendererAnimating = true;
          }
        }
      }
    }

    // 5. 间奏检测与推进
    // P1-C: 间奏检测只依赖 currentTimeMs（positionStream 约 200ms 更新一次），
    // 时间未变且占位动画已收敛时，跳过每帧 O(间奏数) 的线性遍历。
    // 占位未收敛（展开/收起中）时仍需每帧检测以正确处理 clear 时机。
    final bool interludeTimeChanged =
        _authorityTimeMs != _lastInterludeCheckTimeMs;
    final bool interludePlaceholderSettled = _activeInterludeIdx >= 0
        ? _interludeExpandProgress >= 0.999
        : _interludeExpandProgress <= 0.001;
    if (interludeTimeChanged ||
        !interludePlaceholderSettled ||
        tickerGapResume) {
      // 时间回退（seek/跳转回跳）时强制重置间奏点动画时钟：
      // setInterlude 幂等保护无法区分"每帧重复调用"与"seek 回到同一间奏"，
      // 不重置会导致动画从旧进度继续、甚至超时隐藏（间奏点不显示）。
      final bool timeRewound = _authorityTimeMs < _lastInterludeCheckTimeMs;
      // 权威时间是**连续推进**跨过间奏窗口终点（非 seek/点击大跳）→ 判定为
      // 自然结束：即使帧时钟还没走到消失段（被驱动名义步长拖慢），也必须补帧
      // 播完消失动画，而不是按 isInExitPhase 误判成"跳转离开"直接清除圆点。
      final bool naturalAdvance =
          !timeRewound &&
          _lastInterludeCheckTimeMs >= 0 &&
          _authorityTimeMs - _lastInterludeCheckTimeMs <= _smoothPosSeekJumpMs;
      _lastInterludeCheckTimeMs = _authorityTimeMs;
      _updateInterlude(
        forceDotsReset: timeRewound,
        naturalAdvance: naturalAdvance,
        // Ticker 曾被 mute（切走 tab / 退后台）恢复：动画时钟滞后于真实进度，
        // 需对齐到当前间奏窗口内的真实偏移（而非重置从 0 重播入场动画）。
        alignDotsToRealTime: tickerGapResume,
      );
    }

    // 6. 推进间奏点动画时钟（基于帧 dt，逐帧）
    // 暂停时不推进动画时钟，让间奏点随播放器一起暂停
    //
    // 这里曾被「累加帧 dt、满 33ms 才 tick 一次」降到 30fps（"视觉无感"）。
    // 实测该降频在省电模式下**一个帧都省不掉**（占位收起弹簧逐帧变化，本帧
    // 必然重绘），却把圆点的缩放/透明度量化成大台阶：eco 驱动按名义 16ms
    // 步进，`16 × 2 = 32ms` 不足 33.3ms 阈值 → 实际每 3 帧才推进一次（20fps），
    // 收起的最后 750ms 只剩 15 个缩放台阶、透明度只剩 8 档，且 easeInBack 末段
    // 斜率最大，观感就是"一抽一抽地收"。tick 只是标量加法 + 3 个圆，成本可
    // 忽略，故恢复逐帧推进，台阶消失。
    // 帧时钟与播放时钟的系统性滞后（名义 16ms < 真实 vsync）不再靠这里降频
    // 掩盖，改由权威位置**逐次按比例小步追平**（见 [_updateInterlude]）。
    if (widget.isPlaying) {
      _interludeDots.tick(dt);
    }

    // 7. 推进间奏占位 spring（_interludeExpandProgress）
    // 严格 AMLL：进入间奏时段 spring 展开 0 → 1，离开则 spring 收起 1 → 0
    // 用指数衰减逼近目标值：progress += (target - progress) * (1 - exp(-speed * dt))
    // speed = 18 对应 ~300ms 内基本到位（AMLL 视觉过渡感）
    final double interludeTarget = _activeInterludeIdx >= 0 ? 1.0 : 0.0;
    // 展开用 18.0（~300ms 快速展开），收起用 9.0（~767ms 平滑收起，匹配间奏点消失动画 750ms）
    final double interludeSpeed = _activeInterludeIdx >= 0 ? 18.0 : 9.0;
    // P0: 暂停时直接吸附到目标，不再指数逼近。
    // 指数衰减永不精确到达 target，且暂停时动画应冻结；
    // 此前暂停时 progress 缓慢逼近，收敛检测 |progress-target|<0.001 依赖它，
    // 有间奏点的歌曲暂停后 Ticker 迟迟不收敛 → 每帧重绘（间奏点+辉光 shader）→ 120fps。
    if (widget.isPlaying) {
      _interludeExpandProgress +=
          (interludeTarget - _interludeExpandProgress) *
          (1 - math.exp(-interludeSpeed * dt));
    } else {
      _interludeExpandProgress = interludeTarget;
    }
    // 收起到接近 0 时直接归零，避免无限逼近占着微小高度
    if (_activeInterludeIdx < 0 && _interludeExpandProgress < 0.001) {
      _interludeExpandProgress = 0;
      // 收起完成 = 间奏点生命周期的终点：占位已归零，圆点（属于占位行）
      // 与 anchor 一并释放。
      // **必须在此处收口**：progress 归零后画面随即收敛，同一帧末尾的
      // animConverged 判断会停掉 Ticker，之后不再有任何帧回调去执行
      // _updateInterlude 的收尾分支——若把释放放在那里，间奏点会永久
      // 停留在 _isActive（时钟冻结、状态悬空），任何后续帧都不会再清除它。
      _interludeDots.clear();
      _lastActiveAnchorIdx = _noInterludeAnchor;
    }

    // 7.5 逐行副行展开进度：目标由「副行显示范围」决定（见 [LyricAuxScope]），
    // 只有变化到目标的行会被推进（[_auxAnimating]），稳态帧零计算。
    // alpha 与位置共用同一进度（淡入淡出贯穿整个过渡时长，慢歌最多 ~1s
    // 清晰可感知），因此不维护独立的 fade 状态。
    // **暂停时也指数推进（不再吸附）**：切范围 / 开关切换 / 切行是用户主动
    // 触发的 UI 过渡而非播放驱动；推进到收敛后 animConverged 成立、Ticker
    // 自然停止，不会造成持续重绘。
    _advanceAuxProgress(dt, fastLineSwitch: fastLineSwitch);

    // 8. 级联弹簧延迟：检测当前行切换，从限幅后的视口顶部行自上而下错峰牵引
    if (_currentLineIndex >= 0 && _currentLineIndex != _previousLineIndex) {
      // 行切换时不再手动 reset scale：新当前行切换前作为非当前行已 settle 在
      // inactiveScale，_tickPerLineScales 下一帧检测到 target 变 activeScale，
      // 会自然从 0.850 弹到 1.0；离场行 target 变 inactiveScale，从 1.0 平滑缩回。
      // 两侧的缩放都是每行独立弹簧的连贯过渡，无需在此瞬间赋值。
      // 上一当前行退场交接：启动清晰层淡出，与模糊图接管重叠，消除硬切。
      // KRC 行退场前由 WordRenderer 绘制，其 LineRenderer 实例那一帧根本没被
      // 调用过（alpha 停在 0、setLineState 输入缓存判定"未变"而早退），
      // 必须把逐字 alpha 均值交接过去才有可淡出的量；
      // LRC/纯文本行退场前本就是该实例绘制，沿用当前值、只换成快速退场速度。
      final int outgoing = _previousLineIndex;
      if (outgoing >= 0 && outgoing < widget.lines.length) {
        final WordRenderer? outgoingWord = _wordRenderers[outgoing];
        final LineRenderer outgoingLine = _lineRendererFor(outgoing);
        final bool outgoingWasWordMode =
            outgoingWord != null && widget.lines[outgoing].hasWordTiming;
        // 退场淡出时长随该行歌词时长动态：快歌更快、慢歌最多 1s
        final double exitRate = _fadeRateForMs(widget.lines[outgoing].duration);
        outgoingLine.beginExitFadeFrom(
          outgoingWasWordMode
              ? outgoingWord.averageWordAlpha
              : outgoingLine.currentAlpha,
          rate: exitRate,
        );
      }
      // 新当前行入场模糊层：默认关闭（置 1.0 = 不显示，清晰层逐字入场）。
      //
      // 旧实现重置为 0 后让旧模糊图以 opacity=1 整块覆盖再指数淡出，
      // 造成「整行闪一下」而被停用。现在只在「模糊等级渐变切换」开启且
      // 高斯模糊生效时启用；起始不透明度改为该行原本的合成 alpha（见
      // _buildBlurLayers 入场层），让旧模糊图淡出与清晰层逐字淡入互补
      // 交接，不再出现满不透明的白块。
      _entryFadeDurationMs = LyricPreferences.instance.blurLevelFadeMs;
      // 等待期不淡出下一行的模糊图（它要保持模糊直到开唱）。
      _entryBlurProgress =
          (!_visualHold &&
                  LyricPreferences.instance.blurLevelCrossfade &&
                  LyricPreferences.instance.useGaussianBlur)
              ? 0.0
              : 1.0;
      if (fastLineSwitch) {
        // 快速连切兜底：跳过级联登记（延迟 60~750ms 永远等不到释放），
        // 直接把全部偏移弹簧归零、抵消基准对齐当前位置。
        _cascadeTopLine = math.max(0, _currentLineIndex - _cascadeTopLimit);
        _delayStartTimes.clear();
        for (final s in _perLineSprings.values) {
          s.setPosition(0, 0);
        }
        _cascadePosY = _scrollController.posY;
        // 轮次一并作废（快连切路径不消费时间线）。
        _cascadeRound = null;
      } else if (LyricPreferences.instance.staggerFromCurrentLine) {
        // 「错峰从当前行上方开始」开启：旧轮次口径不适用，先结算释放，
        // 再沿用历史登记（起点 = 当前行上一行领头）。
        _endCascadeRound(releaseHeld: true);
        // 抵消基准对齐切换帧：开启模式的登记不带压缩，基准必须为当前 posY。
        _cascadePosY = _scrollController.posY;
        _cascadeTopLine = _computeCascadeTopLine();
        final double now = _frameClockMs;
        final int startI = _cascadeTopLine;
        final int endI = math.min(
          widget.lines.length,
          _currentLineIndex + _overscan,
        );
        final int staggerStartLine = math.max(0, _currentLineIndex - 1);
        for (int i = startI; i < endI; i++) {
          _delayStartTimes[i] = i < staggerStartLine ? -1 : now;
        }
        _delayStartTimes.removeWhere((k, _) => k < startI);
      } else if (_cascadeRound?.anchorLine == _currentLineIndex) {
        // 预启动命中：时间线跨边界存活（不做重锚、不重登记）。
        final _CascadeRound round = _cascadeRound!;
        // 仍在等待期的行属于本轮流线（新当前行下方的行尚待逐行释放），
        // 既不能结算释放（会把下方波浪在边界一次性拍平），也不能重置
        // 抵消基准（锚点保持窗口起点，下方行"钉在预滚动前位置"的语义
        // 才连续）。这里只把统一口径的起点回写，供渲染窗口读取。
        _cascadeTopLine = round.startLine;
        _delayStartTimes.removeWhere((k, _) => k < round.startLine);
      } else {
        // 回落路径：按 `K×步长` 预算新建本轮（内部会先结算旧轮次残留）。
        _startCascadeRound(
          anchorLine: _currentLineIndex,
          preStarted: false,
        );
      }
    }
    _previousLineIndex = _currentLineIndex;
    // 切行帧减负：把下一行的逐字测量 / 副行图烘焙排到帧末（非动画帧），
    // 避免切行帧集中做这些与时间无关的同步工作。
    _schedulePrewarmNextLine();

    // 推进每行偏移弹簧（自上而下瀑布：从 _cascadeTopLine 开始）
    // 性能优化：只覆盖 [_cascadeTopLine, currentLineIndex + overscan] 视口内行，
    // 视口外的行弹簧偏移对渲染不可见，无需每帧推进。
    // 快速连切兜底帧：偏移已全部归零、延迟表已清空，整段级联计算直接跳过。
    // P1-G: 顺带聚合"弹簧偏移是否有显著变化（>0.5px）"，替代
    // _hasPerLineOffsetChanged 的二次 O(N) 遍历。仅检查视口内行——
    // 视口外行偏移对渲染不可见，无需触发重绘。
    bool anySpringOffsetChanged = false;
    final double posYNow = _scrollController.posY;
    // 本帧滚动速度（px/s，向上为负）。等待期行在屏幕上被钉死（速度 0），
    // 释放瞬间若只把弹簧位移接上、初速给 0，整块行会突然以滚动速度起飞
    // ——「上拉到位时速度突变」，有翻译副行（行块更高、目标随副行展开而
    // 持续移动）时更明显。释放时注入 `-滚动速度` 作初速，屏幕速度从 0
    // 连续过渡到弹簧回弹。
    final double? prevPosYForVel = _lastFramePosY;
    final double scrollVel = (prevPosYForVel == null || dt <= 0)
        ? 0.0
        : ((posYNow - prevPosYForVel) / dt).clamp(-4000.0, 4000.0);
    if (!fastLineSwitch) {
      // AMLL 风格级联延迟：delayMs 为逐行累积延迟，baseStepMs 为当前错峰步长。
      // 步长 / 上限 / 衰减均可由用户在设置页"歌词动画"调节（无极）。
      // 循环外读一次偏好，避免每帧重复访问。
      final double cascadeMaxDelay = LyricPreferences.instance.cascadeMaxDelayMs;
      final double cascadeBaseStep = LyricPreferences.instance.cascadeBaseStepMs;
      final double cascadeDecay = LyricPreferences.instance.cascadeStepDecay;
      final bool staggerFromCurrent =
          LyricPreferences.instance.staggerFromCurrentLine;
      // 关闭模式下本轮的时间线（预启动 / 回落共用）；开启模式恒为 null。
      final _CascadeRound? round = staggerFromCurrent ? null : _cascadeRound;
      final int springStartI = round?.startLine ?? _cascadeTopLine;
      final int springEndI = math.min(
        widget.lines.length,
        _currentLineIndex + overscan,
      );
      // 锚行：本轮必须对齐释放的行（预启动窗口内是下一行，边界后是新当前行）。
      final int anchorLine = round?.anchorLine ?? _currentLineIndex;
      // 错峰起点行：开启 = 当前行再往上一行（上一行领头回位）；关闭 = 轮次
      // 起点（此时累加不受起点门控，见下方 delayMs 累加条件）。
      final int staggerStartLine = staggerFromCurrent
          ? math.max(0, _currentLineIndex - 1)
          : springStartI;
      double delayMs = 0;
      double baseStepMs = cascadeBaseStep;
      // —— 关闭模式的延迟压缩（统一口径） ——
      // 轮次已把「预启动」与「回落」合并成一条时间线：`scale` 只压缩锚行
      // 以上的行，锚行延迟 = (anchor−start)×步长×scale。
      //   scale = 1         → 原始步长瀑布（预启动窗口足够长）；
      //   0 < scale < 1     → 等比压缩进剩余时间（迟到进窗）；
      //   回落路径          → scale 由 K×步长预算推出，滞后恒 ≤ K×步长。
      // 上方行必须一并压缩：等待期行被抵消量钉在切换瞬间位置，若只提前
      // 释放锚行而上方行仍被钉住，锚行回位时会向上叠进上方行（布局重叠）。
      double currentCompMs = 0;
      double aboveScale = 1.0;
      if (round != null) {
        aboveScale = round.scale;
        currentCompMs = math.max(
          0.0,
          (round.anchorLine - round.startLine) *
              cascadeBaseStep *
              (1 - round.scale),
        );
      }
      // 时间线用**帧时钟**而非 Ticker 的 `elapsed`：非逐字歌词播放中会「收敛
      // 停帧」省电，Ticker 每次重启都把 elapsed 归零（见 _startTickerIfNeeded），
      // 跨重启用 elapsed 做差会得到负值 → 等待行的延迟永远算不满、被抵消量
      // 钉在原地数秒不随滚动走（表现为该行悬浮/与相邻行重叠，观感像"上飞"）。
      // _frameClockMs 逐帧累加 dt，跨 Ticker 重启保持单调。
      final double nowMs = _frameClockMs;
      // 抵消量：切换帧为 0，随全局 posY 上移而增大（= 该行"本该已经走掉"的距离）
      final double holdOffset = _cascadePosY - posYNow;
      // 上方行压缩仅在「关闭模式且补偿生效」（aboveScale != 1.0）时发生，
      // 折叠成局部布尔：循环内只查局部变量，避免每行重复判断偏好与乘法。
      final bool scaleAboveLines = aboveScale != 1.0;
      bool anyHeldInWindow = false;
      for (int i = springStartI; i < springEndI; i++) {
        // 关闭模式补偿：到达锚行时先一次性前移 currentCompMs（使锚行延迟
        // 等于 (anchor−start)×步长×scale），再参与本行的释放判定；锚行
        // 以下以补偿后的基准继续累加，相对节奏不变（上限 min(·, maxDelay)
        // 照常作用于补偿后的值）。开启模式 currentCompMs=0，减法恒等。
        if (i == anchorLine) {
          delayMs -= currentCompMs;
        }
        final double? start = _delayStartTimes[i];
        final bool held = start != null && start >= 0;
        if (held) {
          anyHeldInWindow = true;
          // 惰性求值：lineDelay（min + 条件乘法）只有等待期行会消费，
          // 不为已释放行白算——稳态帧（绝大多数帧）整段少一次 min 与
          // 条件乘法，基准实测比无补偿的原版还快（见 tmp/bench_cascade）。
          final double effectiveDelayMs =
              scaleAboveLines && i < anchorLine
                  ? delayMs * aboveScale
                  : delayMs;
          if ((nowMs - start) >= math.min(effectiveDelayMs, cascadeMaxDelay)) {
            // 延迟到期 → 释放：弹簧起点 = 残留值 + 当前抵消量，目标 0。
            // 从抵消量接着弹回，而不是从 0 重新跳过去，保证整条曲线连续。
            // 初速注入 -滚动速度：等待期行屏幕速度恒 0，释放瞬间若从静止
            // 起飞会「速度突变」，这样做屏幕速度连续（见 scrollVel 注释）。
            final s = _perLineSpringFor(i);
            s.setPosition(s.position + holdOffset, -scrollVel);
            s.setTarget(0);
            _delayStartTimes[i] = -1;
          }
        } else {
          // 已释放（或从未参与级联）：正常推进弹簧直到收敛。
          // 等待期内刻意不 tick —— 弹簧冻结在残留基数上，作为释放时的起点。
          _perLineSprings[i]?.tick(dt);
        }
        if (i < _reusedPerLineOffsets.length &&
            (_effectiveLineOffset(i) - _reusedPerLineOffsets[i]).abs() > 0.5) {
          anySpringOffsetChanged = true;
        }
        // 为下一行累加本轮步长；且越过锚行后，步长对本轮下一次使用递减。
        // AMLL 语义：先累加本行（锚行用未衰减步长），再衰减供下一行使用
        // （baseDelay *= 1/1.05），实现"越过锚行后先密后疏、总延迟收敛"。
        // 「错峰从当前行开始」开启时：起点行（当前行-1）之前的行不累加延迟
        // ——起点行 delay=0，当前行带一步延迟，向下逐行递增（上方行即使有
        // 残留登记也早已释放，累加值无效）。
        if (!staggerFromCurrent || i >= staggerStartLine) {
          delayMs += baseStepMs;
        }
        if (i >= anchorLine) {
          baseStepMs *= cascadeDecay;
        }
      }
      // 本轮已无等待行 → 收口。仅在本轮锚行已成为当前行之后判定：预启动
      // 窗口内 loop 上界（当前行 + overscan）可能少覆盖最后一行登记，提前
      // 收口会留下「无轮次」的等待行。避免旧轮次 scale/锚点残留到下一轮
      //（历史 `_cascadeTimelinePreStarted` 跨轮存活正是补偿互相覆盖的来源）。
      if (round != null &&
          round.anchorLine <= _currentLineIndex &&
          !anyHeldInWindow) {
        _cascadeRound = null;
      }
    }

    // 级联不连续保护：抵消量没有上界，异常场景下会把整块歌词"粘"住。
    final double linePitch =
        (_cachedFontSize > 0 ? _cachedFontSize : LyricLayout.fontSize(context)) *
        LyricLayout.lineHeight;
    final double? prevPosY = _lastFramePosY;
    final double? prevTargetY = _lastFrameTargetY;
    final double targetYNow = _scrollController.currentTarget;
    final bool userBusy =
        _scrollController.isUserScrolling ||
        _scrollController.isWaitingForAutoReturn;
    // 目标一次跳多行 = 真 seek（点击跳行 / 换源）。用户拖动期间 target 不动，
    // 不参与判定。
    final bool targetJumped =
        prevTargetY != null &&
        !userBusy &&
        (targetYNow - prevTargetY).abs() > linePitch * 1.5;
    // posY 单帧跳变放宽到 2 行：预启动窗口内一次长帧（dt 抖动）不应被误判成
    // seek，否则会把整轮等待行一次性释放（错峰被拦腰打断的冲突来源）。
    final bool posJumped =
        prevPosY != null && (posYNow - prevPosY).abs() > linePitch * 2;
    if (targetJumped || posJumped) {
      _cascadePosY = posYNow;
      _endCascadeRound(releaseHeld: true);
    }
    // 用户拖动 / 等待回弹期间不做抵消：手动滚动没有"切换前位置"可言，
    // 抵消会让手指下的歌词出现橡皮筋拖尾。
    if (userBusy) {
      _cascadePosY = posYNow;
    }
    _lastFramePosY = posYNow;
    _lastFrameTargetY = targetYNow;

    // 10. 模糊渐隐动画：滚动/等待时淡出到0，回弹开始后淡入到1
    final bool shouldBlurFadeOut =
        _scrollController.isUserScrolling ||
        _scrollController.isWaitingForAutoReturn;
    final double blurFadeTarget = shouldBlurFadeOut ? 0.0 : 1.0;
    // 修复：淡入速度 4.0 → 12.0，约 150ms 完成（原 700-1000ms）。
    // 配合修改 1，模糊图在新当前行周围快速淡入出现。
    final double blurFadeSpeed = shouldBlurFadeOut ? 15.0 : 12.0;
    _blurFade +=
        (blurFadeTarget - _blurFade) * (1 - math.exp(-blurFadeSpeed * dt));
    if ((_blurFade - blurFadeTarget).abs() < 0.01) {
      _blurFade = blurFadeTarget;
    }

    // 10.5 入场模糊淡出：用触发时设定的时长线性推进（正常切行 =
    // 时长滑块；提前换行激活 = 180ms 短淡出）。无过渡时该值恒 1。
    if (_entryBlurProgress < 1.0) {
      // 两条驱动取较快者：
      // - byClear（该行演唱进度）：保证模糊层不会比清晰层退得慢 → 不重影；
      // - byTime（时长上限）：保证模糊层不会拖到整行唱完 → 不糊着。
      // 上限由「模糊褪去时长」滑块控制（提前换行路径），正常切行仍用
      // 「模糊等级渐变时长」。两者取 max 是「谁先退完跟谁」，任一方都不会
      // 把另一方顶回去。
      final double durationMs = math.max(1.0, _entryFadeDurationMs);
      final double byTime = _entryBlurProgress + dt * 1000.0 / durationMs;
      final double byClear = _clearAlphaOf(_currentLineIndex);
      _entryBlurProgress = math.min(1.0, math.max(byTime, byClear));
    }

    // 10.6 模糊等级交叉淡入淡出（默认关闭）：复用本帧时钟推进，
    // 不新增驱动源。与切行时既有的 posY / scale 弹簧窗口共帧，
    // 逐字歌词播放中零边际帧提交。
    if (_blurLevelFade < 1.0) {
      final double durationMs = LyricPreferences.instance.blurLevelFadeMs;
      if (durationMs <= 0.0) {
        _finishBlurLevelFade();
      } else {
        _blurLevelFade = math.min(
            1.0, _blurLevelFade + dt * 1000.0 / durationMs);
        if (_blurLevelFade >= 1.0) _finishBlurLevelFade();
      }
    }

    // 11. v3 优化：检测是否暂停且所有动画都已收敛到稳态。
    // 收敛条件：
    //   - 暂停中（!widget.isPlaying）
    //   - scroll controller 已收敛（无用户滚动、无等待回弹、posY 弹簧稳定）
    //   - scale 弹簧已收敛
    //   - 模糊 fade 已到目标
    //   - 间奏 progress 已到目标
    //   - perLine 偏移弹簧全部已收敛
    //   - 视口附近 renderer alpha 已收敛
    // 收敛时停止 Ticker，恢复播放或用户交互时由 didUpdateWidget /
    // _onTapDown / _onVerticalDragUpdate 重新启动。
    // P0-A：非逐字歌词（LRC 逐行 / 纯文本，整首歌无 word timing）在播放中
    // 画面同样静止（无逐字渐变/上浮/辉光），允许播放中停 Ticker 省电；
    // position 更新（约 200ms）由 didUpdateWidget 唤醒一帧检查即可。
    // 逐字歌词（KRC / 字级 LRC，含本地/云盘音乐的 LRC 逐字）必须保持
    // Ticker 持续推进动画，由 canStopWhilePlaying 排除。
    // 间奏激活期间（_activeInterludeIdx >= 0）间奏点有呼吸/亮起动画，
    // 也不能停 Ticker，否则圆点冻结。
    final bool animConverged =
        _scrollController.isConverged &&
        _arePerLineScalesConverged() &&
        (_blurFade - blurFadeTarget).abs() < 0.001 &&
        _blurLevelFade >= 0.999 &&
        _entryBlurProgress >= 0.999 &&
        (_interludeExpandProgress - interludeTarget).abs() < 0.001 &&
        // 逐行副行进度：没有任何行偏离目标即收敛（「所有行」稳态即为空）
        _auxAnimating.isEmpty;
    // P1-G: perLine 弹簧 / renderer 的收敛检测（各 O(±10 行) 遍历）只在
    // 需要"停 Ticker 决策"时执行：逐字歌词播放中永远不会停（P0-A 排除），
    // 跳过这两个循环；非逐字播放中仅每 200ms 唤醒帧执行一次。
    final bool needsStopDecision =
        !widget.isPlaying || !_cachedHasAnyWordTiming;
    final bool canStopWhilePlaying =
        !_cachedHasAnyWordTiming && _activeInterludeIdx < 0;
    final bool deepConverged =
        !needsStopDecision ||
        (_arePerLineSpringsConverged() && _areRenderersConverged());
    if (animConverged &&
        deepConverged &&
        (!widget.isPlaying || canStopWhilePlaying)) {
      _stopTickerIfNeeded();
      // 同时停掉 eco 限帧 Timer：静态画面无需继续驱动 _onTick
      //（否则 Timer 每 16ms 触发一次 setState，仍会产生 60fps 空帧）。
      if (_ecoDriverBound) {
        PlayerFrameDriver.instance.removeListener(_onEcoFrameTick);
        _ecoDriverBound = false;
      }
      // 最后一帧 setState 确保稳态画面渲染；两层各补一次重绘，
      // 避免持久化 painter 实例未变时 CustomPaint 不重画。
      _textRepaint.fireRepaint();
      _currentTextRepaint.fireRepaint();
      _blurRepaint.fireRepaint();
      setState(() {});
      return;
    }

    // 12. v3 优化：检测本帧是否有视觉变化，无变化则跳过 setState。
    // 检测阈值（0.5px / 0.001）远低于人眼感知，肉眼不可见的变化才跳过。
    final double currentPosY = _scrollController.posY;
    // P1-1：区分「几何/布局变化」与「仅当前行逐字动画」。
    // 前者两层都要重绘，后者只重绘当前行层（其余行保持静态位图）。
    final bool geometryChanged =
        _currentLineIndex != _lastRepaintCurrentLineIndex ||
        // P1-1：焦点行 / 视觉冻结 / 行集几何变化都要重绘两层，
        // 否则其余行层会保留「跳过旧焦点行」的旧位图，与当前行层叠加成重影。
        _focusLineIndex != _lastRepaintFocusIndex ||
        _visualHold != _lastRepaintVisualHold ||
        _linesGeneration != _lastRepaintLinesGeneration ||
        _lineHeightsGeneration != _lastRepaintLineHeightsGeneration ||
        _lineTopsGeneration != _lastRepaintLineTopsGeneration ||
        (currentPosY - _lastRepaintPosY).abs() > 0.5 ||
        anyScaleChanged ||
        (_blurFade - _lastRepaintBlurFade).abs() > 0.001 ||
        (_entryBlurProgress - _lastRepaintEntryBlur).abs() > 0.001 ||
        (_blurLevelFade - _lastRepaintBlurLevelFade).abs() > 0.001 ||
        (_interludeExpandProgress - _lastRepaintInterludeProgress).abs() >
            0.001 ||
        // 逐行副行进度任一变化（多行同时下行/上行时单值差分不可用，用代次）
        _auxProgressGeneration != _lastRepaintAuxGeneration ||
        // P1-G: 复用 renderer tick / spring 推进循环的聚合结果，避免二次遍历
        anySpringOffsetChanged;
    // P0: 暂停时间奏点动画已冻结（tick 跳过、画面静止），
    // shouldRender 仅表示"处于间奏时段"，不应再驱动每帧重绘
    final bool interludeAnimating =
        widget.isPlaying && _interludeDots.shouldRender;
    final bool hasVisualChange =
        geometryChanged || anyRendererAnimating || interludeAnimating;

    if (hasVisualChange) {
      _lastRepaintCurrentLineIndex = _currentLineIndex;
      _lastRepaintFocusIndex = _focusLineIndex;
      _lastRepaintVisualHold = _visualHold;
      _lastRepaintLinesGeneration = _linesGeneration;
      _lastRepaintLineHeightsGeneration = _lineHeightsGeneration;
      _lastRepaintLineTopsGeneration = _lineTopsGeneration;
      _lastRepaintPosY = currentPosY;
      _lastRepaintBlurFade = _blurFade;
      _lastRepaintEntryBlur = _entryBlurProgress;
      _lastRepaintBlurLevelFade = _blurLevelFade;
      _lastRepaintInterludeProgress = _interludeExpandProgress;
      _lastRepaintAuxGeneration = _auxProgressGeneration;
      // P0-1 方案 A：统一走持久化 painter 快路径（repaintNotifier 驱动文字层重绘），
      // 避免每帧 setState + build 重建整个 widget tree（LayoutBuilder/GestureDetector/
      // ShaderMask/模糊层 Stack）。
      if (_painter != null) {
        // 每帧只构建一次偏移表：_buildPerLineOffsets 会递增代次，
        // 两层必须共享同一份列表，否则当前行层与其余行层坐标不一致。
        final List<double> offsets = _buildPerLineOffsets();
        void update(_LyricsPainter p) {
          p.updatePerFrame(
            focusLineIndex: _focusLineIndex,
            activationHeld: _visualHold,
            posY: currentPosY,
            currentTimeMs: _authorityTimeMs,
            blurFade: _clearLayerBlurFade,
            interludeExpandProgress: _interludeExpandProgress,
            activeInterludeIdx: _activeInterludeIdx,
            lastActiveAnchorIdx: _lastActiveAnchorIdx,
            auxProgress: _auxProgress,
            auxTargets: _auxTargets,
            auxTopsPrefix: _auxTopsPrefix,
            auxProgressGeneration: _auxProgressGeneration,
            auxSubHeights: _auxSubHeights,
            perLineOffsets: offsets,
            perLineOffsetsGeneration: _perLineOffsetsGeneration,
            perLineScales: _reusedPerLineScales,
          );
        }

        update(_painter!);
        if (_currentPainter != null) update(_currentPainter!);
        // 当前行层：几何变化 / 当前行动画 / 间奏点动画。
        if (geometryChanged || anyActiveRendererAnimating || interludeAnimating) {
          _currentTextRepaint.fireRepaint();
        }
        // 其余行层：几何/布局变化或非当前行淡入淡出才重绘。
        if (geometryChanged || anyNonActiveRendererAnimating) {
          _textRepaint.fireRepaint();
        }
      } else {
        setState(() {});
      }
    }

    // 12.5 模糊层单独门控：只有几何/透明度/图集变化才重绘。
    // 逐字 alpha 与 renderer 动画（anyRendererAnimating）不进这里，
    // 稳态逐字演唱时模糊层保持静止，不再每帧重画十几张全宽纹理。
    final bool blurVisualChange =
        _currentLineIndex != _lastBlurRepaintLine ||
        _visualHold != _lastBlurRepaintVisualHold ||
        _introInterludeOwnsSlot != _lastBlurRepaintHeadSlot ||
        (currentPosY - _lastBlurRepaintPosY).abs() > 0.5 ||
        anyScaleChanged ||
        anySpringOffsetChanged ||
        (_blurFade - _lastBlurRepaintBlurFade).abs() > 0.001 ||
        (_entryBlurProgress - _lastBlurRepaintEntryBlur).abs() > 0.001 ||
        (_blurLevelFade - _lastBlurRepaintLevelFade).abs() > 0.001 ||
        (_interludeExpandProgress - _lastBlurRepaintInterlude).abs() > 0.001 ||
        _auxProgressGeneration != _lastBlurRepaintAuxGeneration ||
        _activeInterludeIdx != _lastBlurRepaintActiveInterlude ||
        _lastActiveAnchorIdx != _lastBlurRepaintAnchor;
    if (blurVisualChange) {
      _lastBlurRepaintLine = _currentLineIndex;
      _lastBlurRepaintVisualHold = _visualHold;
      _lastBlurRepaintHeadSlot = _introInterludeOwnsSlot;
      _lastBlurRepaintPosY = currentPosY;
      _lastBlurRepaintBlurFade = _blurFade;
      _lastBlurRepaintEntryBlur = _entryBlurProgress;
      _lastBlurRepaintLevelFade = _blurLevelFade;
      _lastBlurRepaintInterlude = _interludeExpandProgress;
      _lastBlurRepaintAuxGeneration = _auxProgressGeneration;
      _lastBlurRepaintActiveInterlude = _activeInterludeIdx;
      _lastBlurRepaintAnchor = _lastActiveAnchorIdx;
      _blurRepaint.fireRepaint();
    }
    // 无视觉变化：跳过 setState，节省 build + shouldRepaint 开销
  }

  /// 检测当前时间是否处于某个间奏时段，更新 [_activeInterludeIdx] 和 [_interludeDots]。
  ///
  /// 严格 AMLL 逻辑：遍历所有 [_interludeAfterIndices]，
  /// 找到第一个满足 `gapStart <= currentTime < gapEnd` 的间奏，
  /// 设置为激活间奏（占位动态展开 0 → totalHeight）。
  /// 若无激活，则清除间奏点并收起占位（totalHeight → 0）。
  ///
  /// 间奏时段：[line.endTime, next.startTime - interludeEarlyEndMs]，
  /// 250ms 提前结束以准备下一行渲染（与 AMLL 一致）。
  ///
  /// **间奏点同步收起**：间奏结束后不立即 `clear()` 间奏点，
  /// 让 `_animationTimeMs` 继续推进到 `interludeDuration`，
  /// 间奏点会自然完成消失动画（最后 750ms easeInBack 缩小）。
  /// 占位收起与点消失同步进行（都是 ~300-750ms）。占位收起完成后的
  /// `clear()` + anchor 释放由推进循环的归零分支收口（见 `_onTick`）。
  /// 该"继续播完消失动画"的行为只适用于**自然结束**（`isInExitPhase`）；
  /// 点击其他行歌词跳转 / seek 离开间奏时时钟仍在间奏早期，必须立即清除
  /// 圆点，否则会悬浮穿帮（见下方 else 分支）。
  /// [forceDotsReset] 为 true 时，即使命中的间奏与当前激活相同，也强制重置
  /// 间奏点动画时钟（`_interludeDots.setInterlude(..., forceReset: true)`）。
  /// 用于 seek/跳转回跳：幂等保护会忽略相同间奏，导致动画时钟从旧进度继续，
  /// 一旦超过间奏总时长，间奏点会直接隐藏（识别为"未启用"）。
  ///
  /// [alignDotsToRealTime] 为 true 时，把间奏点动画时钟对齐到
  /// `currentTimeMs - gapStart`（真实窗口内偏移）。用于 Ticker 被 mute
  /// （切走 tab / 退后台）后恢复：帧时钟冻结期间歌曲继续播放，动画时钟
  /// 滞后于真实进度，对齐后间奏点立即处于正确阶段，而非重置重播入场动画。
  ///
  /// [naturalAdvance] 为 true 表示权威时间是连续推进离开间奏窗口（自然结束），
  /// 此时即使帧时钟尚未走到消失段也要补帧，保证圆点播完缩小动画而不是直接消失。
  void _updateInterlude({
    bool forceDotsReset = false,
    bool alignDotsToRealTime = false,
    bool naturalAdvance = false,
  }) {
    int foundIdx = -1;
    int? gapStart;
    int? gapEnd;
    int? foundAnchorIdx;
    for (int i = 0; i < _interludeAfterIndices.length; i++) {
      final int lineIdx = _interludeAfterIndices[i];
      final int anchorIdx;
      final int start;
      final int end;
      if (lineIdx == _interludeIntroIndex) {
        // 头部间奏：窗口 [0, 首行起点 - 提前量)，占位落在首行之前。
        // anchor 记为 -1（而非 0）：占位对包括首行在内的所有行生效，圆点画在
        // 第一行上方；若记 0 会变成"第一行之后"，圆点被推到第一行下面。
        if (widget.lines.isEmpty) continue;
        anchorIdx = _interludeIntroIndex;
        start = 0;
        end = widget.lines.first.startTime - LyricLayout.interludeEarlyEndMs;
      } else {
        if (lineIdx < 0 || lineIdx >= widget.lines.length - 1) continue;
        final current = widget.lines[lineIdx];
        final next = widget.lines[lineIdx + 1];
        // 激活窗口起点与 gap 判定（_recomputeLineHeightsIfNeeded）保持一致，
        // 均用"人声实际结束时间"（KRC 行 duration 覆盖尾音/空白时窗口起点会偏晚，
        // 导致短暂处于真实空档却未激活间奏点）。
        anchorIdx = lineIdx;
        start = AppleLyricsView.effectiveLineEndTime(current);
        end = next.startTime - LyricLayout.interludeEarlyEndMs;
      }
      if (_authorityTimeMs >= start && _authorityTimeMs < end) {
        foundIdx = i;
        gapStart = start;
        gapEnd = end;
        foundAnchorIdx = anchorIdx;
        break;
      }
    }

    _activeInterludeIdx = foundIdx;

    if (foundIdx >= 0 && gapStart != null && gapEnd != null) {
      // 先确保间奏状态正确（新间奏会重置时钟，幂等命中的相同间奏保留），
      // 再按需校正动画时钟。
      _interludeDots.setInterlude(gapStart, gapEnd, forceReset: forceDotsReset);
      // 时钟漂移校正：帧时钟由驱动步进累积，省电模式下心智步长（名义 16ms）
      // 慢于真实 vsync，会稳定落后真实进度。旧实现要落后满 1000ms 才一次性
      // 硬对齐，收起前段表现为 scale 突跳一档；现改为每次权威位置更新
      // （约 200ms 一次）**单向按比例追前**（补掉残差的一半，单次 ≤100ms）：
      // 追平速率恒高于漂移速率，稳态残差约 16ms（肉眼不可见），因此正常播放
      // 几乎不会再触发下面的硬对齐分支。
      //
      // 仅当滞后达到**粗粒度**（Ticker mute / 页面重建，新 State 时钟从 0 起）
      // 时才一次性硬对齐：这种场景下小步追永远追不上，而硬跳不产生可见跳变
      // （圆点尚未按旧时钟画过，或本就停在错误阶段）。
      if (alignDotsToRealTime ||
          _interludeDots.shouldRealignTo(_authorityTimeMs, driftMs: 1000)) {
        // Ticker mute / 页面重建：滞后可能是整段（数秒），需一次性对齐，
        // 否则圆点会停留在错误阶段（表现为"跟不上进度"）。
        _interludeDots.alignToRealTime(_authorityTimeMs);
      } else {
        _interludeDots.correctDriftGently(_authorityTimeMs);
      }
      // 记录最后激活的 anchor 行索引（用于间奏结束后继续计算占位偏移）
      if (foundAnchorIdx != null) {
        _lastActiveAnchorIdx = foundAnchorIdx;
      }
    } else {
      // 间奏结束：不立即 clear() 间奏点
      // 让 _animationTimeMs 继续推进到 interludeDuration，
      // 间奏点会自然完成消失动画（最后 750ms easeInBack 缩小）
      //
      // 但仅限"自然结束"（时钟已在消失阶段）。用户点击其他行歌词跳转 /
      // 拖动进度条 seek 离开间奏时，时钟可能还停在间奏早期（长间奏尤甚），
      // 此时若放任其继续推进，满尺寸、满不透明度的圆点会在占位收起的
      // ~750ms 内悬浮在原 anchor 行，与已切换的歌词同屏 → 穿帮。
      // 这种情况直接清除圆点（_lastActiveAnchorIdx 不在此重置：占位偏移
      // 仍由 _interludeExpandProgress 平滑收起，避免下方行瞬间跳位）。
      //
      // 判定分两条：
      // 1. 权威时间连续推进跨过窗口终点（naturalAdvance）= 自然结束 →
      //    只前进地补到消失段起点，圆点从当前尺寸连续播完消失动画。这是
      //    省电模式收起卡顿的直接修复点：帧时钟被驱动名义步长拖慢后，长间奏
      //    自然结束时可能还没走进消失段，旧的 isInExitPhase 二元判定会把这种
      //    自然结束误判成"跳转离开"而立即 clear（圆点没有缩小过程直接消失）。
      // 2. 时间大跳（seek / 点击其他行）离开 → 维持原严格语义：时钟未到消失段
      //    就立即清除。满尺寸圆点若继续显示，会在占位收起期间悬浮在已切换的
      //    歌词上（穿帮回归护栏的场景）。
      if (naturalAdvance) {
        _interludeDots.snapToExitPhase();
      } else if (!_interludeDots.isInExitPhase) {
        _interludeDots.clear();
      }
    }
    // 注意：间奏点动画时间由 _onTick 中的 _interludeDots.tick(dt) 推进，
    // 不依赖 currentTimeMs（positionStream 5fps 太卡）
  }

  // ============== 点击跳转与手动滚动 ==============

  void _onTapDown(TapDownDetails details) {
    // 用户交互唤醒驱动：统一走 _syncEcoDriver（eco 锁定 → Timer；否则 Ticker），
    // 避免裸起 Ticker 造成与 60fps Timer 并存、Ticker 被 mute 时 Timer 空转
    _syncEcoDriver();
    _tapDownPosition = details.localPosition;
  }

  void _onTapUp(TapUpDetails details) {
    final downPos = _tapDownPosition;
    if (downPos == null) return;
    _tapDownPosition = null;
    // 移动距离 < clickThresholdPx(10px) 视为点击，否则视为滚动
    final delta = (details.localPosition - downPos).distance;
    if (delta >= LyricLayout.clickThresholdPx) return;

    // 计算点击 y 对应的行索引：用预计算的 lineTops（支持非均匀行高）
    // 每行的实际 top = lineTops[i] + _interludeOffsetBefore(i)，
    // 找第一个 (lineTops[i+1] + interludeOffset) + posY > clickY 的 i（即 clickY 落在第 i 行内）
    final posY = _scrollController.posY;
    final relativeY = details.localPosition.dy - posY;
    if (_lineTops.isEmpty) return;
    int index = -1;
    for (int i = 0; i < _lineTops.length; i++) {
      final top =
          _lineTops[i] + _interludeOffsetBefore(i) + _transDeltaBefore(i);
      final height =
          (_lineHeights.length > i ? _lineHeights[i] : 0) +
          _transExtraHeightFor(i);
      if (relativeY >= top && relativeY < top + height) {
        index = i;
        break;
      }
    }
    if (index < 0 && _lineTops.isNotEmpty) {
      // 兆底：找最接近的行
      index = (_lineTops.length - 1).clamp(0, widget.lines.length - 1);
    }
    if (index >= 0 && index < widget.lines.length) {
      AppHaptics.tick(HapticCategory.gesture);
      widget.onSeek?.call(widget.lines[index].startTime);
    }
  }

  /// 双击跳转：使用 onDoubleTapDown 已存储的 _tapDownPosition 触发跳转。
  void _triggerDoubleTapSeek() {
    final downPos = _tapDownPosition;
    if (downPos == null) return;
    _tapDownPosition = null;

    final posY = _scrollController.posY;
    final relativeY = downPos.dy - posY;
    if (_lineTops.isEmpty) return;
    int index = -1;
    for (int i = 0; i < _lineTops.length; i++) {
      final top =
          _lineTops[i] + _interludeOffsetBefore(i) + _transDeltaBefore(i);
      final height =
          (_lineHeights.length > i ? _lineHeights[i] : 0) +
          _transExtraHeightFor(i);
      if (relativeY >= top && relativeY < top + height) {
        index = i;
        break;
      }
    }
    if (index < 0 && _lineTops.isNotEmpty) {
      index = (_lineTops.length - 1).clamp(0, widget.lines.length - 1);
    }
    if (index >= 0 && index < widget.lines.length) {
      widget.onSeek?.call(widget.lines[index].startTime);
    }
  }

  /// 用户垂直拖动歌词：调用 scrollController.onUserScroll 偏移 posY 并重置 5s 回弹倒计时。
  ///
  /// 之前只挂了 onTapDown/onTapUp，导致用户无法上下滑动歌词（spec 要求
  /// 用户滚动后 5s 自动回弹到当前行）。这里补上 onVerticalDragUpdate/End。
  void _onVerticalDragUpdate(DragUpdateDetails details) {
    // 省电模式：用户开始滑动歌词立即解锁帧率限制（保持 120Hz 顺滑滚动）。
    // 必须立刻同步驱动源：取消 60fps Timer、确认 Ticker 在跑，
    // 否则要等下一帧 _onTick 里的 _syncEcoDriver 才切，拖动首帧会多走一次 60fps。
    _ecoUnlocked = true;
    _syncEcoDriver();
    _scrollController.onUserScroll(details.primaryDelta ?? 0);
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    // 传递松手时的垂直速度给 scrollController，用于惯性滚动
    // velocity.pixelsPerSecond.dy 单位 px/s，向下为正
    _scrollController.onUserScrollEnd(
      velocity: details.velocity.pixelsPerSecond.dy,
    );
  }

  /// 鼠标滚轮滚动（Windows 桌面）：滚轮事件不走拖拽手势竞技场，
  /// 必须 Listener.onPointerSignal 显式接收。
  ///
  /// 方向语义：scrollDelta.dy > 0（滚轮向下）= 看后面的行 → posY 减小，
  /// 与 scrollController.posY 的「越负内容越靠后」约定一致，故取负号。
  /// 驱动源处理同 [_onVerticalDragUpdate]：弹簧已收敛时驱动源已停，
  /// 必须先踢活（解锁满帧），否则滚轮事件后画面不动；滚完由 _onTick
  /// 的 eco 重估自动锁回 60fps。5s 自动回弹由 controller 倒计时链路接管。
  ///
  /// **Shift+滚轮让位**：按住 Shift（框架 `ScrollBehavior.pointerAxisModifiers`）
  /// 时滚轮被外层 `PlayerTabPager` 的 PageView 翻转为横向轴切页——此时本视图
  /// 必须不注册 resolver 回调，否则两层都处理（框架 Scrollable 注册在前、
  /// 本 Listener 命中路径更深却在 resolver 里「先到先得」，实测两端都会动）。
  /// 与框架 `Scrollable._pointerSignalEventDelta` 同一套修饰键口径。
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    if (pressed.contains(LogicalKeyboardKey.shiftLeft) ||
        pressed.contains(LogicalKeyboardKey.shiftRight)) {
      return;
    }
    _ecoUnlocked = true;
    _syncEcoDriver();
    _scrollController.onUserWheelScroll(-event.scrollDelta.dy);
  }

  // ============== 构建 ==============

  @override
  Widget build(BuildContext context) {
    // 根据屏幕最短边判断设备类型：>= 600dp 视为 pad（平板），更新 overscan 缓冲行数
    final shortestSide = MediaQuery.of(context).size.shortestSide;
    _overscan = shortestSide >= 600 ? 15 : 10;
    // 动态字体颜色：仅 AM 播放器（深色背景）且开关开启且提取到封面颜色时，
    // 当前行歌词颜色 = 白色与提取色按「混色比例」线性混色；自定义歌词文字色
    // 优先级更高。混色后再兜底提升明度（≥0.78），保证深色背景上的可读性；
    // 仅抬升明度、保留色相与饱和度，视觉上仍是封面色调的浅色。
    final customTextColor = LyricPreferences.instance.customTextColor;
    _activeLineColorValue = resolveActiveLineColorValue(
      useDynamicColor: widget.forceDarkBackground &&
          LyricPreferences.instance.useDynamicLyricColor,
      accentColor: widget.accentColor,
      customTextColor: customTextColor,
      mixRatio: LyricPreferences.instance.dynamicColorMixRatio,
    );
    // 上方行是否跟随已播颜色：独立开关，默认关闭（= 历史白色背景行）。
    _aboveLineColorValue =
        LyricPreferences.instance.useAboveLinesPlayedColor
            ? _activeLineColorValue
            : null;
    // 根据主题亮度设置歌词文字颜色：
    // - AM 风格（forceDarkBackground=true）→ 始终白色
    // - 深色主题 → 白色
    // - 浅色主题 → 黑色
    final isLightTheme = Theme.of(context).brightness == Brightness.light;
    LyricLayout.textColorValue = customTextColor?.toARGB32() ??
        ((widget.forceDarkBackground || !isLightTheme)
            ? 0xFFFFFFFF
            : 0xFF000000);

    return LayoutBuilder(
      builder: (context, constraints) {
        // 设置视口大小，供 scrollController 计算 targetY
        _scrollController.setViewportSize(
          Size(constraints.maxWidth, constraints.maxHeight),
        );

        final fontSize = LyricLayout.fontSize(context);
        final mainLineHeight = fontSize * LyricLayout.lineHeight;
        // 可用最大文字宽度（视口宽 - 左右 1em 边距），用于自动换行
        final maxLineWidth = LyricLayout.maxLineWidth(
          constraints.maxWidth,
          fontSize,
        );

        // 男女对唱预处理：剔除「男：/女：/合：」前缀并生成对齐方式
        // 必须在行高测量之前，确保行高基于剔除后的文本计算
        _recomputeDuetIfNeeded();
        // 性能优化：缓存命中检查，只在数据/字号/视口变化时重算 lineHeights/lineTops
        // 之前每帧都跑 N 次 TextPainter.layout 是 CPU 瓶颈（UI 线程 70%+）
        _recomputeLineHeightsIfNeeded(fontSize, constraints.maxWidth);

        // 根据偏好选择高斯模糊或 alpha 渐变淡出
        final useGaussian = LyricPreferences.instance.useGaussianBlur;
        // 视口宽先于分支赋值：副行清晰图（翻转期绘制）的排版宽度也依赖它，
        // 关闭高斯模糊时也要有值（此前只在模糊层 Builder 内赋值）。
        _viewportWidth = constraints.maxWidth;

        // 创建或复用持久化 painter
        // 性能优化：painter 字段在 _onTick 中通过 updatePerFrame + notifyListeners 更新，
        // 避免每帧 setState + build 重建 widget tree。
        // build() 只在 widget 重建时运行，设置布局相关字段。
        // 其余行层：skipFocusLine=true，焦点行交给当前行层绘制。
        _painter ??= _newLyricsPainter(_textRepaint, onlyFocus: false);
        // P1-1：两层各自同步布局字段。rest 层画非当前行，current 层只画焦点行，
        // 逐字帧只重绘 current 层（见 _onTick 的重绘门控）。
        final List<double> offsets = _buildPerLineOffsets();
        _syncLyricsPainter(
          _painter!,
          fontSize: fontSize,
          mainLineHeight: mainLineHeight,
          maxLineWidth: maxLineWidth,
          useGaussian: useGaussian,
          viewportHeight: constraints.maxHeight,
          viewportWidth: constraints.maxWidth,
          perLineOffsets: offsets,
        );
        _currentPainter ??= _newLyricsPainter(
          _currentTextRepaint,
          onlyFocus: true,
        );
        _syncLyricsPainter(
          _currentPainter!,
          fontSize: fontSize,
          mainLineHeight: mainLineHeight,
          maxLineWidth: maxLineWidth,
          useGaussian: useGaussian,
          viewportHeight: constraints.maxHeight,
          viewportWidth: constraints.maxWidth,
          perLineOffsets: offsets,
        );

        // 每层各自 RepaintBoundary：文字层逐字重绘时不得把模糊层
        // （十几张全宽纹理）与整屏 ShaderMask 一起拖进同一帧。
        // P1-1：文字层拆成「其余行 / 当前行」两个 RepaintBoundary。
        // 逐字帧只重绘当前行层（1 行），其余行层保持静态位图。
        final lyricsContent = ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              RepaintBoundary(
                child: CustomPaint(painter: _painter, size: Size.infinite),
              ),
              RepaintBoundary(
                child: CustomPaint(
                  painter: _currentPainter,
                  size: Size.infinite,
                ),
              ),
            ],
          ),
        );

        // 鼠标滚轮（桌面端）：包一层 Listener 接收 PointerSignalEvent，
        // 触屏拖拽/点击路径不受影响（见 _onPointerSignal）。
        // behavior: opaque——Listener 默认 deferToChild 在 CustomPaint
        // 等不参与命中的子级上会漏掉滚轮信号。
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerSignal: _onPointerSignal,
          child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: widget.doubleTapToJump ? null : _onTapDown,
          onTapUp: widget.doubleTapToJump ? null : _onTapUp,
          onDoubleTapDown: widget.doubleTapToJump ? _onTapDown : null,
          onDoubleTap: widget.doubleTapToJump ? _triggerDoubleTapSeek : null,
          onVerticalDragUpdate: _onVerticalDragUpdate,
          onVerticalDragEnd: _onVerticalDragEnd,
          // 上下 24px 渐隐改为绘制期按行做离屏遮罩（见 _LyricsPainter 与
          // _paintBlurLayers）：只对落在边界带里的 1~2 行做 dstIn，
          // 不再让 ShaderMask 每帧对整屏做一次离屏合成。
          child: useGaussian
              ? ClipRect(
                  child: Builder(
                    builder: (context) {
                      // 视口宽必须先赋值：模糊层几何签名与副行清晰图排版都依赖它。
                      _viewportWidth = constraints.maxWidth;
                      // 模糊等级与烘焙在 build 阶段算一次；绘制全部在画布完成
                      // （见 _paintBlurLayers），逐帧变化不再重建 widget 树。
                      _syncBlurLevels(constraints.maxHeight, mainLineHeight);
                      _blurPainter ??= _BlurLayersPainter(
                        state: this,
                        repaint: _blurRepaint,
                      );
                      return Stack(
                        children: [
                          lyricsContent,
                          RepaintBoundary(
                            child: CustomPaint(
                              painter: _blurPainter,
                              size: Size.infinite,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                )
              : lyricsContent,
        ),
        );
      },
    );
  }

  /// 计算指定行的模糊等级（参考 applemusic-like-lyrics 的 computeLineBlur）。
  ///
  /// 计算指定行的原始模糊级别（不含 fade，用于缓存）。
  int _computeLineBlurRaw(int lineIndex) {
    if (widget.lines.isEmpty) return 0;
    // 头部间奏期间焦点行是占位本身（-1），所有歌词行都按距离参与模糊：
    // 首行距离 1 → 等级 2，与未过滤时首行位于名单行下方时的口径一致。
    if (_currentLineIndex < 0 && !_introInterludeOwnsSlot) return 0;
    final int focus = _focusLineIndex;
    // 等待期不豁免「布局当前行」：下一行到位但仍要画模糊图。
    if (!_visualHold && lineIndex == focus) return 0;
    // 上下对称：相同距离的行使用相同模糊度，便于缓存复用
    final int distance = (lineIndex - focus).abs();
    return (1 + distance).clamp(0, 5);
  }

  /// 重新计算视口内各行的模糊等级并触发异步烘焙（绘制见 [_paintBlurLayers]）。
  ///
  /// 每行歌词独立缓存模糊图片，位置变化时只重定位，不重新计算模糊。
  /// 模糊图片替代歌词显示（而非叠加）。
  void _syncBlurLevels(double viewportHeight, double mainLineHeight) {
    if (_currentLineIndex < 0) return;

    // 修复：用 scroll controller 状态判断是否在滚动，而非 _blurFade。
    // 回弹开始（isWaitingForAutoReturn 由 true→false）的瞬间 isScrolling 立即变 false，
    // 缓存立即更新到新当前行周围的 levels。
    // 此前用 _blurFade < 0.99 会因淡入慢导致缓存冻结 ~1s。
    final bool isScrolling =
        _scrollController.isUserScrolling ||
        _scrollController.isWaitingForAutoReturn;

    // 当前行变化、或影响模糊图渲染的几何输入（字号 / 非当前行缩放 / 视口宽 /
    // 字体）变化时，重新计算 blur levels 并更新缓存（滑动时跳过，滚动结束后补齐）
    final String geomSig = _blurGeometrySig();
    // 激活帧 _currentLineIndex 不变，只有 _visualHold 翻转；漏掉这个
    // 条件会让当前行继续留在 levels 里，与刚亮起的字内渐变叠成重影。
    if ((_currentLineIndex != _cachedBlurLineIndex ||
            _introInterludeOwnsSlot != _cachedBlurHeadSlot ||
            _visualHold != _lastBlurVisualHold ||
            geomSig != _lastBlurGeometrySig) &&
        !isScrolling) {
      _cachedBlurLineIndex = _currentLineIndex;
      _cachedBlurHeadSlot = _introInterludeOwnsSlot;
      _lastBlurVisualHold = _visualHold;
      _lastBlurGeometrySig = geomSig;

      final double visibleRange = viewportHeight / mainLineHeight;
      final int halfRange = (visibleRange / 2).ceil() + 1;
      final int aboveRange = (halfRange * 0.7).ceil();
      final int startIdx = math.max(0, _currentLineIndex - aboveRange);
      final int endIdx = math.min(
        widget.lines.length,
        _currentLineIndex + halfRange + 1,
      );

      final Map<int, int> levels = {};
      for (int i = startIdx; i < endIdx; i++) {
        final int blurLevel = _computeLineBlurRaw(i);
        if (blurLevel > 0) levels[i] = blurLevel;
      }
      _cachedBlurLevels = levels;

      // 参与绘制的行集合/等级变了，模糊层必须重画（含移除旧图的清理结果）。
      _blurRepaint.fireRepaint();

      // 异步渲染变化行的模糊图片（队列 + 帧预算，见 [_pumpBlurBakeQueue]）
      _updateLineBlurCache(levels);
    }

  }

  /// 创建歌词层 painter。
  ///
  /// [onlyFocus] 为 true 时只画焦点行（当前行层），false 时画其余全部行。
  /// 两层共享同一套布局字段，靠 [onlyFocusLine] / [skipFocusLine] 分流绘制范围。
  _LyricsPainter _newLyricsPainter(
    Listenable repaint, {
    required bool onlyFocus,
  }) {
    final _LyricsPainter p = _LyricsPainter(
      repaint: repaint,
      lines: _cleanedLines,
      duetAlignments: _duetAlignments,
      focusLineIndex: _focusLineIndex,
      activationHeld: _visualHold,
      posY: _scrollController.posY,
      fontSize: 1,
      mainLineHeight: 1,
      lineHeights: _lineHeights,
      lineTops: _lineTops,
      viewportHeight: 0,
      viewportWidth: 0,
      maxLineWidth: 0,
      currentTimeMs: _authorityTimeMs,
      enableScale: widget.enableScale,
      wordRenderers: _wordRenderers,
      lineRenderers: _lineRenderers,
      perLineScales: _reusedPerLineScales,
      emphasizeEffect: _emphasizeEffect,
      interludeDots: _interludeDots,
      interludeAfterIndices: _interludeAfterIndices,
      interludePlaceholderHeight: _interludePlaceholderHeight,
      activeInterludeIdx: _activeInterludeIdx,
      lastActiveAnchorIdx: _lastActiveAnchorIdx,
      interludeExpandProgress: _interludeExpandProgress,
      auxProgress: _auxProgress,
      auxTargets: _auxTargets,
      auxTopsPrefix: _auxTopsPrefix,
      auxProgressGeneration: _auxProgressGeneration,
      auxSubHeights: _auxSubHeights,
      wrapPlans: _wrapPlans,
      auxPlans: _auxWrapPlans,
      perLineOffsets: _buildPerLineOffsets(),
      blurFade: _clearLayerBlurFade,
      blurActive: false,
      blurReadyLineIndices: _lineBlurImages.keys,
      auxBlurReadyLineIndices: _auxBlurImages.keys,
      auxTextImages: _auxTextImages,
      textColorValue: LyricLayout.textColorValue,
      activeLineColorValue: _activeLineColorValue,
      aboveLineColorValue: _aboveLineColorValue,
      linesGeneration: _linesGeneration,
      lineHeightsGeneration: _lineHeightsGeneration,
      lineTopsGeneration: _lineTopsGeneration,
      interludeAfterIndicesGeneration: _interludeAfterIndicesGeneration,
      perLineOffsetsGeneration: _perLineOffsetsGeneration,
    );
    p.onlyFocusLine = onlyFocus;
    p.skipFocusLine = !onlyFocus;
    return p;
  }

  /// 同步歌词层 painter 的布局与动画字段（当前行层与其余行层各调用一次）。
  void _syncLyricsPainter(
    _LyricsPainter p, {
    required double fontSize,
    required double mainLineHeight,
    required double maxLineWidth,
    required bool useGaussian,
    required double viewportHeight,
    required double viewportWidth,
    required List<double> perLineOffsets,
  }) {
    p.lines = _cleanedLines;
    p.duetAlignments = _duetAlignments;
    p.focusLineIndex = _focusLineIndex;
    p.activationHeld = _visualHold;
    p.posY = _scrollController.posY;
    p.fontSize = fontSize;
    p.mainLineHeight = mainLineHeight;
    p.lineHeights = _lineHeights;
    p.lineTops = _lineTops;
    p.viewportHeight = viewportHeight;
    p.viewportWidth = viewportWidth;
    p.maxLineWidth = maxLineWidth;
    p.currentTimeMs = _authorityTimeMs;
    p.enableScale = widget.enableScale;
    p.wordRenderers = _wordRenderers;
    p.lineRenderers = _lineRenderers;
    p.perLineScales = _reusedPerLineScales;
    p.emphasizeEffect = _emphasizeEffect;
    p.interludeDots = _interludeDots;
    p.interludeAfterIndices = _interludeAfterIndices;
    p.interludePlaceholderHeight = _interludePlaceholderHeight;
    p.activeInterludeIdx = _activeInterludeIdx;
    p.lastActiveAnchorIdx = _lastActiveAnchorIdx;
    p.interludeExpandProgress = _interludeExpandProgress;
    p.auxProgress = _auxProgress;
    p.auxTargets = _auxTargets;
    p.auxTopsPrefix = _auxTopsPrefix;
    p.auxProgressGeneration = _auxProgressGeneration;
    p.auxSubHeights = _auxSubHeights;
    p.wrapPlans = _wrapPlans;
    p.auxPlans = _auxWrapPlans;
    p.perLineOffsets = perLineOffsets;
    p.blurFade = _clearLayerBlurFade;
    p.blurActive = useGaussian;
    p.blurReadyLineIndices = _lineBlurImages.keys;
    p.auxBlurReadyLineIndices = _auxBlurImages.keys;
    p.auxTextImages = _auxTextImages;
    p.textColorValue = LyricLayout.textColorValue;
    p.activeLineColorValue = _activeLineColorValue;
    p.aboveLineColorValue = _aboveLineColorValue;
    p.linesGeneration = _linesGeneration;
    p.lineHeightsGeneration = _lineHeightsGeneration;
    p.lineTopsGeneration = _lineTopsGeneration;
    p.interludeAfterIndicesGeneration = _interludeAfterIndicesGeneration;
    p.perLineOffsetsGeneration = _perLineOffsetsGeneration;
  }

  /// 与上下 24px 渐隐带相交时返回该行的离屏遮罩区域（裁剪到视口内）。
  Rect? _edgeFadeRect(double top, double height, Size size) {
    const double fadeHeight = 24.0;
    final double bottom = top + height;
    if (top >= fadeHeight && bottom <= size.height - fadeHeight) return null;
    final Rect rect = Rect.fromLTWH(0, top, size.width, height)
        .intersect(Offset.zero & size);
    return rect.isEmpty ? null : rect;
  }

  /// 对 [rect] 内已绘制的模糊图做上下边界 alpha 渐变（与清晰层同一 shader）。
  void _applyEdgeFade(Canvas canvas, Rect rect, Size size) {
    canvas.drawRect(
      rect,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = _fadeShaderCache.forBounds(Offset.zero & size),
    );
  }

  /// 把已烘焙的模糊图合成到画布（主行 + 副行 + 入场层）。
  ///
  /// 之前用 Positioned/Opacity/Transform/RawImage 表达：副行进度、posY、弹簧、
  /// 缩放任意一项逐帧变化都要重建整棵模糊层 Stack（widget + layout）。改成画布
  /// 直接绘制后，每帧只重画纹理，位置与不透明度全部读实时状态，零 widget 重建。
  void _paintBlurLayers(Canvas canvas, Size size) {
    debugBlurDraws?.clear();
    if (_currentLineIndex < 0) return;
    // 字号在 build 阶段缓存；paint 里不能再做 MediaQuery 查询。
    final double fontSize = _cachedFontSize;
    if (fontSize <= 0) return;
    final double viewportW = _viewportWidth;
    if (viewportW <= 0) return;
    final double mainLineHeight = fontSize * LyricLayout.lineHeight;
    final double viewportHeight = size.height;
    final double startX = fontSize;
    final double bakeScale = LyricLayout.blurRenderScale(
      enableScale: widget.enableScale,
    );
    final double blurIntensity = LyricPreferences.instance.blurIntensity;
    final bool crossfade = LyricPreferences.instance.blurLevelCrossfade;
    final List<double> offsets = _reusedPerLineOffsets;
    final double posY = _scrollController.posY;
    final double fallbackScale = math.max(
      LyricLayout.inactiveScale,
      _minLegibleLineScale(fontSize),
    );

    for (final entry in _cachedBlurLevels.entries) {
      final int i = entry.key;
      // sigma / padding / 高度与 _renderLineBlur 渲染侧同一口径
      // （见 _blurGeometry），避免两侧各算一遍导致图片被拉伸或文字错位。
      final double sigma = (entry.value * blurIntensity).clamp(0.5, 10.0);
      if (sigma < 0.1) continue;
      final cached = _lineBlurImages[i];
      if (cached == null) continue;

      final double blockHeight = i < _lineHeights.length
          ? _lineHeights[i]
          : mainLineHeight;
      final double padding = sigma * 3;
      final double imageHeight = blockHeight + padding * 2;
      final double lineTop =
          (i < _lineTops.length ? _lineTops[i] : i * mainLineHeight) +
          _interludeOffsetBefore(i) +
          // 上方行的副行动画高度（退场行收起时模糊层跟随平滑上移）
          _transDeltaBefore(i);
      // 应用弹簧偏移
      final double springOffset = (i < offsets.length) ? offsets[i] : 0.0;
      final double y = lineTop + posY + springOffset;
      if (y + blockHeight < 0 || y > viewportHeight) continue;

      // 逐行副行进度 / 预留高度：主行层与副行层的缩放补偿都要用
      final double auxP = _auxProgressAt(i);
      final double auxSubH = _auxSubHeightOf(i);
      // 模糊图已烘焙"非当前行缩放"（blurRenderScale），这里按该行当前的形变
      // scale 动态跟随：k = current / bake，离场行从大到小与清晰层同步。
      final double currentScale = i < _reusedPerLineScales.length
          ? _reusedPerLineScales[i]
          : fallbackScale;
      final double k = bakeScale > 0 && imageHeight > 0
          ? currentScale / bakeScale
          : 1.0;
      // pivot 复刻清晰层 canvas.scale（_LyricsPainter.paint）：左/右缘/视口中点
      final DuetAlignment al = _duetAlignmentAt(i);
      final double pivotX = al == DuetAlignment.right
          ? viewportW - startX
          : al == DuetAlignment.center
          ? viewportW / 2
          : startX;
      final double widgetPivotY = padding + blockHeight / 2;
      // 透明度偏好与已播着色都在合成期生效（不进烘焙签名）：拖滑块 / 切开关
      // 不触发离屏重烘焙，清晰层与模糊层的互补关系保持不变。
      final bool isAbove = i < _currentLineIndex;
      final double prefScale = LyricLayout.blurOpacityScaleFor(isAbove: isAbove);
      final int? tint = lineColorOverrideValue(
        activeLineColorValue: _activeLineColorValue,
        aboveLineColorValue: _aboveLineColorValue,
        isActive: false,
        isAboveCurrent: isAbove,
      );
      // 缩放中心补偿（主行层）：清晰层 pivot 随副行进度下移，模糊图绕自身
      // 块中心缩放，差值为 d = 副行高 × 进度 / 2 → 逐帧折算成纯位移。
      final double dyMain =
          LyricLayout.blurPivotShiftMain(
            auxSubHeight: auxSubH,
            auxProgress: auxP,
          ) *
          (1 - currentScale);

      // 落在上下 24px 渐隐带里的行才需要离屏遮罩（通常上下各 1 行）。
      final Rect? fadeRect = _edgeFadeRect(
        y - padding,
        blockHeight + auxSubH + padding * 2,
        size,
      );
      if (fadeRect != null) canvas.saveLayer(fadeRect, Paint());

      // 模糊等级交叉淡入淡出（默认关闭）：旧图按自己烘焙时的 blurLevel
      // 求 padding / 高度，作为下层先画；k / dyMain 与几何无关。
      final fadingMain = _lineBlurFading[i];
      final bool mainCrossfading =
          crossfade && fadingMain != null && _blurLevelFade < 1.0;
      if (mainCrossfading) {
        final double oldSigma =
            (fadingMain.blurLevel * blurIntensity).clamp(0.5, 10.0);
        final double oldPadding = oldSigma * 3;
        final double oldImageHeight = blockHeight + oldPadding * 2;
        final double oldPivotY = oldPadding + blockHeight / 2;
        final double opacity =
            (_blurFade *
                    prefScale *
                    _crossfadeOldWeight(
                      _blurLevelFade,
                      _blurFade * prefScale,
                      LyricLayout.blurBakedAlpha,
                    ))
                .clamp(0.0, 1.0);
        _drawBlurImage(
          canvas,
          image: fadingMain.image,
          top: y - oldPadding + dyMain,
          width: viewportW,
          height: oldImageHeight,
          pivotX: pivotX,
          pivotY: oldPivotY,
          scale: k,
          tint: tint,
          opacity: opacity,
        );
      }
      _drawBlurImage(
        canvas,
        image: cached.$1,
        top: y - padding + dyMain,
        width: viewportW,
        height: imageHeight,
        pivotX: pivotX,
        pivotY: widgetPivotY,
        scale: k,
        tint: tint,
        opacity: (_blurFade *
                prefScale *
                (mainCrossfading ? _blurLevelFade : 1.0))
            .clamp(0.0, 1.0),
      );

      // 副行模糊层：独立图，逐帧只算 top / opacity / 位移补偿，**不重烘焙**。
      // 位置与清晰层 LineRenderer 副行同式：
      //   offset.dy + mainHeight + transFontSize × 0.3 + subH × (progress - 1)
      // 收起中的副行不画模糊（块几何 / 翻转锚点与清晰副行不同步，会错位）；
      // 清晰层因「副行模糊未就绪」会照常绘制该副行，由它跟随收起。
      if (auxP > 0.001 && auxSubH > 0 && !_auxExitingAt(i)) {
        final auxCached = _auxBlurImages[i];
        if (auxCached != null) {
          // 副行块几何：高度取该行副行预留高度（含换行行数），几何口径与
          // _auxBlurGeometry / _renderAuxBlur 完全一致。
          final double auxPadding = sigma * 3;
          final double auxImageHeight = auxSubH + auxPadding * 2;
          final double mainHeight = blockHeight;
          final double gap = LyricLayout.auxGap(fontSize);
          final double auxTop = y + mainHeight + gap + auxSubH * (auxP - 1.0);
          final double auxK = bakeScale > 0 && auxImageHeight > 0
              ? currentScale / bakeScale
              : 1.0;
          // 缩放中心补偿（副行层）：pivotClear 与副行块中心相差
          //   d_aux = −(主行高/2 + 形变间隙) + 副行高 × (1 − p)/2
          // p=1 时退化为 −(主行高/2 + gap)：副行图整体需上移 d×(1−scale)，
          // 否则副行模糊影会比清晰副行低约 4px（用户实测的主要偏差来源）。
          final double dyAux =
              LyricLayout.blurPivotShiftAux(
                mainHeight: mainHeight,
                auxSubHeight: auxSubH,
                auxProgress: auxP,
                auxGap: gap,
              ) *
              (1 - currentScale);
          final double auxPivotY = auxPadding + auxSubH / 2;
          // 副行模糊图同样按旧 blurLevel 定位（默认关闭时不进入）。
          final fadingAux = _auxBlurFading[i];
          final bool auxCrossfading =
              crossfade && fadingAux != null && _blurLevelFade < 1.0;
          if (auxCrossfading) {
            final double oldAuxSigma =
                (fadingAux.blurLevel * blurIntensity).clamp(0.5, 10.0);
            final double oldAuxPadding = oldAuxSigma * 3;
            final double oldAuxImageHeight = auxSubH + oldAuxPadding * 2;
            final double oldAuxPivotY = oldAuxPadding + auxSubH / 2;
            final double opacity =
                (_blurFade *
                        prefScale *
                        auxP *
                        _crossfadeOldWeight(
                          _blurLevelFade,
                          _blurFade * prefScale * auxP,
                          LyricLayout.blurAuxBakedAlpha,
                        ))
                    .clamp(0.0, 1.0);
            _drawBlurImage(
              canvas,
              image: fadingAux.image,
              top: auxTop - oldAuxPadding + dyAux,
              width: viewportW,
              height: oldAuxImageHeight,
              pivotX: pivotX,
              pivotY: oldAuxPivotY,
              scale: auxK,
              tint: tint,
              opacity: opacity,
            );
          }
          _drawBlurImage(
            canvas,
            image: auxCached.$1,
            top: auxTop - auxPadding + dyAux,
            width: viewportW,
            height: auxImageHeight,
            pivotX: pivotX,
            pivotY: auxPivotY,
            scale: auxK,
            tint: tint,
            // 烘焙 alpha 已是 translationOpacity，这里只叠进度与模糊淡入
            opacity: (_blurFade *
                    prefScale *
                    auxP *
                    (auxCrossfading ? _blurLevelFade : 1.0))
                .clamp(0.0, 1.0),
          );
        }
      }

      if (fadeRect != null) {
        _applyEdgeFade(canvas, fadeRect, size);
        canvas.restore();
      }
    }

    // 入场模糊层：新当前行轨道成像后，其旧模糊图短暂保留并淡出（时长由
    // 「模糊等级渐变时长」滑块控制），同时跟随该行从 inactiveScale 放大到
    // activeScale（与离场对称）。仅在渐变切换开关开启时启用。
    if (_entryBlurProgress < 0.999) {
      final int ci = _currentLineIndex;
      if (ci >= 0 &&
          ci < widget.lines.length &&
          !_cachedBlurLevels.containsKey(ci)) {
        final cached = _lineBlurImages[ci];
        // paint 阶段不能重算几何签名（需要 MediaQuery）：用最近一次 build 的签名。
        if (cached != null && cached.$2.startsWith('$_lastBlurGeometrySig|')) {
          // 入场层固定按 blurLevel = 1 的几何（与 [_blurGeometry] 同口径）。
          final double ePadding = (1 * blurIntensity).clamp(0.5, 10.0) * 3;
          final double eBlockHeight = ci < _lineHeights.length
              ? _lineHeights[ci]
              : mainLineHeight;
          final double eImageHeight = eBlockHeight + ePadding * 2;
          final double lineTop =
              (ci < _lineTops.length ? _lineTops[ci] : ci * mainLineHeight) +
              _interludeOffsetBefore(ci) +
              _transDeltaBefore(ci);
          final double springOffset = (ci < offsets.length) ? offsets[ci] : 0.0;
          final double y = lineTop + posY + springOffset;
          if (y + eBlockHeight >= 0 && y <= viewportHeight) {
            final double currentScale = ci < _reusedPerLineScales.length
                ? _reusedPerLineScales[ci]
                : LyricLayout.activeScale;
            final double kentry = bakeScale > 0 && eImageHeight > 0
                ? currentScale / bakeScale
                : 1.0;
            final DuetAlignment eal = _duetAlignmentAt(ci);
            final double ePivotX = eal == DuetAlignment.right
                ? viewportW - startX
                : eal == DuetAlignment.center
                ? viewportW / 2
                : startX;
            final double ePivotY = ePadding + eBlockHeight / 2;
            // 起始不透明度 = 该行作为「下方未播行」时模糊层的合成 alpha，
            // 而不是 1.0：满不透明整块覆盖正是历史上「切行闪一下」的根因。
            // 低起点淡出与当前行清晰文字的逐字淡入互补交接。
            final double baseAlpha =
                _blurFade * LyricLayout.blurOpacityScaleFor(isAbove: false);
            final double edyMain =
                LyricLayout.blurPivotShiftMain(
                  auxSubHeight: _auxSubHeightOf(ci),
                  auxProgress: _auxProgressAt(ci),
                ) *
                (1 - currentScale);
            _drawBlurImage(
              canvas,
              image: cached.$1,
              top: y - ePadding + edyMain,
              width: viewportW,
              height: eImageHeight,
              pivotX: ePivotX,
              pivotY: ePivotY,
              scale: kentry,
              tint: null,
              opacity: ((1.0 - _entryBlurProgress) * baseAlpha.clamp(0.0, 1.0))
                  .clamp(0.0, 1.0),
            );
          }
        }
      }
    }
  }

  /// 画一张已烘焙的模糊图，复刻「Positioned + Opacity + Transform.scale +
  /// RawImage(fit: fill)」的合成语义。
  ///
  /// [top] / [width] / [height] 为视口坐标下的块矩形；[pivotX] / [pivotY] 为
  /// **块内**缩放中心（与旧 `Alignment(alignX, alignY)` 等价）。
  /// [tint] 非空时用 `srcIn` 换成该颜色（保留模糊 alpha），为空时只按
  /// [opacity] 调制 alpha（`dstIn`，保留烘焙 RGB）。
  void _drawBlurImage(
    Canvas canvas, {
    required ui.Image image,
    required double top,
    required double width,
    required double height,
    required double pivotX,
    required double pivotY,
    required double scale,
    int? tint,
    required double opacity,
  }) {
    if (opacity <= 0.001 || width <= 0 || height <= 0) return;
    debugBlurDraws?.add((tint: tint, opacity: opacity));
    final Rect src = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    final Rect dst = Rect.fromLTWH(0, 0, width, height);
    canvas.save();
    canvas.translate(0, top);
    if (scale != 1.0) {
      canvas.translate(pivotX, pivotY);
      canvas.scale(scale, scale);
      canvas.translate(-pivotX, -pivotY);
    }
    if (tint != null) {
      _blurImagePaint.colorFilter = ColorFilter.mode(
        Color.fromRGBO(
          (tint >> 16) & 0xFF,
          (tint >> 8) & 0xFF,
          tint & 0xFF,
          opacity,
        ),
        BlendMode.srcIn,
      );
    } else if (opacity < 0.999) {
      _blurImagePaint.colorFilter = ColorFilter.mode(
        Color.fromRGBO(255, 255, 255, opacity),
        BlendMode.dstIn,
      );
    } else {
      _blurImagePaint.colorFilter = null;
    }
    canvas.drawImageRect(image, src, dst, _blurImagePaint);
    canvas.restore();
  }

  /// 异步更新模糊缓存：把变化行排进烘焙队列（帧预算见 [_pumpBlurBakeQueue]）。
  void _updateLineBlurCache(Map<int, int> levels) {
    _lineBlurPending.removeWhere((index, _) => !levels.containsKey(index));
    // 上一次的排队结果已过期：签名/等级可能又变了，整队重建。
    _blurBakeQueue.clear();
    if (levels.isNotEmpty) {
      // 优先级：离当前行越近越先烘焙；副行图排在所有主行图之后。
      final List<int> order = levels.keys.toList()
        ..sort(
          (a, b) => (a - _currentLineIndex)
              .abs()
              .compareTo((b - _currentLineIndex).abs()),
        );
      for (final lineIndex in order) {
        final int blurLevel = levels[lineIndex]!;
        // 检查缓存是否存在且渲染输入签名完全匹配（字号/缩放/视口/字体任一变化即过期）
        final String signature = _blurCacheSignature(blurLevel);
        final cached = _lineBlurImages[lineIndex];
        if (cached != null && cached.$2 == signature) continue;
        if (_lineBlurPending[lineIndex]?.$2 == signature) continue;
        _blurBakeQueue.add((
          lineIndex: lineIndex,
          blurLevel: blurLevel,
          aux: false,
        ));
      }
      // 副行图与主行图同一波次请求：副行进度是逐行动画的，若等「该行开始
      // 显示副行」才请求，切行瞬间会先看到清晰副行再跳到模糊副行（闪一下）。
      // 收起中的副行不烘焙（[_auxExitingAt]：块几何与清晰副行不同步会错位）；
      // 完全收起（进度与目标都 ≈0，如「仅当前行」范围下的非当前行）也不烘焙。
      for (final lineIndex in order) {
        final int blurLevel = levels[lineIndex]!;
        if (_auxSubHeightOf(lineIndex) > 0 &&
            !_auxExitingAt(lineIndex) &&
            (_auxProgressAt(lineIndex) > 0.001 ||
                _auxTargetAt(lineIndex) > 0.001)) {
          _blurBakeQueue.add((
            lineIndex: lineIndex,
            blurLevel: blurLevel,
            aux: true,
          ));
        }
      }
    }

    // 清理不再需要的缓存。
    // 例外：当前行的模糊图**保留不删**。它退回非当前行时（下一句开始）需要
    // 立刻有图可显示，否则要等异步 toImage 完成，期间该行既无清晰文字
    // （alpha 目标为 0）也无模糊图 → 出现 1~3 帧空窗。
    // 仅当几何口径（字号/视口/缩放/字体）仍一致时才保留，否则旧图会被
    // BoxFit.fill 拉伸变形；blurLevel 不同可以保留（半径差 1px 远好于空窗，
    // 且下方队列会异步换成正确半径的图）。
    final String geomSig = _blurGeometrySig();
    final keysToRemove = _lineBlurImages.keys.where((k) {
      if (levels.containsKey(k)) return false;
      if (k == _currentLineIndex &&
          (_lineBlurImages[k]?.$2.startsWith('$geomSig|') ?? false)) {
        return false;
      }
      return true;
    }).toList();
    for (final key in keysToRemove) {
      _lineBlurImages[key]?.$1.dispose();
      _lineBlurImages.remove(key);
      _lineBlurFading.remove(key)?.image.dispose();
    }

    // 副行图清理：口径与主行图一致（同窗口 + 当前行保留），额外要求该行仍
    // 有副行预留高度——副行文本被清空（切范围到无副行的歌、切歌）时立即释放。
    _auxBlurPending.removeWhere((index, _) => !levels.containsKey(index));
    final auxKeysToRemove = _auxBlurImages.keys.where((k) {
      if (levels.containsKey(k) && _auxSubHeightOf(k) > 0) return false;
      if (k == _currentLineIndex &&
          (_auxBlurImages[k]?.$2.startsWith('$geomSig|') ?? false)) {
        return false;
      }
      return true;
    }).toList();
    for (final key in auxKeysToRemove) {
      _auxBlurImages[key]?.$1.dispose();
      _auxBlurImages.remove(key);
      _auxBlurFading.remove(key)?.image.dispose();
    }

    _pumpBlurBakeQueue();
  }

  /// 发起单行主行模糊图烘焙（令牌 / 签名保护）。
  void _requestLineBlur(int lineIndex, int blurLevel) {
    final String signature = _blurCacheSignature(blurLevel);
    final cached = _lineBlurImages[lineIndex];
    if (cached != null && cached.$2 == signature) return;
    if (_lineBlurPending[lineIndex]?.$2 == signature) return;
    final token = Object();
    _lineBlurPending[lineIndex] = (token, signature);

    (lineBlurRendererForTest ?? _renderLineBlur)(
      lineIndex,
      blurLevel,
      _duetAlignmentAt(lineIndex),
    ).then((image) {
      // 只允许最新请求写回；销毁或失效后仍需释放迟到的 GPU 图片。
      if (!mounted || _lineBlurPending[lineIndex]?.$1 != token) {
        image?.dispose();
        if (kDebugMode) {
          debugPrint('[LyricRender] discard stale blur line=$lineIndex');
        }
        return;
      }
      _lineBlurPending.remove(lineIndex);
      if (_blurCacheSignature(blurLevel) != signature) {
        image?.dispose();
        return;
      }
      if (image != null) {
        _stashFadingBlur(
          fading: _lineBlurFading,
          lineIndex: lineIndex,
          old: _lineBlurImages[lineIndex],
        );
        _lineBlurImages[lineIndex] = (image, signature);
        // 模糊层是画布合成（读实时 Map），只需重绘，不必重建 widget。
        _blurRepaint.fireRepaint();
      }
    });
  }

  /// 按帧预算抽干烘焙队列。
  ///
  /// 录制（PictureRecorder + saveLayer(blur) + TextPainter.layout）是同步的，
  /// 切行时十余张全宽图集中录制会直接吃掉一帧；这里每个 16ms 节拍只启动
  /// 固定数量，其余排到后续节拍。队列为空 / 页面不可见时立即停表。
  void _pumpBlurBakeQueue() {
    if (_blurBakeQueue.isEmpty ||
        _lifecycleSuspended ||
        _tickerModeMuted) {
      _blurBakeTimer?.cancel();
      _blurBakeTimer = null;
      return;
    }
    int budget = _blurBakeBudgetPerTick;
    while (budget > 0 && _blurBakeQueue.isNotEmpty) {
      final ({int lineIndex, int blurLevel, bool aux}) job =
          _blurBakeQueue.removeAt(0);
      if (job.aux) {
        _requestAuxBlur(job.lineIndex, job.blurLevel);
      } else {
        _requestLineBlur(job.lineIndex, job.blurLevel);
      }
      budget--;
    }
    if (_blurBakeQueue.isEmpty) {
      _blurBakeTimer?.cancel();
      _blurBakeTimer = null;
    } else {
      _blurBakeTimer ??= Timer.periodic(
        const Duration(milliseconds: 16),
        (_) => _pumpBlurBakeQueue(),
      );
    }
  }

  /// 请求渲染某行的副行模糊图（令牌 / 签名过期保护与主行图完全同构）。
  void _requestAuxBlur(int lineIndex, int blurLevel) {
    final String signature = _auxBlurCacheSignature(blurLevel);
    final cached = _auxBlurImages[lineIndex];
    if (cached != null && cached.$2 == signature) return;
    if (_auxBlurPending[lineIndex]?.$2 == signature) return;
    final token = Object();
    _auxBlurPending[lineIndex] = (token, signature);
    (auxBlurRendererForTest ?? _renderAuxBlur)(
      lineIndex,
      blurLevel,
      _duetAlignmentAt(lineIndex),
    ).then((image) {
      if (!mounted || _auxBlurPending[lineIndex]?.$1 != token) {
        image?.dispose();
        return;
      }
      _auxBlurPending.remove(lineIndex);
      if (_auxBlurCacheSignature(blurLevel) != signature) {
        image?.dispose();
        return;
      }
      if (image != null) {
        _stashFadingBlur(
          fading: _auxBlurFading,
          lineIndex: lineIndex,
          old: _auxBlurImages[lineIndex],
        );
        _auxBlurImages[lineIndex] = (image, signature);
        _blurRepaint.fireRepaint();
      }
    });
  }

  /// 获取指定行的对唱对齐方式（越界或未处理时返回默认左对齐）。
  DuetAlignment _duetAlignmentAt(int lineIndex) {
    if (lineIndex < 0 || lineIndex >= _duetAlignments.length) {
      return DuetAlignment.defaultAlign;
    }
    return _duetAlignments[lineIndex];
  }

  // ============== 副行清晰图（翻转期绘制用） ==============

  /// 预热 [focus] 附近几行的副行清晰图（当前行及其前后各一到两行）。
  ///
  /// 只在当前行变化 / 缓存被清空后调用（[_auxTextImageFocus] 守卫），
  /// 稳态零开销。窗口覆盖「旧当前行（退场翻转）」与「下一行（几秒后才翻转）」，
  /// 正常播放时翻转开始时图已就绪，不会回退到文字透视路径。
  void _syncAuxTextImages(int focus) {
    if (focus == _auxTextImageFocus) return;
    if (_viewportWidth <= 0 || _auxWrapPlans.length != _cleanedLines.length) {
      return;
    }
    _auxTextImageFocus = focus;
    final int n = _cleanedLines.length;
    if (n == 0) {
      _clearAuxTextImages();
      return;
    }
    final int lo = math.max(0, focus - 1);
    final int hi = math.min(n, focus + 3);
    // 窗口外不再参与翻转，立即释放（翻转动效只涉及当前行与相邻行）。
    final List<int> outside = _auxTextImages.keys
        .where((k) => k < lo || k >= hi)
        .toList();
    for (final k in outside) {
      _auxTextImages.remove(k)?.dispose();
      _auxTextSignatures.remove(k);
    }
    _auxTextPending.removeWhere((k, _) => k < lo || k >= hi);
    for (int i = lo; i < hi; i++) {
      if (_auxSubHeightOf(i) > 0) _requestAuxTextImage(i);
    }
  }

  /// 预热第 [index] 行：逐字渲染器预绑定 + 副行清晰图请求。
  ///
  /// 两项都与播放时间无关且幂等，提前做可以把切行帧的同步成本（逐字测量、
  /// 文字 layout + toImage 派发）挪到非动画帧。
  void _prewarmLine(int index) {
    if (index < 0 || index >= widget.lines.length) return;
    // 绝不对当前行预绑定：_ensureBound 会重置 alpha / 精灵缓存，
    // 在动画进行中调用会造成闪变。
    if (index == _currentLineIndex) return;
    final line = widget.lines[index];
    if (line.hasWordTiming && _cachedFontSize > 0) {
      _wordRendererFor(index).prepareFor(line, _cachedFontSize);
    }
    if (_auxSubHeightOf(index) > 0) _requestAuxTextImage(index);
  }

  /// 帧末预热下一行。同一目标只排一次回调（[_prewarmTarget] 去重）。
  void _schedulePrewarmNextLine() {
    final int target = _currentLineIndex + 1;
    if (target < 0 || target >= widget.lines.length) return;
    if (_prewarmTarget == target) return;
    _prewarmTarget = target;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 回调执行前若已再次切行，目标行不再是「下一行」：跳过，留给新一轮调度。
      if (_currentLineIndex + 1 != target) return;
      _prewarmLine(target);
    });
  }

  /// 请求烘焙某行的副行清晰图（令牌 / 签名保护与模糊图链路同构）。
  void _requestAuxTextImage(int lineIndex) {
    if (lineIndex < 0 || lineIndex >= _cleanedLines.length) return;
    final String signature = _auxTextImageSignature(lineIndex);
    if (_auxTextSignatures[lineIndex] == signature) return;
    if (_auxTextPending[lineIndex]?.$2 == signature) return;
    final token = Object();
    _auxTextPending[lineIndex] = (token, signature);
    (auxTextRendererForTest ?? _renderAuxTextImage).call(lineIndex).then((image) {
      if (!mounted || _auxTextPending[lineIndex]?.$1 != token) {
        image?.dispose();
        return;
      }
      _auxTextPending.remove(lineIndex);
      if (image == null) return;
      if (lineIndex >= _cleanedLines.length ||
          _auxTextImageSignature(lineIndex) != signature) {
        image.dispose();
        return;
      }
      final AuxTextImage? old = _auxTextImages.remove(lineIndex);
      _auxTextImages[lineIndex] = image;
      _auxTextSignatures[lineIndex] = signature;
      // 文字层读实时 Map，只需重绘（避免每张副行图完成都触发一次 build）。
      // 副行图可能属于当前行层或其余行层，两层都通知。
      _textRepaint.fireRepaint();
      _currentTextRepaint.fireRepaint();
      if (old != null) {
        // 帧末释放：本帧已录制的 Picture 可能仍引用旧图。
        WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
      }
    });
  }

  /// 副行清晰图签名：几何 / 文本 / 换行行数 / 对齐 / 烘焙倍率，**不含进度与 alpha**
  /// （显隐动画期间零重烘焙）。
  String _auxTextImageSignature(int lineIndex) {
    final LyricLine line = _cleanedLines[lineIndex];
    final String auxText =
        LyricPreferences.instance.displayMode == LyricDisplayMode.roma
        ? (line.roma ?? '')
        : (line.translation ?? '');
    final int rows = lineIndex < _auxWrapPlans.length
        ? _auxWrapPlans[lineIndex].rowCount
        : 0;
    return '${_blurGeometrySig()}|auxtext|$rows|${auxText.hashCode}'
        '|${_duetAlignmentAt(lineIndex).name}'
        '|${_auxTextBakeScale().toStringAsFixed(2)}'
        '|soft=${LyricLayout.softEdgeAntiAlias}';
  }

  /// 副行清晰图的烘焙倍率：跟随设备像素比（上限 2×），翻转缩放时不发糊。
  double _auxTextBakeScale() {
    final double dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
    return dpr.clamp(1.0, 2.0);
  }

  /// 把某行副行文字栅格化为白字、不透明白的图片（主题色与 alpha 在合成期施加）。
  Future<AuxTextImage?> _renderAuxTextImage(int lineIndex) async {
    try {
      if (_viewportWidth <= 0) return null;
      if (lineIndex < 0 || lineIndex >= _cleanedLines.length) return null;
      final LyricLine line = _cleanedLines[lineIndex];
      final String? auxText =
          LyricPreferences.instance.displayMode == LyricDisplayMode.roma
          ? line.roma
          : line.translation;
      if (auxText == null || auxText.isEmpty) return null;
      final double fontSize = LyricLayout.fontSize(context);
      final double maxTextWidth = LyricLayout.maxLineWidth(
        _viewportWidth,
        fontSize,
      );
      if (maxTextWidth <= 0) return null;
      // 与副行绘制同一份换行计划（含硬断点），保证图像行数 == 预留行数。
      final LyricWrapPlan plan = lineIndex < _auxWrapPlans.length
          ? _auxWrapPlans[lineIndex]
          : _emptyPlan;
      final DuetAlignment alignment = _duetAlignmentAt(lineIndex);
      // 柔边：与文字路径同一份 sigma；图四周留 pad，避免模糊衰减被图片边界裁断。
      final double transFontSize = LyricLayout.translationFontSize(fontSize);
      final double softPad =
          LyricLayout.softEdgeAntiAlias ? LyricLayout.softEdgePad(transFontSize) : 0;
      final TextPainter painter = TextPainter(
        textAlign: alignment == DuetAlignment.right
            ? TextAlign.right
            : alignment == DuetAlignment.center
            ? TextAlign.center
            : TextAlign.left,
        textDirection: TextDirection.ltr,
      )..text = TextSpan(
          text: plan.rowTexts.join('\n'),
          style: LyricLayout.paintStyle(
            color: const Color(0xFFFFFFFF),
            fontSize: transFontSize,
            height: LyricLayout.translationLineHeight,
          ),
        );
      painter.layout(maxWidth: maxTextWidth);
      final double logicalWidth = painter.width;
      final double logicalHeight = painter.height;
      if (logicalWidth <= 0 || logicalHeight <= 0) {
        painter.dispose();
        return null;
      }
      final double scale = _auxTextBakeScale();
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(recorder);
      canvas.scale(scale, scale);
      painter.paint(canvas, Offset(softPad, softPad));
      painter.dispose();
      final ui.Picture picture = recorder.endRecording();
      final ui.Image image = await picture.toImage(
        ((logicalWidth + softPad * 2) * scale).ceil(),
        ((logicalHeight + softPad * 2) * scale).ceil(),
      );
      picture.dispose();
      return AuxTextImage(
        image: image,
        width: logicalWidth,
        height: logicalHeight,
        pad: softPad,
      );
    } catch (_) {
      return null;
    }
  }

  /// 释放全部副行清晰图，并让下一次 [_syncAuxTextImages] 重新预热。
  void _clearAuxTextImages() {
    _auxTextPending.clear();
    _auxTextSignatures.clear();
    for (final image in _auxTextImages.values) {
      image.dispose();
    }
    _auxTextImages.clear();
    _auxTextImageFocus = -1;
  }

  /// 模糊层几何（渲染与定位共用，保证 sigma / padding / 高度口径完全一致）。
  ///
  /// blockHeight 取 [_lineHeights]（**纯主行**高度、不含翻译副行——行高缓存
  /// 恒按纯主行测量，副行占位由动画进度动态叠加），与模糊图烘焙内容（仅主行
  /// 文字）严格一致，不会把烘焙图纵向拉伸。取同源测量而非各自按行数重算，
  /// 也消除 KRC 行（word 累加压缩高度）与非 KRC 行（TextPainter 完整行高）
  /// 两套高度模型导致的 pivot Y 偏差。
  ({double sigma, double padding, double blockHeight, double fontSize,
    double imageHeight}) _blurGeometry(int lineIndex, int blurLevel) {
    // sigma = 距离分级值 × 用户强度倍数。
    // 倍数默认 1.0 时与历史行为完全一致（sigma = blurLevel）；
    // 上限 10 = maxBlurIntensity 2.0 × 最远分级 5。
    final double sigma = (blurLevel * LyricPreferences.instance.blurIntensity)
        .clamp(0.5, 10.0);
    final double fontSize = LyricLayout.fontSize(context);
    final double blockHeight = lineIndex < _lineHeights.length
        ? _lineHeights[lineIndex]
        : fontSize * LyricLayout.lineHeight;
    final double padding = sigma * 3;
    return (
      sigma: sigma,
      padding: padding,
      blockHeight: blockHeight,
      fontSize: fontSize,
      imageHeight: blockHeight + padding * 2,
    );
  }

  /// 副行模糊图几何（渲染与定位共用，口径见 [_blurGeometry]）。
  ///
  /// blockHeight 取该行副行预留高度 [_auxSubHeightOf]（含换行行数），**不含**
  /// 副行进度——进度只影响合成期位置与透明度，因此本几何与 blurLevel 一起
  /// 构成稳定的缓存键，进度动画期间不会触发重烘焙。
  ({double sigma, double padding, double blockHeight, double fontSize,
    double imageHeight}) _auxBlurGeometry(int lineIndex, int blurLevel) {
    final double sigma = (blurLevel * LyricPreferences.instance.blurIntensity)
        .clamp(0.5, 10.0);
    final double fontSize = LyricLayout.fontSize(context);
    final double blockHeight = _auxSubHeightOf(lineIndex);
    final double padding = sigma * 3;
    return (
      sigma: sigma,
      padding: padding,
      blockHeight: blockHeight,
      fontSize: fontSize,
      imageHeight: blockHeight + padding * 2,
    );
  }

  /// 模糊层几何签名（不含 blurLevel）：影响渲染结果的所有输入。
  ///
  /// 必须含 `LyricLayout.lineHeight`：模糊图内文字按 `height: lineHeight` 排版，
  /// 行间距变化若不进签名，旧模糊图会停留在旧行高上（表现为调行间距不刷新）。
  /// 必须含 `displayMode`：副行模糊图烘焙的是翻译或罗马音之一，切换模式后
  /// 旧图内容会与新文本不符。
  String _blurGeometrySig() {
    final double fontSize = LyricLayout.fontSize(context);
    return '${fontSize.toStringAsFixed(2)}|${_viewportWidth.toStringAsFixed(2)}'
        '|${widget.enableScale}|${LyricLayout.inactiveScale.toStringAsFixed(4)}'
        '|${LyricLayout.lineHeight.toStringAsFixed(4)}'
        '|${LyricLayout.fontFamily}|${LyricPreferences.instance.blurIntensity.toStringAsFixed(4)}'
        '|${LyricLayout.fontWeight.value}'
        '|${LyricPreferences.instance.displayMode.name}';
  }

  /// 模糊图缓存签名 = 几何签名 + blurLevel（主行）。
  String _blurCacheSignature(int blurLevel) =>
      '${_blurGeometrySig()}|$blurLevel';

  /// 副行模糊图缓存签名：与主行图隔离，避免两类图互相覆盖。
  String _auxBlurCacheSignature(int blurLevel) =>
      '${_blurGeometrySig()}|aux|$blurLevel';

  /// 异步渲染单行模糊图片。
  ///
  /// 渲染歌词文字到 Picture，应用 ImageFilter.blur，转为 ui.Image 缓存。
  ///
  /// **缩放烘焙**：清晰层非当前行绘制时被 `canvas.scale(inactiveScale)` 绕 pivot
  /// 收缩，模糊图必须在离屏渲染时施加同一 pivot+scale 变换，两层字形才会严格
  /// 重合（此前模糊层完全不缩放，恒定比清晰字大 3%，长行行尾偏差可达 ~9px）。
  Future<ui.Image?> _renderLineBlur(
    int lineIndex,
    int blurLevel,
    DuetAlignment alignment,
  ) async {
    try {
      if (_viewportWidth <= 0) return null;

      // sigma / padding / 文字块高度 / 图片高度统一取自 _blurGeometry，
      // 与 _buildBlurLayers 定位侧同一口径。
      final geom = _blurGeometry(lineIndex, blurLevel);
      final double sigma = geom.sigma;
      final double padding = geom.padding;
      final double fontSize = geom.fontSize;
      final double renderHeight = geom.imageHeight;
      final double leftPadding = fontSize;
      final double maxTextWidth = _viewportWidth - fontSize * 2;

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);

      // 修复：与 LineRenderer/WordRenderer 一致采用 _alignX 显式计算文本起始 x，
      // 不依赖 TextPainter.textAlign（textAlign 在某些场景下不可靠，
      // 会导致非当前行模糊图错位到左侧）。
      final textPainter = TextPainter(textDirection: TextDirection.ltr);
      textPainter.text = TextSpan(
        text: _cleanedLines[lineIndex].text,
        style: TextStyle(
          color: Color.fromRGBO(
            LyricLayout.textRed,
            LyricLayout.textGreen,
            LyricLayout.textBlue,
            LyricLayout.blurBakedAlpha,
          ),
          fontSize: fontSize,
          height: LyricLayout.lineHeight,
          // 显式注入歌词 fontFamily，与清晰层保持一致，
          // 否则模糊层尺寸与清晰层不匹配
          fontFamily: LyricLayout.fontFamily,
          fontWeight: LyricLayout.fontWeight,
        ),
      );
      textPainter.layout(maxWidth: maxTextWidth);

      // 对画布应用模糊
      final blurPaint = Paint()
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: tvBlurSigma(sigma),
          sigmaY: tvBlurSigma(sigma),
        );
      canvas.saveLayer(
        Rect.fromLTWH(0, 0, _viewportWidth, renderHeight),
        blurPaint,
      );

      // === 烘焙清晰层非当前行的 pivot+scale 变换 ===
      // 图片局部坐标与视口坐标的关系：Positioned(left: 0, top: y - padding)
      // 使视口点 (vx, vy) 对应局部点 (vx, vy - y + padding)，故清晰层
      // pivotY = y + blockHeight/2 对应局部 padding + blockHeight/2。
      // pivotX 按对齐方式取锚点（左边缘 / 右边缘 / 视口中点），与清晰层逐一对应；
      // 缩放朝 pivot 收缩，内容必然落在原包围盒内，无裁切风险。
      // 变换放在 saveLayer 内部：sigma 保持在未缩放空间，与 padding = sigma*3 同口径。
      final double blurScale = LyricLayout.blurRenderScale(
        enableScale: widget.enableScale,
      );
      final double pivotX = alignment == DuetAlignment.right
          ? _viewportWidth - leftPadding
          : alignment == DuetAlignment.center
          ? _viewportWidth / 2
          : leftPadding;
      final double pivotY = padding + geom.blockHeight / 2;
      canvas.save();
      canvas.translate(pivotX, pivotY);
      canvas.scale(blurScale, blurScale);
      canvas.translate(-pivotX, -pivotY);

      // 是否为多行只看换行计划：与清晰层、行高预留共用同一份断点，
      // 否则模糊图与清晰文字的行数会岔开（历史上这里独立贪心过一次重叠）。
      final LyricWrapPlan blurPlan = lineIndex < _wrapPlans.length
          ? _wrapPlans[lineIndex]
          : _emptyPlan;
      final bool isMultiLine = blurPlan.rowCount > 1;
      if (!isMultiLine) {
        // 单行：用 _alignX 计算起始 x
        final double x = _blurAlignX(
          alignment,
          leftPadding,
          textPainter.width,
          _viewportWidth,
        );
        textPainter.paint(canvas, Offset(x, padding));
      } else {
        // 多行：按计划的视觉行拆分，每行独立 _blurAlignX 对齐绘制
        _paintBlurMultiLineAligned(
          canvas,
          textPainter,
          alignment,
          leftPadding,
          padding,
          fontSize,
          _viewportWidth,
          blurPlan,
        );
      }
      canvas.restore();
      canvas.restore();

      final picture = recorder.endRecording();
      // 用 round 而非 toInt 截断：定位侧按精确逻辑尺寸显示，截断会让整图
      // 少 1px 而被拉伸，右缘文字额外左移。
      final image = await picture.toImage(
        _viewportWidth.round(),
        renderHeight.round(),
      );
      // toImage 经 native 回调栅格化，future 完成后 Picture 不再被引用，此刻释放才安全。
      picture.dispose();
      return image;
    } catch (_) {
      return null;
    }
  }

  /// 异步渲染单行**副行**模糊图片。
  ///
  /// 与 [_renderLineBlur] 同一套烘焙约定（sigma / padding / pivot+scale / 尺寸取整），
  /// 差别只有三处：内容取该行副行文本（翻译或罗马音，按 `displayMode`）、
  /// 字号取 `LyricLayout.translationFontSize`、行距取 `translationLineHeight`。
  ///
  /// 对齐用 [TextPainter.textAlign] + 「左右各留 1em」的布局宽度实现：该区间的
  /// 左缘 / 中心 / 右缘恰好等于清晰层副行的 `_alignX` 三个落点，无需逐行
  /// 复刻多行拆分（副行本来就按 wrap plan 的硬断点排版，行数两边一致）。
  Future<ui.Image?> _renderAuxBlur(
    int lineIndex,
    int blurLevel,
    DuetAlignment alignment,
  ) async {
    try {
      if (_viewportWidth <= 0) return null;
      if (lineIndex < 0 || lineIndex >= _cleanedLines.length) return null;
      final geom = _auxBlurGeometry(lineIndex, blurLevel);
      if (geom.blockHeight <= 0) return null;

      final double sigma = geom.sigma;
      final double padding = geom.padding;
      final double fontSize = geom.fontSize;
      final double renderHeight = geom.imageHeight;
      final double leftPadding = fontSize;
      final double maxTextWidth = _viewportWidth - fontSize * 2;

      final LyricLine line = _cleanedLines[lineIndex];
      final String? auxText =
          LyricPreferences.instance.displayMode == LyricDisplayMode.roma
          ? line.roma
          : line.translation;
      if (auxText == null || auxText.isEmpty) return null;

      // 与清晰层副行同一份换行计划（含硬断点），保证「画几行 == 预留几行」
      final LyricWrapPlan auxPlan = lineIndex < _auxWrapPlans.length
          ? _auxWrapPlans[lineIndex]
          : LyricWrapPlanner.forText(
              auxText,
              LyricLayout.auxStyle(fontSize),
              maxTextWidth,
              balanced: LyricPreferences.instance.lineBalance,
            );

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);

      final textPainter = TextPainter(
        textAlign: alignment == DuetAlignment.right
            ? TextAlign.right
            : alignment == DuetAlignment.center
            ? TextAlign.center
            : TextAlign.left,
        textDirection: TextDirection.ltr,
      );
      textPainter.text = TextSpan(
        text: auxPlan.rowTexts.join('\n'),
        style: TextStyle(
          // 烘焙 alpha = 主行烘焙值 × 副行相对亮度（0.25）。行/帧级别的淡出与
          // 用户透明度偏好都由合成期 Opacity 承担，于是进度动画与拖滑块都不
          // 触发重烘焙。
          color: Color.fromRGBO(
            LyricLayout.textRed,
            LyricLayout.textGreen,
            LyricLayout.textBlue,
            LyricLayout.blurAuxBakedAlpha,
          ),
          fontSize: LyricLayout.translationFontSize(fontSize),
          height: LyricLayout.translationLineHeight,
          fontFamily: LyricLayout.fontFamily,
          fontWeight: LyricLayout.fontWeight,
        ),
      );
      textPainter.layout(maxWidth: maxTextWidth);

      final blurPaint = Paint()
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: tvBlurSigma(sigma),
          sigmaY: tvBlurSigma(sigma),
        );
      canvas.saveLayer(
        Rect.fromLTWH(0, 0, _viewportWidth, renderHeight),
        blurPaint,
      );

      final double blurScale = LyricLayout.blurRenderScale(
        enableScale: widget.enableScale,
      );
      final double pivotX = alignment == DuetAlignment.right
          ? _viewportWidth - leftPadding
          : alignment == DuetAlignment.center
          ? _viewportWidth / 2
          : leftPadding;
      // 与主行图同款：pivot 取副行块中心（烘焙空间），合成期 Transform 的
      // alignment 也按同一局部坐标给，两层缩放行为一致。
      final double pivotY = padding + geom.blockHeight / 2;
      canvas.save();
      canvas.translate(pivotX, pivotY);
      canvas.scale(blurScale, blurScale);
      canvas.translate(-pivotX, -pivotY);
      canvas.save();
      canvas.translate(leftPadding, padding);
      textPainter.paint(canvas, Offset.zero);
      canvas.restore();
      canvas.restore();
      canvas.restore();

      final picture = recorder.endRecording();
      final image = await picture.toImage(
        _viewportWidth.round(),
        renderHeight.round(),
      );
      picture.dispose();
      return image;
    } catch (_) {
      return null;
    }
  }

  /// 模糊层对齐 x 计算（与 LineRenderer._alignX / WordRenderer._alignX 一致）。
  double _blurAlignX(
    DuetAlignment alignment,
    double leftPadding,
    double textWidth,
    double viewportWidth,
  ) {
    if (viewportWidth <= 0 ||
        alignment == DuetAlignment.defaultAlign ||
        alignment == DuetAlignment.left) {
      return leftPadding;
    }
    if (alignment == DuetAlignment.right) {
      return viewportWidth - leftPadding - textWidth;
    }
    // center
    return (viewportWidth - textWidth) / 2;
  }

  /// 模糊层多行文本按视觉行拆分，每行独立对齐绘制。
  /// 与 LineRenderer._paintMultiLineAligned 逻辑一致。
  void _paintBlurMultiLineAligned(
    Canvas canvas,
    TextPainter painter,
    DuetAlignment alignment,
    double leftPadding,
    double padding,
    double fontSize,
    double viewportWidth,
    LyricWrapPlan plan,
  ) {
    final String text = painter.text?.toPlainText() ?? '';
    if (text.isEmpty) return;
    // 视觉行文本来自换行计划（与清晰层 LineRenderer 同源）
    final List<String> rowTexts = plan.rowTexts;
    // 每行独立绘制（与 LineRenderer._paintMultiLineAligned 一致）：
    // 主行完整行高从 padding 起，换行行 0.8x 行高从主行底起，行盒=行距避免重叠
    final double mainLineHeight = fontSize * LyricLayout.lineHeight;
    final double wrapLineHeight =
        mainLineHeight * LyricLayout.wrapLineHeightFactor;
    final lineMeasurer = TextPainter(textDirection: TextDirection.ltr);
    for (int i = 0; i < rowTexts.length; i++) {
      final bool isFirstRow = i == 0;
      final double rowHeight = isFirstRow
          ? LyricLayout.lineHeight
          : LyricLayout.lineHeight * LyricLayout.wrapLineHeightFactor;
      lineMeasurer.text = TextSpan(
        text: rowTexts[i],
        style: painter.text!.style!.copyWith(height: rowHeight),
      );
      lineMeasurer.layout(maxWidth: double.infinity);
      final double x = _blurAlignX(
        alignment,
        leftPadding,
        lineMeasurer.width,
        viewportWidth,
      );
      final double y = isFirstRow
          ? padding
          : padding + mainLineHeight + (i - 1) * wrapLineHeight;
      lineMeasurer.paint(canvas, Offset(x, y));
    }
    lineMeasurer.dispose();
  }
}

/// 一轮级联错峰：行 i 在 `clockMs + delay(i)` 释放（delay 由释放循环累加）。
///
/// 预启动与回落补偿共用本对象，区别只在创建时机与参数：
/// - 预启动：锚行 = 下一行，`clockMs` 为进窗首帧，`scale` 由剩余提前量推出；
/// - 回落：锚行 = 新当前行，`clockMs` 为切行帧，`scale` 由固定预算 K×步长推出。
///
/// `scale` 只压缩锚行**以上**的行（保持自上而下剥离顺序）；锚行延迟 =
/// `(anchorLine − startLine) × 步长 × scale`，于是锚行恰在期望时刻释放。
class _CascadeRound {
  const _CascadeRound({
    required this.anchorLine,
    required this.startLine,
    required this.clockMs,
    required this.scale,
  });

  /// 对齐释放时刻的行（预启动时为下一行，回落时为新当前行）。
  final int anchorLine;

  /// 本轮错峰起点行（由目标 posY 确定性计算）。
  final int startLine;

  /// 时间线锚点（帧时钟 `_frameClockMs`）。
  final double clockMs;

  /// 锚行以上行的延迟压缩系数（1.0 = 原始步长，越小越紧凑）。
  final double scale;
}

/// 歌词上下边界渐隐 shader 缓存（24px）。
///
/// 渐隐参数只依赖视口尺寸，尺寸不变时复用同一 shader。清晰层与模糊层
/// 各自持有一个实例，避免两者尺寸口径不同时互相顶掉缓存。
class _FadeShaderCache {
  ui.Shader? _shader;
  Rect? _bounds;

  ui.Shader forBounds(Rect bounds) {
    if (_shader != null && bounds == _bounds) return _shader!;
    const double fadeHeight = 24.0;
    final double fadeRatio = (fadeHeight / bounds.height).clamp(0.0, 0.5);
    final shader = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: const [
        Colors.transparent,
        Colors.black,
        Colors.black,
        Colors.transparent,
      ],
      stops: [0.0, fadeRatio, 1.0 - fadeRatio, 1.0],
    ).createShader(bounds);
    _shader = shader;
    _bounds = bounds;
    return shader;
  }
}

/// 模糊层合成器。
///
/// 只负责把 State 侧已烘焙的模糊图（主行 + 副行 + 入场层）画到画布上：
/// 位置、缩放、不透明度、副行进度全部读实时状态，逐帧变化只触发重绘，
/// 不再重建 widget 树（历史实现用 Positioned/Opacity/Transform/RawImage，
/// 任意一项逐帧变化都会重建整棵模糊层 Stack）。
class _BlurLayersPainter extends CustomPainter {
  _BlurLayersPainter({required this.state, required Listenable repaint})
    : super(repaint: repaint);

  final _AppleLyricsViewState state;

  @override
  void paint(Canvas canvas, Size size) => state._paintBlurLayers(canvas, size);

  @override
  bool shouldRepaint(covariant _BlurLayersPainter oldDelegate) => true;
}

/// 歌词绘制器。
///
/// 遍历所有 lines，跳过视口外（含 overscan=300px 上下缓冲）的行，
/// 按行调用对应 renderer 的 [WordRenderer.paintLine] / [LineRenderer.paintLine]。
///
/// 每行通过 [perLineScales]（各自 scale 弹簧位置）提供 scale：进场放大 / 离场缩小
/// 均连贯；目标值取自 [LyricLayout.activeScale] / [LyricLayout.inactiveScale]（可调）。
///
/// 间奏时段在视口中央绘制 [InterludeDots]。
///
/// **自动换行**：每行实际高度由 [lineHeights] 提供（非均匀），
/// 行顶部 y = lineTops[i] + posY（累加偏移）。renderer 的 paintLine 接收
/// [maxLineWidth] 参数实现 word 级换行。
class _LyricsPainter extends CustomPainter {
  List<LyricLine> lines;
  List<DuetAlignment> duetAlignments;

  /// 渲染口径的焦点行索引（-1 = 焦点由头部间奏占位占据，没有行激活）。
  ///
  /// 与 State 的 `_focusLineIndex` 同值：普通播放时等于当前行；头部间奏
  /// （首行之前的间奏点）显示期间为 -1，首行因此按"尚未唱到的下行"绘制
  /// （暗态 + 由模糊层接管）。
  int focusLineIndex;
  /// 等待期内冻结视觉激活：所有行按非当前行处理（不画清晰层、不放大）。
  bool activationHeld;
  double posY;
  double fontSize;
  double mainLineHeight;
  List<double> lineHeights;
  List<double> lineTops;
  double viewportHeight;
  double viewportWidth;

  /// 只看焦点行（当前行层）。与 [skipFocusLine] 互斥。
  bool onlyFocusLine = false;

  /// 跳过焦点行（其余行层）。
  bool skipFocusLine = false;

  /// 上下 24px 渐隐 shader 缓存（仅本 painter 使用）。
  final _FadeShaderCache _fade = _FadeShaderCache();
  double maxLineWidth;
  int currentTimeMs;
  bool enableScale;
  Map<int, WordRenderer> wordRenderers;
  Map<int, LineRenderer> lineRenderers;

  /// 每行当前的 scale 弹簧位置（由 _onTick 的 per-line scale 推进循环填充）。
  ///
  /// 每行独立持有 scale 弹簧后，离场行（当前行 → 非当前行）从 1.0 平滑缩到
  /// inactiveScale，进场行从 0.850 平滑放大到 1.0——补上原来"缩小硬切"的观感。
  List<double> perLineScales;
  EmphasizeEffect emphasizeEffect;
  InterludeDots interludeDots;
  List<int> interludeAfterIndices;
  double interludePlaceholderHeight;
  int activeInterludeIdx;
  int lastActiveAnchorIdx;
  double interludeExpandProgress;

  /// 副行动画（逐行）：展开进度 / 目标 / 上方高度前缀和 / 进度代次。
  ///
  /// 三者都是 State 侧的 live 引用（State 可能整体替换实例，构建与
  /// [updatePerFrame] 都会同步），与 [blurReadyLineIndices] 同模式。
  /// 语义必须与 `_LyricsPainter` 之外的 State 侧实现**逐字对应**：
  /// 高度模型、前缀和口径任一岔开都会让清晰层与模糊层错位（本仓重叠教训）。
  List<double> auxProgress;
  List<double> auxTargets;
  List<double> auxTopsPrefix;
  int auxProgressGeneration;

  /// 逐行副行预留高度（含过长换行，索引与 lines 对齐）。
  List<double> auxSubHeights;

  /// 每行主歌词 / 副行的换行计划（由 State 统一生产，索引与 lines 对齐）。
  List<LyricWrapPlan> wrapPlans;
  List<LyricWrapPlan> auxPlans;
  List<double> perLineOffsets;
  double blurFade;
  bool blurActive;
  // P2-I：已就绪模糊图的行索引集合（live view，零分配）。
  // 当 blurActive && blurFade > 0.99 时，非当前行文字 alpha≈0（不可见），
  // 若该行模糊图已就绪则跳过文字层绘制——模糊层已覆盖显示。
  Iterable<int> blurReadyLineIndices;
  /// 已就绪的**副行**模糊图行索引集合（live view，零分配）。
  ///
  /// 跳过清晰层的条件必须同时看它：该行有可见副行时，若只等主行图就绪就跳过，
  /// 副行会在模糊层接管后整体消失（「所有行」下几乎每行都有副行）。
  Iterable<int> auxBlurReadyLineIndices;

  /// 副行清晰图（行索引 → 预栅格化图，live 引用）。
  ///
  /// 翻转期间用它替代文字做透视绘制：文字走透视矩阵会被 Skia 退化成字形
  /// 路径逐帧渲染，是切行掉帧的来源。
  Map<int, AuxTextImage> auxTextImages;
  int textColorValue;
  int? activeLineColorValue;

  /// 上方行颜色覆盖值（ARGB），null = 不覆盖（上方行沿用 [textColorValue]）。
  int? aboveLineColorValue;
  int linesGeneration;
  int lineHeightsGeneration;
  int lineTopsGeneration;
  int interludeAfterIndicesGeneration;
  int perLineOffsetsGeneration;

  _LyricsPainter({
    super.repaint,
    required this.lines,
    required this.duetAlignments,
    required this.focusLineIndex,
    required this.activationHeld,
    required this.posY,
    required this.fontSize,
    required this.mainLineHeight,
    required this.lineHeights,
    required this.lineTops,
    required this.viewportHeight,
    required this.viewportWidth,
    required this.maxLineWidth,
    required this.currentTimeMs,
    required this.enableScale,
    required this.wordRenderers,
    required this.lineRenderers,
    required this.perLineScales,
    required this.emphasizeEffect,
    required this.interludeDots,
    required this.interludeAfterIndices,
    required this.interludePlaceholderHeight,
    required this.activeInterludeIdx,
    required this.lastActiveAnchorIdx,
    required this.interludeExpandProgress,
    required this.auxProgress,
    required this.auxTargets,
    required this.auxTopsPrefix,
    required this.auxProgressGeneration,
    required this.auxSubHeights,
    required this.wrapPlans,
    required this.auxPlans,
    required this.perLineOffsets,
    required this.blurFade,
    required this.blurActive,
    this.blurReadyLineIndices = const <int>[],
    this.auxBlurReadyLineIndices = const <int>[],
    this.auxTextImages = const <int, AuxTextImage>{},
    required this.textColorValue,
    required this.activeLineColorValue,
    required this.aboveLineColorValue,
    required this.linesGeneration,
    required this.lineHeightsGeneration,
    required this.lineTopsGeneration,
    required this.interludeAfterIndicesGeneration,
    required this.perLineOffsetsGeneration,
  });

  /// 更新每帧变化的动画字段（在 _onTick 中调用，避免 setState + build）。
  void updatePerFrame({
    required int focusLineIndex,
    required bool activationHeld,
    required double posY,
    required int currentTimeMs,
    required double blurFade,
    required double interludeExpandProgress,
    required int activeInterludeIdx,
    required int lastActiveAnchorIdx,
    required List<double> auxProgress,
    required List<double> auxTargets,
    required List<double> auxTopsPrefix,
    required int auxProgressGeneration,
    required List<double> auxSubHeights,
    required List<double> perLineOffsets,
    required int perLineOffsetsGeneration,
    required List<double> perLineScales,
  }) {
    this.focusLineIndex = focusLineIndex;
    this.activationHeld = activationHeld;
    this.posY = posY;
    this.currentTimeMs = currentTimeMs;
    this.blurFade = blurFade;
    this.interludeExpandProgress = interludeExpandProgress;
    this.activeInterludeIdx = activeInterludeIdx;
    this.lastActiveAnchorIdx = lastActiveAnchorIdx;
    this.auxProgress = auxProgress;
    this.auxTargets = auxTargets;
    this.auxTopsPrefix = auxTopsPrefix;
    this.auxProgressGeneration = auxProgressGeneration;
    this.auxSubHeights = auxSubHeights;
    this.perLineOffsets = perLineOffsets;
    this.perLineOffsetsGeneration = perLineOffsetsGeneration;
    this.perLineScales = perLineScales;
  }

  /// 获取指定行 i 的实际高度（含换行 + 副行动画高度），降级到 mainLineHeight。
  double _heightOf(int i) =>
      (i < lineHeights.length ? lineHeights[i] : mainLineHeight) +
      _transExtra(i);

  /// 获取指定行 i 的顶部 y（累加偏移），降级到 i * mainLineHeight。
  /// 不包含间奏占位偏移与副行动画高度。
  double _topOf(int i) =>
      i < lineTops.length ? lineTops[i] : i * mainLineHeight;

  /// 第 i 行的副行预留高度（与 State._auxSubHeightOf 同口径，含换行行数）。
  double _auxSubHeightOf(int i) =>
      (i >= 0 && i < auxSubHeights.length) ? auxSubHeights[i] : 0;

  /// 第 i 行的副行当前进度（越界 → 0，与 State._auxProgressAt 同口径）。
  double _auxProgressAt(int i) =>
      (i >= 0 && i < auxProgress.length) ? auxProgress[i] : 0.0;

  /// 第 i 行副行动画额外高度（与 State._transExtraHeightFor **逐字同式**）：
  /// 该行自身的副行预留高度（含换行行数）× 该行当前进度。
  /// 不读 showTranslation 短路（关闭副行时进度衰减到 0，高度平滑收起）。
  double _transExtra(int i) => _auxSubHeightOf(i) * _auxProgressAt(i);

  /// 第 i 行上方副行动画高度之和（与 State._transDeltaBefore 同口径），
  /// 叠加到行 top 消费点（主绘制循环 / 二分查找 / 间奏锚点）。
  /// 读 State 维护的前缀和（live 引用），O(1)。
  double _transDeltaBefore(int i) {
    if (i <= 0) return 0;
    final int last = auxTopsPrefix.length - 1;
    if (last <= 0) return 0;
    return auxTopsPrefix[i < last ? i : last];
  }

  /// 计算指定行索引上方激活间奏的占位高度。
  ///
  /// **progress 驱动**：只要 `interludeExpandProgress > 0` 就返回占位高度，
  /// 不依赖 `activeInterludeIdx`。这样间奏结束后 progress 缓慢收起到 0 期间，
  /// 占位偏移也跟随平滑收起，posY target 不会突变。
  ///
  /// 使用 `lastActiveAnchorIdx` 记录最后激活的间奏 anchor，
  /// 避免影响其他未激活间奏的占位。anchor 为 -1（头部间奏，占位在首行之前）时，
  /// 所有行（含首行）都让位一个占位高度，与 State 侧同口径。
  ///
  /// 高度 = interludePlaceholderHeight * interludeExpandProgress
  double _interludeOffsetBefore(int lineIndex) {
    if (interludeExpandProgress <= 0) return 0;
    final int anchorIdx = lastActiveAnchorIdx;
    if (anchorIdx == _AppleLyricsViewState._noInterludeAnchor ||
        anchorIdx >= lineIndex) {
      return 0;
    }
    return interludePlaceholderHeight * interludeExpandProgress;
  }

  /// 与上下 24px 渐隐带相交时返回该行的离屏遮罩区域（裁剪到视口内）。
  ///
  /// 视口中间的行返回 null，直接绘制、不做任何离屏合成。
  Rect? _edgeFadeRect(double top, double height, Size size) {
    const double fadeHeight = 24.0;
    final double bottom = top + height;
    if (top >= fadeHeight && bottom <= size.height - fadeHeight) return null;
    final Rect rect = Rect.fromLTWH(0, top, size.width, height)
        .intersect(Offset.zero & size);
    return rect.isEmpty ? null : rect;
  }

  /// 对 [rect] 内已绘制的歌词做上下边界 alpha 渐变（复刻原 ShaderMask 的 24px 渐隐）。
  void _applyEdgeFade(Canvas canvas, Rect rect, Size size) {
    canvas.drawRect(
      rect,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = _fade.forBounds(Offset.zero & size),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    // 行水平起始位置：左留 1em 边距（对应 LyricLayout.linePadding 的 horizontal）
    final double startX = fontSize * 1.0;

    // 绘制裁剪缓冲：上下各约一行即可。LyricLayout.overscanPx（300px）只用于
    // 布局/渲染器/模糊图预热窗口，不能拿来做绘制裁剪——按 300px 会把视口外
    // 多出 30%~50% 的行送进文字光栅化。
    final double paintPad = fontSize * 2.0;

    // === 性能优化：二分查找定位首行可见索引 ===
    // 之前从 i=0 遍历所有 lines（200+ 行），只靠 y 范围 continue/break 跳过。
    // 现在用二分查找快速定位第一个可能可见的行，跳过前方所有不可见行。
    // lineTops 是预排序的（递增），适合二分查找。
    int startI = 0;
    if (lineTops.isNotEmpty && lines.isNotEmpty) {
      int lo = 0, hi = lines.length;
      while (lo < hi) {
        final mid = (lo + hi) ~/ 2;
        final double yMid = _topOf(mid) + _transDeltaBefore(mid) + posY;
        if (yMid + _heightOf(mid) < -paintPad) {
          lo = mid + 1;
        } else {
          hi = mid;
        }
      }
      // 向前多看 2 行，处理间奏占位偏移导致的 y 变化
      startI = math.max(0, lo - 2);
    }

    for (int i = startI; i < lines.length; i++) {
      final line = lines[i];
      final double lineHeight = _heightOf(i);
      // 行顶部 y 坐标 = lineTops[i] + 该行上方间奏占位偏移 + 上方副行动画高度
      // + posY + 级联弹簧偏移。
      // 级联偏移仅当前行下方行非 0（上方行恒 0），50ms/行延迟错峰跟随（AMLL stagger），
      // 与模糊层 _buildBlurLayers 的 springOffset 对齐，避免两层错位。
      final double offset = i < perLineOffsets.length ? perLineOffsets[i] : 0.0;
      final double y =
          _topOf(i) +
          _transDeltaBefore(i) +
          _interludeOffsetBefore(i) +
          posY +
          offset;

      // 跳过视口外的行（只留约一行缓冲），避免把预热窗口内的行也光栅化
      if (y + lineHeight < -paintPad) continue;
      if (y > viewportHeight + paintPad) break;

      final bool isActive = !activationHeld && i == focusLineIndex;

      // P1-1 分层：当前行层只画焦点行，其余行层跳过焦点行。
      if (onlyFocusLine && i != focusLineIndex) continue;
      if (skipFocusLine && i == focusLineIndex) continue;

      // P2-I：高斯模糊全开且非当前行 alpha≈0（文字不可见）时，
      // 若该行模糊图已就绪，跳过文字层绘制——模糊层已在其上方覆盖显示。
      // 条件分解：
      // - blurActive && blurFade > 0.99：非当前行 alpha = dynamicDark*(1-blurFade) ≈ 0
      //   （LineRenderer/WordRenderer 中 effectiveFade = blurActive ? blurFade : 0，
      //    非当前行 alpha = dynamicDark * (1 - effectiveFade)）
      // - !isActive：仅跳过非当前行（当前行无模糊图，必须绘制）
      // - blurReadyLineIndices.contains(i)：模糊图已异步渲染完成，模糊层会显示该行；
      //   未就绪时仍绘制文字层，避免 blurFade 刚跨过 0.99 但模糊图尚未到位时出现空缺
      // - !isExitFading：刚退场的行正在做清晰层淡出（与模糊图重叠），
      //   此时跳过绘制会让淡出失效、退回硬切
      // - 该行的模糊图（主行 + 副行）都已就绪：副行也要由模糊层接管，
      //   否则跳过清晰层会让副行整体消失（「所有行」下几乎每行都有副行）
      // - 收起中的副行模糊层**不绘制**（会与清晰副行错位），此时不能跳过
      //   清晰层，否则退场副行会整段消失。
      final bool auxExiting =
          i < auxTargets.length && auxTargets[i] < _auxProgressAt(i) - 1e-4;
      final bool auxBlurReady =
          _auxProgressAt(i) <= 0.001 ||
          (auxBlurReadyLineIndices.contains(i) && !auxExiting);
      if (blurActive &&
          blurFade > 0.99 &&
          !isActive &&
          auxBlurReady &&
          blurReadyLineIndices.contains(i) &&
          !(lineRenderers[i]?.isExitFading ?? false)) {
        continue;
      }

      // 形变 scale 与 alpha scale 分开取：
      // - 形变（canvas.scale）用弹簧值，切行时产生 0.850→1.0 的弹性放大；
      // - alpha 用稳态值（当前行恒为 activeScale），使 factor=1、
      //   默认 unplayedOpacity=0.4 —— 新当前行从 0.4 起淡入，而不是被弹簧
      //   在起点处压到 0.2 再慢慢亮起来。
      // 与 _onTick 步骤 4 传给 renderer 的 scale 口径保持一致。
      // 形变 scale 用每行自己的弹簧位置（perLineScales），这样离场行从 1.0
      // 平滑缩到 inactiveScale、进场行从 0.850 平滑放大到 1.0，都不再硬切。
      // 兜底（perLineScales 尚未建立/长度不足）与状态侧窗口外稳态同口径：
      // enableScale=false 时非当前行不缩小，不能误用 inactiveScale。
      final double steadyScale = enableScale
          ? math.max(LyricLayout.inactiveScale, _minLegibleLineScale(fontSize))
          : LyricLayout.activeScale;
      final double scale = i < perLineScales.length
          ? perLineScales[i]
          : steadyScale;
      final double alphaScale = isActive
          ? LyricLayout.activeScale
          : (enableScale ? LyricLayout.inactiveScale : LyricLayout.activeScale);

      // 对唱对齐方式（越界时降级为默认左对齐）
      final DuetAlignment alignment = i < duetAlignments.length
          ? duetAlignments[i]
          : DuetAlignment.defaultAlign;

      // 落在上下 24px 渐隐带里的行才需要离屏遮罩（通常上下各 1 行）。
      final Rect? fadeRect = _edgeFadeRect(
        y - fontSize * 0.4,
        lineHeight + _transExtra(i) + fontSize * 0.8,
        size,
      );
      if (fadeRect != null) canvas.saveLayer(fadeRect, Paint());

      // 保存画布状态，应用 scale 变换。
      // pivotX 根据 alignment 选择：左对齐用左边缘，右对齐用右边缘，居中用视口中心。
      // 这样 scale<1.0 时文本以对齐锚点为中心收缩，对齐不会偏移。
      // 若统一用左边缘 pivot，右对齐/居中行 scale 后会向左偏移（视觉上对齐失效）。
      canvas.save();
      final double pivotX;
      if (alignment == DuetAlignment.right) {
        pivotX = viewportWidth - startX;
      } else if (alignment == DuetAlignment.center) {
        pivotX = viewportWidth / 2;
      } else {
        pivotX = startX;
      }
      final double pivotY = y + lineHeight / 2;
      canvas.translate(pivotX, pivotY);
      canvas.scale(scale, scale);
      canvas.translate(-pivotX, -pivotY);

      // 当前行 + 有 word 时间戳 → WordRenderer（逐字模式：N 次 layout/帧）
      // 否则 → LineRenderer（整行模式：1 次 layout/帧，含非当前行的 KRC 行）
      // 性能优化：非当前行不需要逐字渐变，用 LineRenderer 大幅减少 layout 次数
      final bool useWordRenderer = isActive && line.hasWordTiming;
      // 行级颜色覆盖：与 _onTick 同一口径（当前行高亮色 / 上方已播行开关）。
      final int? lineColorValue = lineColorOverrideValue(
        activeLineColorValue: activeLineColorValue,
        aboveLineColorValue: aboveLineColorValue,
        isActive: isActive,
        isAboveCurrent: i < focusLineIndex,
      );
      // 翻译副行清晰层与副行模糊图的交接系数：
      // 副行模糊图已就绪且正在接管（非收起中、非当前行）时，清晰副行必须与
      // 主行清晰层同步快速退场；否则副行会保留清晰白字，模糊淡入时同样
      // 「先更白、过一会儿才落到正常色」。未就绪/收起中则保持 1（清晰层独撑）。
      final bool auxBlurCovers =
          blurActive &&
          !isActive &&
          auxBlurReadyLineIndices.contains(i) &&
          i < auxTargets.length &&
          !(auxTargets[i] < _auxProgressAt(i) - 1e-4);
      final double auxClearFade = auxBlurCovers ? (1.0 - blurFade) : 1.0;
      if (useWordRenderer) {
        // 逐字模式：当前行的 KRC 行
        final renderer = wordRenderers[i] ?? WordRenderer();
        // 副行进度按**绘制行号**注入（不走 _onTick 的 ±overscan 窗口）：
        // 逐行进度下任意行都可能有副行，窗口外行若残留旧值会画出幽灵副行。
        final double auxP = _auxProgressAt(i);
        renderer.translationExpand = auxP;
        renderer.translationFade = auxP * auxClearFade;
        renderer.translationExiting = false;
        renderer.setLineState(
          isActive: true,
          scale: alphaScale,
          blurFade: blurFade,
          blurActive: blurActive,
          activeColorValue: lineColorValue,
        );
        renderer.paintLine(
          canvas,
          Offset(startX, y),
          line,
          fontSize,
          maxWidth: maxLineWidth,
          alignment: alignment,
          viewportWidth: viewportWidth,
          wrapPlan: i < wrapPlans.length ? wrapPlans[i] : null,
          auxPlan: i < auxPlans.length ? auxPlans[i] : null,
          auxImage: auxTextImages[i],
        );
      } else {
        // 整行模式：LRC/纯文本行 + 非当前行的 KRC 行
        final renderer = lineRenderers[i] ?? LineRenderer();
        // 副行进度按绘制行号注入（理由同上）。方向标记按「目标 < 当前」判定：
        // 下行 = 出场（绕顶边向上翻走），上行 = 入场（绕底边从下翻出）。
        final double auxP = _auxProgressAt(i);
        final double auxT = (i >= 0 && i < auxTargets.length)
            ? auxTargets[i]
            : 0.0;
        renderer.translationExpand = auxP;
        renderer.translationFade = auxP * auxClearFade;
        renderer.translationExiting = auxT < auxP - 1e-4;
        renderer.setLineState(
          isActive: isActive,
          scale: alphaScale,
          blurFade: blurFade,
          blurActive: blurActive,
          activeColorValue: lineColorValue,
          // 与 _onTick 同一口径：仅上方行且确有已播色时提高清晰层 alpha。
          isAboveCurrent: aboveLineColorValue != null && i < focusLineIndex,
        );
        final bool staticPainted =
            !isActive &&
            auxP <= 0.001 &&
            renderer.tryPaintLineStatic(
              canvas,
              Offset(startX, y),
              line,
              fontSize,
              maxWidth: maxLineWidth,
              alignment: alignment,
              viewportWidth: viewportWidth,
              wrapPlan: i < wrapPlans.length ? wrapPlans[i] : null,
              colorValue: lineColorValue,
            );
        if (!staticPainted) {
          renderer.paintLine(
            canvas,
            Offset(startX, y),
            line,
            fontSize,
            maxWidth: maxLineWidth,
            alignment: alignment,
            viewportWidth: viewportWidth,
            wrapPlan: i < wrapPlans.length ? wrapPlans[i] : null,
            auxPlan: i < auxPlans.length ? auxPlans[i] : null,
            auxImage: auxTextImages[i],
          );
        }
      }

      canvas.restore();
      if (fadeRect != null) {
        _applyEdgeFade(canvas, fadeRect, size);
        canvas.restore();
      }
    }

    // 绘制间奏点（若处于间奏时段或间奏结束后收起期间）。
    // 间奏点作为占位行嵌在歌词流里：普通间奏位于 anchor 行**之后**，
    // 头部间奏（anchor = -1）位于**首行之前**（第一行上方一个占位行高）。
    // 滚动目标把占位行对准「当前行位置」偏好，圆点画在该行中心（见下方 centerY）。
    // 点大小/间距跟随 fontSize 缩放：radius≈fontSize*0.18，spacing≈fontSize*0.9。
    //
    // **同步收起**：间奏结束后 progress 收起期间也绘制间奏点，
    // 让点消失动画与占位收起同步（都是 ~300-750ms）。
    // 占位完全收起（progress == 0）后不得再绘制：圆点属于占位行，
    // 零高度时绘制会残留在占位位置悬浮穿帮。
    // 间奏点只由当前行层绘制（P1-1 分层后两层都会遍历到这里，避免重复叠加）。
    if (onlyFocusLine &&
        interludeDots.shouldRender &&
        interludeExpandProgress > 0 &&
        lastActiveAnchorIdx != _AppleLyricsViewState._noInterludeAnchor &&
        lastActiveAnchorIdx < lines.length) {
      final int anchorIdx = lastActiveAnchorIdx;
      final double anchorBottomY;
      if (anchorIdx < 0) {
        // 头部间奏：占位在首行之前，其底部 = 首行顶部（内容坐标原点，含 posY）。
        // 首行自身也带了占位偏移，所以内容坐标 0 就是占位的上沿。
        anchorBottomY = _topOf(0) + _transDeltaBefore(0) + posY;
      } else {
        // anchor 行底部 y（含 anchor 行上方的间奏偏移 + 副行动画高度）
        anchorBottomY =
            _topOf(anchorIdx) +
            _heightOf(anchorIdx) +
            _transDeltaBefore(anchorIdx) +
            _interludeOffsetBefore(anchorIdx) +
            posY;
      }
      // 间奏点 centerY 居中在**完全展开**的占位行里：
      // 滚动目标把占位行对准「当前行位置」偏好（见 State 的 `_interludeSlotTop`），
      // 圆点因此正好落在焦点上；展开/收缩期间不跟着动态高度上下漂。
      final double centerY = anchorBottomY + interludePlaceholderHeight / 2;
      // 点半径与间距跟随 fontSize 缩放，系数由用户在「歌词动画」页调节
      // （默认 0.18 / 0.9 = 历史写死值，AMLL 风格：直径约 8.6px @ fontSize=24）
      final double dotRadius =
          fontSize * LyricPreferences.instance.interludeDotRadius;
      final double dotSpacing =
          fontSize * LyricPreferences.instance.interludeDotSpacing;
      // 间奏点整体水平起点 = fontSize × 系数（默认 1.5：比歌词左对齐
      // 右移 0.5em，让点整体居中偏右，视觉更平衡）
      final double dotsStartX =
          fontSize * LyricPreferences.instance.interludeDotsStartX;
      interludeDots.paintAtLineY(
        canvas,
        dotsStartX,
        centerY,
        dotRadius: dotRadius,
        spacing: dotSpacing,
        // 间奏点颜色跟随当前行动态色（未开启/未提取到时回退基础歌词色）
        colorValue: activeLineColorValue ?? LyricLayout.textColorValue,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _LyricsPainter oldDelegate) {
    // 持久化 painter：由 notifyListeners() 驱动重绘，shouldRepaint 返回 false。
    // 仅在 build() 创建新 painter 时（首次构建或 widget 重建）才会调用此方法。
    return false;
  }
}

/// ChangeNotifier 子类，暴露 public fireRepaint() 方法。
/// 用于驱动持久化 _LyricsPainter 的重绘，替代 setState + build。
class _RepaintNotifier extends ChangeNotifier {
  void fireRepaint() {
    notifyListeners();
  }
}
