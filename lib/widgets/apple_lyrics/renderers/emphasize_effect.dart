/// 强调辉光（emphasize）效果
///
/// 参照 spec.md "Requirement: 强调辉光（emphasize）效果" 与 AMLL `lyric-line.ts:510-651` 实现。
/// 当字时长 >= 1000ms 且符合字符长度要求（CJK 任意 / 非 CJK 1~7）时触发辉光：
/// - 逐字符波浪：每个字符按 `wordDe = de + (du/2.5/anchorCharCount)*wordIndex` 从左到右依次启动，
///   字符内进度 t∈[0,1] 前段用 bezIn 渐入（放大、上浮、辉光增强），后段用 bezOut 渐出（回落、衰减），
///   形成"依次放大上浮再下落"的海浪般视觉效果。
/// - 正弦浮层：另叠加 `-sin(π·x)×0.05em` 的起伏（提前 400ms、时长 1.4×du），增强海浪脊感。
/// - 末尾字（isLastWord）amount/blur 加强 1.6/1.5 倍。
library;

import 'dart:math';

import 'package:flutter/foundation.dart';

import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';

/// 强调辉光状态（逐字符）。
///
/// 不可变值对象，由 [EmphasizeEffect.computeState] 输出，供绘制层
/// （如 CustomPainter）读取 scale、glowLevel、shadowBlurEm、offsetXEm、
/// offsetYEm、floatYEm 应用 transform 与 textShadow。
@immutable
class EmphasizeState {
  /// 缩放比例，1.0~1.12（含末尾字加强后可能略高）。
  final double scale;

  /// 辉光强度 0~1.2（作为 textShadow 的 alpha 通道）。
  final double glowLevel;

  /// 阴影模糊半径（em 单位），封顶 0.3。
  final double shadowBlurEm;

  /// 水平外扩位移（em 单位）：左字向左、右字向右，随凸起涨落。
  final double offsetXEm;

  /// 上浮位移（em 单位，向上为负）：随凸起涨落（放大时上浮，回落时还原）。
  final double offsetYEm;

  /// 正弦浮层位移（em 单位，向上为负）：独立于凸起的海浪起伏。
  final double floatYEm;

  const EmphasizeState({
    required this.scale,
    required this.glowLevel,
    required this.shadowBlurEm,
    this.offsetXEm = 0,
    this.offsetYEm = 0,
    this.floatYEm = 0,
  });

  /// 空闲状态：无辉光、无缩放、无阴影、无位移。
  ///
  /// 当 word 未触发辉光（[EmphasizeEffect.shouldEmphasize] 返回 false），
  /// 或当前时间不在字内进度 [0, 1] 范围时返回此常量。
  static const EmphasizeState idle = EmphasizeState(
    scale: 1.0,
    glowLevel: 0,
    shadowBlurEm: 0,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EmphasizeState &&
          runtimeType == other.runtimeType &&
          scale == other.scale &&
          glowLevel == other.glowLevel &&
          shadowBlurEm == other.shadowBlurEm &&
          offsetXEm == other.offsetXEm &&
          offsetYEm == other.offsetYEm &&
          floatYEm == other.floatYEm;

  @override
  int get hashCode => Object.hash(
      scale, glowLevel, shadowBlurEm, offsetXEm, offsetYEm, floatYEm);

  @override
  String toString() =>
      'EmphasizeState(scale: $scale, glowLevel: $glowLevel, '
      'shadowBlurEm: $shadowBlurEm, offsetXEm: $offsetXEm, '
      'offsetYEm: $offsetYEm, floatYEm: $floatYEm)';
}

/// 某字符的波浪相位（自驱动动画状态）。
///
/// - [bumpPhase]：凸起进度，0~1 为激活窗口（0.5 达峰）。
/// - [floatPhase]：正弦浮层进度，0~1 为激活窗口（0.5 达最大上浮）。
/// 可为负/超 1（窗口外），由 [EmphasizeEffect.phasesAt] 在锚定时生成，
/// 之后每帧由帧时钟 dt 推进（见 WordRenderer.tick）。
@immutable
class EmphasizePhases {
  final double bumpPhase;
  final double floatPhase;

