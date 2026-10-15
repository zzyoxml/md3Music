/// 歌词「平衡行换行」内核：语义分词 + 动态规划最优断点。
///
/// 算法移植自 AMLL `utils/lyric-line-break.ts` 的 `calcBalancedBreaks`：在可用
/// 宽度内求一组断点，使「各行未用满宽度的方差」最小，同时对断点位置加奖惩——
/// 标点之后 > 空格之后 > CJK 词界 > 其他位置。
///
/// AMLL 用 `Intl.Segmenter` 做语义分词，Dart/Flutter 侧没有等价实现，本文件用
/// 码点级近似（见 [segmentLyricUnits]）：拉丁词整词、CJK 每字一组、标点附着前一
/// 单元。代价是纯中文行可能在词组中间断开——这与 Apple Music 自身对中文歌词的
/// 处理一致（中文无空格，只能按宽度均衡），而「第二行只剩两三个字」这个主要
/// 痛点由 DP 消除。
///
/// 本文件必须是纯 Dart：宽度由调用方给出，便于脱离字体环境单测。
library;

import 'package:flutter/foundation.dart' show immutable;

/// 换行的最小不可分单元：一段文本 + 它的测量宽度。
@immutable
class BalanceUnit {
  const BalanceUnit({
    required this.text,
    required this.width,
    this.isSpace = false,
  });

  /// 单元文本（所有单元拼接后须与原串逐字符相等）。
  final String text;

  /// 测量宽度（像素）。
  final double width;

  /// 是否为纯空白单元（在空白处断行有奖励）。
  final bool isSpace;
}

// ============== 惩罚/奖励常量（相对可用宽的比例，平方后参与 DP）==============

/// 单个单元本身就比容器宽时的大惩罚倍数（被迫独立成行）。
const double _overflowPenaltyMultiplier = 1000;

/// 在 CJK 词组中间断开的惩罚比例。
const double _cjkBreakPenaltyRatio = 0.15;

/// 在普通文本位置（非空格、非标点、非 CJK 词界）断开的惩罚比例。
const double _normalBreakPenaltyRatio = 0.5;

/// 在空格处断开的奖励比例。
const double _spaceBreakRewardRatio = 0.4;

/// 在标点处断开的奖励比例（比空格略高，优先在标点后换行）。
const double _punctuationBreakRewardRatio = 0.6;

/// 单元末尾若是这些字符，判定为「在标点后换行」→ 奖励。
final RegExp _trailingPunctuationRegex = RegExp(
  r'[,.;:!?，。；：！？、）】》」』’”)’}\]…]$',
);

/// 是否 CJK 文字码点（汉字 / 日文假名 / 韩文音节 / 兼容区）。
bool isCjkCodePoint(int rune) =>
    (rune >= 0x3040 && rune <= 0x30ff) || // 平假名 + 片假名
    (rune >= 0x3400 && rune <= 0x4dbf) || // 汉字扩展 A
    (rune >= 0x4e00 && rune <= 0x9fff) || // 汉字基本区
    (rune >= 0xac00 && rune <= 0xd7af) || // 韩文音节
    (rune >= 0xf900 && rune <= 0xfaff); // 兼容汉字

enum _UnitKind { cjk, latin, space, punctuation, combining, other }

_UnitKind _kindOfRune(int rune) {
  if (rune == 0x20 ||
      rune == 0x09 ||
      rune == 0x0a ||
      rune == 0x0d ||
      (rune >= 0x2000 && rune <= 0x200b) ||
      rune == 0x3000) {
    return _UnitKind.space;
  }
  // 组合附加符号 / ZWJ：必须粘在前一单元上，否则会拆坏带音节的字母
  if ((rune >= 0x0300 && rune <= 0x036f) || rune == 0x200d) {
    return _UnitKind.combining;
  }
  if (isCjkCodePoint(rune)) return _UnitKind.cjk;
  final bool isLatinLetterOrDigit =
      (rune >= 0x41 && rune <= 0x5a) ||
      (rune >= 0x61 && rune <= 0x7a) ||
      (rune >= 0x30 && rune <= 0x39) ||
      (rune >= 0xc0 && rune <= 0x24f) || // 拉丁扩展（带音节的欧洲字符）
      rune == 0x27 ||
      rune == 0x2019 || // ’ 视作词内撇号
      rune == 0x2d; // - 连字符不断词
  if (isLatinLetterOrDigit) return _UnitKind.latin;
  if (_trailingPunctuationRegex.hasMatch(String.fromCharCode(rune))) {
    return _UnitKind.punctuation;
  }
  return _UnitKind.other;
}

