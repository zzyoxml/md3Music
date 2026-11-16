/// 歌词换行计划：一次算出视觉行的断点 / 文本 / 宽度，供**测量与绘制共用**。
///
/// 存在理由（本仓铁律）：同一行的「行高测量」与「逐字 / 整行 / 模糊绘制」必须用
/// 同一套断点，否则行数与行盒不一致会导致歌词重叠或跳动。改造前这条约束靠 6 处
/// 复制同一条贪心公式维持；现在断点只在本类算一次，其余全是消费方。
///
/// 单元空间见 [LyricUnitSpace]：KRC 行必须是 word 空间（`WordRenderer` 要按 word
/// 落点），纯文本行用分段空间。
library;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/painting.dart';

import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import 'lyric_line_balance.dart';

/// 断点所在的单元空间。
enum LyricUnitSpace {
  /// 单元 = `LyricLine.words`；`rowStarts` 可直接当 word 下标用。
  words,

  /// 单元 = [segmentLyricUnits] 的语义分段（无 word 的行 + 开启平衡）。
  segments,

  /// 降级：断点来自 TextPainter 自动换行（无 word 的行 + 关闭平衡），
  /// 与改造前行为逐字一致。此空间下 [LyricWrapPlan.rowIndexOfUnit] 恒返回 0。
  painterWrap,
}

/// 一行歌词的换行计划（不可变值对象）。
class LyricWrapPlan {
  const LyricWrapPlan({
    required this.rowStarts,
    required this.rowTexts,
    required this.rowWidths,
    required this.unitSpace,
  });

  /// 每视觉行的起始**单元**下标（升序，首元素 0）。
  final List<int> rowStarts;

  /// 每视觉行的文本（拼接后等于原行文本；words 空间为 word 文本重拼）。
  final List<String> rowTexts;

  /// 每视觉行的宽度。
  final List<double> rowWidths;

  /// 单元空间，见 [LyricUnitSpace]。
  final LyricUnitSpace unitSpace;

  /// 视觉行数（>= 1）。
  int get rowCount => rowTexts.length;

  /// 是否占多行高度。
  bool get isMultiLine => rowTexts.length > 1;

  /// 单元（word / 分段）下标 -> 视觉行号。
  int rowIndexOfUnit(int unitIndex) {
    if (unitSpace == LyricUnitSpace.painterWrap) return 0;
    for (int r = rowStarts.length - 1; r >= 0; r--) {
      if (unitIndex >= rowStarts[r]) return r;
    }
    return 0;
  }
}

/// 换行计划的唯一生产者：测宽 + DP/贪心 + 结果缓存。
class LyricWrapPlanner {
  LyricWrapPlanner._();

  /// 计划缓存（LRU：命中重插到末尾，插入前逐出最旧）。
  ///
  /// Dart 默认 `Map` 即 `LinkedHashMap`，插入序 == 迭代序，故 `keys.first` 即最旧。
  static final Map<String, LyricWrapPlan> _cache = <String, LyricWrapPlan>{};

  /// 计划缓存上限。计划只在「行集 / 字号 / 字族 / 行距 / 可用宽 / 开关」变化时重建；
  /// 一首长歌（含翻译副行）可达数百项，故上限须显著高于 256，且超限只逐出最旧、
  /// 而非整表清空——否则长歌缓存命中率归零且每若干帧清一次表。
  static const int _maxCacheEntries = 1024;

  /// 单元自然宽度 memo（键 = 文本 + 字体度量）。
  ///
  /// 转屏 / 拖字号时单元文本不变、字形宽大多不变，而逐单元 layout 是交互态重算的
  /// 主要成本。自定义字体每次加载都用带计数器的**唯一 family 名**
  /// （见 `LyricPreferences._tryLoadCustomFont`），故字体更新后键自然失效，无需额外清理。
  static final Map<String, double> _unitWidthCache = <String, double>{};
  static const int _maxUnitWidthCacheEntries = 4096;

  @visibleForTesting
  static void clearCache() {
    _cache.clear();
    _unitWidthCache.clear();
  }

  /// 缓存查找（LRU：命中则重插到末尾，使其不易被逐出）。
  static LyricWrapPlan? _lookup(String key) {
    final LyricWrapPlan? hit = _cache.remove(key);
    if (hit != null) _cache[key] = hit;
    return hit;
  }

  /// 按行类型分派：有 words 走 word 空间，否则走文本空间。
  static LyricWrapPlan forLine(
    LyricLine line,
    TextStyle style,
    double maxWidth, {
    required bool balanced,
  }) {
    if (line.words.isNotEmpty) {
      return forUnits(
        line.words.map((LyricWord w) => w.text).toList(growable: false),
        style,
        maxWidth,
        balanced: balanced,
        space: LyricUnitSpace.words,
      );
    }
    return forText(line.text, style, maxWidth, balanced: balanced);
  }

  /// 任意文本（MD 主行 / 副行、AM 无 word 的行都走这里）。
  static LyricWrapPlan forText(
    String text,
    TextStyle style,
    double maxWidth, {
    required bool balanced,
  }) {
    if (!balanced) return _painterWrap(text, style, maxWidth);
    return forUnits(
      segmentLyricUnits(text),
      style,
      maxWidth,
      balanced: true,
      space: LyricUnitSpace.segments,
    );
  }

