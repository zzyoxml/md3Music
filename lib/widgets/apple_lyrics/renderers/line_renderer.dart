/// 整行降级渲染器（用于 LRC 与纯文本，无逐字时间戳；亦用于非当前行的 KRC 行）
///
/// 参照 spec.md "Requirement: 逐字 mask alpha 渲染" 中"非当前行渲染"场景与
/// tasks.md Task 10 实现。启用整行模式的场景：
/// - hasWordTiming=false 的行（LRC/纯文本）：始终用本类
/// - hasWordTiming=true 的非当前行（KRC）：用本类降级渲染（性能优化）
///
/// 渲染规则：
/// - 当前行（isActive）：整行 alpha = dynamicBrightAlpha（随 scale 0.2~1.0）
/// - 非当前行：整行 alpha = dynamicDarkAlpha（随 scale 0.2~0.4，SOLID 模式）
/// - 行内无 mask 渐变，整行使用同一 alpha
/// - 行切换通过指数衰减实现淡入淡出过渡（变亮 ATTACK_SPEED=50，变暗 RELEASE_SPEED=7）
///
/// 与 [WordRenderer] 的关系：
/// - [WordRenderer] 处理当前行 + hasWordTiming=true 的逐字模式（有 mask 渐变 + 上浮）
/// - 本类处理 hasWordTiming=false 的行 + 非当前行的 KRC 行（无 mask 渐变）
/// - 上层 AppleLyricsView 根据 isActive 与 hasWordTiming 调度使用哪个 renderer
/// - 非当前行不需要逐字渐变，用本类每帧只 1 次 layout，大幅降低 CPU
///
/// 本类不是 Widget，是核心绘制逻辑类，由外部 CustomPainter 调用 [paintLine]。
/// 动画驱动由外部 AnimationController + Ticker 调用 [tick] 实现。
library;

import 'dart:math';

import 'package:flutter/widgets.dart';

import '../layout/duet_layout.dart';
import '../layout/lyric_layout.dart';
import '../layout/lyric_preferences.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';

/// 整行降级渲染器。
///
/// 持有当前 isActive 状态与单一 [_currentAlpha] 值（整行共用一个 alpha），
/// 通过 [tick] 推进指数衰减动画，通过 [paintLine] 用当前 alpha 绘制白色文本。
class LineRenderer {
  LineRenderer();

  // ============== 内部状态 ==============

  /// 当前是否为当前行（高亮）。默认 false（SOLID 暗态）。
  bool _isActive = false;

  /// 当前整行 alpha 值。初始 [LyricLayout.currentDarkAlpha]=0.2（SOLID 非当前行暗态）。
  double _currentAlpha = LyricLayout.currentDarkAlpha;

  /// 目标 alpha 值。isActive=true 时 1.0，false 时 0.2。
  double _targetAlpha = LyricLayout.currentDarkAlpha;

  /// v3 优化：alpha 是否已收敛到 target（最近一次 tick 中 alpha 变化 < 1e-6）。
  /// 用于 AppleLyricsView 判断是否可以停止 Ticker。
  bool _isConverged = true;

  /// 复用的 TextPainter 实例（避免每帧创建对象）。
  ///
  /// **性能优化**：之前每帧 paintLine 都创建新 TextPainter + GC，
  /// 现在复用实例，只重新 set text + layout（alpha 变了需要重新 layout）。
  final TextPainter _painter = TextPainter(textDirection: TextDirection.ltr);

  /// 翻译副行专用 TextPainter（与主文本分离，避免复用 _painter 导致
  /// v4 缓存校验失效——主文本在 alpha 未变时会跳过 set text，若 _painter
  /// 被翻译副行改写过，下次主文本绘制会错误地画出翻译文本）。
  final TextPainter _translationPainter =
      TextPainter(textDirection: TextDirection.ltr);

  /// 最近一次多行绘制时的视觉行数（0 表示上次为单行/未多行）。
  ///
  /// 翻译副行定位需要"压缩后的主文本高度"（与 measureLineHeight 一致：
  /// `mainLineHeight + (rowCount-1)*mainLineHeight*0.8`），而 TextPainter 整行
  /// 高度是完整行高（每行 ≈ mainLineHeight），两者不一致会导致多行歌词的
  /// 翻译副行向下偏移而与下一行歌词重叠——因此用该行数反推压缩高度。
  int _lastMultiLineRowCount = 0;

