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

import 'dart:math';
import 'dart:ui';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../layout/duet_layout.dart';
import '../layout/lyric_layout.dart';
import '../layout/lyric_preferences.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
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

  /// v4 优化：每个 word index 上次设置的 alpha（量化步进值）。
  /// 仅在量化值变化时才 set text + layout，避免每帧 N 次 layout。
  List<int> _lastSetAlphas = const <int>[];

  /// 每个 word index 的当前 alpha 值。
  List<double> _wordAlphas = const <double>[];

  /// v3 优化：renderer 是否已收敛（alpha 和 Y offset 都不再变化）。
  /// 用于 AppleLyricsView 判断是否可以停止 Ticker。
  bool _isConverged = true;

  /// 每个 word index 的当前 Y 轴偏移（上浮特效）。
  ///
  /// AMLL 规范：当前字会轻微上浮（最大约 -3px），用指数衰减平滑过渡。
  /// 已播字回到 0，未播字保持 0，当前字上浮。
  List<double> _wordYOffsets = const <double>[];

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

  /// 当前行专用的文字颜色（ARGB int，仅 [_isActive] 时生效）。
  /// 动态字体颜色：由封面提取色按「70% 白 + 30% 提取色」混色得到，
  /// null 表示不使用（回退到 LyricLayout.textColorValue）。
  int? _activeColorValue;

  /// 每字辉光判定缓存（行绑定期计算一次）。
  /// 与 [_wordPainters] / [_wordWidths] 同长度同索引。
  /// true 表示该 word 应触发辉光（已通过 duration + 内容过滤）。
  /// 仅依赖 [LyricWord.text] 与 [LyricWord.duration]，在 [_ensureBound] 时计算。
  List<bool> _wordEmphasisFlags = const <bool>[];

  /// 翻译副行专用 TextPainter（复用避免每帧创建，仅 active 行使用）。
  final TextPainter _translationPainter =
      TextPainter(textDirection: TextDirection.ltr);

  /// 渐变路径复用的 Paint 实例（避免每帧新建，减少 GC）。
  /// 渐变路径稳态下每帧只改 shader，0 次 layout。
  final Paint _gradientPaint = Paint();

  /// 辉光层复用的 Paint 实例（避免每帧新建 Paint + ImageFilter）。
  final Paint _glowBlurPaint = Paint();

  /// P1-5 方案 1：辉光精灵缓存（wordIndex → 最大 blur 的模糊白字图）。
  ///
  /// word 激活时用 [PictureRecorder] + [ui.Image] 异步渲染一次，
  /// 之后每帧 [Canvas.drawImage] 贴图（透明度跟随 glowLevel），
  /// 替代每帧 `saveLayer + ImageFilter.blur` 的 GPU 开销。
  /// 仅在 _ensureBound 重置（切行/字号变化）与文字颜色变化时失效。
  final Map<int, ui.Image> _glowSprites = <int, ui.Image>{};

  /// 正在异步渲染辉光精灵的 wordIndex 集合（避免重复请求）。
  final Set<int> _glowSpritePending = <int>{};

  /// 精灵渲染代数：_ensureBound / reset 时递增，
  /// 异步回调用代数校验，丢弃过期（renderer 已重置/切行）的渲染结果。
  int _spriteEpoch = 0;

  /// 辉光精灵贴图复用的 Paint（透明度由 glowLevel 经 ColorFilter 驱动）。
  final Paint _glowImagePaint = Paint();

  /// 最大辉光 blur sigma：shadowBlurEm 封顶 0.3em × 0.8 = 0.24 × fontSize。
  static double _maxGlowSigma(double fontSize) => 0.24 * fontSize;

  // ============== 渐变遮罩状态 ==============

  /// 当前正在演唱的 word 索引（-1 表示还未开始）。
  int _currentWordIdx = -1;

  /// 当前 word 内进度（0.0-1.0）。
  double _intraWordProgress = 0.0;

  /// 行级渐变 mask 位置（相对于行首的累计已播宽度）。
  ///
  /// **行级渐变模型**：mask 边界随演唱进度从行首移动到行尾，
  /// 跨越多个 word。长字上停留久（速度慢），短字上快速掠过，
  /// 自然实现"根据字长不同改变移动速度"。
  /// -1 表示无效（非当前行），double.infinity 表示已播完。
  double _maskX = -1.0;

  /// 预计算的每个 word 在行内的起始 X 坐标（相对于行首）。
  /// 在 [_ensureBound] 时一次性计算，避免每帧 O(n²) 循环累加。
  List<double> _wordStartXs = const <double>[];

  /// 缓存的上次换行扫描的 maxWidth，用于判断是否需要重算 _cachedVisualLineWidths。
  double _cachedMaxWidth = -1;
  /// 缓存的每条视觉行的 word 累计宽度，避免每帧重新分配 List。
  List<double> _cachedVisualLineWidths = const <double>[];

  // ============== 状态查询 ==============

  /// 当前 alpha map（不可变视图，供测试断言）。
  ///
  /// 内部用 List 存储（性能优化），此处通过 [List.asMap] 返回 Map 视图，
  /// 保持测试接口兼容。仅测试调用，非热路径。
  @visibleForTesting
  Map<int, double> get wordAlphas => _wordAlphas.asMap();

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
  void setLineState({required bool isActive, required double scale, double blurFade = 1.0, bool blurActive = true, int? activeColorValue}) {
    _isActive = isActive;
    _scale = scale;
    _blurFade = blurActive ? blurFade : 0.0;
    _activeColorValue = activeColorValue;
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
  ///
  /// **性能优化（上浮动画功耗优化）**：
  /// - 预计算 decay：dt 对所有 word 相同，speed 只有 attack/release 两值，
  ///   每帧只调 4 次 exp() 而非最多 2N 次（N=word 数）
  /// - 非激活行快速路径：跳过 currentWordIdx 计算、smoothstep、per-word target 分支，
  ///   所有 word 统一 target=dark / Y=0 / emphasis=idle
  /// - early-exit 已收敛字：90% 的字已收敛，跳过乘法运算
  void tick(double dt, int currentTimeMs) {
    if (dt <= 0) return;
    if (_boundLine == null || _boundLine!.words.isEmpty) return;

    final double dark = dynamicDarkAlpha;
    final double bright = dynamicBrightAlpha;
    final words = _boundLine!.words;
    final int wordCount = words.length;

    // === 预计算 decay 值（核心优化：每帧只调 4 次 exp()）===
    // 之前每 word 最多调 2 次 exp()（alpha + Y offset），10 word 行 = 20 次/帧
    // 现在固定 4 次/帧，与 word 数无关
    final double alphaAttackDecay = 1.0 - exp(-LyricLayout.attackSpeed * dt);
    final double alphaReleaseDecay = 1.0 - exp(-LyricLayout.releaseSpeed * dt);
    final double liftAttackDecay = 1.0 - exp(-_liftAttackSpeed * dt);
    final double liftReleaseDecay = 1.0 - exp(-_liftReleaseSpeed * dt);

    // === 非当前行快速路径 ===
    // 非当前行：所有 word alpha 目标 = dark，Y offset 目标 = 0，emphasis = idle
    // 跳过 currentWordIdx 查找、smoothstep、per-word target 分支判断
    if (!_isActive) {
      bool anyChanged = false;
      for (int i = 0; i < wordCount; i++) {
        // Alpha → dark（使用方向判断选 decay，兼容 dark 值随 scale 变化的情况）
        final double current = _wordAlphas[i];
        if ((current - dark).abs() >= LyricLayout.alphaEpsilon) {
          final double decay = dark >= current ? alphaAttackDecay : alphaReleaseDecay;
          double next = current + (dark - current) * decay;
          if ((next - dark).abs() < LyricLayout.alphaEpsilon) next = dark;
          _wordAlphas[i] = next;
          anyChanged = true;
        }
        // Y offset → 0（非当前行不上浮）
        final double currentY = _wordYOffsets[i];
        if (currentY.abs() >= 0.01) {
          final double yDecay = 0 >= currentY ? liftAttackDecay : liftReleaseDecay;
          double nextY = currentY + (0 - currentY) * yDecay;
          if (nextY.abs() < 0.01) nextY = 0;
          _wordYOffsets[i] = nextY;
          anyChanged = true;
        }
        // Emphasis: 非当前行一律 idle
        _emphasizeStates[i] = EmphasizeState.idle;
      }
      _isConverged = !anyChanged;
      _currentWordIdx = -1;
      _intraWordProgress = 0.0;
      _maskX = -1.0;
      return;
    }

    // === 当前行：完整 per-word 处理 ===
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

    // 记录当前演唱状态，供 paintLine 中行级渐变使用
    _currentWordIdx = currentWordIdx;
    _intraWordProgress = intraWordProgress;

    // === 计算行级 mask 位置（核心：行级渐变模型）===
    // maskX = 已播字总宽度 + 当前字内进度 × 当前字宽
    // 渐变边界随演唱进度从行首移动到行尾，跨越多个 word。
    // 长字上停留久（速度慢），短字上快速掠过。
    if (currentWordIdx < 0) {
      _maskX = -1.0; // 无效，全 dark
    } else if (currentWordIdx >= wordCount) {
      _maskX = double.infinity; // 已播完，全 bright
    } else {
      _maskX = _wordStartXs[currentWordIdx] +
          _wordWidths[currentWordIdx] * _intraWordProgress;
    }

    // 行级辉光判定（循环外计算一次）：
    // _isMetadataLine 在 _ensureBound 时缓存（行切换时才更新）；
    // _isActive / useGlowEffect / _emphasizeEffect 运行时可变，每帧检查。
    final bool skipLineEmphasis = _emphasizeEffect == null ||
        !LyricPreferences.instance.useGlowEffect ||
        _isMetadataLine;

    bool anyChanged = false;
    // 性能优化：内联 target 计算 + early-exit 已收敛字 + 预计算 decay
    // 90% 的字在任意时刻已收敛到目标值，跳过乘法运算可大幅降低 CPU 开销
    for (int i = 0; i < wordCount; i++) {
      // === Alpha 动画 ===
      final double target;
      if (i < currentWordIdx) {
        target = bright;
      } else if (i > currentWordIdx) {
        target = dark;
      } else {
        target = dark + (bright - dark) * intraWordProgress;
      }

      final double current = _wordAlphas[i];
      if ((current - target).abs() < LyricLayout.alphaEpsilon) {
        // 已收敛：直接吸附到目标，跳过乘法
        if (current != target) _wordAlphas[i] = target;
      } else {
        // 使用预计算的 decay，避免每 word 调 exp()
        final double decay = target >= current
            ? alphaAttackDecay
            : alphaReleaseDecay;
        double next = current + (target - current) * decay;
        if ((next - target).abs() < LyricLayout.alphaEpsilon) {
          next = target;
        }
        _wordAlphas[i] = next;
        anyChanged = true;
      }

      // === Y 偏移动画（上浮特效）===
      final double targetY;
      if (i < currentWordIdx) {
        targetY = _maxLiftPx;
      } else if (i == currentWordIdx) {
        // smoothstep 缓动（仅 3 次乘法 + 1 次加法，开销极低）
        final double eased = intraWordProgress * intraWordProgress * (3 - 2 * intraWordProgress);
        targetY = _maxLiftPx * eased;
      } else {
        targetY = 0;
      }

      final double currentY = _wordYOffsets[i];
      // Y offset 用 0.01px epsilon（3px 范围，0.3% 不可见）
      if ((currentY - targetY).abs() < 0.01) {
        // 已收敛：直接吸附到目标，跳过乘法
        if (currentY != targetY) _wordYOffsets[i] = targetY;
      } else {
        // 使用预计算的 decay，避免每 word 调 exp()
        final double yDecay = targetY >= currentY
            ? liftAttackDecay
            : liftReleaseDecay;
        double nextY = currentY + (targetY - currentY) * yDecay;
        if ((nextY - targetY).abs() < 0.01) {
          nextY = targetY;
        }
        _wordYOffsets[i] = nextY;
        anyChanged = true;
      }

      // === 强调辉光效果 ===
      // 字级判定（含正则匹配）在 _ensureBound 时已缓存，此处仅 O(1) 数组读取
      if (!skipLineEmphasis && _wordEmphasisFlags[i]) {
        _emphasizeStates[i] = _emphasizeEffect!.computeState(
          word: words[i],
          currentTimeMs: currentTimeMs,
          isLastWord: i == wordCount - 1,
          wordIndex: i,
          anchorCharCount: words[i].text.runes.length,
        );
      } else {
        _emphasizeStates[i] = EmphasizeState.idle;
      }
    }
    // v3 优化：跟踪 alpha/Y offset 是否仍在变化（用于 AppleLyricsView 判断停止 Ticker）
    _isConverged = !anyChanged;
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

    // 解析当前行实际文字颜色：动态字体颜色（仅当前行）优先，否则回退主题默认色。
    // 颜色变化时清空 alpha 缓存强制重建所有 word TextSpan。
    final int textColorValue =
        (_isActive && _activeColorValue != null)
            ? _activeColorValue!
            : LyricLayout.textColorValue;
    if (textColorValue != _lastTextColorValue) {
      _lastSetAlphas = List<int>.filled(_lastSetAlphas.length, -1);
      _lastTextColorValue = textColorValue;
      // P1-5：辉光精灵颜色跟随文字色（当前行渐变路径下为白色），
      // 颜色变化（主题/动态字体色切换）时失效所有精灵缓存。
      for (final img in _glowSprites.values) {
        img.dispose();
      }
      _glowSprites.clear();
    }
    final int textRed = (textColorValue >> 16) & 0xFF;
    final int textGreen = (textColorValue >> 8) & 0xFF;
    final int textBlue = textColorValue & 0xFF;

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
    final double bright = dynamicBrightAlpha;
    // 换行内部行高 = 主行高 × 0.8（与 LyricLayout.measureLineHeight 一致）
    final double wrapLineHeight =
        fontSize * LyricLayout.lineHeight * LyricLayout.wrapLineHeightFactor;
    final double lineHeight = LyricLayout.lineHeight;

    // === 行级渐变参数（核心：行级 maskX 模型）===
    // 过渡区以 _maskX 为中心，宽度 = 2 × 当前字宽，让渐变跨越 2-3 个 word。
    // 长字过渡区宽，渐变在字上移动慢；短字过渡区窄，移动快。
    // _maskX < 0 表示非当前行或未开始，全 dark。
    final bool useGradient = _isActive &&
        _boundLine != null &&
        _boundLine!.words.length == line.words.length &&
        _maskX >= 0;
    final double transitionHalfWidth = useGradient &&
            _currentWordIdx >= 0 &&
            _currentWordIdx < _wordWidths.length
        ? _wordWidths[_currentWordIdx]
        : 0.0;
    final double transitionStart = _maskX - transitionHalfWidth;
    final double transitionEnd = _maskX + transitionHalfWidth;
    final double transitionSpan = transitionEnd - transitionStart;

    for (int i = 0; i < line.words.length; i++) {
      final LyricWord word = line.words[i];
      // AMLL 上浮特效：当前字 Y 偏移（上浮）
      final double yOffset = i < _wordYOffsets.length ? _wordYOffsets[i] : 0;
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

      // === 计算渲染 alpha ===
      // 行级 maskX 模型：基于 word 在行内的累计 X 坐标计算边缘 alpha。
      // 已播区（maskX 左侧远端）= bright，未播区（maskX 右侧远端）= dark，
      // 过渡区内线性插值，实现跨字平滑渐变。
      final double leftAlpha;
      final double rightAlpha;
      if (!useGradient) {
        leftAlpha = rightAlpha = i < _wordAlphas.length ? _wordAlphas[i] : dark;
      } else {
        final double wordStartX = i < _wordStartXs.length ? _wordStartXs[i] : 0;
        final double wordEndX = wordStartX + width;
        leftAlpha = _alphaAtX(wordStartX, transitionStart, transitionSpan, bright, dark);
        rightAlpha = _alphaAtX(wordEndX, transitionStart, transitionSpan, bright, dark);
      }

      final painter = _wordPainters[i];

      // === 强调辉光：save + scale（公共路径）===
      final bool needEmphasis = emState.scale != 1.0 || emState.glowLevel > 0;
      if (needEmphasis) {
        canvas.save();
        final double centerX = wordX + width / 2;
        final double centerY = wordY + fontSize * lineHeight / 2;
        canvas.translate(centerX, centerY);
        canvas.scale(emState.scale, emState.scale);
        canvas.translate(-centerX, -centerY);
      }

      // === 渲染文字 ===
      // 性能优化（核心）：左右 alpha 几乎一致时用均匀绘制（量化缓存，跳过 layout）。
      // 过渡区内的 word 走渐变路径，用 saveLayer + BlendMode.modulate 应用渐变。
      //
      // **layout 复用原理**：
      // - 渐变路径保持 painter.text 为 plain white（color=white, alpha=1.0）
      // - TextSpan.== 比较时 plain white 的 color/fontSize/fontFamily 不变 → 不触发 relayout
      // - 渐变通过 saveLayer + drawRect(modulate) 事后应用，不影响 layout
      // - 稳态下 0 次 layout/帧（仅路径切换时 1 次 layout）
      //
      // **BlendMode.modulate 公式**：result = src × dst（逐分量含 alpha）
      // - dst = 白色文字（color=white, alpha=文字形状）
      // - src = 渐变（color=white, alpha=leftAlpha→rightAlpha）
      // - result.color = white × white = white
      // - result.alpha = 渐变alpha × 文字形状 ✓
      final bool isUniform = (leftAlpha - rightAlpha).abs() < 0.01;
      if (isUniform) {
        // === 均匀路径 ===
        final double uniformAlpha = (leftAlpha + rightAlpha) * 0.5;
        final int alphaStep = (uniformAlpha * 20).round();
        if (_lastSetAlphas[i] != alphaStep) {
          // 量化值变化或从渐变路径切换过来：重新 set text + layout
          painter.text = TextSpan(
            text: word.text,
            style: TextStyle(
              color: Color.fromRGBO(textRed, textGreen, textBlue, uniformAlpha),
              fontSize: fontSize,
              height: lineHeight,
              fontFamily: LyricLayout.fontFamily,
            ),
          );
          painter.layout();
          _lastSetAlphas[i] = alphaStep;
        }
      } else {
        // === 渐变路径（saveLayer + modulate，复用 layout）===
        // 确保 painter 处于 plain white 状态（只在切换时 set text + layout）
        if (_lastSetAlphas[i] != -1) {
          painter.text = TextSpan(
            text: word.text,
            style: TextStyle(
              color: const Color.fromRGBO(255, 255, 255, 1.0), // plain white
              fontSize: fontSize,
              height: lineHeight,
              fontFamily: LyricLayout.fontFamily,
            ),
          );
          painter.layout();
          _lastSetAlphas[i] = -1; // 标记 plain white 已缓存
        }
      }

      // === 辉光层 + 正常文字层绘制 ===
      // 辉光逻辑为公共路径，均匀和渐变共用
      if (needEmphasis && emState.glowLevel > 0) {
        final double blurSigma = emState.shadowBlurEm * fontSize * 0.8;
        if (blurSigma > 0) {
          final glowRect = Rect.fromLTWH(
            wordX - blurSigma * 2, wordY - blurSigma * 2,
            width + blurSigma * 4, fontSize * lineHeight + blurSigma * 4,
          );
          // P1-5 方案 1：优先用预渲染辉光精灵贴图。
          // 精灵 = 固定最大 blur 的模糊白字图，透明度经 ColorFilter 跟随
          // glowLevel 平滑变化；每帧成本从「saveLayer + blur」降为「一次贴图」。
          // 视觉差异：blur 半径不再随字内进度连续变化，改为恒定最大 + 透明度动画
          // （主要区间——满强度段 blur 本就是最大——与现状一致）。
          final ui.Image? sprite = _glowSprites[i];
          if (sprite != null) {
            final double pad = _maxGlowSigma(fontSize) * 2;
            // 辉光整体透明度随 glowLevel 平滑变化，避免辉光开关式突兀出现/消失
            _glowImagePaint.colorFilter = ColorFilter.matrix(<double>[
              1, 0, 0, 0, 0,
              0, 1, 0, 0, 0,
              0, 0, 1, 0, 0,
              0, 0, 0, emState.glowLevel.clamp(0.0, 1.0), 0,
            ]);
            canvas.drawImage(
              sprite,
              Offset(wordX - pad, wordY - pad),
              _glowImagePaint,
            );
          } else {
            // 精灵未就绪（word 激活早期，glowLevel≈0 几乎不可见）：
            // 异步请求渲染，本帧降级旧 saveLayer 路径保证视觉连续。
            _requestGlowSprite(i, word, fontSize);
            _glowBlurPaint.imageFilter = ImageFilter.blur(
              sigmaX: blurSigma, sigmaY: blurSigma,
            );
            // 辉光整体透明度随 glowLevel 平滑变化，避免辉光开关式突兀出现/消失
            _glowBlurPaint.colorFilter = ColorFilter.matrix(<double>[
              1, 0, 0, 0, 0,
              0, 1, 0, 0, 0,
              0, 0, 1, 0, 0,
              0, 0, 0, emState.glowLevel.clamp(0.0, 1.0), 0,
            ]);
            canvas.saveLayer(glowRect, _glowBlurPaint);
            painter.paint(canvas, wordPos);
            canvas.restore();
          }
        }
      }

      if (isUniform) {
        // 均匀路径：直接 paint（text 的 color 已是目标 alpha）
        painter.paint(canvas, wordPos);
      } else {
        // 渐变路径：saveLayer + paint(plain white) + drawRect(modulate) 应用渐变
        final Rect wordRect = Rect.fromLTWH(wordX, wordY, width, fontSize * lineHeight);
        canvas.saveLayer(wordRect, Paint());
        painter.paint(canvas, wordPos); // dst = 白色文字（layout 已缓存，不重算）
        // 复用 _gradientPaint 实例，只改 shader 和 blendMode。
        // 注意：不要对渐变 alpha 做量化缓存（曾引入 5% 可见阶跃闪烁 + 频繁清空重建反而卡顿）。
        _gradientPaint.shader = LinearGradient(
          colors: [
            Color.fromRGBO(textRed, textGreen, textBlue, leftAlpha),
            Color.fromRGBO(textRed, textGreen, textBlue, rightAlpha),
          ],
          stops: const <double>[0.0, 1.0],
        ).createShader(wordRect);
        _gradientPaint.blendMode = BlendMode.modulate;
        canvas.drawRect(wordRect, _gradientPaint); // src = 渐变
        canvas.restore();
      }

      if (needEmphasis) {
        canvas.restore();
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
          color: Color.fromRGBO(textRed, textGreen, textBlue, LyricLayout.translationOpacity),
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

  /// 计算指定 X 坐标处的 alpha 值（行级渐变模型核心）。
  ///
  /// 过渡区 [transitionStart, transitionStart + transitionSpan]：
  /// - x <= transitionStart：bright（已播区）
  /// - x >= transitionStart + transitionSpan：dark（未播区）
  /// - 过渡区内：bright → dark 线性插值
  ///
  /// 通过此函数计算每个 word 左右边缘的 alpha，决定均匀绘制还是渐变 shader。
  /// 渐变边界随 maskX 移动跨越多个 word，自然实现"长字慢、短字快"。
  static double _alphaAtX(double x, double transitionStart, double transitionSpan,
      double bright, double dark) {
    if (transitionSpan <= 0) return x <= transitionStart ? bright : dark;
    if (x <= transitionStart) return bright;
    final double t = (x - transitionStart) / transitionSpan;
    if (t >= 1.0) return dark;
    return bright + (dark - bright) * t;
  }

  /// 按换行逻辑预扫描，计算每条视觉行的 word 累计宽度。
  /// 与 paintLine 循环中的换行判断一致：dx + width > maxWidth 且 dx > 0 时换行。
  /// 性能优化：缓存结果，maxWidth 不变时直接返回缓存。
  List<double> _computeVisualLineWidths(double maxWidth) {
    if (maxWidth == _cachedMaxWidth && _cachedVisualLineWidths.isNotEmpty) {
      return _cachedVisualLineWidths;
    }
    _cachedMaxWidth = maxWidth;
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
    _cachedVisualLineWidths = widths;
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
    // 动态字体颜色（仅当前行）优先，否则回退主题默认色
    final int colorValue =
        (_isActive && _activeColorValue != null)
            ? _activeColorValue!
            : LyricLayout.textColorValue;
    final painter = TextPainter(textDirection: TextDirection.ltr);
    painter.text = TextSpan(
      text: line.text,
      style: TextStyle(
        color: Color.fromRGBO((colorValue >> 16) & 0xFF, (colorValue >> 8) & 0xFF, colorValue & 0xFF, alpha),
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

  /// P1-5 方案 1：异步渲染 word 的最大 blur 辉光精灵图并缓存。
  ///
  /// 渲染内容 = 纯白文字 + 恒定最大 blur（sigma = 0.24 × fontSize），
  /// 与现状「当前字渐变路径（painter=plain white）下的辉光」颜色一致；
  /// 透明度由每帧 [emState.glowLevel] 经 ColorFilter 控制，不参与精灵内容。
  ///
  /// 幂等保护：wordIndex 已在缓存或渲染中时直接返回。
  /// 异步回调用 [_spriteEpoch] 校验，renderer 已重置/切行时丢弃结果。
  void _requestGlowSprite(int wordIndex, LyricWord word, double fontSize) {
    if (_glowSpritePending.contains(wordIndex)) return;
    if (_glowSprites.containsKey(wordIndex)) return;
    _glowSpritePending.add(wordIndex);
    final int epoch = _spriteEpoch;
    final double sigma = _maxGlowSigma(fontSize);
    final double pad = sigma * 2;
    final double wordH = fontSize * LyricLayout.lineHeight;
    // 空字安全保护
    if (word.text.isEmpty || wordH <= 0) {
      _glowSpritePending.remove(wordIndex);
      return;
    }
    // 异步渲染（toImage 在光栅线程执行，回调回 UI 线程）
    _renderGlowSpriteImage(word, fontSize, sigma, pad).then((image) {
      _glowSpritePending.remove(wordIndex);
      if (image == null) return;
      if (epoch != _spriteEpoch) {
        // renderer 已重置/切行：过期结果直接释放
        image.dispose();
        return;
      }
      _glowSprites[wordIndex]?.dispose();
      _glowSprites[wordIndex] = image;
    });
  }

  /// 渲染单张辉光精灵图（纯白文字 + blur，异步）。
  ///
  /// 内部 try-catch 兜底：任何渲染失败（如 GPU 资源紧张）返回 null，
  /// 下次 _requestGlowSprite 会重新尝试。
  Future<ui.Image?> _renderGlowSpriteImage(
      LyricWord word, double fontSize, double sigma, double pad) async {
    try {
      final textPainter = TextPainter(textDirection: TextDirection.ltr)
        ..text = TextSpan(
          text: word.text,
          style: TextStyle(
            // 与渐变路径 painter 一致：plain white，blur 后即白色辉光
            color: const Color.fromRGBO(255, 255, 255, 1.0),
            fontSize: fontSize,
            height: LyricLayout.lineHeight,
            fontFamily: LyricLayout.fontFamily,
          ),
        )
        ..layout();
      final int imgW = (textPainter.width + pad * 2).ceil();
      final int imgH = (fontSize * LyricLayout.lineHeight + pad * 2).ceil();
      if (imgW <= 0 || imgH <= 0) {
        textPainter.dispose();
        return null;
      }

      final recorder = ui.PictureRecorder();
      final glowCanvas = Canvas(recorder);
      glowCanvas.saveLayer(
        Rect.fromLTWH(0, 0, imgW.toDouble(), imgH.toDouble()),
        Paint()
          ..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
      );
      textPainter.paint(glowCanvas, Offset(pad, pad));
      textPainter.dispose();
      glowCanvas.restore();

      final picture = recorder.endRecording();
      final image = await picture.toImage(imgW, imgH);
      return image;
    } catch (_) {
      return null;
    }
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
    // 注意：_wordAlphas/_wordYOffsets/_lastSetAlphas 不能用 .clear()，
    // 因为它们可能被 const <T>[] 初始化（不可修改）。后面会直接重新赋值，无需 clear。
    _emphasizeStates.clear();

    // 行级元数据判定缓存：作词/作曲/编曲 等元数据行整行禁用辉光。
    // 仅依赖 line.text（行绑定后不变），此处计算一次，tick 中仅读取字段。
    _isMetadataLine = EmphasizeEffect.shouldSkipEmphasizeForLine(line);

    // 释放旧 _wordPainters（line 缩短时避免泄漏）
    for (final painter in _wordPainters) {
      painter.dispose();
    }

    final double dark = dynamicDarkAlpha;
    // P1-5：行绑定切换（切行/字号变化）时失效辉光精灵缓存——
    // 旧行的 word 文本/字号不同，精灵图不再匹配；异步渲染中的结果也丢弃。
    _spriteEpoch++;
    for (final img in _glowSprites.values) {
      img.dispose();
    }
    _glowSprites.clear();
    _glowSpritePending.clear();
    // 测量所有 word 宽度并初始化 per-word TextPainter
    _wordWidths = List<double>.filled(line.words.length, 0);
    _wordPainters = List<TextPainter>.generate(
      line.words.length,
      (_) => TextPainter(textDirection: TextDirection.ltr),
    );
    // 预分配辉光判定缓存数组（与 _wordPainters 同长度同索引）
    _wordEmphasisFlags = List<bool>.filled(line.words.length, false);
    // 预计算 word 起始 X 坐标（避免每帧 O(n²) 循环累加）
    _wordStartXs = List<double>.filled(line.words.length, 0);
    // 预分配 alpha / Y offset / lastSetAlphas 数组
    _wordAlphas = List<double>.filled(line.words.length, dark);
    _wordYOffsets = List<double>.filled(line.words.length, 0);
    _lastSetAlphas = List<int>.filled(line.words.length, -1);
    
    double accumWidth = 0;
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
      _wordStartXs[i] = accumWidth;
      accumWidth += _wordPainters[i].width;
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
    _activeColorValue = null;
    _boundFontSize = -1;
    _wordWidths = const <double>[];
    _wordStartXs = const <double>[];
    _cachedMaxWidth = -1;
    _cachedVisualLineWidths = const <double>[];
    _currentWordIdx = -1;
    _intraWordProgress = 0.0;
    _maskX = -1.0;
    // 清理辉光判定缓存
    _wordEmphasisFlags = const <bool>[];
    _isMetadataLine = false;
    // v4 优化：dispose per-word TextPainter 实例
    for (final painter in _wordPainters) {
      painter.dispose();
    }
    _wordPainters = const <TextPainter>[];
    _wordAlphas = const <double>[];
    _wordYOffsets = const <double>[];
    _lastSetAlphas = const <int>[];
    _emphasizeStates.clear();
    // P1-5：reset 时失效辉光精灵缓存（dispose 图片 + 代数递增丢弃异步结果）
    _spriteEpoch++;
    for (final img in _glowSprites.values) {
      img.dispose();
    }
    _glowSprites.clear();
    _glowSpritePending.clear();
  }
}