  const EmphasizePhases({
    required this.bumpPhase,
    required this.floatPhase,
  });
}

/// 强调辉光效果计算器。
///
/// 无状态工具类：所有计算基于入参，内部不持有可变状态。
/// 通过 [shouldEmphasize] 判断 word 是否需要辉光，
/// 通过 [computeState] / [computeStateFromPhases] 计算辉光参数
/// （scale / glowLevel / shadowBlurEm / offsetXEm / offsetYEm / floatYEm）。
class EmphasizeEffect {
  EmphasizeEffect();

  // ============== 触发条件常量 ==============

  /// 默认兜底阈值（ms）：无逐字歌词 / 无 BPM / 样本不足时使用。
  static const int _durationThresholdMs = 500;

  /// 逐字歌词统计所需的最小样本数（字）。样本过少时统计不可靠，交由兜底。
  static const int _lyricsSampleMin = 20;

  /// 触发阈值：字时长 >= 此值才触发辉光（默认兜底值，见 [resolveThresholdMs]）。
  ///
  /// 快歌（KRC 逐字歌词，字时长常见 300~800ms）固定阈值易造成快歌不触发、
  /// 慢歌过密；改用 [resolveThresholdMs] 按歌曲 BPM / 歌词字长中位数 ×
  /// [LyricPreferences.glowThresholdFactor] 自适应推断（设置页可调 1.0~2.0），
  /// 再经 [shouldEmphasize] 的 [thresholdMs] 传入。
  static const int _nonCjkMaxLength = 7;

  // ============== 内容过滤常量 ==============

  /// 匹配任意 Unicode 字母或数字（用于判定纯符号）。
  /// \p{L} = 所有字母（含 CJK 汉字、平假名、片假名、韩文、拉丁、西里尔等）
  /// \p{N} = 所有数字
  /// 注意：CJK 标点（、。：等）属于 \p{P}（标点），不会被匹配 → 纯符号判定生效
  static final RegExp _letterOrNumberRegex = RegExp(
    r'[\p{L}\p{N}]',
    unicode: true,
  );

  /// 带冒号的歌手标签：男：/女：/合：/男声：/女声：/合唱： 等。
  /// 单字标签必须带冒号，避免 "男"/"女"/"合" 在正常歌词中误伤。
  static final RegExp _singerLabelWithColonRegex = RegExp(
    r'^[\s(（]*(男|女|合|童|男声|女声|合唱|男唱|女唱|男独|女独|独唱|伴唱|和声|男和|女和)[\s)）]*[:：]$',
  );

  /// 括号包裹的歌手标签：(男)/（女）/(合唱) 等。
  static final RegExp _parenSingerLabelRegex = RegExp(
    r'^[(（]\s*(男|女|合|童|男声|女声|合唱|男唱|女唱|男独|女独|独唱|伴唱|和声)\s*[)）]$',
  );

  /// 多字歌手标签（无冒号也视为标签）：男声/女声/合唱/男唱/女唱 等。
  /// 这些词在正常歌词中极少作为独立 word 出现，可直接过滤。
  static final RegExp _multiCharSingerLabelRegex = RegExp(
    r'^(男声|女声|合唱|男唱|女唱|男独|女独|独唱|伴唱|和声|男和|女和)$',
  );

  /// 元数据行关键词（行首匹配，trim 后判定）。
  /// 覆盖常见中文歌曲元数据：作词/作曲/编曲 等。
  static const List<String> _metadataLineKeywords = [
    '作词', '作曲', '词：', '词:', '曲：', '曲:',
    '编曲', '制作人', '混音', '录音', '母带', '出品',
    '监制', '和声', '演唱', '演奏', '乐团', '乐队',
    '原唱', '翻唱', '吉他', '钢琴', '贝斯', '鼓：', '鼓:',
    '弦乐', '管乐', '合声', '伴奏', '独唱', '合唱',
    'OP', 'SP', '音乐总监', '原曲', '原词', '改编',
    '缩混', '统筹', '企划', '发行', '出版', '版权',
    '词曲', '歌词', '歌曲', '歌名', '歌手', '专辑',
    '制作', '编辑', '校对', 'OP:', 'OP：', 'SP:', 'SP：',
  ];