  /// KRC 行 word 宽度缓存（与 WordRenderer._wordWidths 同口径：同 TextStyle 单字 layout）。
  ///
  /// **换行一致性**：measureLineHeight 与 WordRenderer（当前行）都用"word 累加"
  /// 判定换行（`dx + width > maxWidth && dx > 0`），而 LineRenderer（非当前 KRC 行）
  /// 若用 TextPainter 整行自动换行，两者在含英文/空格/禁则时行数可能不同
  /// （探针实测英文句差 1 行），导致非当前行高度与 _lineHeights 不匹配而重叠。
  /// 因此 LineRenderer 对 KRC 行也用同一套 word 累加分块。
  List<double> _wordWidths = const <double>[];

  /// word 宽度缓存绑定的行（变化即重算）。
  LyricLine? _wordWidthsLine;

  /// word 宽度缓存绑定的字号（变化即重算）。
  double _wordWidthsFontSize = -1;

  /// v4 优化：上次 set text + layout 时的 alpha。
  /// 仅在 alpha 变化 > 0.001 时才 set text + layout，避免每帧 N 次 layout。
  /// LineRenderer 每行独立实例（`Map<int, LineRenderer>`），无 v3 共享 painter bug 风险。
  double _lastSetAlpha = -1;

  /// v4 优化：上次 set text + layout 时的 maxWidth。
  /// maxWidth 变化时也需重新 layout（视口宽度变化导致换行变化）。
  double _lastSetMaxWidth = -1;

  /// 上次 set text 时的文字颜色值。
  /// 主题切换时 textColorValue 变化，需强制重建 TextSpan。
  int _lastTextColorValue = -1;

  /// 上次 set text 时使用的字重。字重变化时需强制重建 TextSpan。
  FontWeight _lastFontWeight = FontWeight.normal;

  /// 当前行专用的文字颜色（ARGB int，仅 [_isActive] 时生效）。
  /// 动态字体颜色：由封面提取色按「70% 白 + 30% 提取色」混色得到，
  /// null 表示不使用（回退到 LyricLayout.textColorValue）。
  int? _activeColorValue;

  /// 当前绑定的 LyricLine 引用。
  ///
  /// 用于检测 line 切换（如 useDuetLayout 切换后 _cleanedLines 重建为新对象），
  /// 触发强制 set text + layout，避免 _painter 缓存旧文本（带「男：」前缀）
  /// 导致 _painter.width 错误、alignment 计算偏移。
  LyricLine? _boundLine;

  /// 上次绘制时使用的对齐方式。alignment 变化时强制重建（避免缓存不一致）。
  DuetAlignment _lastAlignment = DuetAlignment.defaultAlign;

  /// 多行对齐绘制时使用的临时 TextPainter（仅 _paintMultiLineAligned 内用）。
  /// 与 _painter 分离避免污染主 painter 的 layout 缓存。
  final TextPainter _lineMeasurer = TextPainter(textDirection: TextDirection.ltr);

  // ============== setLineState 输入缓存 ==============
  //
  // 播放稳态下（无用户交互、无 blurFade 变化），每帧都调用 setLineState 但
  // isActive/scale/blurFade/blurActive 四个输入其实都没变，dynamicDark/dynamicBright
  // 公式重算纯属浪费。缓存这四个输入，全相等时直接早退，跳过 ~5 次浮点运算 +
  // target 比较 + _isConverged 重置判断。每帧 30 行 × 120Hz = 3600 次/秒无意义计算。

  bool _lastIsActive = false;
  double _lastScale = double.nan;
  double _lastBlurFade = double.nan;
  bool _lastBlurActive = false;
  int? _lastActiveColorValue;

  // ============== 状态查询 ==============

  /// 当前 alpha（用于测试与外部协调）。
  double get currentAlpha => _currentAlpha;

  /// 当前是否为当前行。
  bool get isActive => _isActive;