  /// 已知单元文本时直接求计划（KRC 行、以及已分好段的文本）。
  static LyricWrapPlan forUnits(
    List<String> unitTexts,
    TextStyle style,
    double maxWidth, {
    required bool balanced,
    required LyricUnitSpace space,
  }) {
    final String key =
        'U|${space.index}|$balanced|${_widthKey(maxWidth)}|'
        '${_styleKey(style)}|${_unitsKeyPart(unitTexts)}';
    final LyricWrapPlan? cached = _lookup(key);
    if (cached != null) return cached;

    final List<BalanceUnit> units = <BalanceUnit>[];
    final String metricKey = _styleKey(style);
    TextPainter? painter;
    for (final String t in unitTexts) {
      final String widthKey = '$t\u0002$metricKey';
      double? w = _unitWidthCache[widthKey];
      if (w == null) {
        final TextPainter p =
            painter ??= TextPainter(textDirection: TextDirection.ltr);
        p.text = TextSpan(text: t, style: style);
        p.layout();
        w = p.width;
        _rememberUnitWidth(widthKey, w);
      }
      units.add(BalanceUnit(text: t, width: w, isSpace: t.trim().isEmpty));
    }
    painter?.dispose();

    final List<int> starts = balanced
        ? balancedRowStarts(units, maxWidth)
        : greedyRowStarts(units, maxWidth);
    final LyricWrapPlan plan = _buildPlan(units, starts, space);
    _remember(key, plan);
    return plan;
  }

  /// 关闭平衡 + 无 word 的行：沿用 TextPainter 自动换行（改造前的既有行为）。
  ///
  /// 视觉行的切法与 `LineRenderer._paintMultiLineAligned` 的无 word 分支完全相同
  /// （沿 `getLineBoundary` 逐行推进），保证「关闭态 == 旧版」逐字成立。
  static LyricWrapPlan _painterWrap(
    String text,
    TextStyle style,
    double maxWidth,
  ) {
    final String key =
        'P|${_widthKey(maxWidth)}|${_styleKey(style)}|${text.length}:$text';
    final LyricWrapPlan? cached = _lookup(key);
    if (cached != null) return cached;

    final TextPainter painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    );
    if (maxWidth.isFinite && maxWidth > 0) {
      painter.layout(maxWidth: maxWidth);
    } else {
      painter.layout();
    }

    final List<int> starts = <int>[0];
    final List<String> rowTexts = <String>[];
    final List<double> rowWidths = <double>[];
    int pos = 0;
    while (pos < text.length) {
      final boundary = painter.getLineBoundary(TextPosition(offset: pos));
      final int end = boundary.end;
      if (end <= pos) break;
      final String rowText = text.substring(pos, end);
      rowTexts.add(rowText);
      rowWidths.add(_measureSingleLineWidth(rowText, style));
      pos = end;
      if (pos < text.length) starts.add(pos);
    }
    painter.dispose();
    if (rowTexts.isEmpty) {
      rowTexts.add(text);
      rowWidths.add(_measureSingleLineWidth(text, style));
    }

    final LyricWrapPlan plan = LyricWrapPlan(
      rowStarts: starts,
      rowTexts: rowTexts,
      rowWidths: rowWidths,
      unitSpace: LyricUnitSpace.painterWrap,
    );
    _remember(key, plan);
    return plan;
  }

  /// 按断点把单元切成行文本与行宽。
  static LyricWrapPlan _buildPlan(
    List<BalanceUnit> units,
    List<int> starts,
    LyricUnitSpace space,
  ) {
    final List<String> rowTexts = <String>[];
    final List<double> rowWidths = <double>[];
    for (int r = 0; r < starts.length; r++) {
      final int s = starts[r];
      final int e = r + 1 < starts.length ? starts[r + 1] : units.length;
      final StringBuffer sb = StringBuffer();
      double w = 0;
      for (int i = s; i < e; i++) {
        sb.write(units[i].text);
        w += units[i].width;
      }
      rowTexts.add(sb.toString());
      rowWidths.add(w);
    }
    if (rowTexts.isEmpty) {
      rowTexts.add('');
      rowWidths.add(0);
    }
    return LyricWrapPlan(
      rowStarts: starts,
      rowTexts: rowTexts,
      rowWidths: rowWidths,
      unitSpace: space,
    );
  }

  /// 单行文本的自然宽度（不受约束，供行宽/对齐使用）。
  static double _measureSingleLineWidth(String text, TextStyle style) {
    final TextPainter painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: double.infinity);
    final double width = painter.width;
    painter.dispose();
    return width;
  }

  /// 写入计划缓存（LRU：插入前逐出最旧，替代原「满即整表 clear」）。
  static void _remember(String key, LyricWrapPlan plan) {
    _cache.remove(key);
    if (_cache.length >= _maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = plan;
  }

  /// 写入单元宽度 memo（同上 LRU 逐出策略）。
  static void _rememberUnitWidth(String key, double width) {
    if (_unitWidthCache.length >= _maxUnitWidthCacheEntries) {
      _unitWidthCache.remove(_unitWidthCache.keys.first);
    }
    _unitWidthCache[key] = width;
  }

  /// 只取影响宽度的字段：颜色不参与测量，不能让换行计划随主题变色而重算。
  static String _styleKey(TextStyle style) =>
      '${style.fontSize}|${style.fontWeight?.value}|${style.fontFamily}|'
      '${style.height}|${style.letterSpacing}';

  static String _widthKey(double maxWidth) =>
      maxWidth.isFinite ? maxWidth.toStringAsFixed(1) : 'inf';

  /// 单元列表指纹：带个数并用分隔符连接，避免不同分组方式撞同一个键。
  static String _unitsKeyPart(List<String> unitTexts) {
    final StringBuffer sb = StringBuffer('${unitTexts.length}#');
    for (final String t in unitTexts) {
      sb.write(t);
      sb.writeCharCode(0x02);
    }
    return sb.toString();
  }
}
