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

  /// 复用的 TextPainter 实例（避免每帧创建对象）。
  ///
  /// 注意：text setter 会标记需要 layout，所以 layout 还是要做，
  /// 但省了 TextPainter 对象创建+GC 的开销。
  final TextPainter _painter = TextPainter(textDirection: TextDirection.ltr);

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

      // 强调辉光效果：计算每个 word 的 EmphasizeState
      final LyricWord emWord = words[i];
      if (_emphasizeEffect != null && _isActive && LyricPreferences.instance.useGlowEffect) {
        final bool shouldEm = EmphasizeEffect.shouldEmphasize(emWord);
        if (shouldEm) {
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
  /// - 复用 [_painter] 实例，避免每帧创建对象（layout 还是要做，
  ///   因为 alpha 变了需要重新设置 TextSpan，但省了对象创建+GC）
  void paintLine(
      Canvas canvas, Offset offset, LyricLine line, double fontSize,
      {double maxWidth = double.infinity}) {
    _ensureBound(line, fontSize);

    if (line.words.isEmpty) {
      _paintSolidFallback(canvas, offset, line, fontSize, maxWidth: maxWidth);
      return;
    }

    double dx = 0; // 相对 offset.dx 的水平偏移
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
      }

      final double wordX = offset.dx + dx;
      final double wordY = currentY + yOffset;
      final Offset wordPos = Offset(wordX, wordY);

      // 设置文字样式 + layout。
      // 注意：_painter 在循环里被多个 word 共用，每次循环到新 word 都必须重新
      // set text + layout，否则 painter 仍保留上一个 word 的 text。
      // v3 实测发现按 alpha 缓存跳过 set text 会引入"当前行重复显示同一字"的 bug，
      // 已回滚到 v2 行为（每次 set text + layout）。
      _painter.text = TextSpan(
        text: word.text,
        style: TextStyle(
          color: Color.fromRGBO(255, 255, 255, alpha),
          fontSize: fontSize,
          height: lineHeight,
          // 显式注入歌词 fontFamily，与测量路径保持一致
          fontFamily: LyricLayout.fontFamily,
        ),
      );
      _painter.layout();

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
            _painter.paint(canvas, wordPos);
            canvas.restore();
          }
        }

        // 绘制正常文字层
        _painter.paint(canvas, wordPos);
        canvas.restore();
      } else {
        // 无辉光：直接绘制
        _painter.paint(canvas, wordPos);
      }

      dx += width;
    }
  }

  /// 整行降级绘制（无 word 时间戳时使用）。
  ///
  /// [maxWidth] 用于自动换行（默认 [double.infinity] 不换行）。
  /// 复用 [_painter] 实例避免对象创建。
  void _paintSolidFallback(
      Canvas canvas, Offset offset, LyricLine line, double fontSize,
      {double maxWidth = double.infinity}) {
    if (line.text.isEmpty) return;
    final double alpha = dynamicDarkAlpha;
    _painter.text = TextSpan(
      text: line.text,
      style: TextStyle(
        color: Color.fromRGBO(255, 255, 255, alpha),
        fontSize: fontSize,
        height: LyricLayout.lineHeight,
        // 显式注入歌词 fontFamily，与 paintLine 路径保持一致
        fontFamily: LyricLayout.fontFamily,
      ),
    );
    _painter.layout(
        maxWidth: maxWidth == double.infinity ? double.infinity : maxWidth);
    _painter.paint(canvas, offset);
  }

  /// 检测 line 切换并重置 alpha map，同时测量并缓存所有 word 宽度。
  ///
  /// 若传入的 line 与当前绑定不是同一对象引用（[identical] 失败），
  /// 或 fontSize 变化，重新初始化每个 word 的 alpha 为 [dynamicDarkAlpha]，
  /// 并测量每个 word 的宽度缓存到 [_wordWidths]。
  ///
  /// **性能优化**：word 宽度只在此时测量一次，paintLine 用缓存宽度做换行判断，
  /// 避免每帧创建 N 个 TextPainter + layout。
  void _ensureBound(LyricLine line, double fontSize) {
    final sameLine = identical(_boundLine, line);
    final sameFontSize = _boundFontSize == fontSize;
    if (sameLine && sameFontSize) return;
    _boundLine = line;
    _boundFontSize = fontSize;
    _wordAlphas.clear();
    _wordYOffsets.clear();
    _emphasizeStates.clear();
    final double dark = dynamicDarkAlpha;
    // 测量所有 word 宽度并缓存
    _wordWidths = List<double>.filled(line.words.length, 0);
    for (int i = 0; i < line.words.length; i++) {
      _painter.text = TextSpan(
        text: line.words[i].text,
        style: TextStyle(
          fontSize: fontSize,
          height: LyricLayout.lineHeight,
          // 显式注入歌词 fontFamily，必须与 paintLine 渲染路径一致，
          // 否则 word 宽度测量会出错导致换行错位
          fontFamily: LyricLayout.fontFamily,
        ),
      );
      _painter.layout();
      _wordWidths[i] = _painter.width;
      _wordAlphas[i] = dark;
      _wordYOffsets[i] = 0;
    }
  }

  /// 重置状态：清空 alpha map、Y 偏移、归零 progress、scale 回到 inactive、isActive=false、解绑 line。
  void reset() {
    _isActive = false;
    _scale = LyricLayout.inactiveScale;
    _boundLine = null;
    _boundFontSize = -1;
    _wordWidths = const <double>[];
    _wordAlphas.clear();
    _wordYOffsets.clear();
    _emphasizeStates.clear();
  }
}