  // ============== amount / blur 公式常量 ==============

  /// amount 缩放系数（spec.md：amount *= 0.6）
  static const double _amountScale = 0.6;

  /// amount 封顶（spec.md：amount > 1.2 时封顶为 1.2）
  static const double _amountCap = 1.2;

  /// blur 缩放系数（spec.md：blur *= 0.5）
  static const double _blurScale = 0.5;

  /// blur 封顶（spec.md：blur > 0.8 时封顶为 0.8）
  static const double _blurCap = 0.8;

  /// 末尾字 amount 加强系数（spec.md：isLastWord 时 amount *= 1.6）
  static const double _lastWordAmountBoost = 1.6;

  /// 末尾字 blur 加强系数（spec.md：isLastWord 时 blur *= 1.5）
  static const double _lastWordBlurBoost = 1.5;

  /// 缩放公式中 transX 的系数（spec.md：scale = 1 + transX * 0.1 * amount）
  static const double _scaleTransFactor = 0.1;

  /// shadowBlurEm 封顶（spec.md：textShadow: 0 0 min(0.3, blur*0.3)em）
  static const double _shadowBlurEmCap = 0.3;

  // ============== 逐字符波浪常量（对齐 AMLL lyric-line.ts） ==============

  /// 字符错位 spread 除数：所有字符起始时间跨度 = du / 2.5
  static const double _staggerSpreadDivisor = 2.5;

  /// 上浮位移系数（AMLL：offsetY = -transX * 0.025 * amount）
  static const double _offsetYFactor = 0.025;

  /// 水平外扩系数（AMLL：offsetX = -transX * 0.03 * amount * (n/2 - i)）
  static const double _offsetXFactor = 0.03;

  /// 正弦浮层幅度（em，AMLL：y = -sin(π·x) * 0.05em）
  static const double _floatAmpEm = 0.05;

  /// 正弦浮层相对凸起的提前量（ms，AMLL：delay = wordDe - 400）
  static const double _floatLeadMs = 400;

  /// 正弦浮层时长系数（AMLL：duration = du * 1.4）
  static const double _floatDurationFactor = 1.4;

  /// 浮层边缘渐隐宽度（占凸起窗口的比例）：起始/结束各 15% 内从 0 平滑过渡，
  /// 消除字切换瞬间浮层跳变上移与字尾回落突兀。
  static const double _floatEdgeFadeWidth = 0.15;

  /// 基于凸起相位的浮层边缘渐隐系数（0~1）。
  ///
  /// - 凸起窗口外（未开始 / 已结束，含浮层尾巴）：返回 0，浮层不显示。
  /// - 凸起起始 [0, width]：线性 0→1。
  /// - 凸起结束 [1-width, 1]：线性 1→0。
  /// - 中间：恒 1。
  static double _floatEdgeFade(bool bumpActive, double bumpPhase) {
    if (!bumpActive) return 0;
    if (bumpPhase < _floatEdgeFadeWidth) {
      return bumpPhase / _floatEdgeFadeWidth;
    }
    if (bumpPhase > 1 - _floatEdgeFadeWidth) {
      return (1 - bumpPhase) / _floatEdgeFadeWidth;
    }
    return 1;
  }

  // ============== bezier 控制点 ==============
  //
  // spec.md："bezIn = bezier(0.2, 0.4, 0.58, 1.0)"、"bezOut = bezier(0.3, 0.0, 0.58, 1.0)"
  // 对应 CSS cubic-bezier(x1, y1, x2, y2) 记法，P0=(0,0), P3=(1,1)。
  // 本实现按 spec 公式仅使用前两个值作为 P1/P2（P0=0, P3=1 内置）。

