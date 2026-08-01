/// 逐字 mask alpha 渲染器（核心渲染组件）
///
/// 参照 spec.md "Requirement: 逐字 mask alpha 渲染" 实现。
/// 文字本身固定白色，靠 mask alpha 区分已播 / 未播字：
/// - 当前行（GRADIENT 模式）：已播字 alpha = dynamicBrightAlpha，未播字 alpha = dynamicDarkAlpha，
///   当前字按指数衰减在两者之间过渡，左亮右暗。
/// - 非当前行（SOLID 模式）：整行均匀 alpha = dynamicDarkAlpha。
///
/// 本类不是 Widget，是核心绘制逻辑类，由外部 CustomPainter 调用 [paintLine]。
/// 动画驱动由外部 AnimationController + Ticker 调用 [tick] 实现（SubTask 7.7）。
library;

import 'dart:collection';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/widgets.dart';

import '../layout/duet_layout.dart';
import '../layout/lyric_layout.dart';
import '../layout/lyric_preferences.dart';
import '../models/lyric_line.dart';
import 'emphasize_effect.dart';

/// 逐字 mask alpha 渲染器。
///
/// 持有当前 scale、isActive、currentLineProgress 与每个 word 的当前 alpha 值，
/// 通过 [tick] 推进指数衰减动画，通过 [paintLine] 用对应 alpha 逐字绘制白色文本。
class WordRenderer {
  WordRenderer();

  // ============== 内部状态 ==============

  /// 当前是否为当前行（GRADIENT 模式）。默认 false（SOLID）。
  bool _isActive = false;

  /// 当前行缩放，0.97（inactive）~1.0（active）。默认 inactive。
  double _scale = LyricLayout.inactiveScale;

  /// 模糊淡入淡出系数：1.0=正常模糊，0.0=无模糊。
  double _blurFade = 1.0;

  /// 当前绑定的 LyricLine。用于检测 line 切换并重置 alpha map。
  LyricLine? _boundLine;

  /// 缓存的字号（用于检测 fontSize 变化时重新测量 word 宽度）。
  double _boundFontSize = -1;

  /// 每个 word 的缓存宽度（在 [_ensureBound] 时一次性测量）。
  ///
  /// **性能优化**：之前每帧 paintLine 都为每个 word 创建 TextPainter + layout
  /// 来测量宽度（用于换行判断）。现在只在 line 切换或 fontSize 变化时测量一次。
  /// 10 word/行 × 60fps = 每秒 600 次 layout → 缓存后降为 0 次/帧。
  List<double> _wordWidths = const <double>[];

  /// v4 优化：per-word TextPainter 实例列表。
  ///
  /// **背景**：v3 Task 1 用单实例 _painter + _lastSetAlphas 缓存导致"当前行重复显示同一字"bug
  /// （commit b56b7e9 已回滚）。根因：单实例 _painter 在循环中被多个 word 共用，下一个 word 的
  /// set text 会覆盖 painter.text，导致 _lastSetAlphas[i] 比较时基于"上次循环的最后一个 word"
  /// 状态而非该 word 自身上次状态。
  /// **v4 解决方案**：每个 word 独占一个 TextPainter 实例，alpha 不变时跳过 set text + layout 是安全的。
  /// 10 word/行 × 60fps = 每秒 600 次 layout → 缓存后降到 ~100-200 次/秒
  /// （仅当前字 + 边界附近 word 在过渡）。
  List<TextPainter> _wordPainters = const <TextPainter>[];

  /// v4 优化：每个 word index 上次设置的 alpha。
  /// 仅在 alpha 变化时才 set text + layout，避免每帧 N 次 layout。
  final Map<int, double> _lastSetAlphas = <int, double>{};

  /// 每个 word index 的当前 alpha 值。
  final Map<int, double> _wordAlphas = <int, double>{};

  /// v3 优化：renderer 是否已收敛（alpha 和 Y offset 都不再变化）。
  /// 用于 AppleLyricsView 判断是否可以停止 Ticker。
  bool _isConverged = true;

  /// 每个 word index 的当前 Y 轴偏移（上浮特效）。
  ///
  /// AMLL 规范：当前字会轻微上浮（最大约 -3px），用指数衰减平滑过渡。
  /// 已播字回到 0，未播字保持 0，当前字上浮。
  final Map<int, double> _wordYOffsets = <int, double>{};