  /// v3 优化：alpha 是否已收敛（最近一次 tick 无变化）。
  /// 用于 AppleLyricsView 判断是否可以停止 Ticker。
  bool get isConverged => _isConverged;

  /// 目标 alpha（用于测试断言）。
  @visibleForTesting
  double get targetAlpha => _targetAlpha;

  // ============== 状态设置 ==============

  /// 设置当前行状态。
  ///
  /// [isActive] 为 true 时整行高亮（alpha 目标 dynamicBrightAlpha），
  /// 为 false 时整行 SOLID 暗态（alpha 目标 dynamicDarkAlpha）。
  /// [scale] 是行缩放，0.97（inactive）~1.0（active）。
  /// [blurFade] 控制非当前行透明度：1.0=透明（模糊图片覆盖），0.0=正常显示。
  /// [blurActive] 是否启用高斯模糊：false 时不降低非当前行透明度。
  ///
  /// **v4 bug 修复**：检测 _targetAlpha 变化时重置 _isConverged=false。
  /// 之前 setLineState 修改 _targetAlpha 但不重置 _isConverged，
  /// 导致后续 tick 调用时 _isConverged=true（来自上次收敛）即便 target 已变也不会重新计算。
  void setLineState({required bool isActive, required double scale, double blurFade = 1.0, bool blurActive = true, int? activeColorValue}) {
    // 输入缓存早退：稳态下 5 个输入全相等 → 跳过 dynamic 公式重算与 target 比较
    if (isActive == _lastIsActive &&
        scale == _lastScale &&
        blurFade == _lastBlurFade &&
        blurActive == _lastBlurActive &&
        activeColorValue == _lastActiveColorValue) {
      return;
    }
    _lastIsActive = isActive;
    _lastScale = scale;
    _lastBlurFade = blurFade;
    _lastBlurActive = blurActive;
    _lastActiveColorValue = activeColorValue;

    _isActive = isActive;
    _activeColorValue = activeColorValue;
    final double factor = ((scale - LyricLayout.inactiveScale) /
            (LyricLayout.activeScale - LyricLayout.inactiveScale))
        .clamp(0.0, 1.0)
        .toDouble();
    final double dynamicDark = factor * 0.2 + 0.2;
    final double dynamicBright = factor * 0.8 + 0.2;
    // 非当前行 alpha = dynamicDark * (1 - blurFade)，blurActive=false 时不降低
    final double effectiveFade = blurActive ? blurFade : 0.0;
    final double newTargetAlpha = isActive ? dynamicBright : dynamicDark * (1.0 - effectiveFade);
    // v4 修复：target 变化时重置 _isConverged，让 tick 重新计算 alpha
    if ((newTargetAlpha - _targetAlpha).abs() > 1e-6) {
      _isConverged = false;
    }
    _targetAlpha = newTargetAlpha;
  }

  // ============== 动画推进 ==============

  /// 推进动画。
  ///
  /// [dt] 距上一帧的时间间隔（秒）。
  /// 用指数衰减公式 `_currentAlpha += (_targetAlpha - _currentAlpha) * (1 - exp(-speed * dt))`
  /// 平滑过渡：变亮用 [LyricLayout.attackSpeed]（50.0），变暗用 [LyricLayout.releaseSpeed]（7.0）。
  /// 差值小于 [LyricLayout.alphaEpsilon]（0.001）时吸附到目标。
  ///
  /// **v4 优化**：isConverged=true 时早 return 跳过已收敛行的指数衰减计算。
  /// setLineState 检测 target 变化时会重置 _isConverged=false，确保 target 变化后能重新计算。
  void tick(double dt) {
    if (dt <= 0) return;
    if (_isConverged) return; // v4 优化：已收敛的行跳过 tick
    // 变亮用 ATTACK（快），变暗用 RELEASE（慢）
    final double speed = _targetAlpha >= _currentAlpha
        ? LyricLayout.attackSpeed
        : LyricLayout.releaseSpeed;
    final double decay = 1.0 - exp(-speed * dt);
    double next = _currentAlpha + (_targetAlpha - _currentAlpha) * decay;
    // 阈值收敛：差值小于 alphaEpsilon 直接吸附到目标
    if ((next - _targetAlpha).abs() < LyricLayout.alphaEpsilon) {
      next = _targetAlpha;
    }
    // v3 优化：跟踪 alpha 是否仍在变化（用于 AppleLyricsView 判断停止 Ticker）
    _isConverged = (next - _currentAlpha).abs() < 1e-6;
    _currentAlpha = next;
  }