  /// bezIn 控制点 P1（曲线前半段）
  static const double _bezInP1 = 0.2;

  /// bezIn 控制点 P2（曲线前半段）
  static const double _bezInP2 = 0.4;

  /// bezOut 控制点 P1（曲线后半段）
  static const double _bezOutP1 = 0.3;

  /// bezOut 控制点 P2（曲线后半段）
  static const double _bezOutP2 = 0.0;

  // ============== 公开 API ==============

  /// 判断整行是否应禁用辉光（行级过滤）。
  ///
  /// 返回 true 表示该行【不应】有任何辉光。
  /// 在 [WordRenderer.tick] 中先调用此方法，若返回 true 则跳过所有 word 的辉光计算。
  ///
  /// 判定规则：行文本 trim 后为空，或以元数据关键词开头（作词/作曲/编曲 等）。
  /// 结果仅依赖 [LyricLine.text]（行绑定后不变），可安全缓存。
  static bool shouldSkipEmphasizeForLine(LyricLine line) {
    final lineText = line.text.trim();
    if (lineText.isEmpty) return true;
    for (final keyword in _metadataLineKeywords) {
      if (lineText.startsWith(keyword)) return true;
    }
    return false;
  }

  /// 解析整首歌的辉光触发阈值（ms）：**单位字长 × 阈值系数**，随节奏自适应。
  ///
  /// 单位字长来源（结合 BPM 真数据 + 歌词字长推断）：
  /// 1. [songBpm] 非空（酷狗接口 / 本地音频 TBPM 标签）：按「一字一拍」
  ///    换算 `60000 / BPM` 作为单位字长（如 BPM=120 → 500ms）。
  /// 2. 歌词字长统计（KRC 逐字）：取所有字时长中位数作为单位字长；
  ///    样本不足返回 null 交给兜底。
  /// 3. 兜底返回 [fallback]（默认 [_durationThresholdMs]=500）。
  ///
  /// 阈值系数默认取 [LyricPreferences.glowThresholdFactor]（设置页可调
  /// 1.0~2.0，默认 1.4），也可经 [thresholdFactor] 显式传入（供测试）。
  ///
  /// 例：字长中位数 400ms（快歌）× 1.4 → 阈值 560ms；800ms（慢歌）→ 1120ms，
  /// 快慢之间平滑过渡，不再使用固定两档。
  static int resolveThresholdMs({
    List<LyricLine>? lines,
    int? songBpm,
    int fallback = _durationThresholdMs,
    double? thresholdFactor,
  }) {
    final double factor =
        thresholdFactor ?? LyricPreferences.instance.glowThresholdFactor;
    // 1. 显式 BPM：一字一拍换算单位字长，再 × 系数
    if (songBpm != null && songBpm > 0) {
      final double beatMs = 60000 / songBpm;
      return (beatMs * factor).round();
    }
    // 2. KRC 逐字歌词字长中位数 × 系数
    if (lines != null) {
      final int? median = _lyricsMedianMs(lines);
      if (median != null) return (median * factor).round();
    }
    // 3. 兜底
    return fallback;
  }

  /// 由 KRC 逐字歌词统计字长中位数（ms）；无逐字或样本不足返回 null。
  static int? _lyricsMedianMs(List<LyricLine> lines) {
    final List<int> durations = <int>[];
    for (final line in lines) {
      if (!line.hasWordTiming) continue;
      for (final w in line.words) {
        durations.add(w.duration);
      }
    }
    if (durations.length < _lyricsSampleMin) return null;
    durations.sort();
    return durations[durations.length ~/ 2];
  }