  /// AMLL 上浮最大幅度（px）：当前字最大上浮 -3px。
  static const double _maxLiftPx = -3.0;

  /// AMLL 上浮 ATTACK 速度：当前字上浮指数衰减系数。
  static const double _liftAttackSpeed = 30.0;

  /// AMLL 上浮 RELEASE 速度：当前字回落指数衰减系数。
  static const double _liftReleaseSpeed = 10.0;

  /// 强调辉光效果计算器（由外部注入）。
  EmphasizeEffect? _emphasizeEffect;

  /// 每个 word index 的当前辉光状态。
  final Map<int, EmphasizeState> _emphasizeStates = <int, EmphasizeState>{};

  /// 行级元数据判定缓存（行绑定期计算一次）。
  /// true 表示该行为元数据行（作词/作曲 等），整行禁用辉光。
  /// 仅依赖 [LyricLine.text]，在 [_ensureBound] 时计算，避免每帧重复正则匹配。
  bool _isMetadataLine = false;

  /// 上次 set text 时的文字颜色值。
  /// 主题切换时 textColorValue 变化，需清空 _lastSetAlphas 强制重建所有 word TextSpan。
  int _lastTextColorValue = -1;

  /// 每字辉光判定缓存（行绑定期计算一次）。
  /// 与 [_wordPainters] / [_wordWidths] 同长度同索引。
  /// true 表示该 word 应触发辉光（已通过 duration + 内容过滤）。
  /// 仅依赖 [LyricWord.text] 与 [LyricWord.duration]，在 [_ensureBound] 时计算。
  List<bool> _wordEmphasisFlags = const <bool>[];

  /// 翻译副行专用 TextPainter（复用避免每帧创建，仅 active 行使用）。
  final TextPainter _translationPainter =
      TextPainter(textDirection: TextDirection.ltr);

  // ============== 状态查询 ==============

  /// 当前 alpha map（不可变视图，供测试断言）。
  ///
  /// 使用 [UnmodifiableMapView] 包装，外部只读，修改不影响内部状态。
  @visibleForTesting
  Map<int, double> get wordAlphas =>
      UnmodifiableMapView<int, double>(_wordAlphas);

  /// 当前 scale 对应的 factor（0~1）。
  ///
  /// 公式：`factor = clamp01((scale - 0.97) / 0.03)`
  double get factor {
    final raw = (_scale - LyricLayout.inactiveScale) /
        (LyricLayout.activeScale - LyricLayout.inactiveScale);
    return raw.clamp(0.0, 1.0).toDouble();
  }

  /// 动态暗态 alpha（未播字 / 非当前行 SOLID）。
  ///
  /// 公式：`dynamicDarkAlpha = factor * 0.2 + 0.2`，范围 0.2~0.4。
  double get dynamicDarkAlpha => factor * 0.2 + 0.2;

  /// 动态亮态 alpha（已播字 / 当前字目标）。
  ///
  /// 公式：`dynamicBrightAlpha = factor * 0.8 + 0.2`，范围 0.2~1.0。
  double get dynamicBrightAlpha => factor * 0.8 + 0.2;

  /// 当前是否为当前行。
  bool get isActive => _isActive;

  /// v3 优化：renderer 是否已收敛（alpha 和 Y offset 都不再变化）。
  /// 用于 AppleLyricsView 判断是否可以停止 Ticker。
  bool get isConverged => _isConverged;

  // ============== 状态设置 ==============

  /// 设置当前行状态。
  ///
  /// [isActive] 为 true 时启用 GRADIENT 模式（已播亮 / 未播暗），
  /// 为 false 时启用 SOLID 模式（整行均匀暗）。
  /// [scale] 是行缩放，0.97（inactive）~1.0（active）。
  /// [blurFade] 控制非当前行透明度：1.0=透明（模糊图片覆盖），0.0=正常显示。
  /// [blurActive] 是否启用高斯模糊：false 时不降低非当前行透明度。
  void setLineState({required bool isActive, required double scale, double blurFade = 1.0, bool blurActive = true}) {
    _isActive = isActive;
    _scale = scale;
    _blurFade = blurActive ? blurFade : 0.0;
  }