/// 把文本切成不可再分的换行单元；**拼接结果与原串逐字符相等**。
///
/// 规则：拉丁词（含词内撇号/连字符）整块、空白整块、CJK 每字一块、
/// 标点与组合符号附着到前一块（避免视觉行以标点开头），其余按码点成块。
/// 用 `runes` 遍历码点，代理对（emoji）不会被拆坏。
List<String> segmentLyricUnits(String text) {
  final List<String> units = <String>[];
  final StringBuffer buffer = StringBuffer();
  _UnitKind? kind;
  for (final int rune in text.runes) {
    final _UnitKind k = _kindOfRune(rune);
    final bool attachToPrevious =
        (k == _UnitKind.punctuation || k == _UnitKind.combining) &&
        buffer.isNotEmpty &&
        kind != _UnitKind.space;
    if (attachToPrevious) {
      buffer.writeCharCode(rune);
      continue;
    }
    // cjk / other 每码点自成一单元；其余同类字符并入同一单元
    final bool startNew =
        buffer.isEmpty ||
        kind != k ||
        k == _UnitKind.cjk ||
        k == _UnitKind.other;
    if (startNew) {
      if (buffer.isNotEmpty) units.add(buffer.toString());
      buffer.clear();
      kind = k;
    }
    buffer.writeCharCode(rune);
  }
  if (buffer.isNotEmpty) units.add(buffer.toString());
  return units;
}

/// 贪心断点：**必须与改造前的旧规则逐字等价**（开关关闭时的行为基线）。
///
/// 旧规则见 `word_renderer.dart` / `lyric_layout.dart`：
/// `dx + width > maxWidth && dx > 0` 时换行。
List<int> greedyRowStarts(List<BalanceUnit> units, double maxWidth) {
  final List<int> starts = <int>[0];
  if (units.isEmpty || !maxWidth.isFinite || maxWidth <= 0) return starts;
  double dx = 0;
  for (int i = 0; i < units.length; i++) {
    final double w = units[i].width;
    if (dx + w > maxWidth && dx > 0) {
      starts.add(i);
      dx = 0;
    }
    dx += w;
  }
  return starts;
}

/// DP 求平衡断点。
///
/// 返回每视觉行的**起始单元下标**（升序，首元素恒为 0，不含 `units.length`）。
List<int> balancedRowStarts(List<BalanceUnit> units, double maxWidth) {
  final int n = units.length;
  if (n == 0 || !maxWidth.isFinite || maxWidth <= 0) return <int>[0];

  final List<double> prefixWidth = List<double>.filled(n + 1, 0);
  for (int i = 0; i < n; i++) {
    prefixWidth[i + 1] = prefixWidth[i] + units[i].width;
  }
  // 一行放得下就不断行
  if (prefixWidth[n] <= maxWidth) return <int>[0];

  final double penCjk =
      maxWidth * maxWidth * _cjkBreakPenaltyRatio * _cjkBreakPenaltyRatio;
  final double penNormal =
      maxWidth * maxWidth * _normalBreakPenaltyRatio * _normalBreakPenaltyRatio;
  final double rewardSpace =
      -(maxWidth * maxWidth * _spaceBreakRewardRatio * _spaceBreakRewardRatio);
  final double rewardPunctuation =
      -(
        maxWidth *
        maxWidth *
        _punctuationBreakRewardRatio *
        _punctuationBreakRewardRatio
      );

  // dp[i] = 从单元 i 排到结尾的最小代价；next[i] = i 之后下一行的起始下标
  final List<double> dp = List<double>.filled(n + 1, double.infinity);
  final List<int> next = List<int>.filled(n + 1, -1);
  dp[n] = 0;

  for (int i = n - 1; i >= 0; i--) {
    for (int j = i + 1; j <= n; j++) {
      final double w = prefixWidth[j] - prefixWidth[i];
      double lineCost;
      if (w > maxWidth) {
        // 单元宽度非负，再加单元只会更宽 → 单元素行是被迫超宽，其余剪枝
        if (j != i + 1) break;
        final double over = w - maxWidth;
        lineCost = _overflowPenaltyMultiplier * over * over;
      } else {
        // 目标函数：让每行都尽量填满可用宽（等价于各行长度方差最小）
        final double slack = maxWidth - w;
        lineCost = slack * slack;
      }

      double breakPenalty = 0;
      if (j < n) {
        final BalanceUnit prev = units[j - 1];
        if (_trailingPunctuationRegex.hasMatch(prev.text)) {
          breakPenalty = rewardPunctuation;
        } else if (prev.isSpace) {
          breakPenalty = rewardSpace;
        } else if (isCjkCodePoint(prev.text.runes.last) ||
            isCjkCodePoint(units[j].text.runes.first)) {
          breakPenalty = penCjk;
        } else {
          breakPenalty = penNormal;
        }
      }

      final double total = lineCost + breakPenalty + dp[j];
      if (total < dp[i]) {
        dp[i] = total;
        next[i] = j;
      }
    }
  }

  final List<int> starts = <int>[0];
  int curr = 0;
  while (curr < n && next[curr] > curr && next[curr] < n) {
    curr = next[curr];
    starts.add(curr);
  }
  return starts;
}
