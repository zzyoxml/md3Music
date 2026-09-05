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
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../core/utils/app_haptics.dart';
import 'package:flutter/widgets.dart';

import 'controllers/lyric_scroll_controller.dart';
import 'animation/spring.dart';
import 'layout/duet_layout.dart';
import 'layout/lyric_layout.dart';
import 'layout/lyric_preferences.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import 'renderers/emphasize_effect.dart';
import 'renderers/interlude_dots.dart';
import 'renderers/line_renderer.dart';
import 'renderers/word_renderer.dart';

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
  /// 为 true 时，当前行歌词颜色按「70% 白 + 30% 提取色」混色；
  /// 非当前行保持默认白色不变。
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
    with SingleTickerProviderStateMixin {
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
  double _lastRepaintTransExpand = 0;
  double _lastRepaintTransFade = 0;
  int _lastRepaintCurrentLineIndex = -1;

  /// P0-1 方案 A：高斯模糊层（Positioned/Opacity/RawImage）的脏标记缓存。
  ///
  /// 稳态逐字演唱时模糊层完全静止（行 / posY / blurFade / 间奏占位 / 弹簧
  /// 都不变），无需每帧 setState 重建 widget 树。仅当以下任一变化时重建：
  /// 当前行、posY(>0.5px)、blurFade(>0.001)、间奏占位 progress(>0.001)、
  /// perLine 弹簧偏移(>0.5px)。
  /// blurFade 初始 -1 强制首帧重建（首次进入需创建模糊层）。
  int _lastBlurRebuildLineIndex = -1;
  double _lastBlurRebuildPosY = 0;
  double _lastBlurRebuildBlurFade = -1;
  double _lastBlurRebuildInterludeProgress = -1;
  double _lastBlurRebuildEntryBlur = -1;

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

  // P0: 间奏点动画降频（30fps）用的帧时间累积器
  double _interludeAccumulator = 0;

  /// 逐字动画平滑时间的权威位置校正：
  ///
  /// - [_smoothPosSeekJumpMs]：权威位置跳变超过此值视为 seek/大跳变，直接吸附。
  /// - [_smoothPosCorrRate]：正常 position 更新时平滑逼近权威位置的速率（指数衰减系数）。
  ///   平滑逼近而非硬跳，避免音频时钟与帧时钟漂移导致权威位置硬跳跨过逐字边界、
  ///   字切换来回抖动（英文歌字短、边界密集时更明显，表现为"下一个字闪一下"）。
  static const int _smoothPosSeekJumpMs = 500;
  static const double _smoothPosCorrRate = 20.0;

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

  /// eco 锁定时的 60fps 限帧定时器（真正的帧率限制驱动源）。
  Timer? _ecoTimer;

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

  /// P1-C：上次间奏检测时的权威播放时间（毫秒）。
  ///
  /// 间奏检测只依赖 currentTimeMs（positionStream 约 200ms 更新一次），
  /// 时间未变且占位动画已收敛时，跳过每帧 O(间奏数) 的线性遍历。
  /// 同时用于检测时间回退（seek/跳转）：currentTimeMs < 上次值时说明
  /// 播放位置回跳，需强制重置间奏点动画时钟（见 [_updateInterlude]）。
  int _lastInterludeCheckTimeMs = -1;

  // ============== 动态字体颜色（仅 AM 播放器，默认关闭） ==============
  // 开启后当前行歌词颜色按「70% 白 + 30% 封面提取色」混色，
  // 非当前行保持默认白色。颜色由 build 根据 accentColor 计算一次，
  // _onTick 与 painter 每帧读取，避免每帧 Color.lerp 分配。

  /// 当前行动态字体颜色（ARGB int），null 表示不使用（回退默认白色）。
  int? _activeLineColorValue;

  // overscan 视口缓冲行数：pad 端 15、手机端 10。在 build 中根据最短边更新
  int _overscan = 10;

  /// 模糊渐隐系数（1.0=正常模糊，0.0=无模糊）。
  /// 用户滚动时淡出到0，松手等待期间保持0，回弹开始后淡入到1。
  double _blurFade = 1.0;

  /// 入场模糊淡出进度：0 = 完全显示（新当前行下方叠加它的旧模糊图），1 = 完全隐藏。
  ///
  /// 行切换时对**新当前行**复位为 0，随后以 [_entryBlurRate] 指数逼近 1：
  /// 时长随该行歌词时长动态（快歌更快、慢歌最多 1s），入场有"模糊层淡出 +
  /// 跟随该行从 inactiveScale 放大到 activeScale"的过渡，与离场对称。
  double _entryBlurProgress = 1.0;

  /// 当前入场模糊的淡出速率（/s），切行时按该行歌词时长动态计算。
  double _entryBlurRate = _entryBlurFadeSpeed;

  /// 入场模糊淡出缺省速率（/s，按 1s 反推）。
  ///
  /// 实际值由切行时按该行歌词时长覆盖（见 [_fadeRateForMs]）。
  static const double _entryBlurFadeSpeed = 6.9;

  /// 模糊级别缓存：只在当前行变化时重算
  int _cachedBlurLineIndex = -1;
  Map<int, int> _cachedBlurLevels = const {};

  /// Per-Line 模糊缓存：行索引 → (模糊图, 渲染输入签名)。
  ///
  /// 签名覆盖 blurLevel / fontSize / 视口宽 / enableScale / inactiveScale /
  /// fontFamily / fontWeight，任一变化即判定过期并重渲染（修掉字号与非当前行
  /// 缩放变化后旧模糊图长期不刷新的问题）。
  final Map<int, (ui.Image image, String signature)> _lineBlurImages = {};

  /// 上次构建模糊层时的几何签名，用于字号/缩放/视口变化时强制重算 levels。
  String _lastBlurGeometrySig = '';
  double _viewportWidth = 0;

  // P2-H 方案 A：ShaderMask 上下渐隐 shader 缓存。
  // shaderCallback 在每次 build 时被调用，渐隐参数仅依赖 bounds 尺寸，
  // 尺寸不变时复用同一 shader，避免每帧/每次重建 LinearGradient + createShader。
  ui.Shader? _fadeShader;
  Rect? _fadeShaderBounds;

  /// 获取（或按需重建）歌词界面上下边界渐隐 shader。
  ///
  /// 渐隐是静态的（上下 24px alpha 渐变），仅随视口尺寸变化。
  /// bounds 不变时直接返回缓存实例，消除每次 build 的对象与 shader 分配。
  ui.Shader _fadeShaderFor(Rect bounds) {
    if (_fadeShader != null && bounds == _fadeShaderBounds) {
      return _fadeShader!;
    }
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
      stops: [
        0.0,
        fadeRatio,
        1.0 - fadeRatio,
        1.0,
      ],
    ).createShader(bounds);
    _fadeShader = shader;
    _fadeShaderBounds = bounds;
    return shader;
  }

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
    // 失效模糊图片缓存：对齐/文本变化后旧模糊图位置与内容均不再匹配
    for (final entry in _lineBlurImages.values) {
      entry.$1.dispose();
    }
    _lineBlurImages.clear();
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

  /// 上一帧的当前行索引，用于检测行切换。
  int _previousLineIndex = -1;

  /// 级联牵引起点（限幅后的视口顶部可见行）。行切换时计算一次并缓存。
  int _cascadeTopLine = 0;

  /// 级联瀑布向上覆盖的可见行上限：起点不低于 currentLineIndex - K，
  /// 避免极端滚动/切歌跳变时起点过低拖出全屏。
  static const int _cascadeTopLimit = 8;

  /// 预计算每行实际高度（含自动换行）。
  ///
  /// **性能优化**：只在 lines/fontSize/viewportWidth 变化时重算，
  /// 不再每帧重算（之前每帧 build 都跑 N 次 TextPainter.layout 是 CPU 杀手）。
  /// [_recomputeLineHeightsIfNeeded] 负责缓存命中判断。
  List<double> _lineHeights = const <double>[];
  List<double> _lineTops = const <double>[];

  /// 哪些行索引后面有间奏（gap >= thresholdMs）。
  ///
  /// 用于检测当前是否进入间奏时段（_activeInterludeAfterIndex）。
  /// 注意：只有激活间奏才占位高度（动态展开/收起），非激活间奏占位 = 0。
  List<int> _interludeAfterIndices = const <int>[];

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
  /// 通过 _repaintNotifier 驱动重绘，避免每帧 setState + build 的 widget tree 开销。
  _LyricsPainter? _painter;

  /// painter 的重绘信号源。fireRepaint() 触发 CustomPaint 重绘。
  final _RepaintNotifier _repaintNotifier = _RepaintNotifier();

  /// 当前激活的间奏在 _interludeAfterIndices 中的索引（-1 表示无激活）。
  ///
  /// 严格 AMLL 逻辑：只有 currentTime 真正进入间奏时段
  /// （gapStart < now < gapEnd）才激活占位。
  /// 一激活就开始 spring 展开 0 → totalHeight，
  /// 间奏结束（now >= gapEnd）就 spring 收起 totalHeight → 0。
  int _activeInterludeIdx = -1;

  /// 最后激活的间奏 anchor 行索引（-1 表示从未激活过）。
  ///
  /// 用于间奏结束后 progress 收起期间继续计算占位偏移，
  /// 避免 `_interludeOffsetBefore` 在间奏一结束就立即返回 0 导致 targetY 突变。
  /// 当 `_interludeExpandProgress` 收起到 0 后重置为 -1。
  int _lastActiveAnchorIdx = -1;

  /// 间奏占位 spring 进度（0 = 完全收起，1 = 完全展开）。
  ///
  /// 用指数衰减逼近目标值，目标由 _activeInterludeIdx 决定：
  /// - 激活：target = 1.0
  /// - 未激活：target = 0.0
  /// 每帧 _onTick 中推进：progress += (target - progress) * (1 - exp(-speed * dt))
  /// speed = 18（300ms 内基本到位）
  double _interludeExpandProgress = 0;

  /// 当前行翻译副行展开进度（0→1 副行"长出"，1→0 收起），指数逼近。
  ///
  /// 仅当前行预留副行高度（未播放歌词不占位）。本进度驱动当前行副行的
  /// 视觉"浮出/收起"（WordRenderer 浮出 + alpha 渐显）。
  double _translationExpandProgress = 0.0;
  /// 副行显隐 alpha 进度（0→1 渐显，1→0 渐隐），指数逼近。
  double _translationFade = 0.0;

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
  // 副行缓存：仅当前行预留副行高度（未播放歌词不占用翻译副行空间）。
  // 当前行切换、showTranslation / displayMode / 布局输入变化时重算。
  int _cachedCurrentLineIndex = -1;
  bool _cachedShowTranslation = false;
  // 副行布局缓存：displayMode 切换也需重算（虽副行高度不变，但需触发重绘）
  LyricDisplayMode _cachedDisplayMode = LyricDisplayMode.translation;

  /// 返回指定行索引上方所有激活间奏占位的累计高度。
  ///
  /// **progress 驱动**：只要 `_interludeExpandProgress > 0` 就返回占位高度，
  /// 不依赖 `_activeInterludeIdx`。这样间奏结束后 progress 缓慢收起到 0 期间，
  /// 占位偏移也跟随平滑收起，posY target 不会突变。
  ///
  /// 使用 `_lastActiveAnchorIdx` 记录最后激活的间奏 anchor，
  /// 避免影响其他未激活间奏的占位。
  ///
  /// 高度 = _interludePlaceholderHeight × _interludeExpandProgress
  double _interludeOffsetBefore(int lineIndex) {
    if (_interludeExpandProgress <= 0) return 0;
    final int anchorIdx = _lastActiveAnchorIdx;
    if (anchorIdx < 0 || anchorIdx >= lineIndex) return 0;
    return _interludePlaceholderHeight * _interludeExpandProgress;
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
    final currentShowTranslation = LyricPreferences.instance.showTranslation;
    final currentDisplayMode = LyricPreferences.instance.displayMode;
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
        _currentLineIndex == _cachedCurrentLineIndex &&
        currentShowTranslation == _cachedShowTranslation &&
        currentDisplayMode == _cachedDisplayMode) {
      return; // 缓存命中
    }
    _cachedFontSize = fontSize;
    _cachedViewportWidth = viewportWidth;
    _cachedLineHeight = currentLineHeight;
    _cachedLinesLength = _cleanedLines.length;
    _cachedLinesRef = _cleanedLines;
    _cachedFontFamily = currentFontFamily;
    _cachedFontWeight = currentFontWeight;
    _cachedCurrentLineIndex = _currentLineIndex;
    _cachedShowTranslation = currentShowTranslation;
    _cachedDisplayMode = currentDisplayMode;

    // v3 优化：列表内容变化时递增 generation counter。
    // lines 用 identical 比较，只有引用变化才递增；
    // lineHeights/lineTops/interludeAfterIndices 每次重算都递增。
    if (!identitySame) {
      _linesGeneration++;
    }
    _lineHeightsGeneration++;
    _lineTopsGeneration++;
    _interludeAfterIndicesGeneration++;

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
    double acc = 0;
    for (int i = 0; i < _cleanedLines.length; i++) {
      final line = _cleanedLines[i];
      // 仅当前行预留翻译副行高度（未播放歌词不占用翻译副行空间）。
      final showTrans = i == _currentLineIndex &&
          LyricPreferences.instance.showTranslation;
      heights.add(LyricLayout.measureLineHeight(
        line,
        fontSize,
        mainLineHeight,
        maxLineWidth,
        showTranslation: showTrans,
      ));
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
    _lineHeights = heights;
    _lineTops = tops;
    _interludeAfterIndices = interludeIndices;
    // 重置激活间奏（lines 变化时）
    _activeInterludeIdx = -1;
    _lastActiveAnchorIdx = -1;
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
    _startTickerIfNeeded(); // v3 优化：幂等启动
    _lastElapsed = Duration.zero;
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
    if (widget.isPlaying) {
      final bool ecoLocked =
          LyricPreferences.instance.ecoMode && !_ecoUnlocked;
      if (ecoLocked) {
        _syncEcoDriver();
      } else {
        _startTickerIfNeeded();
      }
    }
  }

  /// 省电模式驱动源同步：在 Ticker（满帧）与 60fps Timer 之间切换。
  ///
  /// - eco 开启且锁定 → 停 Ticker，用 16.67ms Timer 驱动 _onTick，
  ///   把实际帧生产限制到 60fps（Ticker 每帧 scheduleFrame 会让 120Hz 屏
  ///   始终 120fps，仅节流 _onTick 计算省不掉帧）。
  /// - 解锁 / eco 关闭 → 取消 Timer，恢复 Ticker 满帧。
  void _syncEcoDriver() {
    final bool wantTimer = LyricPreferences.instance.ecoMode && !_ecoUnlocked;
    if (wantTimer) {
      if (_isTickerRunning) {
        _stopTickerIfNeeded();
      }
      _ecoTimer ??= Timer.periodic(
        const Duration(milliseconds: 16),
        _onEcoTimerTick,
      );
    } else {
      _ecoTimer?.cancel();
      _ecoTimer = null;
      if (!_isTickerRunning) {
        // 复用幂等启动：Ticker 重启后首帧回调传 elapsed=0，必须重置 _lastElapsed
        // 使首帧 dt=0，否则会算出负 dt（blurFade 指数爆炸超出 [0,1]）。
        _startTickerIfNeeded();
      }
    }
  }

  /// eco 锁定态下由 60fps Timer 驱动：以 16ms 步进推进帧时钟，调用 [_onTick]。
  void _onEcoTimerTick(Timer timer) {
    if (!mounted || _isTickerRunning) return;
    // 用 _lastElapsed + 16ms 作为本帧时间：_onTick 内 dt 即 16ms，动画按真实时间推进
    _onTick(_lastElapsed + const Duration(milliseconds: 16));
  }

  /// v3 优化：检测所有 perLine 偏移弹簧是否已收敛。
  /// P0 修复：只检查视口范围内的弹簧（与 _onTick 的 tick 范围一致，±15 行）。
  /// 此前遍历所有 _perLineSprings：行切换时为当前行下方所有行创建弹簧，
  /// 但视口外的弹簧从不被 tick → 永远 isSettled=false →
  /// 收敛检测恒 false → 暂停后 Ticker 永不停止 → 每帧重绘 → 功耗降不下来。
  bool _arePerLineSpringsConverged() {
    final int overscan = _overscan;
    final int startI = _cascadeTopLine;
    final int endI = math.min(widget.lines.length, _currentLineIndex + overscan);
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
  bool _arePerLineScalesConverged() {
    for (final s in _perLineScaleSprings.values) {
      if (!s.isSettled) return false;
    }
    return true;
  }

  /// 推进每行独立的 scale 弹簧，并填充 [_reusedPerLineScales]。
  ///
  /// 返回是否有任一行仍在运动（供重绘门控与收敛判定）。
  ///
  /// 相比旧的单实例 LineScaleController 只服务当前行，这里每行都有自己的弹簧：
  /// - 进场行（非当前 0.97 → 当前）：target 变 activeScale，从 0.97 平滑放大到 1.0；
  /// - 离场行（当前 1.0 → 非当前）：target 变 inactiveScale，从 1.0 平滑缩到 0.97，
  ///   补上原来"当前行缩小时硬切"的连贯动画。
  /// 只推进视口附近行（与 renderer/偏移同范围）。
  bool _tickPerLineScales(double dt) {
    final int len = widget.lines.length;
    if (_reusedPerLineScales.length != len) {
      _reusedPerLineScales = List<double>.filled(len, LyricLayout.activeScale);
    }
    final int overscan = _overscan;
    final int startI = math.max(0, _currentLineIndex - overscan);
    final int endI = math.min(len, _currentLineIndex + overscan);
    bool anyChanged = false;
    final double active = LyricLayout.activeScale;
    final double inactive =
        widget.enableScale ? LyricLayout.inactiveScale : active;
    for (int i = startI; i < endI; i++) {
      final double target = i == _currentLineIndex ? active : inactive;
      final Spring spring = _perLineScaleSprings[i] ??= Spring(
            mass: LyricLayout.scaleSpringMass,
            damping: LyricLayout.scaleSpringDamping,
            stiffness: LyricLayout.scaleSpringStiffness,
            // 首次创建直接落在目标，避免从默认 1.0 一路动画到目标造成"飘"
            initialPosition: target,
          );
      // 目标变化时 setTarget：行切换触发放大/缩小的连贯过渡
      if (spring.target != target) {
        spring.setTarget(target);
      }
      if (!spring.isSettled) {
        spring.tick(dt);
        anyChanged = true;
      }
      _reusedPerLineScales[i] = spring.position;
    }
    return anyChanged;
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
    final int endIdx =
        math.min(widget.lines.length, _currentLineIndex + overscan);
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
    // 字体/字重变化时失效所有依赖字体测量的缓存
    final currentFontFamily = LyricLayout.fontFamily;
    final currentFontWeight = LyricLayout.fontWeight.value;
    if (currentFontFamily != _cachedFontFamily ||
        currentFontWeight != _cachedFontWeight) {
      // 失效行高缓存（让 _recomputeLineHeightsIfNeeded 重算）
      _cachedFontFamily = null;
      _cachedFontWeight = -1;
      // 失效模糊图片缓存（dispose 图片资源 + 清空 Map）
      for (final entry in _lineBlurImages.values) {
        entry.$1.dispose();
      }
      _lineBlurImages.clear();
      _cachedBlurLineIndex = -1;
      _cachedBlurLevels = const {};
      // 失效 WordRenderer/LineRenderer 内部绑定（清空后下次 paint 会重新创建 +
      // 重新 _ensureBound 测量 word 宽度，避免用旧字体宽度做换行判断）
      _wordRenderers.clear();
      _lineRenderers.clear();
    }
    // 始终重启 ticker + setState，确保偏好变化（如 useDuetLayout）触发 build
    _startTickerIfNeeded();
    // eco 开关变化时同步驱动源：锁定 → 60fps Timer 限帧；解锁/关闭 → Ticker 满帧
    _syncEcoDriver();
    setState(() {});
  }

  @override
  void didUpdateWidget(covariant AppleLyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // lines 列表缩短时，清理不再存在的行索引对应的 renderer 缓存，避免内存泄漏
    _wordRenderers.removeWhere((key, _) => key >= widget.lines.length);
    _lineRenderers.removeWhere((key, _) => key >= widget.lines.length);
    // v3 优化：恢复播放或切歌时立即重启驱动（停止态恢复）。
    //
    // **省电模式关键**：eco 开启且锁定（_ecoUnlocked=false）时，驱动源是
    // 60fps Timer，这里**绝不能**直接 `_startTickerIfNeeded()`——否则每 ~200ms
    // position 更新（ListenableBuilder 重建本 widget）都会把 Ticker 以 120Hz
    // 重启一帧，即便画面静止也持续产生额外帧，破坏"锁 60fps"（这正是
    // "开了开关仍锁不住 60fps"的一个因素）。统一走 [_syncEcoDriver] 决策：
    // 锁定 → 确保 60fps Timer 在跑；解锁/关闭 eco → 才用 Ticker 满帧。
    final bool ecoLocked =
        LyricPreferences.instance.ecoMode && !_ecoUnlocked;
    if (oldWidget.isPlaying != widget.isPlaying && widget.isPlaying) {
      if (ecoLocked) {
        _syncEcoDriver();
      } else {
        _startTickerIfNeeded();
      }
    }
    // v3 优化：切歌（lines 引用变化）时重启驱动，重新推进新行的 renderer
    if (!identical(oldWidget.lines, widget.lines) ||
        oldWidget.songBpm != widget.songBpm) {
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
      // 切歌后首次定位直接瞬移到新歌当前行（避免从旧歌曲的长距离滚动）
      _scrollController.resetInitialJump();
      if (ecoLocked) {
        _syncEcoDriver();
      } else {
        _startTickerIfNeeded();
      }
    }
    // P0-A: 非逐字歌词在播放中可能已停 Ticker（静止省电）。position 更新
    //（约 200ms，经 ListenableBuilder 重建本 widget）时唤醒一帧：若确实
    // 发生行切换 / 滚动回弹 / 间奏等动画则继续跑，否则下一帧再次收敛停止。
    // **省电模式锁定态**：由 60fps Timer 持续驱动，无需（也不应）重启 Ticker。
    if (oldWidget.currentTimeMs != widget.currentTimeMs && widget.isPlaying) {
      if (ecoLocked) {
        _syncEcoDriver();
      } else {
        _startTickerIfNeeded();
      }
    }
    // 解耦：positionListenable 实例变化时重新挂载订阅
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
    widget.positionListenable?.removeListener(_onExternalPosition);
    _ecoTimer?.cancel();
    _ecoTimer = null;
    _ticker.dispose();
    _scrollController.dispose();
    _repaintNotifier.dispose();
    for (final entry in _lineBlurImages.values) {
      entry.$1.dispose();
    }
    _lineBlurImages.clear();
    LyricPreferences.instance.removeListener(_onPreferencesChanged);
    super.dispose();
  }

  // ============== 工具方法 ==============

  /// 获取或创建指定行的 [WordRenderer]。
  WordRenderer _wordRendererFor(int index) =>
      _wordRenderers.putIfAbsent(index, () => WordRenderer());

  /// 获取或创建指定行的 [LineRenderer]。
  LineRenderer _lineRendererFor(int index) =>
      _lineRenderers.putIfAbsent(index, () => LineRenderer());

  /// 获取或创建指定行的偏移弹簧。
  Spring _perLineSpringFor(int index) => _perLineSprings.putIfAbsent(
      index,
      () => Spring(
            mass: 1.0,
            damping: 15.0,
            stiffness: 100.0,
            initialPosition: 0,
          ));

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

  /// 计算级联牵引起点：限幅后的视口顶部可见行。
  ///
  /// 优先取满足 `lineTop+posY+间奏偏移 >= -overscanPx` 的最小可见行（二分，
  /// 与 _LyricsPainter 定位一致），再与 `currentLineIndex - _cascadeTopLimit`
  /// 取较大值（限幅）。painter 未就绪（视口高度未知）时兜底。
  int _computeCascadeTopLine() {
    final int len = widget.lines.length;
    if (len == 0) return 0;
    final double viewportH = _painter?.viewportHeight ?? 0;
    int lo;
    if (viewportH <= 0 || _lineTops.isEmpty) {
      lo = math.max(0, _currentLineIndex - _cascadeTopLimit);
    } else {
      final double posY = _scrollController.posY;
      int l = 0, h = len;
      while (l < h) {
        final int mid = (l + h) ~/ 2;
        final double fs = LyricLayout.fontSize(context);
        final double top = mid < _lineTops.length
            ? _lineTops[mid]
            : mid * fs * LyricLayout.lineHeight;
        final double lineH = mid < _lineHeights.length
            ? _lineHeights[mid]
            : fs * LyricLayout.lineHeight;
        final double y = top + posY + _interludeOffsetBefore(mid);
        if (y + lineH < -LyricLayout.overscanPx) {
          l = mid + 1;
        } else {
          h = mid;
        }
      }
      lo = l.clamp(0, len - 1);
    }
    final int floor = math.max(0, _currentLineIndex - _cascadeTopLimit);
    return (lo > floor) ? lo : floor;
  }

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
    for (int i = _offsetsWindowStart;
        i < _offsetsWindowEnd && i < _reusedPerLineOffsets.length;
        i++) {
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

    // 检测 Ticker 曾被 mute（TabBarView 切走 / App 退后台 / 长时间卡顿）：
    // 恢复后首帧 dt 会等于切走时长（远大于正常帧间隔）。mute 期间
    // 间奏点动画时钟（帧 dt 累积）冻结而歌曲继续播放，需在本帧把时钟
    // 对齐到真实窗口进度（见 _updateInterlude 的 alignDotsToRealTime）。
    // 该检测为 O(1) 比较，不增加每帧开销。
    final bool tickerGapResume = dt > _tickerGapResumeThreshold;

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
      _ecoUnlocked = _scrollController.isUserScrolling ||
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
    // 暂停时冻结在权威位置。
    if (widget.isPlaying) {
      _smoothPosMs += dt * 1000;
      if (_authorityTimeMs != _lastAuthorityPosMs) {
        final int jump = (_authorityTimeMs - _lastAuthorityPosMs).abs();
        _lastAuthorityPosMs = _authorityTimeMs;
        if (jump > _smoothPosSeekJumpMs) {
          // seek/大跳变：直接吸附，避免平滑拖尾
          _smoothPosMs = _authorityTimeMs.toDouble();
        } else {
          // 正常 position 更新：平滑逼近权威，避免硬跳跨字边界造成闪烁
          final double corr = 1.0 - math.exp(-_smoothPosCorrRate * dt);
          _smoothPosMs += (_authorityTimeMs - _smoothPosMs) * corr;
        }
      } else if ((_smoothPosMs - _lastAuthorityPosMs).abs() > 300) {
        // 兜底：权威位置长时间不更新（缓冲等）时防止平滑值漂移过大
        _smoothPosMs = _lastAuthorityPosMs.toDouble();
      }
    } else {
      _smoothPosMs = _authorityTimeMs.toDouble();
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
    }

    // 2. 推进滚动控制器（需要 lineHeight 与 intervalMs 计算目标 posY）
    if (_currentLineIndex >= 0) {
      final fontSize = LyricLayout.fontSize(context);
      final mainLineHeight = fontSize * LyricLayout.lineHeight;
      // 当前行实际高度（含换行）：用预计算 _lineHeights，无则降级 mainLineHeight
      final currentLineHeight = (_currentLineIndex < _lineHeights.length
              ? _lineHeights[_currentLineIndex]
              : mainLineHeight);
      // 当前行顶部 y（前面所有行高度的累加 + 间奏占位偏移）
      final currentLineRawTop = (_currentLineIndex < _lineTops.length
              ? _lineTops[_currentLineIndex]
              : _currentLineIndex * mainLineHeight);
      final currentLineTop =
          currentLineRawTop + _interludeOffsetBefore(_currentLineIndex);
      // intervalMs = 下一行 startTime - 当前行 endTime，用于动态 stiffness
      int intervalMs = 0;
      if (_currentLineIndex < widget.lines.length - 1) {
        final current = widget.lines[_currentLineIndex];
        final next = widget.lines[_currentLineIndex + 1];
        intervalMs = next.startTime - current.endTime;
      }
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
      );
    }
    _scrollController.tick(dt);

    // 3. 推进每行独立的 scale 弹簧（离场缩 0.97 / 进场放 1.0，均连贯）
    // 返回是否有缩放动画仍在进行，供下方重绘门控与收敛判定使用。
    final bool anyScaleChanged = _tickPerLineScales(dt);

    // 4. 推进每行的 renderer
    // 性能优化：只 tick 视口附近的行（前后各 15 行），避免 200+ 行全量 tick。
    // 当前行用 WordRenderer（逐字 alpha + 上浮），其他行用 LineRenderer。
    final int overscan = _overscan;
    final int startIdx = math.max(0, _currentLineIndex - overscan);
    final int endIdx = math.min(widget.lines.length, _currentLineIndex + overscan);
    // P1-G: 顺带聚合"是否有 renderer 仍在动画"，替代 _hasRendererAlphaChanged
    // 的二次 O(±10 行) 遍历（hasVisualChange 与收敛判断复用）。
    bool anyRendererAnimating = false;
    for (int i = startIdx; i < endIdx; i++) {
      final line = widget.lines[i];
      final isActive = i == _currentLineIndex;
      // 文字层不再使用 scale 弹簧，当前行瞬移到 activeScale
      final scale = isActive
          ? LyricLayout.activeScale
          : (widget.enableScale
              ? LyricLayout.inactiveScale
              : LyricLayout.activeScale);
      final bool useWordRenderer = isActive && line.hasWordTiming;
      // 纯文本歌词无时间轴时强制关闭高斯模糊
      final bool blurActive = hasTimestamps && LyricPreferences.instance.useGaussianBlur;
      if (useWordRenderer) {
        final renderer = _wordRendererFor(i);
        renderer.emphasizeEffect = _emphasizeEffect;
        // 快慢歌辉光阈值（切歌时重算），行绑定时据此判定强调字
        renderer.thresholdMs = _glowThresholdMs;
        // 翻译副行浮出/渐显进度（仅当前行注入；非当前行 WordRenderer 不绘制副行）
        renderer.translationExpand = _translationExpandProgress;
        renderer.translationFade = _translationFade;
        renderer.setLineState(isActive: true, scale: scale, blurFade: _blurFade, blurActive: blurActive, activeColorValue: _activeLineColorValue);
        // 用平滑时间驱动逐字动画（上浮/字内渐变），避免 positionStream 5fps 卡顿
        // isPlaying 用于冻结自驱动波浪：暂停时波浪不推进，防止辉光持续闪烁
        renderer.tick(dt, _smoothPosMs.round(), isPlaying: widget.isPlaying);
        if (!renderer.isConverged) anyRendererAnimating = true;
      } else {
        final renderer = _lineRendererFor(i);
        renderer.setLineState(isActive: isActive, scale: scale, blurFade: _blurFade, blurActive: blurActive, activeColorValue: _activeLineColorValue);
        renderer.tick(dt);
        if (!renderer.isConverged) anyRendererAnimating = true;
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
      final bool timeRewound =
          _authorityTimeMs < _lastInterludeCheckTimeMs;
      _lastInterludeCheckTimeMs = _authorityTimeMs;
      _updateInterlude(
        forceDotsReset: timeRewound,
        // Ticker 曾被 mute（切走 tab / 退后台）恢复：动画时钟滞后于真实进度，
        // 需对齐到当前间奏窗口内的真实偏移（而非重置从 0 重播入场动画）。
        alignDotsToRealTime: tickerGapResume,
      );
    }

    // 6. 推进间奏点动画时钟（基于帧 dt，60fps 流畅，不受 positionStream 5fps 限制）
    // 暂停时不推进动画时钟，让间奏点随播放器一起暂停
    // P0: 降到 30fps 推进（累积帧时间，33ms 才 tick 一次），视觉无感但减半推进开销
    if (widget.isPlaying) {
      _interludeAccumulator += dt;
      if (_interludeAccumulator >= 1.0 / 30.0) {
        _interludeDots.tick(_interludeAccumulator);
        _interludeAccumulator = 0;
      }
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
      _interludeExpandProgress += (interludeTarget - _interludeExpandProgress) *
          (1 - math.exp(-interludeSpeed * dt));
    } else {
      _interludeExpandProgress = interludeTarget;
    }
    // 收起到接近 0 时直接归零，避免无限逼近占着微小高度
    if (_activeInterludeIdx < 0 && _interludeExpandProgress < 0.001) {
      _interludeExpandProgress = 0;
    }

    // 7.5 翻译副行进度：当前行且开启翻译 → 展开/渐显，否则收起/渐隐。
    // 展开 18.0（~250ms 快速长出），收起 9.0（平滑收回），与间奏占位同源手法；
    // 暂停直接吸附目标（与间奏占位一致，避免冻结重绘）。
    final bool transVisible =
        _currentLineIndex >= 0 && LyricPreferences.instance.showTranslation;
    final double transExpandTarget = transVisible ? 1.0 : 0.0;
    final double transFadeTarget = transVisible ? 1.0 : 0.0;
    if (widget.isPlaying) {
      _translationExpandProgress +=
          (transExpandTarget - _translationExpandProgress) *
              (1 - math.exp(-(transVisible ? 18.0 : 9.0) * dt));
      _translationFade += (transFadeTarget - _translationFade) *
          (1 - math.exp(-(transVisible ? 15.0 : 10.0) * dt));
    } else {
      _translationExpandProgress = transExpandTarget;
      _translationFade = transFadeTarget;
    }
    if (_translationExpandProgress < 0.001) _translationExpandProgress = 0;
    if (_translationFade < 0.001) _translationFade = 0;

    // 8. 级联弹簧延迟：检测当前行切换，从限幅后的视口顶部行自上而下错峰牵引
    if (_currentLineIndex >= 0 && _currentLineIndex != _previousLineIndex) {
      final now = _lastElapsed.inMicroseconds / 1000.0;
      // 行切换时不再手动 reset scale：新当前行切换前作为非当前行已 settle 在
      // inactiveScale，_tickPerLineScales 下一帧检测到 target 变 activeScale，
      // 会自然从 0.97 弹到 1.0；离场行 target 变 inactiveScale，从 1.0 平滑缩回。
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
            rate: exitRate);
      }
      // 新当前行入场：若该行的旧模糊图仍在缓存且几何匹配，重置入场模糊淡出
      // 进度为 0（叠加显示），随后指数淡出到隐藏——入场也有"模糊层淡出 + 跟随
      // 放大"的过渡，与离场对称。无可用模糊图（纯文本/LRC 或关闭高斯）则保持隐藏。
      // 淡出速率按该行歌词时长动态（快歌更快、慢歌最多 1s）。
      _entryBlurRate = _fadeRateForMs(widget.lines[_currentLineIndex].duration);
      final cacheForCurrent = _lineBlurImages[_currentLineIndex];
      if (cacheForCurrent != null &&
          cacheForCurrent.$2.startsWith('${_blurGeometrySig()}|')) {
        _entryBlurProgress = 0;
      } else {
        _entryBlurProgress = 1.0;
      }
      _cascadeTopLine = _computeCascadeTopLine(); // 缓存起点（含限幅）
      // 上一轮仍在等待期的行：先用旧基准把抵消量结算进弹簧基数，再重置基准。
      // 快歌切换间隔小于等待期（≤280ms）时，若直接重置 _cascadePosY，
      // 这些行的有效偏移会瞬间回跳一个 holdOffset —— 又一次瞬移。
      final double pendingHold = _cascadePosY - _scrollController.posY;
      if (pendingHold.abs() > 0.01 && _delayStartTimes.isNotEmpty) {
        for (final k in _delayStartTimes.keys.toList()) {
          if (_delayStartTimes[k]! >= 0) {
            final s = _perLineSpringFor(k);
            s.setPosition(s.position + pendingHold, 0);
            s.setTarget(0);
            _delayStartTimes[k] = -1;
          }
        }
      }
      // 记录抵消基准：等待期内该行偏移 = 本值 − 当前 posY，即停在切换瞬间的位置。
      // 本帧两者相等 → 抵消量为 0 → 有效偏移等于上一帧残留，不存在瞬时位移。
      _cascadePosY = _scrollController.posY;
      final int startI = _cascadeTopLine;
      final int endI = math.min(widget.lines.length, _currentLineIndex + _overscan);
      // 只登记延迟起点，**绝不 setPosition 播种偏移**：
      // 旧实现 `spring.setPosition(offset, 0)` 是瞬时赋值，切换帧整块歌词
      // 会先向下抖最多一个行距的固定比例、再逐行弹回，形成"两段动画 + 瞬移"。
      // 上一轮残留的弹簧值原样保留，释放时叠加进新起点，保证连续。
      for (int i = startI; i < endI; i++) {
        _delayStartTimes[i] = now;
      }
      // 清除起点以下(视口外/限幅外)与过旧的延迟记录
      _delayStartTimes.removeWhere((k, _) => k < startI);
    }
    _previousLineIndex = _currentLineIndex;

    // 推进每行偏移弹簧（自上而下瀑布：从 _cascadeTopLine 开始）
    // 性能优化：只覆盖 [_cascadeTopLine, currentLineIndex + overscan] 视口内行，
    // 视口外的行弹簧偏移对渲染不可见，无需每帧推进。
    final int springStartI = _cascadeTopLine;
    final int springEndI = math.min(widget.lines.length, _currentLineIndex + overscan);
    // P1-G: 顺带聚合"弹簧偏移是否有显著变化（>0.5px）"，替代
    // _hasPerLineOffsetChanged 的二次 O(N) 遍历。仅检查视口内行——
    // 视口外行偏移对渲染不可见，无需触发重绘。
    bool anySpringOffsetChanged = false;
    // AMLL 风格级联延迟：delayMs 为逐行累积延迟，baseStepMs 为当前错峰步长。
    // 步长 / 上限 / 衰减均可由用户在设置页"歌词动画"调节（无极）。
    // 循环外读一次偏好，避免每帧重复访问。
    final double cascadeMaxDelay = LyricPreferences.instance.cascadeMaxDelayMs;
    final double cascadeBaseStep = LyricPreferences.instance.cascadeBaseStepMs;
    final double cascadeDecay = LyricPreferences.instance.cascadeStepDecay;
    double delayMs = 0;
    double baseStepMs = cascadeBaseStep;
    final double posYNow = _scrollController.posY;
    final double nowMs = _lastElapsed.inMicroseconds / 1000.0;
    // 抵消量：切换帧为 0，随全局 posY 上移而增大（= 该行"本该已经走掉"的距离）
    final double holdOffset = _cascadePosY - posYNow;
    for (int i = springStartI; i < springEndI; i++) {
      final double lineDelay = math.min(delayMs, cascadeMaxDelay);
      final double? start = _delayStartTimes[i];
      final bool held = start != null && start >= 0;
      if (held && (nowMs - start) >= lineDelay) {
        // 延迟到期 → 释放：弹簧起点 = 残留值 + 当前抵消量，目标 0。
        // 从抵消量接着弹回，而不是从 0 重新跳过去，保证整条曲线连续。
        final s = _perLineSpringFor(i);
        s.setPosition(s.position + holdOffset, 0);
        s.setTarget(0);
        _delayStartTimes[i] = -1;
      } else if (!held) {
        // 已释放（或从未参与级联）：正常推进弹簧直到收敛。
        // 等待期内刻意不 tick —— 弹簧冻结在残留基数上，作为释放时的起点。
        _perLineSprings[i]?.tick(dt);
      }
      if (i < _reusedPerLineOffsets.length &&
          (_effectiveLineOffset(i) - _reusedPerLineOffsets[i]).abs() > 0.5) {
        anySpringOffsetChanged = true;
      }
      // 为下一行累加本轮步长；且越过当前行后，步长对本轮下一次使用递减。
      // AMLL 语义：先累加本行（当前行用未衰减步长），再衰减供下一行使用
      // （baseDelay *= 1/1.05），实现"越过当前行后先密后疏、总延迟收敛"。
      delayMs += baseStepMs;
      if (i >= _currentLineIndex) {
        baseStepMs *= cascadeDecay;
      }
    }

    // 级联不连续保护：抵消量没有上界，异常场景下会把整块歌词"粘"住。
    final double linePitch =
        LyricLayout.fontSize(context) * LyricLayout.lineHeight;
    final double? prevPosY = _lastFramePosY;
    // 单帧 posY 跳变超过一行高 → 判定为 seek：重置抵消基准，并把所有仍在
    // 等待期的行直接释放（否则它们会带着 seek 前的基准继续抵消一段距离）。
    if (prevPosY != null && (posYNow - prevPosY).abs() > linePitch) {
      _cascadePosY = posYNow;
      _delayStartTimes.updateAll((k, v) => v >= 0 ? -1 : v);
    }
    // 用户拖动 / 等待回弹期间不做抵消：手动滚动没有"切换前位置"可言，
    // 抵消会让手指下的歌词出现橡皮筋拖尾。
    if (_scrollController.isUserScrolling ||
        _scrollController.isWaitingForAutoReturn) {
      _cascadePosY = posYNow;
    }
    _lastFramePosY = posYNow;

    // 10. 模糊渐隐动画：滚动/等待时淡出到0，回弹开始后淡入到1
    final bool shouldBlurFadeOut = _scrollController.isUserScrolling ||
        _scrollController.isWaitingForAutoReturn;
    final double blurFadeTarget = shouldBlurFadeOut ? 0.0 : 1.0;
    // 修复：淡入速度 4.0 → 12.0，约 150ms 完成（原 700-1000ms）。
    // 配合修改 1，模糊图在新当前行周围快速淡入出现。
    final double blurFadeSpeed = shouldBlurFadeOut ? 15.0 : 12.0;
    _blurFade += (blurFadeTarget - _blurFade) *
        (1 - math.exp(-blurFadeSpeed * dt));
    if ((_blurFade - blurFadeTarget).abs() < 0.01) {
      _blurFade = blurFadeTarget;
    }

    // 10.5 入场模糊淡出：新当前行的旧模糊图从叠加态指数淡出到隐藏（时长随该行
    // 歌词时长动态，见 _entryBlurRate），与退场对称。
    if (_entryBlurProgress < 1.0) {
      _entryBlurProgress += (1.0 - _entryBlurProgress) *
          (1 - math.exp(-_entryBlurRate * dt));
      if (1.0 - _entryBlurProgress < 0.001) _entryBlurProgress = 1.0;
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
            _entryBlurProgress >= 0.999 &&
            (_interludeExpandProgress - interludeTarget).abs() < 0.001 &&
            (_translationExpandProgress - transExpandTarget).abs() < 0.001 &&
            (_translationFade - transFadeTarget).abs() < 0.001;
    // P1-G: perLine 弹簧 / renderer 的收敛检测（各 O(±10 行) 遍历）只在
    // 需要"停 Ticker 决策"时执行：逐字歌词播放中永远不会停（P0-A 排除），
    // 跳过这两个循环；非逐字播放中仅每 200ms 唤醒帧执行一次。
    final bool needsStopDecision = !widget.isPlaying || !_cachedHasAnyWordTiming;
    final bool canStopWhilePlaying =
        !_cachedHasAnyWordTiming && _activeInterludeIdx < 0;
    final bool deepConverged = !needsStopDecision ||
        (_arePerLineSpringsConverged() && _areRenderersConverged());
    if (animConverged && deepConverged &&
        (!widget.isPlaying || canStopWhilePlaying)) {
      _stopTickerIfNeeded();
      // 同时停掉 eco 限帧 Timer：静态画面无需继续驱动 _onTick
      //（否则 Timer 每 16ms 触发一次 setState，仍会产生 60fps 空帧）。
      _ecoTimer?.cancel();
      _ecoTimer = null;
      // 最后一帧 setState 确保稳态画面渲染
      setState(() {});
      return;
    }

    // 12. v3 优化：检测本帧是否有视觉变化，无变化则跳过 setState。
    // 检测阈值（0.5px / 0.001）远低于人眼感知，肉眼不可见的变化才跳过。
    final double currentPosY = _scrollController.posY;
    final bool hasVisualChange =
        _currentLineIndex != _lastRepaintCurrentLineIndex ||
            (currentPosY - _lastRepaintPosY).abs() > 0.5 ||
            anyScaleChanged ||
            (_blurFade - _lastRepaintBlurFade).abs() > 0.001 ||
            (_entryBlurProgress - _lastRepaintEntryBlur).abs() > 0.001 ||
            (_interludeExpandProgress - _lastRepaintInterludeProgress).abs() >
                0.001 ||
            (_translationExpandProgress - _lastRepaintTransExpand).abs() >
                0.001 ||
            (_translationFade - _lastRepaintTransFade).abs() > 0.001 ||
            // P1-G: 复用 renderer tick / spring 推进循环的聚合结果，避免二次遍历
            anySpringOffsetChanged ||
            anyRendererAnimating ||
            // P0: 暂停时间奏点动画已冻结（tick 跳过、画面静止），
            // shouldRender 仅表示"处于间奏时段"，不应再驱动每帧重绘
            (widget.isPlaying && _interludeDots.shouldRender);

    if (hasVisualChange) {
      _lastRepaintCurrentLineIndex = _currentLineIndex;
      _lastRepaintPosY = currentPosY;
      _lastRepaintBlurFade = _blurFade;
      _lastRepaintEntryBlur = _entryBlurProgress;
      _lastRepaintInterludeProgress = _interludeExpandProgress;
      _lastRepaintTransExpand = _translationExpandProgress;
      _lastRepaintTransFade = _translationFade;
      // P0-1 方案 A：统一走持久化 painter 快路径（repaintNotifier 驱动文字层重绘），
      // 避免每帧 setState + build 重建整个 widget tree（LayoutBuilder/GestureDetector/
      // ShaderMask/模糊层 Stack）。
      // 高斯模糊层（Positioned/Opacity/RawImage）仅在自身状态变化时才 setState 重建：
      // 当前行 / posY / blurFade / 间奏占位 progress / perLine 弹簧偏移任一变化。
      // 稳态逐字演唱时模糊层完全静止，零重建。
      if (_painter != null) {
        _painter!.updatePerFrame(
          currentLineIndex: _currentLineIndex,
          posY: currentPosY,
          currentTimeMs: _authorityTimeMs,
          blurFade: _blurFade,
          interludeExpandProgress: _interludeExpandProgress,
          activeInterludeIdx: _activeInterludeIdx,
          lastActiveAnchorIdx: _lastActiveAnchorIdx,
          perLineOffsets: _buildPerLineOffsets(),
          perLineOffsetsGeneration: _perLineOffsetsGeneration,
          perLineScales: _reusedPerLineScales,
        );
        _repaintNotifier.fireRepaint();
        final useGaussian = LyricPreferences.instance.useGaussianBlur;
        if (useGaussian &&
            (_currentLineIndex != _lastBlurRebuildLineIndex ||
                (currentPosY - _lastBlurRebuildPosY).abs() > 0.5 ||
                (_blurFade - _lastBlurRebuildBlurFade).abs() > 0.001 ||
                (_entryBlurProgress - _lastBlurRebuildEntryBlur).abs() > 0.001 ||
                (_interludeExpandProgress - _lastBlurRebuildInterludeProgress)
                        .abs() >
                    0.001 ||
                anySpringOffsetChanged ||
                // scale 弹簧运动期间每帧重建模糊层，让 k（跟随缩放）实时生效
                anyScaleChanged)) {
          _lastBlurRebuildLineIndex = _currentLineIndex;
          _lastBlurRebuildPosY = currentPosY;
          _lastBlurRebuildBlurFade = _blurFade;
          _lastBlurRebuildEntryBlur = _entryBlurProgress;
          _lastBlurRebuildInterludeProgress = _interludeExpandProgress;
          setState(() {});
        }
      } else {
        setState(() {});
      }
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
  /// 占位收起与点消失同步进行（都是 ~300-750ms）。
  /// 只有当 `_interludeExpandProgress` 收起到 0 后才 `clear()` 间奏点状态。
  /// [forceDotsReset] 为 true 时，即使命中的间奏与当前激活相同，也强制重置
  /// 间奏点动画时钟（`_interludeDots.setInterlude(..., forceReset: true)`）。
  /// 用于 seek/跳转回跳：幂等保护会忽略相同间奏，导致动画时钟从旧进度继续，
  /// 一旦超过间奏总时长，间奏点会直接隐藏（识别为"未启用"）。
  ///
  /// [alignDotsToRealTime] 为 true 时，把间奏点动画时钟对齐到
  /// `currentTimeMs - gapStart`（真实窗口内偏移）。用于 Ticker 被 mute
  /// （切走 tab / 退后台）后恢复：帧时钟冻结期间歌曲继续播放，动画时钟
  /// 滞后于真实进度，对齐后间奏点立即处于正确阶段，而非重置重播入场动画。
  void _updateInterlude({
    bool forceDotsReset = false,
    bool alignDotsToRealTime = false,
  }) {
    int foundIdx = -1;
    int? gapStart;
    int? gapEnd;
    for (int i = 0; i < _interludeAfterIndices.length; i++) {
      final int lineIdx = _interludeAfterIndices[i];
      if (lineIdx < 0 || lineIdx >= widget.lines.length - 1) continue;
      final current = widget.lines[lineIdx];
      final next = widget.lines[lineIdx + 1];
      // 激活窗口起点与 gap 判定（_recomputeLineHeightsIfNeeded）保持一致，
      // 均用"人声实际结束时间"（KRC 行 duration 覆盖尾音/空白时窗口起点会偏晚，
      // 导致短暂处于真实空档却未激活间奏点）。
      final start = AppleLyricsView.effectiveLineEndTime(current);
      final end = next.startTime - LyricLayout.interludeEarlyEndMs;
      if (_authorityTimeMs >= start && _authorityTimeMs < end) {
        foundIdx = i;
        gapStart = start;
        gapEnd = end;
        break;
      }
    }

    _activeInterludeIdx = foundIdx;

    if (foundIdx >= 0 && gapStart != null && gapEnd != null) {
      // 先确保间奏状态正确（新间奏会重置时钟，幂等命中的相同间奏保留），
      // 再按需校正动画时钟。
      _interludeDots.setInterlude(gapStart, gapEnd,
          forceReset: forceDotsReset);
      // 时钟漂移校正：帧时钟在 Ticker mute（切走 tab / 退后台）或页面重建
      // （TabBarView 默认销毁 State，新 State 时钟从 0 开始）期间滞后于真实
      // 进度。每次权威位置更新时比较偏差，超阈值（1s）即对齐到真实窗口偏移。
      // 正常播放下偏差不超过 position 更新粒度（约 200ms），不会误触发，
      // 因此不引入额外开销。
      if (alignDotsToRealTime ||
          _interludeDots.shouldRealignTo(_authorityTimeMs, driftMs: 1000)) {
        _interludeDots.alignToRealTime(_authorityTimeMs);
      }
      // 记录最后激活的 anchor 行索引（用于间奏结束后继续计算占位偏移）
      if (foundIdx < _interludeAfterIndices.length) {
        _lastActiveAnchorIdx = _interludeAfterIndices[foundIdx];
      }
    } else {
      // 间奏结束：不立即 clear() 间奏点
      // 让 _animationTimeMs 继续推进到 interludeDuration，
      // 间奏点会自然完成消失动画（最后 750ms easeInBack）
      // 只有当 _interludeExpandProgress 收起到 0 后才 clear()
      if (_interludeExpandProgress <= 0.001) {
        _interludeDots.clear();
        _lastActiveAnchorIdx = -1;
      }
    }
    // 注意：间奏点动画时间由 _onTick 中的 _interludeDots.tick(dt) 推进，
    // 不依赖 currentTimeMs（positionStream 5fps 太卡）
  }

  // ============== 点击跳转与手动滚动 ==============

  void _onTapDown(TapDownDetails details) {
    _startTickerIfNeeded(); // v3 优化：用户交互时重启 Ticker（即便暂停态）
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
      final top = _lineTops[i] + _interludeOffsetBefore(i);
      final height = _lineHeights.length > i ? _lineHeights[i] : 0;
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
      AppHaptics.tick();
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
      final top = _lineTops[i] + _interludeOffsetBefore(i);
      final height = _lineHeights.length > i ? _lineHeights[i] : 0;
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
    _startTickerIfNeeded(); // v3 优化：用户滚动时重启 Ticker
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
        velocity: details.velocity.pixelsPerSecond.dy);
  }

  // ============== 构建 ==============

  @override
  Widget build(BuildContext context) {
    // 根据屏幕最短边判断设备类型：>= 600dp 视为 pad（平板），更新 overscan 缓冲行数
    final shortestSide = MediaQuery.of(context).size.shortestSide;
    _overscan = shortestSide >= 600 ? 15 : 10;
    // 动态字体颜色：仅 AM 播放器（深色背景）且开关开启且提取到封面颜色时，
    // 当前行歌词颜色 = 85% 白 + 15% 提取色；否则回退默认白色（null）。
    // 混色后再兜底提升明度（≥0.78），保证深色背景上的可读性；
    // 仅抬升明度、保留色相与饱和度，视觉上仍是封面色调的浅色。
    if (widget.forceDarkBackground &&
        LyricPreferences.instance.useDynamicLyricColor &&
        widget.accentColor != null) {
      final mixed = Color.lerp(Colors.white, widget.accentColor!, 0.15)!;
      final hsl = HSLColor.fromColor(mixed);
      _activeLineColorValue = hsl
          .withLightness(math.max(hsl.lightness, 0.78))
          .toColor()
          .toARGB32();
    } else {
      _activeLineColorValue = null;
    }
    // 根据主题亮度设置歌词文字颜色：
    // - AM 风格（forceDarkBackground=true）→ 始终白色
    // - 深色主题 → 白色
    // - 浅色主题 → 黑色
    final isLightTheme = Theme.of(context).brightness == Brightness.light;
    LyricLayout.textColorValue =
        (widget.forceDarkBackground || !isLightTheme)
            ? 0xFFFFFFFF
            : 0xFF000000;

    return LayoutBuilder(
      builder: (context, constraints) {
        // 设置视口大小，供 scrollController 计算 targetY
        _scrollController.setViewportSize(
          Size(constraints.maxWidth, constraints.maxHeight),
        );

        final fontSize = LyricLayout.fontSize(context);
        final mainLineHeight = fontSize * LyricLayout.lineHeight;
        // 可用最大文字宽度（视口宽 - 左右 1em 边距），用于自动换行
        final maxLineWidth =
            LyricLayout.maxLineWidth(constraints.maxWidth, fontSize);

        // 男女对唱预处理：剔除「男：/女：/合：」前缀并生成对齐方式
        // 必须在行高测量之前，确保行高基于剔除后的文本计算
        _recomputeDuetIfNeeded();
        // 性能优化：缓存命中检查，只在数据/字号/视口变化时重算 lineHeights/lineTops
        // 之前每帧都跑 N 次 TextPainter.layout 是 CPU 瓶颈（UI 线程 70%+）
        _recomputeLineHeightsIfNeeded(fontSize, constraints.maxWidth);

        // 根据偏好选择高斯模糊或 alpha 渐变淡出
        final useGaussian = LyricPreferences.instance.useGaussianBlur;

        // 创建或复用持久化 painter
        // 性能优化：painter 字段在 _onTick 中通过 updatePerFrame + notifyListeners 更新，
        // 避免每帧 setState + build 重建 widget tree。
        // build() 只在 widget 重建时运行，设置布局相关字段。
        if (_painter == null) {
          _painter = _LyricsPainter(
            repaint: _repaintNotifier,
            lines: _cleanedLines,
            duetAlignments: _duetAlignments,
            currentLineIndex: _currentLineIndex,
            posY: _scrollController.posY,
            fontSize: fontSize,
            mainLineHeight: mainLineHeight,
            lineHeights: _lineHeights,
            lineTops: _lineTops,
            viewportHeight: constraints.maxHeight,
            viewportWidth: constraints.maxWidth,
            maxLineWidth: maxLineWidth,
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
            perLineOffsets: _buildPerLineOffsets(),
            blurFade: _blurFade,
            blurActive: useGaussian,
            blurReadyLineIndices: _lineBlurImages.keys,
            textColorValue: LyricLayout.textColorValue,
            activeLineColorValue: _activeLineColorValue,
            linesGeneration: _linesGeneration,
            lineHeightsGeneration: _lineHeightsGeneration,
            lineTopsGeneration: _lineTopsGeneration,
            interludeAfterIndicesGeneration: _interludeAfterIndicesGeneration,
            perLineOffsetsGeneration: _perLineOffsetsGeneration,
          );
        } else {
          // 复用持久化 painter，更新所有字段（布局 + 动画）
          _painter!.lines = _cleanedLines;
          _painter!.duetAlignments = _duetAlignments;
          _painter!.currentLineIndex = _currentLineIndex;
          _painter!.posY = _scrollController.posY;
          _painter!.fontSize = fontSize;
          _painter!.mainLineHeight = mainLineHeight;
          _painter!.lineHeights = _lineHeights;
          _painter!.lineTops = _lineTops;
          _painter!.viewportHeight = constraints.maxHeight;
          _painter!.viewportWidth = constraints.maxWidth;
          _painter!.maxLineWidth = maxLineWidth;
          _painter!.currentTimeMs = _authorityTimeMs;
          _painter!.enableScale = widget.enableScale;
          _painter!.wordRenderers = _wordRenderers;
          _painter!.lineRenderers = _lineRenderers;
          _painter!.perLineScales = _reusedPerLineScales;
          _painter!.emphasizeEffect = _emphasizeEffect;
          _painter!.interludeDots = _interludeDots;
          _painter!.interludeAfterIndices = _interludeAfterIndices;
          _painter!.interludePlaceholderHeight = _interludePlaceholderHeight;
          _painter!.activeInterludeIdx = _activeInterludeIdx;
          _painter!.lastActiveAnchorIdx = _lastActiveAnchorIdx;
          _painter!.interludeExpandProgress = _interludeExpandProgress;
          _painter!.perLineOffsets = _buildPerLineOffsets();
          _painter!.blurFade = _blurFade;
          _painter!.blurActive = useGaussian;
          // P2-I：同步已就绪模糊图行索引（live view，map 修改后自动反映最新状态）
          _painter!.blurReadyLineIndices = _lineBlurImages.keys;
          _painter!.textColorValue = LyricLayout.textColorValue;
          _painter!.activeLineColorValue = _activeLineColorValue;
          _painter!.linesGeneration = _linesGeneration;
          _painter!.lineHeightsGeneration = _lineHeightsGeneration;
          _painter!.lineTopsGeneration = _lineTopsGeneration;
          _painter!.interludeAfterIndicesGeneration = _interludeAfterIndicesGeneration;
          _painter!.perLineOffsetsGeneration = _perLineOffsetsGeneration;
        }

        final lyricsContent = ClipRect(
          child: CustomPaint(
            painter: _painter,
            size: Size.infinite,
          ),
        );

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: widget.doubleTapToJump ? null : _onTapDown,
          onTapUp: widget.doubleTapToJump ? null : _onTapUp,
          onDoubleTapDown: widget.doubleTapToJump ? _onTapDown : null,
          onDoubleTap: widget.doubleTapToJump ? _triggerDoubleTapSeek : null,
          onVerticalDragUpdate: _onVerticalDragUpdate,
          onVerticalDragEnd: _onVerticalDragEnd,
          child: ShaderMask(
            // 歌词界面上下边界 alpha 渐变（参数与评论区一致：24px 渐变高度），
            // 顶部 24px alpha 0→1，底部 24px alpha 1→0，
            // 让歌词从边界柔和淡入/淡出。
            // P2-H 方案 A：shader 按 bounds 尺寸缓存复用，避免每次 build 重建。
            shaderCallback: (Rect bounds) => _fadeShaderFor(bounds),
            blendMode: BlendMode.dstIn,
            child: useGaussian
                ? ClipRect(
                    child: Builder(
                      builder: (context) {
                        // 视口宽必须先赋值：_buildBlurLayers 内的几何签名依赖它，
                        // 宽度变化由签名比对自动触发模糊图重渲染（无需手动清空缓存，
                        // 手动清空会连带丢弃仍然有效的行）。
                        _viewportWidth = constraints.maxWidth;
                        return Stack(
                          children: [
                            lyricsContent,
                            ..._buildBlurLayers(
                              constraints.maxHeight,
                              mainLineHeight,
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
    if (_currentLineIndex < 0 || lineIndex == _currentLineIndex) return 0;
    // 上下对称：相同距离的行使用相同模糊度，便于缓存复用
    final int distance = (lineIndex - _currentLineIndex).abs();
    return (1 + distance).clamp(0, 5);
  }

  /// 构建基于距离驱动的高斯模糊层（Per-Line 缓存版）。
  ///
  /// 每行歌词独立缓存模糊图片，位置变化时只重定位，不重新计算模糊。
  /// 模糊图片替代歌词显示（而非叠加）。
  List<Widget> _buildBlurLayers(double viewportHeight, double mainLineHeight) {
    if (_currentLineIndex < 0) return const [];

    // 修复：用 scroll controller 状态判断是否在滚动，而非 _blurFade。
    // 回弹开始（isWaitingForAutoReturn 由 true→false）的瞬间 isScrolling 立即变 false，
    // 缓存立即更新到新当前行周围的 levels。
    // 此前用 _blurFade < 0.99 会因淡入慢导致缓存冻结 ~1s。
    final bool isScrolling = _scrollController.isUserScrolling ||
        _scrollController.isWaitingForAutoReturn;

    // 当前行变化、或影响模糊图渲染的几何输入（字号 / 非当前行缩放 / 视口宽 /
    // 字体）变化时，重新计算 blur levels 并更新缓存（滑动时跳过，滚动结束后补齐）
    final String geomSig = _blurGeometrySig();
    if ((_currentLineIndex != _cachedBlurLineIndex ||
            geomSig != _lastBlurGeometrySig) &&
        !isScrolling) {
      _cachedBlurLineIndex = _currentLineIndex;
      _lastBlurGeometrySig = geomSig;

      final double visibleRange = viewportHeight / mainLineHeight;
      final int halfRange = (visibleRange / 2).ceil() + 1;
      final int aboveRange = (halfRange * 0.7).ceil();
      final int startIdx = math.max(0, _currentLineIndex - aboveRange);
      final int endIdx = math.min(widget.lines.length, _currentLineIndex + halfRange + 1);

      final Map<int, int> levels = {};
      for (int i = startIdx; i < endIdx; i++) {
        final int blurLevel = _computeLineBlurRaw(i);
        if (blurLevel > 0) levels[i] = blurLevel;
      }
      _cachedBlurLevels = levels;

      // 异步渲染变化行的模糊图片
      _updateLineBlurCache(levels);
    }

    // 从缓存绘制模糊层
    final List<Widget> layers = [];
    // P0-2：perLine 弹簧偏移列表只需构建一次供所有模糊层复用，
    // 避免每层都全量遍历 O(N) 行（k 层 × N 行 = 每帧 O(k×N) 迭代）。
    final List<double> offsets = _buildPerLineOffsets();

    for (final entry in _cachedBlurLevels.entries) {
      final int i = entry.key;
      // sigma / padding / 高度统一由 _blurGeometry 提供，与 _renderLineBlur
      // 渲染侧同一口径，避免两侧各算一遍导致图片被拉伸或文字错位。
      final geom = _blurGeometry(i, entry.value);
      if (geom.sigma < 0.1) continue;

      final cached = _lineBlurImages[i];
      if (cached == null) continue;
      final image = cached.$1;

      final double lineTop = (i < _lineTops.length
              ? _lineTops[i]
              : i * mainLineHeight) +
          _interludeOffsetBefore(i);
      // 应用弹簧偏移
      final double springOffset = (i < offsets.length) ? offsets[i] : 0.0;
      final double y = lineTop + _scrollController.posY + springOffset;

      if (y + geom.blockHeight < 0 || y > viewportHeight) continue;

      // 模糊图已烘焙"非当前行缩放"（blurRenderScale），这里是 inactiveScale 基准。
      // 让模糊图跟随该行当前的形变 scale 动态缩放：离场行动画期间清晰层从
      // activeScale 平滑缩小到 inactiveScale，模糊图用 Transform 逐帧乘以
      // k = current/bake，从大到小同步跟随 → 动画期间两层尺寸始终一致，不穿帮。
      final double currentScale = i < _reusedPerLineScales.length
          ? _reusedPerLineScales[i]
          : LyricLayout.inactiveScale;
      final double bakeScale =
          LyricLayout.blurRenderScale(enableScale: widget.enableScale);
      final double imageHeight = geom.imageHeight;
      final double k = bakeScale > 0 && imageHeight > 0
          ? currentScale / bakeScale
          : 1.0;
      // pivot 复刻清晰层 canvas.scale（_LyricsPainter.paint）：左/右缘/视口中点
      final double viewportW = _viewportWidth;
      final double startX = LyricLayout.fontSize(context) * 1.0;
      final DuetAlignment al = _duetAlignmentAt(i);
      final double pivotX = al == DuetAlignment.right
          ? viewportW - startX
          : al == DuetAlignment.center
              ? viewportW / 2
              : startX;
      // Positioned top = y - padding，故清晰层 pivotY= y+blockHeight/2 的 widget
      // 坐标 = (y + blockHeight/2) - (y - padding) = padding + blockHeight/2
      final double widgetPivotY = geom.padding + geom.blockHeight / 2;
      // Transform.scale 的 alignment 是 Alignment（-1..1，0=中心）
      final double alignX = viewportW > 0 ? (pivotX / viewportW) * 2 - 1 : 0;
      final double alignY = imageHeight > 0
          ? (widgetPivotY / imageHeight) * 2 - 1
          : 0;

      layers.add(Positioned(
        top: y - geom.padding,
        left: 0,
        width: viewportW,
        height: imageHeight,
        child: Opacity(
          opacity: _blurFade,
          child: Transform.scale(
            scale: k,
            alignment: Alignment(alignX, alignY),
            child: RawImage(
              image: image,
              fit: BoxFit.fill,
            ),
          ),
        ),
      ));
    }

    // 入场模糊层：新当前行轨道成像后，其旧模糊图短暂保留并淡出（约 1s），
    // 同时跟随该行从 inactiveScale 放大到 activeScale（与离场对称）。
    if (_entryBlurProgress < 0.999) {
      final int ci = _currentLineIndex;
      if (ci >= 0 && ci < widget.lines.length &&
          !_cachedBlurLevels.containsKey(ci)) {
        final cached = _lineBlurImages[ci];
        if (cached != null && cached.$2.startsWith('${_blurGeometrySig()}|')) {
          final image = cached.$1;
          final egeom = _blurGeometry(ci, 1);
          final double lineTop =
              (ci < _lineTops.length ? _lineTops[ci] : ci * mainLineHeight) +
                  _interludeOffsetBefore(ci);
          final double springOffset =
              (ci < offsets.length) ? offsets[ci] : 0.0;
          final double y = lineTop + _scrollController.posY + springOffset;
          if (y + egeom.blockHeight >= 0 && y <= viewportHeight) {
            final double currentScale = ci < _reusedPerLineScales.length
                ? _reusedPerLineScales[ci]
                : LyricLayout.activeScale;
            final double bakeScale =
                LyricLayout.blurRenderScale(enableScale: widget.enableScale);
            final double imageHeight = egeom.imageHeight;
            final double kentry = bakeScale > 0 && imageHeight > 0
                ? currentScale / bakeScale
                : 1.0;
            final double viewportW = _viewportWidth;
            final double startX = LyricLayout.fontSize(context) * 1.0;
            final DuetAlignment eal = _duetAlignmentAt(ci);
            final double pivotX = eal == DuetAlignment.right
                ? viewportW - startX
                : eal == DuetAlignment.center
                    ? viewportW / 2
                    : startX;
            final double widgetPivotY =
                egeom.padding + egeom.blockHeight / 2;
            final double alignX =
                viewportW > 0 ? (pivotX / viewportW) * 2 - 1 : 0;
            final double alignY = imageHeight > 0
                ? (widgetPivotY / imageHeight) * 2 - 1
                : 0;
            final double opacity = (1.0 - _entryBlurProgress) * _blurFade;
            layers.add(Positioned(
              top: y - egeom.padding,
              left: 0,
              width: viewportW,
              height: imageHeight,
              child: Opacity(
                opacity: opacity,
                child: Transform.scale(
                  scale: kentry,
                  alignment: Alignment(alignX, alignY),
                  child: RawImage(image: image, fit: BoxFit.fill),
                ),
              ),
            ));
          }
        }
      }
    }

    return layers;
  }

  /// 异步更新模糊缓存：为变化的行渲染模糊图片。
  void _updateLineBlurCache(Map<int, int> levels) {
    for (final entry in levels.entries) {
      final int lineIndex = entry.key;
      final int blurLevel = entry.value;
      // 检查缓存是否存在且渲染输入签名完全匹配（字号/缩放/视口/字体任一变化即过期）
      final String signature = _blurCacheSignature(blurLevel);
      final cached = _lineBlurImages[lineIndex];
      if (cached != null && cached.$2 == signature) {
        continue;
      }

      _renderLineBlur(lineIndex, blurLevel, _duetAlignmentAt(lineIndex)).then((image) {
        if (image != null) {
          _lineBlurImages[lineIndex]?.$1.dispose();
          _lineBlurImages[lineIndex] = (image, signature);
          // P0-1 方案 A：异步模糊图渲染完成后必须重建一次模糊层。
          // 稳态（无其他 setState 源）下若不 setState，新图片永远不会显示。
          if (mounted) setState(() {});
        }
      });
    }

    // 清理不再需要的缓存。
    // 例外：当前行的模糊图**保留不删**。它退回非当前行时（下一句开始）需要
    // 立刻有图可显示，否则要等异步 toImage 完成，期间该行既无清晰文字
    // （alpha 目标为 0）也无模糊图 → 出现 1~3 帧空窗。
    // 仅当几何口径（字号/视口/缩放/字体）仍一致时才保留，否则旧图会被
    // BoxFit.fill 拉伸变形；blurLevel 不同可以保留（半径差 1px 远好于空窗，
    // 且下方 levels 循环会异步换成正确半径的图）。
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
    }
  }

  /// 获取指定行的对唱对齐方式（越界或未处理时返回默认左对齐）。
  DuetAlignment _duetAlignmentAt(int lineIndex) {
    if (lineIndex < 0 || lineIndex >= _duetAlignments.length) {
      return DuetAlignment.defaultAlign;
    }
    return _duetAlignments[lineIndex];
  }

  /// 模糊层几何（渲染与定位共用，保证 sigma / padding / 高度口径完全一致）。
  ///
  /// blockHeight 直接取 [_lineHeights]——即清晰层 scale pivot 用的同一个值，
  /// 不再各自按行数重算，消除 KRC 行（word 累加压缩高度）与非 KRC 行
  /// （TextPainter 完整行高）两套高度模型导致的 pivot Y 偏差。
  ({double sigma, double padding, double blockHeight, double fontSize,
    double imageHeight}) _blurGeometry(int lineIndex, int blurLevel) {
    final double sigma = blurLevel.toDouble().clamp(0.5, 5.0);
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

  /// 模糊层几何签名（不含 blurLevel）：影响渲染结果的所有输入。
  ///
  /// 必须含 `LyricLayout.lineHeight`：模糊图内文字按 `height: lineHeight` 排版，
  /// 行间距变化若不进签名，旧模糊图会停留在旧行高上（表现为调行间距不刷新）。
  String _blurGeometrySig() {
    final double fontSize = LyricLayout.fontSize(context);
    return '${fontSize.toStringAsFixed(2)}|${_viewportWidth.toStringAsFixed(2)}'
        '|${widget.enableScale}|${LyricLayout.inactiveScale.toStringAsFixed(4)}'
        '|${LyricLayout.lineHeight.toStringAsFixed(4)}'
        '|${LyricLayout.fontFamily}|${LyricLayout.fontWeight.value}';
  }

  /// 模糊图缓存签名 = 几何签名 + blurLevel。
  String _blurCacheSignature(int blurLevel) =>
      '${_blurGeometrySig()}|$blurLevel';

  /// 异步渲染单行模糊图片。
  ///
  /// 渲染歌词文字到 Picture，应用 ImageFilter.blur，转为 ui.Image 缓存。
  ///
  /// **缩放烘焙**：清晰层非当前行绘制时被 `canvas.scale(inactiveScale)` 绕 pivot
  /// 收缩，模糊图必须在离屏渲染时施加同一 pivot+scale 变换，两层字形才会严格
  /// 重合（此前模糊层完全不缩放，恒定比清晰字大 3%，长行行尾偏差可达 ~9px）。
  Future<ui.Image?> _renderLineBlur(int lineIndex, int blurLevel, DuetAlignment alignment) async {
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
      final textPainter = TextPainter(
        textDirection: TextDirection.ltr,
      );
      textPainter.text = TextSpan(
        text: _cleanedLines[lineIndex].text,
        style: TextStyle(
          color: Color.fromRGBO(LyricLayout.textRed, LyricLayout.textGreen, LyricLayout.textBlue, 0.5),
          fontSize: fontSize,
          height: LyricLayout.lineHeight,
          // 显式注入歌词 fontFamily，与清晰层保持一致，
          // 否则模糊层尺寸与清晰层不匹配
          fontFamily: LyricLayout.fontFamily,
          fontWeight: LyricLayout.fontWeight,
        ),
      );
      textPainter.layout(maxWidth: maxTextWidth);

      final LyricLine blurLine = _cleanedLines[lineIndex];

      // 对画布应用模糊
      final blurPaint = Paint()
        ..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
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
      final double blurScale =
          LyricLayout.blurRenderScale(enableScale: widget.enableScale);
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

      // 判断是否为多行文本（自动换行）
      final bool isMultiLine =
          geom.blockHeight > fontSize * LyricLayout.lineHeight * 1.5;
      if (!isMultiLine) {
        // 单行：用 _alignX 计算起始 x
        final double x = _blurAlignX(
            alignment, leftPadding, textPainter.width, _viewportWidth);
        textPainter.paint(canvas, Offset(x, padding));
      } else {
        // 多行：按视觉行拆分，每行独立 _alignX 对齐绘制
        _paintBlurMultiLineAligned(canvas, textPainter, blurLine, alignment,
            leftPadding, padding, fontSize, _viewportWidth);
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
      return image;
    } catch (_) {
      return null;
    }
  }

  /// 模糊层对齐 x 计算（与 LineRenderer._alignX / WordRenderer._alignX 一致）。
  double _blurAlignX(DuetAlignment alignment, double leftPadding,
      double textWidth, double viewportWidth) {
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
      Canvas canvas, TextPainter painter, LyricLine line, DuetAlignment alignment,
      double leftPadding, double padding, double fontSize, double viewportWidth) {
    final String text = painter.text?.toPlainText() ?? '';
    if (text.isEmpty) return;
    // 拆分视觉行文本：
    // - KRC 行（有 word）：按 word 累加换行（与清晰层 LineRenderer / 测量一致），
    //   避免模糊图行数与清晰层不同导致错位重叠。
    // - 无 word 行：TextPainter getLineBoundary 自动换行。
    final List<String> rowTexts;
    if (line.hasWordTiming) {
      final double maxWidth = viewportWidth - 2 * fontSize;
      final List<double> widths = <double>[];
      for (final w in line.words) {
        final TextPainter p = TextPainter(
          text: TextSpan(text: w.text, style: painter.text!.style!),
          textDirection: TextDirection.ltr,
        )..layout();
        widths.add(p.width);
        p.dispose();
      }
      final List<int> rowWordStarts = <int>[0];
      double dx = 0;
      for (int wi = 0; wi < line.words.length; wi++) {
        if (dx + widths[wi] > maxWidth && dx > 0) {
          rowWordStarts.add(wi);
          dx = 0;
        }
        dx += widths[wi];
      }
      rowTexts = <String>[];
      for (int r = 0; r < rowWordStarts.length; r++) {
        final ws = rowWordStarts[r];
        final we =
            r + 1 < rowWordStarts.length ? rowWordStarts[r + 1] : line.words.length;
        final StringBuffer sb = StringBuffer();
        for (int wi = ws; wi < we; wi++) {
          sb.write(line.words[wi].text);
        }
        rowTexts.add(sb.toString());
      }
    } else {
      final List<int> lineStarts = <int>[0];
      int pos = 0;
      while (pos < text.length) {
        final boundary = painter.getLineBoundary(TextPosition(offset: pos));
        final lineEnd = boundary.end;
        if (lineEnd <= pos) break;
        pos = lineEnd;
        if (pos < text.length) lineStarts.add(pos);
      }
      rowTexts = <String>[];
      for (int r = 0; r < lineStarts.length; r++) {
        final s = lineStarts[r];
        final e = r + 1 < lineStarts.length ? lineStarts[r + 1] : text.length;
        rowTexts.add(text.substring(s, e));
      }
    }
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
          alignment, leftPadding, lineMeasurer.width, viewportWidth);
      final double y = isFirstRow
          ? padding
          : padding + mainLineHeight + (i - 1) * wrapLineHeight;
      lineMeasurer.paint(canvas, Offset(x, y));
    }
    lineMeasurer.dispose();
  }
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
  int currentLineIndex;
  double posY;
  double fontSize;
  double mainLineHeight;
  List<double> lineHeights;
  List<double> lineTops;
  double viewportHeight;
  double viewportWidth;
  double maxLineWidth;
  int currentTimeMs;
  bool enableScale;
  Map<int, WordRenderer> wordRenderers;
  Map<int, LineRenderer> lineRenderers;
  /// 每行当前的 scale 弹簧位置（由 _onTick 的 per-line scale 推进循环填充）。
  ///
  /// 每行独立持有 scale 弹簧后，离场行（当前行 → 非当前行）从 1.0 平滑缩到
  /// inactiveScale，进场行从 0.97 平滑放大到 1.0——补上原来"缩小硬切"的观感。
  List<double> perLineScales;
  EmphasizeEffect emphasizeEffect;
  InterludeDots interludeDots;
  List<int> interludeAfterIndices;
  double interludePlaceholderHeight;
  int activeInterludeIdx;
  int lastActiveAnchorIdx;
  double interludeExpandProgress;
  List<double> perLineOffsets;
  double blurFade;
  bool blurActive;
  // P2-I：已就绪模糊图的行索引集合（live view，零分配）。
  // 当 blurActive && blurFade > 0.99 时，非当前行文字 alpha≈0（不可见），
  // 若该行模糊图已就绪则跳过文字层绘制——模糊层已覆盖显示。
  Iterable<int> blurReadyLineIndices;
  int textColorValue;
  int? activeLineColorValue;
  int linesGeneration;
  int lineHeightsGeneration;
  int lineTopsGeneration;
  int interludeAfterIndicesGeneration;
  int perLineOffsetsGeneration;

  _LyricsPainter({
    super.repaint,
    required this.lines,
    required this.duetAlignments,
    required this.currentLineIndex,
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
    required this.perLineOffsets,
    required this.blurFade,
    required this.blurActive,
    this.blurReadyLineIndices = const <int>[],
    required this.textColorValue,
    required this.activeLineColorValue,
    required this.linesGeneration,
    required this.lineHeightsGeneration,
    required this.lineTopsGeneration,
    required this.interludeAfterIndicesGeneration,
    required this.perLineOffsetsGeneration,
  });

  /// 更新每帧变化的动画字段（在 _onTick 中调用，避免 setState + build）。
  void updatePerFrame({
    required int currentLineIndex,
    required double posY,
    required int currentTimeMs,
    required double blurFade,
    required double interludeExpandProgress,
    required int activeInterludeIdx,
    required int lastActiveAnchorIdx,
    required List<double> perLineOffsets,
    required int perLineOffsetsGeneration,
    required List<double> perLineScales,
  }) {
    this.currentLineIndex = currentLineIndex;
    this.posY = posY;
    this.currentTimeMs = currentTimeMs;
    this.blurFade = blurFade;
    this.interludeExpandProgress = interludeExpandProgress;
    this.activeInterludeIdx = activeInterludeIdx;
    this.lastActiveAnchorIdx = lastActiveAnchorIdx;
    this.perLineOffsets = perLineOffsets;
    this.perLineOffsetsGeneration = perLineOffsetsGeneration;
    this.perLineScales = perLineScales;
  }

  /// 获取指定行 i 的实际高度（含换行），降级到 mainLineHeight。
  double _heightOf(int i) =>
      i < lineHeights.length ? lineHeights[i] : mainLineHeight;

  /// 获取指定行 i 的顶部 y（累加偏移），降级到 i * mainLineHeight。
  /// 不包含间奏占位偏移。
  double _topOf(int i) =>
      i < lineTops.length ? lineTops[i] : i * mainLineHeight;

  /// 计算指定行索引上方激活间奏的占位高度。
  ///
  /// **progress 驱动**：只要 `interludeExpandProgress > 0` 就返回占位高度，
  /// 不依赖 `activeInterludeIdx`。这样间奏结束后 progress 缓慢收起到 0 期间，
  /// 占位偏移也跟随平滑收起，posY target 不会突变。
  ///
  /// 使用 `lastActiveAnchorIdx` 记录最后激活的间奏 anchor，
  /// 避免影响其他未激活间奏的占位。
  ///
  /// 高度 = interludePlaceholderHeight * interludeExpandProgress
  double _interludeOffsetBefore(int lineIndex) {
    if (interludeExpandProgress <= 0) return 0;
    final int anchorIdx = lastActiveAnchorIdx;
    if (anchorIdx < 0 || anchorIdx >= lineIndex) return 0;
    return interludePlaceholderHeight * interludeExpandProgress;
  }

  @override
  void paint(Canvas canvas, Size size) {
    // 行水平起始位置：左留 1em 边距（对应 LyricLayout.linePadding 的 horizontal）
    final double startX = fontSize * 1.0;

    // === 性能优化：二分查找定位首行可见索引 ===
    // 之前从 i=0 遍历所有 lines（200+ 行），只靠 y 范围 continue/break 跳过。
    // 现在用二分查找快速定位第一个可能可见的行，跳过前方所有不可见行。
    // lineTops 是预排序的（递增），适合二分查找。
    int startI = 0;
    if (lineTops.isNotEmpty && lines.isNotEmpty) {
      int lo = 0, hi = lines.length;
      while (lo < hi) {
        final mid = (lo + hi) ~/ 2;
        final double yMid = _topOf(mid) + posY;
        if (yMid + _heightOf(mid) < -LyricLayout.overscanPx) {
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
      // 行顶部 y 坐标 = lineTops[i] + 该行上方间奏占位偏移 + posY + 级联弹簧偏移。
      // 级联偏移仅当前行下方行非 0（上方行恒 0），50ms/行延迟错峰跟随（AMLL stagger），
      // 与模糊层 _buildBlurLayers 的 springOffset 对齐，避免两层错位。
      final double offset =
          i < perLineOffsets.length ? perLineOffsets[i] : 0.0;
      final double y = _topOf(i) + _interludeOffsetBefore(i) + posY + offset;

      // 跳过视口外（含 overscan=300px 上下缓冲）的行，避免不必要的绘制
      if (y + lineHeight < -LyricLayout.overscanPx) continue;
      if (y > viewportHeight + LyricLayout.overscanPx) break;

      final bool isActive = i == currentLineIndex;

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
      if (blurActive &&
          blurFade > 0.99 &&
          !isActive &&
          blurReadyLineIndices.contains(i) &&
          !(lineRenderers[i]?.isExitFading ?? false)) {
        continue;
      }

      // 形变 scale 与 alpha scale 分开取：
      // - 形变（canvas.scale）用弹簧值，切行时产生 0.97→1.0 的弹性放大；
      // - alpha 用稳态值（当前行恒为 activeScale），使 factor=1、
      //   dynamicDarkAlpha=0.4 —— 新当前行从 0.4 起淡入，而不是被弹簧
      //   在起点处压到 0.2 再慢慢亮起来。
      // 与 _onTick 步骤 4 传给 renderer 的 scale 口径保持一致。
      // 形变 scale 用每行自己的弹簧位置（perLineScales），这样离场行从 1.0
      // 平滑缩到 inactiveScale、进场行从 0.97 平滑放大到 1.0，都不再硬切。
      final double scale =
          i < perLineScales.length ? perLineScales[i] : LyricLayout.inactiveScale;
      final double alphaScale = isActive
          ? LyricLayout.activeScale
          : (enableScale
              ? LyricLayout.inactiveScale
              : LyricLayout.activeScale);

      // 对唱对齐方式（越界时降级为默认左对齐）
      final DuetAlignment alignment = i < duetAlignments.length
          ? duetAlignments[i]
          : DuetAlignment.defaultAlign;

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
      if (useWordRenderer) {
        // 逐字模式：当前行的 KRC 行
        final renderer = wordRenderers[i] ?? WordRenderer();
        renderer.setLineState(isActive: true, scale: alphaScale, blurFade: blurFade, blurActive: blurActive, activeColorValue: activeLineColorValue);
        renderer.paintLine(
          canvas,
          Offset(startX, y),
          line,
          fontSize,
          maxWidth: maxLineWidth,
          alignment: alignment,
          viewportWidth: viewportWidth,
        );
      } else {
        // 整行模式：LRC/纯文本行 + 非当前行的 KRC 行
        final renderer = lineRenderers[i] ?? LineRenderer();
        renderer.setLineState(isActive: isActive, scale: alphaScale, blurFade: blurFade, blurActive: blurActive, activeColorValue: activeLineColorValue);
        renderer.paintLine(
          canvas,
          Offset(startX, y),
          line,
          fontSize,
          maxWidth: maxLineWidth,
          alignment: alignment,
          viewportWidth: viewportWidth,
        );
      }

      canvas.restore();
    }

    // 绘制间奏点（若处于间奏时段或间奏结束后收起期间）。
    // 间奏点作为占位行嵌在歌词流里，位于激活间奏的 anchor 行之后。
    // 占位高度 = interludePlaceholderHeight * interludeExpandProgress（动态展开/收起）
    // centerY 居中在占位区域内（动态高度的一半）。
    // 点大小/间距跟随 fontSize 缩放：radius≈fontSize*0.18，spacing≈fontSize*0.9。
    //
    // **同步收起**：间奏结束后 progress 收起期间也绘制间奏点，
    // 让点消失动画与占位收起同步（都是 ~300-750ms）。
    if (interludeDots.shouldRender &&
        lastActiveAnchorIdx >= 0 &&
        lastActiveAnchorIdx < lines.length) {
      final int anchorIdx = lastActiveAnchorIdx;
      final double anchorHeight = _heightOf(anchorIdx);
      final double anchorTop = _topOf(anchorIdx);
      // anchor 行底部 y（含 anchor 行上方的间奏偏移）
      final double anchorBottomY =
          anchorTop + anchorHeight + _interludeOffsetBefore(anchorIdx) + posY;
      // 占位高度动态展开：0 → interludePlaceholderHeight
      final double placeholderH =
          interludePlaceholderHeight * interludeExpandProgress;
      // 间奏点 centerY 居中在占位区域内
      final double centerY = anchorBottomY + placeholderH / 2;
      // 点半径与间距跟随 fontSize 缩放（AMLL 风格：直径约 6-8px @ fontSize=24）
      final double dotRadius = fontSize * 0.18;
      final double dotSpacing = fontSize * 0.9;
      // 间奏点单独右移：startX * 1.5（比歌词左对齐右移 0.5em）
      // 让点整体居中偏右，视觉更平衡
      final double dotsStartX = fontSize * 1.5;
      interludeDots.paintAtLineY(canvas, dotsStartX, centerY,
          dotRadius: dotRadius,
          spacing: dotSpacing,
          // 间奏点颜色跟随当前行动态色（未开启/未提取到时回退基础歌词色）
          colorValue: activeLineColorValue ?? LyricLayout.textColorValue);
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