  /// 设置强调辉光效果计算器。
  set emphasizeEffect(EmphasizeEffect? effect) => _emphasizeEffect = effect;

  // ============== 动画推进 ==============

  /// 推进动画。
  ///
  /// [dt] 距上一帧的时间间隔（秒）。[currentTimeMs] 当前播放位置（毫秒），
  /// 用于根据每个 word 的 [LyricWord.startTime] / [LyricWord.duration]
  /// 精确判断当前正在演唱的 word 及 word 内进度。
  /// 用指数衰减公式 `alpha += (target - alpha) * (1 - exp(-speed * dt))`
  /// 平滑过渡：变亮用 [LyricLayout.attackSpeed]（50.0），变暗用 [LyricLayout.releaseSpeed]（7.0）。
  /// 差值小于 [LyricLayout.alphaEpsilon]（0.001）时吸附到目标。
  void tick(double dt, int currentTimeMs) {
    if (dt <= 0) return;
    if (_boundLine == null || _boundLine!.words.isEmpty) return;

    final double dark = dynamicDarkAlpha;
    final double bright = dynamicBrightAlpha;
    final words = _boundLine!.words;
    final int wordCount = words.length;

    // 找到当前正在演唱的 word 索引及 word 内进度
    int currentWordIdx = -1;
    double intraWordProgress = 0.0;

    for (int i = 0; i < wordCount; i++) {
      final w = words[i];
      if (currentTimeMs >= w.startTime &&
          currentTimeMs < w.startTime + w.duration) {
        currentWordIdx = i;
        intraWordProgress = w.duration > 0
            ? ((currentTimeMs - w.startTime) / w.duration).clamp(0.0, 1.0)
            : 0.0;
        break;
      } else if (currentTimeMs >= w.startTime + w.duration &&
          (i == wordCount - 1 || currentTimeMs < words[i + 1].startTime)) {
        // 当前 word 已结束，下一个 word 还没开始 → 保持当前 word 为"已播"
        currentWordIdx = i;
        intraWordProgress = 1.0;
      }
    }

    // 如果 currentTimeMs 在所有 word 之前，第一个 word 为当前
    if (currentWordIdx == -1 && wordCount > 0 && currentTimeMs < words[0].startTime) {
      currentWordIdx = 0;
      intraWordProgress = 0.0;
    }

    // 行级辉光判定（循环外计算一次）：
    // _isMetadataLine 在 _ensureBound 时缓存（行切换时才更新）；
    // _isActive / useGlowEffect / _emphasizeEffect 运行时可变，每帧检查。
    final bool skipLineEmphasis = _emphasizeEffect == null ||
        !_isActive ||
        !LyricPreferences.instance.useGlowEffect ||
        _isMetadataLine;

    bool anyChanged = false;
    for (int i = 0; i < wordCount; i++) {
      final double target = _targetAlphaForExact(i, currentWordIdx, intraWordProgress, dark, bright);
      final double current = _wordAlphas[i] ?? dark;
      final double speed = target >= current
          ? LyricLayout.attackSpeed
          : LyricLayout.releaseSpeed;
      final double decay = 1.0 - exp(-speed * dt);
      double next = current + (target - current) * decay;
      if ((next - target).abs() < LyricLayout.alphaEpsilon) {
        next = target;
      }
      if ((next - current).abs() > 1e-6) anyChanged = true;
      _wordAlphas[i] = next;

      // AMLL 上浮特效
      final double targetY = _targetYOffsetForExact(i, currentWordIdx, intraWordProgress);
      final double currentY = _wordYOffsets[i] ?? 0;
      final double ySpeed = targetY >= currentY
          ? _liftAttackSpeed
          : _liftReleaseSpeed;
      final double yDecay = 1.0 - exp(-ySpeed * dt);
      double nextY = currentY + (targetY - currentY) * yDecay;
      if ((nextY - targetY).abs() < LyricLayout.alphaEpsilon) {
        nextY = targetY;
      }
      if ((nextY - currentY).abs() > 1e-6) anyChanged = true;
      _wordYOffsets[i] = nextY;

      // 强调辉光效果：改用缓存的 _wordEmphasisFlags[i] 替代每帧调用 shouldEmphasize。
      // 字级判定（含正则匹配）在 _ensureBound 时已缓存，此处仅 O(1) 数组读取。
      final LyricWord emWord = words[i];
      if (!skipLineEmphasis && _wordEmphasisFlags[i]) {
        _emphasizeStates[i] = _emphasizeEffect!.computeState(
          word: emWord,
          currentTimeMs: currentTimeMs,
          isLastWord: i == wordCount - 1,
          wordIndex: i,
          anchorCharCount: emWord.text.runes.length,
        );
      } else {
        _emphasizeStates[i] = EmphasizeState.idle;
      }
    }
    // v3 优化：跟踪 alpha/Y offset 是否仍在变化（用于 AppleLyricsView 判断停止 Ticker）
    _isConverged = !anyChanged;
  }

