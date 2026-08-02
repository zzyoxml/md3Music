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
/// - [LineScaleController] 仅管理当前行 scale 弹簧，非当前行直接用 inactiveScale
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'controllers/line_scale_controller.dart';
import 'controllers/lyric_scroll_controller.dart';
import 'animation/spring.dart';
import 'layout/duet_layout.dart';
import 'layout/lyric_layout.dart';
import 'layout/lyric_preferences.dart';
import 'models/lyric_line.dart';
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
  double _lastRepaintScale = 0;
  double _lastRepaintBlurFade = 0;
  double _lastRepaintInterludeProgress = 0;
  int _lastRepaintCurrentLineIndex = -1;

  // ============== 控制器与效果 ==============

  final LyricScrollController _scrollController = LyricScrollController();
  final LineScaleController _scaleController = LineScaleController();
  final InterludeDots _interludeDots = InterludeDots();
  final EmphasizeEffect _emphasizeEffect = EmphasizeEffect();

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

  /// 模糊渐隐系数（1.0=正常模糊，0.0=无模糊）。
  /// 用户滚动时淡出到0，松手等待期间保持0，回弹开始后淡入到1。
  double _blurFade = 1.0;

  /// 模糊级别缓存：只在当前行变化时重算
  int _cachedBlurLineIndex = -1;
  Map<int, int> _cachedBlurLevels = const {};

  /// Per-Line 模糊缓存：每行独立缓存模糊图片和对应的 blurLevel
  final Map<int, (ui.Image image, int blurLevel)> _lineBlurImages = {};
  double _viewportWidth = 0;

  /// 最大 sigma 限制
  static const double _maxSigma = 2.0;

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

  // ============== 级联弹簧延迟 ==============

  /// 每行偏移弹簧（行索引 → Spring）。
  ///
  /// 当前行切换时，下方行的弹簧从正偏移（行在下方）动画到 0（行到自然位置），
  /// 形成逐级延迟上拉效果。
  final Map<int, Spring> _perLineSprings = {};

  /// 每行延迟开始时间戳（行索引 → 毫秒）。
  final Map<int, double> _delayStartTimes = {};

  /// 上一帧的当前行索引，用于检测行切换。
  int _previousLineIndex = -1;

  /// 级联延迟：相邻行间延迟毫秒数。
  static const double _perLineDelayMs = 50.0;

  /// 级联偏移系数：每行初始向下偏移 = lineHeight × 此系数。
  /// 正值 = 向下偏移，弹簧拉回 0 = 向上回到自然位置。
  static const double _perLineOffsetFactor = 0.2;

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

  /// 间奏占位完全展开后的总高度（含上下 0.4em 边距，跟随 fontSize 缩放）。
  double _interludePlaceholderHeight = 0;

  // 缓存命中判断字段
  double _cachedFontSize = -1;
  double _cachedViewportWidth = -1;
  int _cachedLinesLength = -1;
  Object? _cachedLinesRef;
  // 字体缓存：字体变化时强制重算行高 + 失效所有模糊图片缓存
  // （TextPainter 用 fontFamily 测量，旧缓存会与新字体渲染尺寸不一致）
  String? _cachedFontFamily;
  // 翻译副行缓存：当前行变化或 showTranslation 开关切换时，
  // 当前行高度需重算（副行高度仅计入当前行）
  // displayMode 切换也需重算（虽副行高度不变，但需触发重绘）
  int _cachedCurrentLineIndex = -1;
  bool _cachedShowTranslation = false;
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
    final currentShowTranslation = LyricPreferences.instance.showTranslation;
    final currentDisplayMode = LyricPreferences.instance.displayMode;
    if (fontSize == _cachedFontSize &&
        viewportWidth == _cachedViewportWidth &&
        _cleanedLines.length == _cachedLinesLength &&
        identitySame &&
        _lineHeights.length == _cleanedLines.length &&
        currentFontFamily == _cachedFontFamily &&
        _currentLineIndex == _cachedCurrentLineIndex &&
        currentShowTranslation == _cachedShowTranslation &&
        currentDisplayMode == _cachedDisplayMode) {
      return; // 缓存命中
    }
    _cachedFontSize = fontSize;
    _cachedViewportWidth = viewportWidth;
    _cachedLinesLength = _cleanedLines.length;
    _cachedLinesRef = _cleanedLines;
    _cachedFontFamily = currentFontFamily;
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
      // 当前行 + 开关开启时，把翻译副行高度计入（仅当前行预留空间）
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
        final gap = next.startTime - line.endTime;
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
    // createTicker 由 SingleTickerProviderStateMixin 提供，
    // 在 widget 不可见时自动暂停（muted），节省 CPU。
    _ticker = createTicker(_onTick);
    _startTickerIfNeeded(); // v3 优化：幂等启动
    _lastElapsed = Duration.zero;
    // 自动回弹触发时恢复模糊（由 _computeLineBlur 自动处理）
    _scrollController.onAutoReturn = () {};
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

  /// v3 优化：检测所有 perLine 偏移弹簧是否已收敛。
  bool _arePerLineSpringsConverged() {
    for (final spring in _perLineSprings.values) {
      if (!spring.isSettled) return false;
    }
    return true;
  }

  /// v3 优化：检测视口附近 renderer 是否已收敛。
  /// 检查当前行的 WordRenderer + 视口内 LineRenderer 的 isConverged。
  bool _areRenderersConverged() {
    final currentRenderer = _wordRenderers[_currentLineIndex];
    if (currentRenderer != null && !currentRenderer.isConverged) {
      return false;
    }
    final int overscan = 15;
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

  /// v3 优化：检测本帧 perLine 偏移是否有显著变化（>0.5px）。
  /// 用于 _onTick 末尾判断是否需要 setState。
  bool _hasPerLineOffsetChanged() {
    final int len = _reusedPerLineOffsets.length;
    for (int i = 0; i < len; i++) {
      final spring = _perLineSprings[i];
      if (spring == null) continue;
      if ((spring.position - _reusedPerLineOffsets[i]).abs() > 0.5) {
        return true;
      }
    }
    return false;
  }

  /// v3 优化：检测本帧 renderer alpha 是否有显著变化。
  /// !isConverged 表示仍在动画中，需要继续 setState。
  bool _hasRendererAlphaChanged() {
    final currentWord = _wordRenderers[_currentLineIndex];
    if (currentWord != null && !currentWord.isConverged) {
      return true;
    }
    final int overscan = 15;
    final int startIdx = math.max(0, _currentLineIndex - overscan);
    final int endIdx =
        math.min(widget.lines.length, _currentLineIndex + overscan);
    for (int i = startIdx; i < endIdx; i++) {
      final renderer = _lineRenderers[i];
      if (renderer != null && !renderer.isConverged) {
        return true;
      }
    }
    return false;
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
    // 字体变化时失效所有依赖字体测量的缓存
    final currentFontFamily = LyricLayout.fontFamily;
    if (currentFontFamily != _cachedFontFamily) {
      // 失效行高缓存（让 _recomputeLineHeightsIfNeeded 重算）
      _cachedFontFamily = null;
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
    setState(() {});
  }

  @override
  void didUpdateWidget(covariant AppleLyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // lines 列表缩短时，清理不再存在的行索引对应的 renderer 缓存，避免内存泄漏
    _wordRenderers.removeWhere((key, _) => key >= widget.lines.length);
    _lineRenderers.removeWhere((key, _) => key >= widget.lines.length);
    // v3 优化：恢复播放或切歌时立即重启 Ticker（停止态恢复）
    if (oldWidget.isPlaying != widget.isPlaying && widget.isPlaying) {
      _startTickerIfNeeded();
    }
    // v3 优化：切歌（lines 引用变化）时重启 Ticker，重新推进新行的 renderer
    if (!identical(oldWidget.lines, widget.lines)) {
      _startTickerIfNeeded();
    }
  }

  @override
  void dispose() {
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

  /// 构建每行的偏移量列表，传给 _LyricsPainter。
  ///
  /// v3 优化：复用 List 实例，仅更新内容。
  /// lines 长度变化时重新分配 List，否则原地 []= 更新。
  /// 同时递增 _perLineOffsetsGeneration，让 shouldRepaint 通过 counter 检测变化。
  List<double> _buildPerLineOffsets() {
    final int len = widget.lines.length;
    if (_reusedPerLineOffsets.length != len) {
      _reusedPerLineOffsets = List<double>.filled(len, 0.0);
    } else if (_currentLineIndex > 0) {
      // 性能优化：上方行无 spring（永远 0），清零当前行上方的残留值
      // 当前行下方由后续循环覆盖，无需清零
      for (int i = 0; i < _currentLineIndex && i < len; i++) {
        _reusedPerLineOffsets[i] = 0.0;
      }
    }
    // 性能优化：_perLineSprings 只为当前行下方的行设置 spring（见 _onTick 行切换逻辑），
    // 上方行永远返回 0。跳过上方行减少无意义遍历（200+ 行 → 仅遍历当前行到末尾）。
    final int startI = math.max(0, _currentLineIndex);
    for (int i = startI; i < len; i++) {
      _reusedPerLineOffsets[i] = _perLineSprings[i]?.position ?? 0.0;
    }
    _perLineOffsetsGeneration++;
    return _reusedPerLineOffsets;
  }

  // ============== 动画推进 ==============

  void _onTick(Duration elapsed) {
    // 使用 Ticker 的调度器时钟（测试中为模拟时间）计算 dt，
    // 避免 DateTime.now() 在测试中返回真实墙钟时间导致弹簧不推进。
    final dt = (elapsed - _lastElapsed).inMicroseconds / 1000000.0;
    _lastElapsed = elapsed;

    // 1. 找当前行
    // 纯文本歌词（无时间轴）不高亮、不滚动、不模糊，直接平铺显示
    // 性能优化：缓存 hasTimestamps 结果，避免每帧 O(N) 遍历所有 lines
    final bool hasTimestamps = _cachedHasTimestamps;
    _currentLineIndex = hasTimestamps
        ? AppleLyricsView.findCurrentLineIndex(widget.lines, widget.currentTimeMs)
        : -1;

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

    // 3. 推进当前行缩放控制器（仅管理当前行的 scale 弹簧 0.97→1.0）
    _scaleController.setLineState(
      isActive: true,
      enableScale: widget.enableScale,
    );
    _scaleController.tick(dt);

    // 4. 推进每行的 renderer
    // 性能优化：只 tick 视口附近的行（前后各 15 行），避免 200+ 行全量 tick。
    // 当前行用 WordRenderer（逐字 alpha + 上浮），其他行用 LineRenderer。
    final int overscan = 15;
    final int startIdx = math.max(0, _currentLineIndex - overscan);
    final int endIdx = math.min(widget.lines.length, _currentLineIndex + overscan);
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
        renderer.setLineState(isActive: true, scale: scale, blurFade: _blurFade, blurActive: blurActive);
        renderer.tick(dt, widget.currentTimeMs);
      } else {
        final renderer = _lineRendererFor(i);
        renderer.setLineState(isActive: isActive, scale: scale, blurFade: _blurFade, blurActive: blurActive);
        renderer.tick(dt);
      }
    }

    // 5. 间奏检测与推进
    _updateInterlude();

    // 6. 推进间奏点动画时钟（基于帧 dt，60fps 流畅，不受 positionStream 5fps 限制）
    // 暂停时不推进动画时钟，让间奏点随播放器一起暂停
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
    _interludeExpandProgress += (interludeTarget - _interludeExpandProgress) *
        (1 - math.exp(-interludeSpeed * dt));
    // 收起到接近 0 时直接归零，避免无限逼近占着微小高度
    if (_activeInterludeIdx < 0 && _interludeExpandProgress < 0.001) {
      _interludeExpandProgress = 0;
    }

    // 8. 级联弹簧延迟：检测当前行切换，为下方行设置延迟偏移
    if (_currentLineIndex >= 0 && _currentLineIndex != _previousLineIndex) {
      final now = _lastElapsed.inMicroseconds / 1000.0;
      // 使用当前行的实际高度（含换行），而非理论 mainLineHeight
      final currentLineHeight = (_currentLineIndex < _lineHeights.length
          ? _lineHeights[_currentLineIndex]
          : LyricLayout.fontSize(context) * LyricLayout.lineHeight);
      // 为当前行下方的行设置延迟和弹簧初始偏移
      // 偏移量与距离成正比，但递增幅度逐行衰减，避免过远的行偏移过大
      for (int i = _currentLineIndex + 1; i < widget.lines.length; i++) {
        final distance = i - _currentLineIndex;
        // 衰减公式：offset = lineHeight * factor * (1 - 1/distance)
        // distance=1 → 0, distance=2 → 0.5*factor, distance=3 → 0.67*factor, ...
        // 这样相邻行偏移小，远处行偏移趋近上限
        final offset = currentLineHeight * _perLineOffsetFactor *
            (1 - 1.0 / distance);
        _delayStartTimes[i] = now;
        final spring = _perLineSpringFor(i);
        spring.setPosition(offset, 0);
        spring.setTarget(0);
      }
      // 清除已过行的延迟记录
      _delayStartTimes.removeWhere((k, _) => k <= _currentLineIndex);
    }
    _previousLineIndex = _currentLineIndex;

    // 推进每行偏移弹簧
    // 性能优化：只遍历当前行到末尾，跳过上方行（上方行永远 0，无需 setPosition）。
    // 之前遍历所有 _perLineSprings（含上方 100+ 行），每帧 100+ 次无意义 setPosition(0,0)。
    final int springStartI = math.max(0, _currentLineIndex);
    for (int i = springStartI; i < widget.lines.length; i++) {
      final spring = _perLineSprings[i];
      if (spring == null) continue;
      final delayStart = _delayStartTimes[i];
      if (delayStart != null) {
        final elapsedMs = (_lastElapsed.inMicroseconds / 1000.0) - delayStart;
        final delayMs = (i - _currentLineIndex) * _perLineDelayMs;
        if (elapsedMs >= delayMs) {
          spring.tick(dt);
        }
        // 延迟未到：保持初始偏移（setPosition 已设置）
      }
    }

    // 10. 模糊渐隐动画：滚动/等待时淡出到0，回弹开始后淡入到1
    final bool shouldBlurFadeOut = _scrollController.isUserScrolling ||
        _scrollController.isWaitingForAutoReturn;
    final double blurFadeTarget = shouldBlurFadeOut ? 0.0 : 1.0;
    // 修复：淡入速度 4.0 → 12.0，约 150ms 完成（原 700-1000ms）。
    // 配合修改 1，模糊图在新当前行周围快速淡入出现。
    final double blurFadeSpeed = shouldBlurFadeOut ? 15.0 : 12.0;
    final double oldBlurFade = _blurFade;
    _blurFade += (blurFadeTarget - _blurFade) *
        (1 - math.exp(-blurFadeSpeed * dt));
    if ((_blurFade - blurFadeTarget).abs() < 0.01) {
      _blurFade = blurFadeTarget;
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
    if (!widget.isPlaying &&
        _scrollController.isConverged &&
        _scaleController.isConverged &&
        (_blurFade - blurFadeTarget).abs() < 0.001 &&
        (_interludeExpandProgress - interludeTarget).abs() < 0.001 &&
        _arePerLineSpringsConverged() &&
        _areRenderersConverged()) {
      _stopTickerIfNeeded();
      // 最后一帧 setState 确保稳态画面渲染
      setState(() {});
      return;
    }

    // 12. v3 优化：检测本帧是否有视觉变化，无变化则跳过 setState。
    // 检测阈值（0.5px / 0.001）远低于人眼感知，肉眼不可见的变化才跳过。
    final double currentScale = _scaleController.currentScale;
    final double currentPosY = _scrollController.posY;
    final bool hasVisualChange =
        _currentLineIndex != _lastRepaintCurrentLineIndex ||
            (currentPosY - _lastRepaintPosY).abs() > 0.5 ||
            (currentScale - _lastRepaintScale).abs() > 0.001 ||
            (_blurFade - _lastRepaintBlurFade).abs() > 0.001 ||
            (_interludeExpandProgress - _lastRepaintInterludeProgress).abs() >
                0.001 ||
            _hasPerLineOffsetChanged() ||
            _hasRendererAlphaChanged() ||
            _interludeDots.shouldRender;

    if (hasVisualChange) {
      _lastRepaintCurrentLineIndex = _currentLineIndex;
      _lastRepaintPosY = currentPosY;
      _lastRepaintScale = currentScale;
      _lastRepaintBlurFade = _blurFade;
      _lastRepaintInterludeProgress = _interludeExpandProgress;
      // 性能优化：用持久化 painter + notifyListeners 替代 setState，
      // 避免每帧触发 build() 重建整个 widget tree（LayoutBuilder/GestureDetector/ShaderMask）。
      // Gaussian 模糊需要重建 widget（Positioned/Opacity 层），仍用 setState。
      final useGaussian = LyricPreferences.instance.useGaussianBlur;
      if (_painter != null && !useGaussian) {
        _painter!.updatePerFrame(
          currentLineIndex: _currentLineIndex,
          posY: currentPosY,
          currentTimeMs: widget.currentTimeMs,
          blurFade: _blurFade,
          interludeExpandProgress: _interludeExpandProgress,
          activeInterludeIdx: _activeInterludeIdx,
          lastActiveAnchorIdx: _lastActiveAnchorIdx,
          perLineOffsets: _buildPerLineOffsets(),
          perLineOffsetsGeneration: _perLineOffsetsGeneration,
        );
        _repaintNotifier.fireRepaint();
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
  void _updateInterlude() {
    int foundIdx = -1;
    int? gapStart;
    int? gapEnd;
    for (int i = 0; i < _interludeAfterIndices.length; i++) {
      final int lineIdx = _interludeAfterIndices[i];
      if (lineIdx < 0 || lineIdx >= widget.lines.length - 1) continue;
      final current = widget.lines[lineIdx];
      final next = widget.lines[lineIdx + 1];
      final start = current.endTime;
      final end = next.startTime - LyricLayout.interludeEarlyEndMs;
      if (widget.currentTimeMs >= start && widget.currentTimeMs < end) {
        foundIdx = i;
        gapStart = start;
        gapEnd = end;
        break;
      }
    }

    _activeInterludeIdx = foundIdx;

    if (foundIdx >= 0 && gapStart != null && gapEnd != null) {
      _interludeDots.setInterlude(gapStart, gapEnd);
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
            currentTimeMs: widget.currentTimeMs,
            enableScale: widget.enableScale,
            wordRenderers: _wordRenderers,
            lineRenderers: _lineRenderers,
            scaleController: _scaleController,
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
            textColorValue: LyricLayout.textColorValue,
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
          _painter!.currentTimeMs = widget.currentTimeMs;
          _painter!.enableScale = widget.enableScale;
          _painter!.wordRenderers = _wordRenderers;
          _painter!.lineRenderers = _lineRenderers;
          _painter!.scaleController = _scaleController;
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
          _painter!.textColorValue = LyricLayout.textColorValue;
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
            shaderCallback: (Rect bounds) {
              const double fadeHeight = 24.0;
              final double fadeRatio =
                  (fadeHeight / bounds.height).clamp(0.0, 0.5);
              return LinearGradient(
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
            },
            blendMode: BlendMode.dstIn,
            child: useGaussian
                ? ClipRect(
                    child: Builder(
                      builder: (context) {
                        // 检测视口宽度变化，清除模糊缓存
                        if (_viewportWidth != constraints.maxWidth && _viewportWidth > 0) {
                          for (final entry in _lineBlurImages.values) {
                            entry.$1.dispose();
                          }
                          _lineBlurImages.clear();
                          _cachedBlurLineIndex = -1;
                        }
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
  /// - 当前行：0
  /// - 已过行：1 + |currentLine - lineIndex| + 1
  /// - 未到行：1 + |lineIndex - currentLine|
  /// - 用户滚动时：0
  /// 计算指定行的模糊级别（含 fade）。
  int _computeLineBlur(int lineIndex) {
    if (_currentLineIndex < 0 || lineIndex == _currentLineIndex) return 0;
    if (_blurFade < 0.01) return 0;
    return (_computeLineBlurRaw(lineIndex) * _blurFade).round().clamp(0, 5);
  }

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

    // 当前行变化时重新计算 blur levels 并更新缓存（滑动时跳过）
    if (_currentLineIndex != _cachedBlurLineIndex && !isScrolling) {
      _cachedBlurLineIndex = _currentLineIndex;

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

    for (final entry in _cachedBlurLevels.entries) {
      final int i = entry.key;
      // 修复：sigma 不乘 _blurFade，与 _renderLineBlur 的渲染 sigma 一致。
      // 这样 padding 和 scaledHeight 与渲染图片尺寸匹配，不会被拉伸。
      // _blurFade 通过 Opacity 控制透明度实现淡入淡出。
      final double sigma = entry.value.toDouble().clamp(0.5, 5.0);
      if (sigma < 0.1) continue;

      final cached = _lineBlurImages[i];
      if (cached == null) continue;
      final image = cached.$1;

      final double lineTop = (i < _lineTops.length
              ? _lineTops[i]
              : i * mainLineHeight) +
          _interludeOffsetBefore(i);
      // 应用弹簧偏移
      final List<double> offsets = _buildPerLineOffsets();
      final double springOffset = (i < offsets.length) ? offsets[i] : 0.0;
      final double y = lineTop + _scrollController.posY + springOffset;
      final double lineHeight = (i < _lineHeights.length)
          ? _lineHeights[i]
          : mainLineHeight;

      if (y + lineHeight < 0 || y > viewportHeight) continue;

      final double padding = sigma * 3;

      // 简化：模糊层不缩放，直接以视口全宽显示。
      // 模糊图片中的文字已通过 textAlign 按对齐方式排列，
      // 图片宽度 = _viewportWidth，left=0 即可让文字位置与清晰层匹配。
      // 非当前行清晰层 scale=0.97 与模糊层 scale=1.0 的 3% 差异对模糊层不可见。
      // 用 image 实际尺寸避免垂直拉伸（lineHeight 与 actualTextHeight 不一致时）。
      final double imgWidth = image.width.toDouble();
      final double imgHeight = image.height.toDouble();

      layers.add(Positioned(
        top: y - padding,
        left: 0,
        width: imgWidth,
        height: imgHeight,
        child: Opacity(
          opacity: _blurFade,
          child: RawImage(
            image: image,
            fit: BoxFit.fill,
          ),
        ),
      ));
    }

    return layers;
  }

  /// 异步更新模糊缓存：为变化的行渲染模糊图片。
  void _updateLineBlurCache(Map<int, int> levels) {
    for (final entry in levels.entries) {
      final int lineIndex = entry.key;
      final int blurLevel = entry.value;
      // 检查缓存是否存在且 blurLevel 匹配
      final cached = _lineBlurImages[lineIndex];
      if (cached != null && cached.$2 == blurLevel) {
        continue;
      }

      _renderLineBlur(lineIndex, blurLevel, _duetAlignmentAt(lineIndex)).then((image) {
        if (image != null) {
          _lineBlurImages[lineIndex]?.$1.dispose();
          _lineBlurImages[lineIndex] = (image, blurLevel);
        }
      });
    }

    // 清理不再需要的缓存
    final keysToRemove = _lineBlurImages.keys
        .where((k) => !levels.containsKey(k))
        .toList();
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

  /// 异步渲染单行模糊图片。
  ///
  /// 渲染歌词文字到 Picture，应用 ImageFilter.blur，转为 ui.Image 缓存。
  Future<ui.Image?> _renderLineBlur(int lineIndex, int blurLevel, DuetAlignment alignment) async {
    try {
      if (_viewportWidth <= 0) return null;

      // 修复：sigma 不乘 _blurFade，确保渲染尺寸固定不依赖淡入进度。
      // _blurFade 通过 Opacity 控制透明度，不需要再通过 sigma 控制模糊度。
      // 此前 sigma 依赖 _blurFade 会导致：
      //   - 异步渲染时 _blurFade 还小 → sigma 被 clamp 到 0.5 → 模糊太浅
      //   - renderHeight 太小 → 绘制时图片被拉伸（上下比例太长）
      final double sigma = blurLevel.toDouble().clamp(0.5, 5.0);
      final double fontSize = LyricLayout.fontSize(context);
      final double padding = sigma * 3;
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
        ),
      );
      textPainter.layout(maxWidth: maxTextWidth);

      // 使用 TextPainter 布局后的实际文本高度，而非 _lineHeights 中的值。
      // _lineHeights 对换行行使用 wrapLineHeightFactor=0.8 压缩行距（显示紧凑），
      // 但 TextPainter 用完整 lineHeight 渲染，两者不匹配会导致底部文字被裁断。
      final double actualTextHeight = textPainter.height;
      final double renderHeight = actualTextHeight + padding * 2;

      // 对画布应用模糊
      final blurPaint = Paint()
        ..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
      canvas.saveLayer(
        Rect.fromLTWH(0, 0, _viewportWidth, renderHeight),
        blurPaint,
      );
      // 判断是否为多行文本（自动换行）
      final bool isMultiLine = actualTextHeight >
          fontSize * LyricLayout.lineHeight * 1.5;
      if (!isMultiLine) {
        // 单行：用 _alignX 计算起始 x
        final double x = _blurAlignX(
            alignment, leftPadding, textPainter.width, _viewportWidth);
        textPainter.paint(canvas, Offset(x, padding));
      } else {
        // 多行：按视觉行拆分，每行独立 _alignX 对齐绘制
        _paintBlurMultiLineAligned(canvas, textPainter, alignment,
            leftPadding, padding, fontSize, _viewportWidth);
      }
      canvas.restore();

      final picture = recorder.endRecording();
      final image = await picture.toImage(
        _viewportWidth.toInt(),
        renderHeight.toInt(),
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
      Canvas canvas, TextPainter painter, DuetAlignment alignment,
      double leftPadding, double padding, double fontSize, double viewportWidth) {
    final String text = painter.text?.toPlainText() ?? '';
    if (text.isEmpty) return;
    // 通过 getLineBoundary 拆分视觉行
    final List<int> lineStarts = <int>[0];
    int pos = 0;
    while (pos < text.length) {
      final boundary = painter.getLineBoundary(TextPosition(offset: pos));
      final lineEnd = boundary.end;
      if (lineEnd <= pos) break;
      pos = lineEnd;
      if (pos < text.length) lineStarts.add(pos);
    }
    // 每行独立绘制
    final double wrapLineHeight =
        fontSize * LyricLayout.lineHeight * LyricLayout.wrapLineHeightFactor;
    final lineMeasurer = TextPainter(textDirection: TextDirection.ltr);
    for (int i = 0; i < lineStarts.length; i++) {
      final start = lineStarts[i];
      final end = i + 1 < lineStarts.length ? lineStarts[i + 1] : text.length;
      final lineText = text.substring(start, end);
      lineMeasurer.text = TextSpan(
        text: lineText,
        style: painter.text!.style,
      );
      lineMeasurer.layout(maxWidth: double.infinity);
      final double x = _blurAlignX(
          alignment, leftPadding, lineMeasurer.width, viewportWidth);
      final double y = padding + i * wrapLineHeight;
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
/// 当前行通过 [LineScaleController.currentScale] 提供 scale（弹簧动画），
/// 非当前行直接使用 [LyricLayout.inactiveScale]=0.97。
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
  LineScaleController scaleController;
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
  int textColorValue;
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
    required this.scaleController,
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
    required this.textColorValue,
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
      // 行顶部 y 坐标 = lineTops[i] + 该行上方间奏占位偏移 + posY（文字层不再使用 perLine 弹簧偏移）
      final double offset = 0.0;
      final double y = _topOf(i) + _interludeOffsetBefore(i) + posY + offset;

      // 跳过视口外（含 overscan=300px 上下缓冲）的行，避免不必要的绘制
      if (y + lineHeight < -LyricLayout.overscanPx) continue;
      if (y > viewportHeight + LyricLayout.overscanPx) break;

      final bool isActive = i == currentLineIndex;
      // 文字层不再使用 scale 弹簧，当前行瞬移到 activeScale
      final double scale = isActive
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
        renderer.setLineState(isActive: true, scale: scale, blurFade: blurFade, blurActive: blurActive);
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
        renderer.setLineState(isActive: isActive, scale: scale, blurFade: blurFade, blurActive: blurActive);
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
          dotRadius: dotRadius, spacing: dotSpacing);
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