  // ============== 绘制 ==============

  /// 绘制整行歌词。
  ///
  /// [offset] 是行起始绘制原点（leftPadding, y）。文字颜色固定白色 #FFFFFFFF，
  /// alpha 由 [_currentAlpha] 控制（整行同一 alpha，无 mask 渐变）。
  /// 使用复用的 [_painter] 实例测量整行宽度并绘制。
  ///
  /// [maxWidth] 为可用最大文字宽度，超出时 TextPainter 自动换行（默认不换行）。
  ///
  /// **对齐实现**：与 [WordRenderer] 一致采用 [_alignX] 显式计算文本起始 x
  /// 坐标。不依赖 [TextPainter.textAlign]，因为 textAlign 在某些场景下
  /// （缓存命中跳过 layout 时）可能不会重新生效，导致非当前行错位到左侧。
  /// 多行文本（自动换行）通过 [_paintMultiLineAligned] 按视觉行拆分，
  /// 每行独立应用 [_alignX] 计算对齐。
  ///
  /// **性能优化**：
  /// - 复用 [_painter] 实例，避免每帧创建 TextPainter 对象 + GC
  /// - **v4 优化**：alpha 变化 < 0.001 且 maxWidth 未变时跳过 set text + layout
  ///   （layout 结果与 alpha 无关，复用上次的 layout 结果直接 paint）
  void paintLine(
      Canvas canvas, Offset offset, LyricLine line, double fontSize,
      {double maxWidth = double.infinity,
      DuetAlignment alignment = DuetAlignment.defaultAlign,
      double viewportWidth = 0}) {
    if (line.text.isEmpty) return;
    // 解析当前行实际文字颜色：动态字体颜色（仅当前行）优先，否则回退主题默认色
    final int textColorValue =
        (_isActive && _activeColorValue != null)
            ? _activeColorValue!
            : LyricLayout.textColorValue;
    final int textRed = (textColorValue >> 16) & 0xFF;
    final int textGreen = (textColorValue >> 8) & 0xFF;
    final int textBlue = textColorValue & 0xFF;
    // v4 优化：alpha 变化 < 0.001 且 maxWidth 未变且颜色未变时跳过 set text + layout
    // 新增：line 引用变化时强制 set text + layout，避免 useDuetLayout 切换后
    // _painter 缓存旧文本（带「男：」前缀）导致 alignment 计算用错误宽度
    final bool colorChanged = textColorValue != _lastTextColorValue;
    final bool lineChanged = !identical(_boundLine, line);
    // 临时调试：行切换时打印换行分析（定位歌词重叠）
    if (lineChanged) {
      _debugLogWrap(line, fontSize, maxWidth);
    }
    // alignment 变化时也强制重建（避免 _painter 缓存旧 textAlign 影响多行对齐）
    final bool alignChanged = _lastAlignment != alignment;
    // 字重变化时也强制重建（字重影响字形宽度/换行）
    final bool fontWeightChanged = LyricLayout.fontWeight != _lastFontWeight;
    if (lineChanged ||
        (_currentAlpha - _lastSetAlpha).abs() > 0.001 ||
        maxWidth != _lastSetMaxWidth ||
        colorChanged ||
        alignChanged ||
        fontWeightChanged) {
      _painter.text = TextSpan(
        text: line.text,
        style: TextStyle(
          // 文字颜色从 LyricLayout 获取，支持主题动态切换；
          // 当前行动态字体颜色时用混色后的 RGB
          color: Color.fromRGBO(textRed, textGreen, textBlue, _currentAlpha),
          fontSize: fontSize,
          height: LyricLayout.lineHeight,
          // 显式注入歌词 fontFamily（system 模式为 null，走系统字体链）
          fontFamily: LyricLayout.fontFamily,
          fontWeight: LyricLayout.fontWeight,
        ),
      );
      _painter.layout(
          maxWidth: maxWidth == double.infinity ? double.infinity : maxWidth);
      _lastSetAlpha = _currentAlpha;
      _lastSetMaxWidth = maxWidth;
      _lastTextColorValue = textColorValue;
      _boundLine = line;
      _lastAlignment = alignment;
      _lastFontWeight = LyricLayout.fontWeight;
    }
    // 用 _alignX 计算文本起始 x，与 WordRenderer 一致。
    // 单行：直接用 _painter.width（layout 后的整体宽度）计算 x。
    // 多行：按视觉行拆分绘制，每行独立对齐。
    // 多行判定：KRC 行（有 word）用 word 累加行数（与 measureLineHeight 一致），
    // 纯文本/LRC 行用 TextPainter 整行高度（与 measure 的 TextPainter 换行一致）。
    final bool isMultiLine = line.hasWordTiming
        ? _wordAccumulateRowStarts(line, fontSize, maxWidth).length > 1
        : _painter.height > fontSize * LyricLayout.lineHeight * 1.5;
    if (!isMultiLine) {
      // 单行：直接用整体对齐 x
      final double x = _alignX(
          alignment, offset.dx, _painter.width, viewportWidth);
      _painter.paint(canvas, Offset(x, offset.dy));
      // 单行重置多行行数（防上次多行残留影响翻译副行高度计算）
      _lastMultiLineRowCount = 0;
    } else {
      // 多行：按行拆分绘制，每行独立对齐
      _paintMultiLineAligned(canvas, offset, line, fontSize, alignment,
          maxWidth, viewportWidth, textColorValue);
    }

    // 辅助副行（翻译或罗马音）：仅当前行 + 开关开启 + 有内容时绘制
    // 根据 displayMode 选择显示 translation 还是 roma
    // 副行字号为主行 70%，alpha 固定 translationOpacity（不随主行动画变化）
    final auxText = LyricPreferences.instance.displayMode == LyricDisplayMode.roma
        ? line.roma
        : line.translation;
    if (_isActive &&
        LyricPreferences.instance.showTranslation &&
        auxText != null &&
        auxText.isNotEmpty) {
      final transFontSize = LyricLayout.translationFontSize(fontSize);
      // 主文本实际高度（含换行）：与 measureLineHeight 的压缩模型一致。
      // TextPainter 整行高度是完整行高（每行 ≈ mainLineHeight），而
      // _lineHeights 对换行行按 0.8x 压缩，两者不一致会使翻译副行向下偏移
      // 与下一行歌词重叠——多行时用压缩高度反推。
      final double mainHeight = _lastMultiLineRowCount > 1
          ? fontSize * LyricLayout.lineHeight +
              (_lastMultiLineRowCount - 1) *
                  fontSize *
                  LyricLayout.lineHeight *
                  LyricLayout.wrapLineHeightFactor
          : _painter.height;
      // 主副行间留 0.3em 间隙，与 measureLineHeight 计算保持一致
      final transY = offset.dy + mainHeight + transFontSize * 0.3;
      _translationPainter.text = TextSpan(
        text: auxText,
        style: TextStyle(
          color: Color.fromRGBO(textRed, textGreen, textBlue, LyricLayout.translationOpacity),
          fontSize: transFontSize,
          height: LyricLayout.translationLineHeight,
          fontFamily: LyricLayout.fontFamily,
          fontWeight: LyricLayout.fontWeight,
        ),
      );
      _translationPainter.layout(
          maxWidth:
              maxWidth == double.infinity ? double.infinity : maxWidth);
      // 翻译副行对齐跟随原文，用 _alignX 计算起始 x
      final double transX = _alignX(alignment, offset.dx,
          _translationPainter.width, viewportWidth);
      // 多行翻译副行需设置 textAlign 让每条视觉行独立对齐到 transX
      _translationPainter.textAlign = _duetToTextAlign(alignment);
      _translationPainter.paint(canvas, Offset(transX, transY));
    }
  }