  /// 计算指定 word index 的目标 Y 偏移（AMLL 上浮特效），基于逐字时间戳。
  ///
  /// - 非当前行：所有 word Y=0。
  /// - 当前行：
  ///   - 已播字（index < currentWordIdx）：Y=_maxLiftPx（保持上浮）。
  ///   - 当前字（index == currentWordIdx）：按 word 内进度 smoothstep 上浮。
  ///   - 未播字（index > currentWordIdx）：Y=0。
  double _targetYOffsetForExact(int index, int currentWordIdx, double intraWordProgress) {
    if (!_isActive) return 0;
    if (index < currentWordIdx) {
      return _maxLiftPx;
    }
    if (index == currentWordIdx) {
      final double eased = intraWordProgress * intraWordProgress * (3 - 2 * intraWordProgress);
      return _maxLiftPx * eased;
    }
    return 0;
  }

  /// 计算指定 word index 的目标 alpha，基于逐字时间戳。
  ///
  /// - 非当前行：alpha = dynamicDarkAlpha * (1 - blurFade)。
  ///   blurFade=1 时 alpha=0（模糊图片覆盖），blurFade=0 时正常显示。
  /// - 当前行：
  ///   - 已播字（index < currentWordIdx）目标 = [dynamicBrightAlpha]。
  ///   - 未播字（index > currentWordIdx）目标 = [dynamicDarkAlpha]。
  ///   - 当前字（index == currentWordIdx）按 word 内进度在 dark~bright 之间线性插值。
  double _targetAlphaForExact(
      int index, int currentWordIdx, double intraWordProgress, double dark, double bright) {
    if (!_isActive) return dark * (1.0 - _blurFade);
    if (index < currentWordIdx) {
      return bright;
    } else if (index > currentWordIdx) {
      return dark;
    } else {
      return dark + (bright - dark) * intraWordProgress;
    }
  }

  // ============== 绘制 ==============

