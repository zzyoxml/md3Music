/// 男女对唱歌词布局处理器。
///
/// 支持两种歌词格式：
/// 1. **前缀模式**：「男：你好」「女：你好啊」—— 标记和歌词在同一行
/// 2. **标记行模式**：「女：」独占一行，后续歌词行属于该性别，直到下一个标记行
///
/// 剔除标记文本，并根据首次出现的性别决定左右对齐：
/// - 先出现「男」→ 男=左，女=右
/// - 先出现「女」→ 女=左，男=右
/// - 「合」始终居中
/// 翻译/罗马音若同样带标记则一并剔除，对齐跟随原文。
library;

import '../models/lyric_line.dart';

/// 对唱歌词对齐方式。
enum DuetAlignment {
  /// 默认左对齐（非对唱行，或功能关闭时）。
  defaultAlign,
  left,
  right,
  center,
}

/// 对唱歌词处理结果。
class DuetResult {
  /// 剔除标记后的行列表（与原列表等长、等时间戳）。
  final List<LyricLine> cleanedLines;

  /// 每行对应的对齐方式。
  final List<DuetAlignment> alignments;

  DuetResult(this.cleanedLines, this.alignments);
}

/// 男女对唱歌词布局处理器。
class DuetLayout {
  DuetLayout._();

  /// 匹配行首的性别标记：男/女/合 + 全角或半角冒号 + 可选空白。
  static final RegExp _prefixRegExp = RegExp(r'^(男|女|合)[：:]\s*');

  /// 判断一行是否为纯标记行（仅「男：」「女：」「合：」+ 可选空白，无歌词内容）。
  /// 标记行的对齐会「继承」到后续歌词行，直到遇到下一个标记行。
  static bool _isPureMarkerLine(String text) {
    return _prefixRegExp.hasMatch(text) &&
        text.replaceFirst(_prefixRegExp, '').trim().isEmpty;
  }

  /// 提取标记行的性别（男/女/合），仅当为纯标记行时返回。
  static String? _markerGender(String text) {
    if (!_isPureMarkerLine(text)) return null;
    return _prefixRegExp.firstMatch(text)?.group(1);
  }

  /// 处理整段歌词：返回剔除标记后的行列表与每行对齐方式。
  ///
  /// [enabled] 为 false 时直接返回原列表与 [DuetAlignment.defaultAlign]，
  /// 保留原 [LyricLine] 引用（零拷贝）。
  static DuetResult process(List<LyricLine> lines, bool enabled) {
    if (!enabled) {
      return DuetResult(
        List.of(lines),
        List.filled(lines.length, DuetAlignment.defaultAlign),
      );
    }

    // 第一遍：找出首个男/女标记，决定左右分配
    // 仅「合」标记的歌词不构成对唱，默认男=左
    String? firstGender;
    String? currentGender; // 标记行模式下的当前性别
    for (final line in lines) {
      final text = line.text;
      // 优先检查纯标记行
      final marker = _markerGender(text);
      if (marker != null) {
        if (marker == '男' || marker == '女') {
          firstGender ??= marker;
        }
        currentGender = marker;
        continue;
      }
      // 再检查前缀模式
      final m = _prefixRegExp.firstMatch(text);
      if (m != null) {
        final g = m.group(1);
        if (g == '男' || g == '女') {
          firstGender ??= g;
        }
      }
    }
    final String leftGender = firstGender ?? '男';
    final String rightGender = leftGender == '男' ? '女' : '男';

    final cleaned = <LyricLine>[];
    final aligns = <DuetAlignment>[];
    // 标记行模式：当前激活的性别（由纯标记行设置，应用到后续歌词行）
    String? activeGender;
    for (final line in lines) {
      final text = line.text;
      // 1. 检查是否为纯标记行
      final marker = _markerGender(text);
      if (marker != null) {
        // 纯标记行：更新 activeGender，行本身设为 center 对齐
        // 文本置空（不显示标记行），保留时间戳供 onSeek 定位
        activeGender = marker;
        cleaned.add(line.copyWith(
          text: '',
          words: const [],
          clearTranslation: true,
          clearRoma: true,
        ));
        aligns.add(_genderToAlign(marker, leftGender, rightGender));
        continue;
      }
      // 2. 检查前缀模式（标记和歌词同行）
      final m = _prefixRegExp.firstMatch(text);
      if (m != null) {
        final gender = m.group(1)!;
        // 前缀模式也更新 activeGender，让后续无前缀行继承对齐
        // 例如「男：梦中人熟悉的脸孔」后续的「你是我守候的温柔」也属于男声
        activeGender = gender;
        final cleanedText = line.text.substring(m.end);
        final cleanedWords = _stripPrefixWords(line.words, m.end);
        final newTrans = _stripPrefix(line.translation);
        final newRoma = _stripPrefix(line.roma);
        final clearTrans = newTrans != null && newTrans.isEmpty;
        final clearRoma = newRoma != null && newRoma.isEmpty;

        cleaned.add(line.copyWith(
          text: cleanedText,
          words: cleanedWords,
          translation: clearTrans ? null : newTrans,
          clearTranslation: clearTrans,
          roma: clearRoma ? null : newRoma,
          clearRoma: clearRoma,
        ));
        aligns.add(_genderToAlign(gender, leftGender, rightGender));
        continue;
      }
      // 3. 普通歌词行：继承最近一次标记（前缀行或纯标记行）的性别对齐
      // 例如「男：梦中人熟悉的脸孔」后的「你是我守候的温柔」继承男声=left
      cleaned.add(line);
      if (activeGender != null) {
        aligns.add(_genderToAlign(activeGender, leftGender, rightGender));
      } else {
        aligns.add(DuetAlignment.defaultAlign);
      }
    }
    return DuetResult(cleaned, aligns);
  }

  /// 性别 → 对齐方式。
  static DuetAlignment _genderToAlign(
      String gender, String leftGender, String rightGender) {
    if (gender == '合') return DuetAlignment.center;
    if (gender == leftGender) return DuetAlignment.left;
    if (gender == rightGender) return DuetAlignment.right;
    return DuetAlignment.defaultAlign;
  }

  /// 从 words 列表头部移除累计字符数等于 [prefixCharCount] 的 word。
  ///
  /// 前缀通常是一个 word（「男：」）或两个 word（「男」「：」），也可能带尾随空白。
  /// 若前缀边界落在 word 内部，则拆分该 word，保留尾部。
  /// 无法精确匹配时保守返回原列表（避免破坏逐字时间轴）。
  static List<LyricWord> _stripPrefixWords(
      List<LyricWord> words, int prefixCharCount) {
    if (words.isEmpty || prefixCharCount <= 0) return words;
    int consumed = 0;
    for (int i = 0; i < words.length; i++) {
      final w = words[i];
      final len = w.text.length;
      if (consumed + len > prefixCharCount) {
        // 边界落在当前 word 内部：拆分保留尾部
        final remain = prefixCharCount - consumed;
        if (remain > 0 && remain < len) {
          final tail = w.text.substring(remain);
          return <LyricWord>[
            LyricWord(
              startTime: w.startTime,
              duration: w.duration,
              text: tail,
            ),
            ...words.sublist(i + 1),
          ];
        }
        // remain==0 或 remain==len：边界对齐，交给下方相等分支处理
        break;
      }
      consumed += len;
      if (consumed == prefixCharCount) {
        return words.sublist(i + 1);
      }
    }
    return words;
  }

  /// 剔除翻译/罗马音文本开头的性别标记。
  static String? _stripPrefix(String? text) {
    if (text == null) return null;
    return text.replaceFirst(_prefixRegExp, '');
  }
}