  /// 临时调试：打印行换行分析（word 累加 vs TextPainter 行数），定位歌词重叠。
  void _debugLogWrap(LyricLine line, double fontSize, double maxWidth) {
    final StringBuffer sb = StringBuffer();
    sb.write('[LyricWrap] LR hasWord=${line.hasWordTiming} '
        'text="${line.text}" maxW=${maxWidth.toStringAsFixed(1)} fs=$fontSize');
    if (line.hasWordTiming) {
      final List<int> starts =
          _wordAccumulateRowStarts(line, fontSize, maxWidth);
      sb.write(' wordRows=${starts.length}');
      final List<double> widths = _ensureWordWidths(line, fontSize);
      sb.write(' words[');
      for (int i = 0; i < line.words.length; i++) {
        sb.write('"${line.words[i].text}"(${widths[i].toStringAsFixed(1)}) ');
      }
      sb.write(']');
    } else {
      final TextPainter tp = TextPainter(
        text: TextSpan(
          text: line.text,
          style: TextStyle(
            fontSize: fontSize,
            height: LyricLayout.lineHeight,
            fontFamily: LyricLayout.fontFamily,
            fontWeight: LyricLayout.fontWeight,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: maxWidth);
      sb.write(' tpRows=${tp.computeLineMetrics().length}');
      tp.dispose();
    }
    // ignore: avoid_print
    print(sb.toString());
  }

  /// 多行文本按行独立对齐绘制：按视觉行拆分文本，每行用对应 x 偏移。
  void _paintMultiLineAligned(
      Canvas canvas, Offset offset, LyricLine line, double fontSize,
      DuetAlignment alignment, double maxWidth, double viewportWidth,
      int textColorValue) {
    final String text = line.text;
    final int textRed = (textColorValue >> 16) & 0xFF;
    final int textGreen = (textColorValue >> 8) & 0xFF;
    final int textBlue = textColorValue & 0xFF;
    // 拆分视觉行文本：
    // - KRC 行（有 word）：按 word 累加换行（与 measureLineHeight / WordRenderer
    //   完全一致的算法），保证非当前行行数与当前行、测量高度一致，避免重叠。
    // - 纯文本/LRC 行（无 word）：用 TextPainter getLineBoundary 自动换行
    //   （与 measure 的 TextPainter 换行一致）。
    final List<String> rowTexts;
    if (line.hasWordTiming) {
      final List<int> rowStarts = _wordAccumulateRowStarts(line, fontSize, maxWidth);
      rowTexts = <String>[];
      for (int r = 0; r < rowStarts.length; r++) {
        final ws = rowStarts[r];
        final we =
            r + 1 < rowStarts.length ? rowStarts[r + 1] : line.words.length;
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
        final boundary = _painter.getLineBoundary(TextPosition(offset: pos));
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
    // 每行独立绘制。
    // 换行行盒模型（与 LyricLayout.measureLineHeight 一致）：
    //   - 第 1 个视觉行（主行）：完整行高 mainLineHeight，从 offset.dy 开始；
    //   - 换行行：0.8x 行高（height = lineHeight × wrapLineHeightFactor），
    //     从主行底部（offset.dy + mainLineHeight）开始，后续每行再 +0.8x 行高。
    // 旧实现把每行都画在 i * wrapLineHeight 且用完整行高：行盒（≈mainLineHeight）
    // 大于 0.8x 间距导致相邻行盒重叠，且主行被压在 0.8x 位置与换行行错位。
    final double mainLineHeight = fontSize * LyricLayout.lineHeight;
    final double wrapLineHeight =
        mainLineHeight * LyricLayout.wrapLineHeightFactor;
    _lastMultiLineRowCount = rowTexts.length;
    for (int i = 0; i < rowTexts.length; i++) {
      final bool isFirstRow = i == 0;
      // 第 1 行完整行高；换行行 0.8x 行高（行盒=行距，避免行盒重叠）
      final double rowHeight = isFirstRow
          ? LyricLayout.lineHeight
          : LyricLayout.lineHeight * LyricLayout.wrapLineHeightFactor;
      _lineMeasurer.text = TextSpan(
        text: rowTexts[i],
        style: TextStyle(
          color: Color.fromRGBO(textRed, textGreen, textBlue, _currentAlpha),
          fontSize: fontSize,
          height: rowHeight,
          fontFamily: LyricLayout.fontFamily,
          fontWeight: LyricLayout.fontWeight,
        ),
      );
      _lineMeasurer.layout(maxWidth: double.infinity);
      final double x = _alignX(
          alignment, offset.dx, _lineMeasurer.width, viewportWidth);
      final double y = isFirstRow
          ? offset.dy
          : offset.dy + mainLineHeight + (i - 1) * wrapLineHeight;
      _lineMeasurer.paint(canvas, Offset(x, y));
    }
  }

  /// KRC 行 word 宽度测量（缓存，与 WordRenderer._wordWidths 同口径）。
  List<double> _ensureWordWidths(LyricLine line, double fontSize) {
    if (identical(_wordWidthsLine, line) &&
        _wordWidthsFontSize == fontSize &&
        _wordWidths.length == line.words.length) {
      return _wordWidths;
    }
    final List<double> widths = List<double>.filled(line.words.length, 0);
    for (int i = 0; i < line.words.length; i++) {
      final TextPainter p = TextPainter(
        text: TextSpan(
          text: line.words[i].text,
          style: TextStyle(
            fontSize: fontSize,
            height: LyricLayout.lineHeight,
            fontFamily: LyricLayout.fontFamily,
            fontWeight: LyricLayout.fontWeight,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      widths[i] = p.width;
      p.dispose();
    }
    _wordWidths = widths;
    _wordWidthsLine = line;
    _wordWidthsFontSize = fontSize;
    return _wordWidths;
  }

  /// 按 word 累加换行（与 measureLineHeight 逐字分支、WordRenderer 完全一致）：
  /// 返回每视觉行的起始 word 索引（首元素 0）。
  List<int> _wordAccumulateRowStarts(
      LyricLine line, double fontSize, double maxWidth) {
    final List<int> starts = <int>[0];
    if (line.words.isEmpty || maxWidth == double.infinity) return starts;
    final List<double> widths = _ensureWordWidths(line, fontSize);
    double dx = 0;
    for (int wi = 0; wi < line.words.length; wi++) {
      final double ww = widths[wi];
      if (dx + ww > maxWidth && dx > 0) {
        starts.add(wi);
        dx = 0;
      }
      dx += ww;
    }
    return starts;
  }

  /// 根据对唱对齐方式计算文本起始 x 坐标（与 [WordRenderer._alignX] 一致）。
  /// [leftPadding] 为左侧 1em 边距（即 offset.dx），右侧对称留白。
  double _alignX(DuetAlignment alignment, double leftPadding,
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

  /// 对唱对齐方式 → TextAlign 映射（用于多行翻译副行内部对齐）。
  /// left/defaultAlign → start（左对齐）
  /// right → end（右对齐）
  /// center → center（居中）
  static TextAlign _duetToTextAlign(DuetAlignment alignment) {
    switch (alignment) {
      case DuetAlignment.center:
        return TextAlign.center;
      case DuetAlignment.right:
        return TextAlign.end;
      default:
        return TextAlign.start;
    }
  }

  /// 重置状态：alpha 回到初始值（0.2），isActive=false。
  ///
  /// **v4 优化**：重置 alpha 缓存字段，下次 paintLine 会重新 set text + layout。
  void reset() {
    _isActive = false;
    _currentAlpha = LyricLayout.currentDarkAlpha;
    _targetAlpha = LyricLayout.currentDarkAlpha;
    _isConverged = true;
    _lastSetAlpha = -1;
    _lastSetMaxWidth = -1;
    _lastTextColorValue = -1;
    _lastFontWeight = FontWeight.normal;
    _boundLine = null;
    _activeColorValue = null;
    _lastAlignment = DuetAlignment.defaultAlign;
    // 同步重置 setLineState 输入缓存，避免 reset 后下次 setLineState 误命中早退
    _lastIsActive = false;
    _lastScale = double.nan;
    _lastBlurFade = double.nan;
    _lastBlurActive = false;
    _lastActiveColorValue = null;
  }
}