  /// 绘制单行歌词。
  ///
  /// [offset] 是行起始绘制原点。文字颜色固定白色 #FFFFFFFF，
  /// 通过逐字 alpha 区分已播 / 未播。
  ///
  /// [maxWidth] 为该行可用最大文字宽度（视口宽 - 左右 1em 边距）。
  /// 当 word 累加 dx 超过 [maxWidth] 且 dx > 0 时换行：
  /// dx 归零，currentY += mainLineHeight × wrapLineHeightFactor（0.8x 行高）。
  ///
  /// **性能优化**：
  /// - word 宽度用 [_wordWidths] 缓存（[_ensureBound] 时一次性测量），
  ///   换行判断不再每帧创建 TextPainter + layout
  /// - **v4 优化**：per-word TextPainter 实例 + alpha 缓存。
  ///   仅在 alpha 变化时才 set text + layout，alpha 不变时直接 paint。
  ///   这与 v3 Task 1 共享 painter 不同：每个 word 独占一个 TextPainter 实例，
  ///   不会出现"下一个 word 覆盖 painter.text 导致 _lastSetAlphas[i] 错乱"的 bug。
  void paintLine(
      Canvas canvas, Offset offset, LyricLine line, double fontSize,
      {double maxWidth = double.infinity,
      DuetAlignment alignment = DuetAlignment.defaultAlign,
      double viewportWidth = 0}) {
    _ensureBound(line, fontSize);

    // 主题切换时 textColorValue 变化，清空 alpha 缓存强制重建所有 word TextSpan
    if (LyricLayout.textColorValue != _lastTextColorValue) {
      _lastSetAlphas.clear();
      _lastTextColorValue = LyricLayout.textColorValue;
    }

    if (line.words.isEmpty) {
      _paintSolidFallback(canvas, offset, line, fontSize,
          maxWidth: maxWidth, alignment: alignment, viewportWidth: viewportWidth);
      return;
    }

    // 对唱对齐：预扫描每视觉行的 word 宽度，换行时重算 baseX
    // _visualLineWidths[i] = 第 i 条视觉行的 word 累计宽度
    final List<double> visualLineWidths = _computeVisualLineWidths(maxWidth);
    int visualLineIndex = 0;
    double baseX = _alignX(alignment, offset.dx,
        visualLineWidths.isNotEmpty ? visualLineWidths[0] : 0, viewportWidth);

    double dx = 0; // 相对 baseX 的水平偏移
    double currentY = offset.dy; // 当前视觉行的 y 坐标
    final double dark = dynamicDarkAlpha;
    // 换行内部行高 = 主行高 × 0.8（与 LyricLayout.measureLineHeight 一致）
    final double wrapLineHeight =
        fontSize * LyricLayout.lineHeight * LyricLayout.wrapLineHeightFactor;
    final double lineHeight = LyricLayout.lineHeight;

    for (int i = 0; i < line.words.length; i++) {
      final LyricWord word = line.words[i];
      final double alpha = _wordAlphas[i] ?? dark;
      // AMLL 上浮特效：当前字 Y 偏移（上浮）
      final double yOffset = _wordYOffsets[i] ?? 0;
      // 强调辉光状态
      final EmphasizeState emState = _emphasizeStates[i] ?? EmphasizeState.idle;
      // 用缓存宽度做换行判断（避免每帧 TextPainter.layout 测量）
      final double width =
          i < _wordWidths.length ? _wordWidths[i] : 0;
      // 自动换行：累计宽度超过 maxWidth 且本视觉行已有 word 时换行
      if (dx + width > maxWidth && dx > 0) {
        dx = 0;
        currentY += wrapLineHeight;
        // 换行后重算对齐 baseX
        visualLineIndex++;
        if (visualLineIndex < visualLineWidths.length) {
          baseX = _alignX(alignment, offset.dx,
              visualLineWidths[visualLineIndex], viewportWidth);
        }
      }

      final double wordX = baseX + dx;
      final double wordY = currentY + yOffset;
      final Offset wordPos = Offset(wordX, wordY);

      // **v4 性能优化**：per-word TextPainter + alpha 缓存。
      // 仅在 alpha 变化时才 set text + layout，alpha 不变时直接 paint。
      final painter = _wordPainters[i];
      if (_lastSetAlphas[i] != alpha) {
        painter.text = TextSpan(
          text: word.text,
          style: TextStyle(
            color: Color.fromRGBO(LyricLayout.textRed, LyricLayout.textGreen, LyricLayout.textBlue, alpha),
            fontSize: fontSize,
            height: lineHeight,
            // 显式注入歌词 fontFamily，与测量路径保持一致
            fontFamily: LyricLayout.fontFamily,
          ),
        );
        painter.layout();
        _lastSetAlphas[i] = alpha;
      }

      // 应用强调辉光效果：per-word scale + glow shadow
      if (emState.scale != 1.0 || emState.glowLevel > 0) {
        canvas.save();
        // 以 word 中心为缩放锚点
        final double centerX = wordX + width / 2;
        final double centerY = wordY + fontSize * lineHeight / 2;
        canvas.translate(centerX, centerY);
        canvas.scale(emState.scale, emState.scale);
        canvas.translate(-centerX, -centerY);

        // 绘制辉光层：saveLayer + ImageFilter.blur
        if (emState.glowLevel > 0) {
          final double blurSigma = emState.shadowBlurEm * fontSize * 0.8;
          if (blurSigma > 0) {
            final glowRect = Rect.fromLTWH(
              wordX - blurSigma * 2, wordY - blurSigma * 2,
              width + blurSigma * 4, fontSize * lineHeight + blurSigma * 4,
            );
            canvas.saveLayer(
              glowRect,
              Paint()..imageFilter = ImageFilter.blur(
                sigmaX: blurSigma, sigmaY: blurSigma,
              ),
            );
            painter.paint(canvas, wordPos);
            canvas.restore();
          }
        }

        // 绘制正常文字层
        painter.paint(canvas, wordPos);
        canvas.restore();
      } else {
        // 无辉光：直接绘制
        painter.paint(canvas, wordPos);
      }

      dx += width;
    }

    // 辅助副行（翻译或罗马音）：WordRenderer 仅在当前行（KRC）被调用，故无需再判 _isActive。
    // 根据 displayMode 选择显示 translation 还是 roma
    // 副行字号为主行 70%，alpha 固定 translationOpacity（不随逐字 mask 变化）。
    final auxText = LyricPreferences.instance.displayMode == LyricDisplayMode.roma
        ? line.roma
        : line.translation;
    if (LyricPreferences.instance.showTranslation &&
        auxText != null &&
        auxText.isNotEmpty) {
      final transFontSize = LyricLayout.translationFontSize(fontSize);
      // currentY 是循环结束后的最后视觉行 Y；副行 Y = currentY + 主行高 + 0.3em 间隙
      final transY =
          currentY + fontSize * LyricLayout.lineHeight + transFontSize * 0.3;
      _translationPainter.text = TextSpan(
        text: auxText,
        style: TextStyle(
          color: Color.fromRGBO(LyricLayout.textRed, LyricLayout.textGreen, LyricLayout.textBlue, LyricLayout.translationOpacity),
          fontSize: transFontSize,
          height: LyricLayout.translationLineHeight,
          fontFamily: LyricLayout.fontFamily,
        ),
      );
      _translationPainter.layout(
          maxWidth:
              maxWidth == double.infinity ? double.infinity : maxWidth);
      // 翻译副行对齐跟随原文，按副行自身宽度计算 x
      final double transX = _alignX(alignment, offset.dx,
          _translationPainter.width, viewportWidth);
      // 多行翻译副行需设置 textAlign 让每条视觉行独立对齐到 transX
      // 单行时 textAlign 不影响，_alignX 已计算正确 x
      _translationPainter.textAlign = _duetToTextAlign(alignment);
      _translationPainter.paint(canvas, Offset(transX, transY));
    }
  }

