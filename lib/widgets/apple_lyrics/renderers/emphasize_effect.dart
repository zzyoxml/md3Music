/// 强调辉光（emphasize）效果
///
/// 参照 spec.md "Requirement: 强调辉光（emphasize）效果" 与 AMLL `lyric-line.ts:510-651` 实现。
/// 当字时长 >= 1000ms 且符合字符长度要求（CJK 任意 / 非 CJK 1~7）时触发辉光：
/// - 字内进度 0~0.5 用 bezIn 曲线渐入（缩放放大、辉光增强）
/// - 字内进度 0.5~1 用 bezOut 曲线渐出（缩放回 1.0、辉光衰减）
/// - 末尾字（isLastWord）amount/blur 加强 1.6/1.5 倍
/// - 字符间错位 delay：wordIndex 越大，字活跃起始时间越晚
library;

import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/lyric_line.dart';

/// 强调辉光状态。
///
/// 不可变值对象，由 [EmphasizeEffect.computeState] 输出，供绘制层
/// （如 CustomPainter）读取 scale、glowLevel、shadowBlurEm 三个参数
/// 应用 transform 与 textShadow。
@immutable
class EmphasizeState {
  /// 缩放比例，1.0~1.12（含末尾字加强后可能略高）。
  final double scale;

  /// 辉光强度 0~1.2（作为 textShadow 的 alpha 通道）。
  final double glowLevel;

  /// 阴影模糊半径（em 单位），封顶 0.3。
  final double shadowBlurEm;

  const EmphasizeState({
    required this.scale,
    required this.glowLevel,
    required this.shadowBlurEm,
  });

  /// 空闲状态：无辉光、无缩放、无阴影。
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
          shadowBlurEm == other.shadowBlurEm;

  @override
  int get hashCode => Object.hash(scale, glowLevel, shadowBlurEm);

  @override
  String toString() =>
      'EmphasizeState(scale: $scale, glowLevel: $glowLevel, '
      'shadowBlurEm: $shadowBlurEm)';
}

/// 强调辉光效果计算器。
///
/// 无状态工具类：所有计算基于入参，内部不持有可变状态。
/// 通过 [shouldEmphasize] 判断 word 是否需要辉光，
/// 通过 [computeState] 计算某时刻的辉光参数（scale / glowLevel / shadowBlurEm）。
class EmphasizeEffect {
  EmphasizeEffect();

  // ============== 触发条件常量 ==============

  /// 触发阈值：字时长 >= 1000ms
  static const int _durationThresholdMs = 1000;

  /// 非 CJK 字最大长度
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

  /// 判断 word 是否触发辉光。
  ///
  /// 触发条件（spec.md "Requirement: 强调辉光（emphasize）效果" + 内容过滤）：
  /// - 字时长 [LyricWord.duration] >= 1000ms
  /// - 文本非空
  /// - 【新增】非纯符号/标点（_ - \ 、 @ * . , … — 等）
  /// - 【新增】非歌手标签（男：/女：/(男)/合唱 等）
  /// - 且为 CJK 字符（任意长度）或 非 CJK 字符长度 1~7
  ///
  /// CJK 判定：[String.runes] 中任一字符落在 CJK 统一表意 / 平假名 /
  /// 片假名 / CJK 标点 / 韩文 任一 Unicode 范围内，即视为 CJK 字符。
  ///
  /// 结果仅依赖 [LyricWord.text] 与 [LyricWord.duration]（行绑定后不变），可安全缓存。
  static bool shouldEmphasize(LyricWord word) {
    if (word.duration < _durationThresholdMs) return false;
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

  /// 计算某时刻的辉光状态。
  ///
  /// [word] 目标字（含 startTime / duration）。
  /// [currentTimeMs] 当前播放时间（毫秒，绝对时间）。
  /// [isLastWord] 是否末尾字（影响 amount/blur 加强系数）。
  /// [wordIndex] 字索引（用于字符错位 delay 计算）。
  /// [anchorCharCount] 该字字符数（用于 delay 分母）。
  ///
  /// 返回 [EmphasizeState]：scale / glowLevel / shadowBlurEm。
  /// - 当 currentTimeMs 不在 [wordDe, wordDe + duration] 区间时返回 [EmphasizeState.idle]
  /// - 字内进度 t < 0.5 用 bezIn 曲线渐入；t >= 0.5 用 bezOut 曲线渐出
  EmphasizeState computeState({
    required LyricWord word,
    required int currentTimeMs,
    required bool isLastWord,
    required int wordIndex,
    required int anchorCharCount,
  }) {
    // 边界保护：duration 为 0 会触发除零，anchorCharCount 为 0 同理
    if (word.duration <= 0) return EmphasizeState.idle;
    if (anchorCharCount <= 0) return EmphasizeState.idle;

    // 字起始时间
    final int de = word.startTime;

    // 字内进度 t（未 clamp，超出 [0,1] 视为未激活）
    // 与上浮动画同步：从 word.startTime 开始即触发辉光
    final double t = (currentTimeMs - de) / word.duration;

    // 超出 [0, 1] 范围：字未激活或已结束，返回 idle
    if (t < 0 || t > 1) return EmphasizeState.idle;

    // 计算 transX：前半段用 bezIn(t*2)，后半段用 bezOut((1-t)*2)
    // 前半段从 0 渐增到 1（bezIn(0)=0, bezIn(1)=1），后半段从 1 渐减回 0
    final double transX;
    if (t < 0.5) {
      transX = cubicBezier(t * 2, _bezInP1, _bezInP2, 0.58, 1.0);
    } else {
      transX = cubicBezier((1 - t) * 2, _bezOutP1, _bezOutP2, 0.58, 1.0);
    }

    // amount 计算（spec.md 公式）
    // amount = (duration / 2000)，>1 时取 sqrt，<=1 时取立方，再 *0.6，封顶 1.2
    double amount = word.duration / 2000;
    if (amount > 1) {
      amount = sqrt(amount);
    } else {
      amount = amount * amount * amount; // ^3
    }
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

    // 最终输出三参数
    // scale = 1 + transX * 0.1 * amount
    // glowLevel = transX * amount（作为 textShadow 的 alpha 通道）
    // shadowBlurEm = min(0.3, blur * 0.3)
    final double scale = 1 + transX * _scaleTransFactor * amount;
    final double glowLevel = transX * amount;
    final double shadowBlurEm = min(_shadowBlurEmCap, blur * 0.3);

    return EmphasizeState(
      scale: scale,
      glowLevel: glowLevel,
      shadowBlurEm: shadowBlurEm,
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