  /// 判断 word 是否触发辉光。
  ///
  /// 触发条件（spec.md "Requirement: 强调辉光（emphasize）效果" + 内容过滤）：
  /// - 字时长 [LyricWord.duration] >= [thresholdMs]（快慢歌阈值，见 [resolveThresholdMs]）
  /// - 文本非空
  /// - 【新增】非纯符号/标点（_ - \ 、 @ * . , … — 等）
  /// - 【新增】非歌手标签（男：/女：/(男)/合唱 等）
  /// - 且为 CJK 字符（任意长度）或 非 CJK 字符长度 1~7
  ///
  /// CJK 判定：[String.runes] 中任一字符落在 CJK 统一表意 / 平假名 /
  /// 片假名 / CJK 标点 / 韩文 任一 Unicode 范围内，即视为 CJK 字符。
  ///
  /// 结果仅依赖 [LyricWord.text] 与 [LyricWord.duration]（行绑定后不变），可安全缓存。
  static bool shouldEmphasize(LyricWord word, {int thresholdMs = _durationThresholdMs}) {
    if (word.duration < thresholdMs) return false;
    final text = word.text;
    if (text.isEmpty) return false;

    // 纯符号/标点 word 不触发辉光（_ - \ 、 @ * . , … — 等）
    if (_isPureSymbol(text)) return false;

    // 歌手标签 word 不触发辉光（男：/女：/(男)/合唱 等）
    if (_isSingerLabel(text)) return false;

    final runes = text.runes.toList();
    final hasCJK = runes.any(_isCJKCodePoint);
    if (hasCJK) {
      // CJK 字符：任意长度均触发
      return true;
    }
    // 非 CJK 字符：长度需在 1~7 之间
    return runes.isNotEmpty && runes.length <= _nonCjkMaxLength;
  }

  /// 动画时长 du = max(1000, duration)（duration 已由 shouldEmphasize 保证 >= 1000）。
  static double duMs(LyricWord word) => max(1000.0, word.duration.toDouble());

  /// 正弦浮层时长系数（AMLL：duration = du * 1.4）。
  static const double floatDurationFactor = _floatDurationFactor;

  /// 计算某时刻、某字符的波浪相位（用于自驱动动画的【锚定】）。
  ///
  /// 返回字符错位后的凸起进度与正弦浮层进度（可为负/超 1，表示窗口外）。
  /// 自驱动波浪在字切换 / seek 时用本方法初始化一次相位，之后每帧由帧时钟 dt
  /// 推进（见 WordRenderer.tick），保证动画平滑且与音频对齐。
  static EmphasizePhases phasesAt({
    required LyricWord word,
    required int currentTimeMs,
    required int wordIndex,
    required int anchorCharCount,
  }) {
    final double du = duMs(word);
    final double charDelay =
        (du / _staggerSpreadDivisor / anchorCharCount) * wordIndex;
    final double wordDe = word.startTime + charDelay;
    return EmphasizePhases(
      bumpPhase: (currentTimeMs - wordDe) / du,
      floatPhase:
          (currentTimeMs - (wordDe - _floatLeadMs)) / (du * _floatDurationFactor),
    );
  }