  /// 按换行逻辑预扫描，计算每条视觉行的 word 累计宽度。
  /// 与 paintLine 循环中的换行判断一致：dx + width > maxWidth 且 dx > 0 时换行。
  List<double> _computeVisualLineWidths(double maxWidth) {
    final List<double> widths = <double>[];
    double dx = 0;
    double lineW = 0;
    for (int i = 0; i < _wordWidths.length; i++) {
      final w = _wordWidths[i];
      if (dx + w > maxWidth && dx > 0) {
        widths.add(lineW);
        dx = 0;
        lineW = 0;
      }
      dx += w;
      lineW += w;
    }
    if (lineW > 0) widths.add(lineW);
    return widths;
  }

  /// 根据对唱对齐方式计算文本起始 x 坐标。
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

  /// 整行降级绘制（无 word 时间戳时使用）。
  ///
  /// [maxWidth] 用于自动换行（默认 [double.infinity] 不换行）。
  /// 用临时 TextPainter 实例（仅在 fallback 路径，频率低不缓存）。
  void _paintSolidFallback(
      Canvas canvas, Offset offset, LyricLine line, double fontSize,
      {double maxWidth = double.infinity,
      DuetAlignment alignment = DuetAlignment.defaultAlign,
      double viewportWidth = 0}) {
    if (line.text.isEmpty) return;
    final double alpha = dynamicDarkAlpha;
    final painter = TextPainter(textDirection: TextDirection.ltr);
    painter.text = TextSpan(
      text: line.text,
      style: TextStyle(
        color: Color.fromRGBO(LyricLayout.textRed, LyricLayout.textGreen, LyricLayout.textBlue, alpha),
        fontSize: fontSize,
        height: LyricLayout.lineHeight,
        // 显式注入歌词 fontFamily，与 paintLine 路径保持一致
        fontFamily: LyricLayout.fontFamily,
      ),
    );
    painter.layout(
        maxWidth: maxWidth == double.infinity ? double.infinity : maxWidth);
    final double x = _alignX(alignment, offset.dx, painter.width, viewportWidth);
    painter.paint(canvas, Offset(x, offset.dy));
    painter.dispose();
  }