  /// 由【已推进的相位】计算某字符的辉光状态（逐字符波浪，自驱动核心）。
  ///
  /// [bumpPhase] 凸起进度（0~1 窗口内激活，t<0.5 用 bezIn 渐入、t>=0.5 用 bezOut 渐出）。
  /// [floatPhase] 正弦浮层进度（-sin(π·x)·0.05em，与凸起独立）。
  /// 其余参数同 [computeState]。
  ///
  /// 返回 [EmphasizeState]：scale / glowLevel / shadowBlurEm / offsetXEm /
  /// offsetYEm / floatYEm。凸起与浮层都不在窗口内时返回 [EmphasizeState.idle]。
  EmphasizeState computeStateFromPhases({
    required LyricWord word,
    required double bumpPhase,
    required double floatPhase,
    required bool isLastWord,
    required int wordIndex,
    required int anchorCharCount,
  }) {
    // 边界保护：duration 为 0 会触发除零，anchorCharCount 为 0 同理
    if (word.duration <= 0) return EmphasizeState.idle;
    if (anchorCharCount <= 0) return EmphasizeState.idle;

    final bool bumpActive = bumpPhase >= 0 && bumpPhase <= 1;
    final bool floatActive = floatPhase >= 0 && floatPhase <= 1;
    // 凸起与浮层都不在窗口内：未激活或已结束
    if (!bumpActive && !floatActive) return EmphasizeState.idle;

    // transX：前段用 bezIn 渐入（t=0.5 达峰 1），后段用 bezOut 渐出（t=1 归 0）
    final double transX;
    if (bumpActive) {
      if (bumpPhase < 0.5) {
        transX = cubicBezier(bumpPhase * 2, _bezInP1, _bezInP2, 0.58, 1.0);
      } else {
        transX =
            1 - cubicBezier((bumpPhase - 0.5) * 2, _bezOutP1, _bezOutP2, 0.58, 1.0);
      }
    } else {
      transX = 0;
    }

    // 正弦浮层高度（em，向上为负）：floatPhase=0.5 时达最大抬起。
    // **边缘渐隐**：浮层只在凸起窗口内可见，且起始/结束各 _edgeFadeWidth 相位内
    // 从 0 平滑过渡——消除字切换瞬间浮层跳变上移、与字尾浮层尾巴被截断的回落突兀
    //（歌词较快、字切换频繁时更明显）。凸起窗口外（含浮层尾巴）直接置 0。
    final double floatYEm = floatActive
        ? -sin(pi * floatPhase) * _floatAmpEm * _floatEdgeFade(bumpActive, bumpPhase)
        : 0;

    // amount 计算（spec.md 公式，快歌优化）
    // amount = sqrt(duration / 2000)，再 *0.6，封顶 1.2
    // 原公式短字（≤1）取立方会把 1000ms 字压到 0.075，快歌辉光几乎不可见；
    // 统一取 sqrt：短字（快歌）强度显著提升（500ms→0.3、1000ms→0.42），
    // 长字（>2000ms 慢歌）保持原样（原本就 sqrt），不影响慢歌观感。
    double amount = sqrt(word.duration / 2000);
    amount *= _amountScale;
    if (amount > _amountCap) amount = _amountCap;

    // blur 计算（spec.md 公式）
    // blur = (duration / 3000) * 0.5，封顶 0.8
    double blur = word.duration / 3000;
    blur *= _blurScale;
    if (blur > _blurCap) blur = _blurCap;

    // 末尾字加强（spec.md：isLastWord 时 amount *= 1.6, blur *= 1.5）
    // 注意：加强在封顶之后，故末尾字实际 amount 可能超过 1.2
    if (isLastWord) {
      amount *= _lastWordAmountBoost;
      blur *= _lastWordBlurBoost;
    }

    // 最终输出六参数
    // scale = 1 + transX * 0.1 * amount
    // glowLevel = transX * amount（作为 textShadow 的 alpha 通道）
    // shadowBlurEm = min(0.3, blur * 0.3)
    // offsetXEm = -transX * 0.03 * amount * (n/2 - i)（左字向左、右字向右外扩）
    // offsetYEm = -transX * 0.025 * amount（上浮）
    final double scale = 1 + transX * _scaleTransFactor * amount;
    final double glowLevel = transX * amount;
    final double shadowBlurEm = min(_shadowBlurEmCap, blur * 0.3);
    final double offsetXEm =
        -transX * _offsetXFactor * amount * (anchorCharCount / 2 - wordIndex);
    final double offsetYEm = -transX * _offsetYFactor * amount;

    return EmphasizeState(
      scale: scale,
      glowLevel: glowLevel,
      shadowBlurEm: shadowBlurEm,
      offsetXEm: offsetXEm,
      offsetYEm: offsetYEm,
      floatYEm: floatYEm,
    );
  }

  /// 计算某时刻、某字符的辉光状态（绝对时间版）。
  ///
  /// 内部委托 [phasesAt] + [computeStateFromPhases]，行为与自驱动完全一致。
  /// 保留供测试断言；渲染层已改用自驱动相位（见 WordRenderer.tick）。
  EmphasizeState computeState({
    required LyricWord word,
    required int currentTimeMs,
    required bool isLastWord,
    required int wordIndex,
    required int anchorCharCount,
  }) {
    final EmphasizePhases phases = phasesAt(
      word: word,
      currentTimeMs: currentTimeMs,
      wordIndex: wordIndex,
      anchorCharCount: anchorCharCount,
    );
    return computeStateFromPhases(
      word: word,
      bumpPhase: phases.bumpPhase,
      floatPhase: phases.floatPhase,
      isLastWord: isLastWord,
      wordIndex: wordIndex,
      anchorCharCount: anchorCharCount,
    );
  }