  /// 检测 line 切换并重置 alpha map，同时测量并缓存所有 word 宽度。
  ///
  /// 若传入的 line 与当前绑定不是同一对象引用（[identical] 失败），
  /// 或 fontSize 变化，重新初始化每个 word 的 alpha 为 [dynamicDarkAlpha]，
  /// 并测量每个 word 的宽度缓存到 [_wordWidths]。
  ///
  /// **v4 性能优化**：
  /// - 用 per-word TextPainter 实例列表替代共享 _painter
  /// - word 宽度只在此时测量一次，paintLine 用缓存宽度做换行判断
  /// - _lastSetAlphas 在 line 切换时清空，强制下次 paintLine 重新 set text + layout
  void _ensureBound(LyricLine line, double fontSize) {
    final sameLine = identical(_boundLine, line);
    final sameFontSize = _boundFontSize == fontSize;
    if (sameLine && sameFontSize && _wordPainters.length == line.words.length) {
      return; // 缓存命中
    }
    _boundLine = line;
    _boundFontSize = fontSize;
    _wordAlphas.clear();
    _wordYOffsets.clear();
    _emphasizeStates.clear();
    _lastSetAlphas.clear(); // v4 优化：line 切换时清空 alpha 缓存

    // 行级元数据判定缓存：作词/作曲/编曲 等元数据行整行禁用辉光。
    // 仅依赖 line.text（行绑定后不变），此处计算一次，tick 中仅读取字段。
    _isMetadataLine = EmphasizeEffect.shouldSkipEmphasizeForLine(line);

    // 释放旧 _wordPainters（line 缩短时避免泄漏）
    for (final painter in _wordPainters) {
      painter.dispose();
    }

    final double dark = dynamicDarkAlpha;
    // 测量所有 word 宽度并初始化 per-word TextPainter
    _wordWidths = List<double>.filled(line.words.length, 0);
    _wordPainters = List<TextPainter>.generate(
      line.words.length,
      (_) => TextPainter(textDirection: TextDirection.ltr),
    );
    // 预分配辉光判定缓存数组（与 _wordPainters 同长度同索引）
    _wordEmphasisFlags = List<bool>.filled(line.words.length, false);
    for (int i = 0; i < line.words.length; i++) {
      _wordPainters[i].text = TextSpan(
        text: line.words[i].text,
        style: TextStyle(
          fontSize: fontSize,
          height: LyricLayout.lineHeight,
          // 显式注入歌词 fontFamily，必须与 paintLine 渲染路径一致，
          // 否则 word 宽度测量会出错导致换行错位
          fontFamily: LyricLayout.fontFamily,
        ),
      );
      _wordPainters[i].layout();
      _wordWidths[i] = _wordPainters[i].width;
      _wordAlphas[i] = dark;
      _wordYOffsets[i] = 0;
      // 缓存该 word 的辉光判定结果（含正则匹配，仅在此执行一次）
      // tick 中通过 _wordEmphasisFlags[i] O(1) 读取，避免每帧重复正则匹配
      _wordEmphasisFlags[i] = EmphasizeEffect.shouldEmphasize(line.words[i]);
      // _lastSetAlphas[i] 不设置（默认 null），下次 paintLine 会重新 set text + layout
    }
  }

  /// 重置状态：清空 alpha map、Y 偏移、归零 progress、scale 回到 inactive、isActive=false、解绑 line。
  ///
  /// **v4 优化**：dispose 所有 per-word TextPainter 实例避免内存泄漏。
  void reset() {
    _isActive = false;
    _scale = LyricLayout.inactiveScale;
    _boundLine = null;
    _boundFontSize = -1;
    _wordWidths = const <double>[];
    // 清理辉光判定缓存
    _wordEmphasisFlags = const <bool>[];
    _isMetadataLine = false;
    // v4 优化：dispose per-word TextPainter 实例
    for (final painter in _wordPainters) {
      painter.dispose();
    }
    _wordPainters = const <TextPainter>[];
    _wordAlphas.clear();
    _wordYOffsets.clear();
    _emphasizeStates.clear();
    _lastSetAlphas.clear();
  }
}