  /// 重置。
  ///
  /// 本类无内部可变状态，此方法为 API 占位，与 [WordRenderer.reset] 对齐
  /// 便于上层统一调用 reset 而无需区分渲染器类型。
  void reset() {}

  // ============== 工具方法 ==============

  /// cubic bezier 求值。
  ///
  /// 标准 cubic bezier 公式：B(t) = (1-t)^3*P0 + 3*(1-t)^2*t*P1 + 3*(1-t)*t^2*P2 + t^3*P3
  /// 其中 P0=0, P3=1（CSS cubic-bezier 约定），故简化为：
  /// B(t) = 3*(1-t)^2*t*p1 + 3*(1-t)*t^2*p2 + t^3
  ///
  /// [p3]、[p4] 仅用于完整记录 CSS cubic-bezier(x1, y1, x2, y2) 的四个参数
  /// （方便对照 spec.md "bezIn = bezier(0.2, 0.4, 0.58, 1.0)"），
  /// 实际计算只使用 [p1]、[p2]（对应 P1、P2）。
  @visibleForTesting
  static double cubicBezier(
      double t, double p1, double p2, double p3, double p4) {
    final u = 1 - t;
    return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t;
  }

  /// 判断 code point 是否落在 CJK Unicode 范围内。
  ///
  /// 覆盖范围（spec.md "CJK 检测"）：
  /// - CJK 统一表意：U+4E00 ~ U+9FFF
  /// - 平假名：U+3040 ~ U+309F
  /// - 片假名：U+30A0 ~ U+30FF
  /// - CJK 标点：U+3000 ~ U+303F
  /// - 韩文：U+AC00 ~ U+D7AF
  static bool _isCJKCodePoint(int codePoint) {
    return (codePoint >= 0x4E00 && codePoint <= 0x9FFF) || // CJK 统一表意
        (codePoint >= 0x3040 && codePoint <= 0x309F) || // 平假名
        (codePoint >= 0x30A0 && codePoint <= 0x30FF) || // 片假名
        (codePoint >= 0x3000 && codePoint <= 0x303F) || // CJK 标点
        (codePoint >= 0xAC00 && codePoint <= 0xD7AF); // 韩文
  }

  /// 判断 text 是否仅由符号/标点构成（不含任何字母或数字）。
  ///
  /// 例：`_` `-` `\` `、` `@` `*` `.` `,` `…` `—` `～` 等均返回 true；
  ///     `"a-"` `"你好。"` `"1."` 等含字母/数字的均返回 false。
  ///
  /// 使用 `\p{L}\p{N}` 反向判定：若 text 中无任何字母或数字，则视为纯符号。
  /// CJK 标点（、。：等）属于 `\p{P}`（标点），不会被匹配 → 正确判定为纯符号。
  static bool _isPureSymbol(String text) {
    return text.isNotEmpty && !_letterOrNumberRegex.hasMatch(text);
  }

  /// 判断 text 是否为歌手标签（男：/女：/(男)/合唱/男声 等）。
  ///
  /// 单字标签（男/女/合/童）必须带冒号或括号才判定，避免误伤正常歌词
  /// （如「合欢花」「女儿情」「童年」中的单字）。
  /// 多字标签（男声/女声/合唱/男唱 等）在正常歌词中极少作为独立 word 出现，可直接过滤。
  static bool _isSingerLabel(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    return _singerLabelWithColonRegex.hasMatch(trimmed) ||
        _parenSingerLabelRegex.hasMatch(trimmed) ||
        _multiCharSingerLabelRegex.hasMatch(trimmed);
  }
}
