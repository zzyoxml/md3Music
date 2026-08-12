/// 男女对唱歌词布局处理器。
///
/// 支持三种歌词格式：
/// 1. **中文前缀模式**：「男：你好」「女：你好啊」—— 标记和歌词在同一行
/// 2. **中文标记行模式**：「女：」独占一行，后续歌词行属于该性别
/// 3. **歌手名标记行模式**：「Ed Sheeran：」「Taylor Swift：」「Taylor Swift/Ed Sheeran：」
///    独占一行，后续歌词行属于该歌手；多歌手用 `/` 分隔视为合唱
///
/// 中文模式按男=左/女=右/合=居中分配；歌手名模式按首次出现顺序，
/// 第一个歌手=left，第二个不同歌手=right，多歌手合唱=center。
///
/// 人员名单（Lyrics by/Composed by/Produced by 等）不参与对唱分组，保持默认对齐。
/// 翻译/罗马音若同样带中文前缀则一并剔除，对齐跟随原文。
library;

import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';

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

  /// 匹配行首的中文性别标记：男/女/合 + 全角或半角冒号 + 可选空白。
  static final RegExp _prefixRegExp = RegExp(r'^(男|女|合)[：:]\s*');

  /// 匹配行尾的冒号（歌手名标记行）：如「Ed Sheeran：」「Taylor Swift/Ed Sheeran：」。
  /// 允许全角/半角冒号，冒号前可有空白，冒号后可有尾随空白。
  /// 要求整行仅含「歌手名 + 冒号」（去除冒号后无歌词内容）。
  static final RegExp _singerMarkerRegExp = RegExp(r'^.+?[：:]\s*$');

  /// 人员名单关键词（英文 + 中文常见变体）。
  /// 匹配这些行时不视为对唱标记，保持默认对齐。
  static final RegExp _creditsRegExp = RegExp(
    r'^\s*(lyrics\s*by|composed\s*by|produced\s*by|music\s*by|words\s*by|'
    r'arranged\s*by|mixed\s*by|recorded\s*by|written\s*by|'
    r'作词|作曲|编曲|混音|录音|制作人|制作|词：|曲：|编曲：|混音：|录音：|'
    r'cover|vocal|guitar|bass|drum|keyboard|piano|string)',
    caseSensitive: false,
  );

  /// 判断一行是否为纯中文性别标记行（仅「男：」「女：」「合：」无歌词内容）。
  static bool _isPureGenderMarker(String text) {
    return _prefixRegExp.hasMatch(text) &&
        text.replaceFirst(_prefixRegExp, '').trim().isEmpty;
  }

  /// 提取纯中文性别标记行的性别（男/女/合）。
  static String? _genderMarker(String text) {
    if (!_isPureGenderMarker(text)) return null;
    return _prefixRegExp.firstMatch(text)?.group(1);
  }

  /// 判断一行是否为人员名单（Lyrics by / 作词 / 等）。
  static bool _isCreditsLine(String text) {
    return _creditsRegExp.hasMatch(text);
  }

  /// 解析歌手名标记行，返回歌手列表；非标记行返回 null。
  ///
  /// 例如「Ed Sheeran：」→ ['Ed Sheeran']
  /// 「Taylor Swift/Ed Sheeran：」→ ['Taylor Swift', 'Ed Sheeran']
  /// 「男：」→ null（交给中文模式处理）
  /// 「Lyrics by：Ed Sheeran」→ null（人员名单）
  static List<String>? _singerMarker(String text) {
    // 先排除中文性别标记（交给中文模式）
    if (_prefixRegExp.hasMatch(text)) return null;
    // 排除人员名单
    if (_isCreditsLine(text)) return null;
    // 必须匹配「内容 + 冒号 + 结尾」
    final m = _singerMarkerRegExp.firstMatch(text);
    if (m == null) return null;
    // 提取冒号前的歌手名部分
    final colonIdx = text.lastIndexOf('：');
    final colonIdx2 = text.lastIndexOf(':');
    final idx = colonIdx > colonIdx2 ? colonIdx : colonIdx2;
    if (idx <= 0) return null;
    final namesPart = text.substring(0, idx).trim();
    if (namesPart.isEmpty) return null;
    // 按 `/` 分割多歌手
    final singers = namesPart
        .split('/')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    return singers.isNotEmpty ? singers : null;
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

    // 第一遍：确定对唱分组
    // - 中文模式：首个男/女决定 leftGender/rightGender
    // - 歌手名模式：首个歌手=leftSinger，第二个不同歌手=rightSinger
    String? firstGender;
    String? leftSinger;
    String? rightSinger;
    for (final line in lines) {
      final text = line.text;
      // 1. 中文纯标记行
      final gender = _genderMarker(text);
      if (gender != null) {
        if (gender == '男' || gender == '女') {
          firstGender ??= gender;
        }
        continue;
      }
      // 2. 中文前缀模式
      final m = _prefixRegExp.firstMatch(text);
      if (m != null) {
        final g = m.group(1);
        if (g == '男' || g == '女') {
          firstGender ??= g;
        }
        continue;
      }
      // 3. 歌手名标记行
      final singers = _singerMarker(text);
      if (singers != null) {
        if (singers.length == 1) {
          // 单歌手：分配 left/right
          if (leftSinger == null) {
            leftSinger = singers[0];
          } else if (rightSinger == null && singers[0] != leftSinger) {
            rightSinger = singers[0];
          }
        }
        // 多歌手合唱不分配 left/right
        continue;
      }
    }

    final String leftGender = firstGender ?? '男';
    final String rightGender = leftGender == '男' ? '女' : '男';

    final cleaned = <LyricLine>[];
    final aligns = <DuetAlignment>[];
    // 当前激活的对齐来源：中文性别 或 歌手列表
    String? activeGender;
    List<String>? activeSingersForAlign;

    for (final line in lines) {
      final text = line.text;

      // 1. 中文纯标记行
      final gender = _genderMarker(text);
      if (gender != null) {
        activeGender = gender;
        activeSingersForAlign = null;
        cleaned.add(line.copyWith(
          text: '',
          words: const [],
          clearTranslation: true,
          clearRoma: true,
        ));
        aligns.add(_genderToAlign(gender, leftGender, rightGender));
        continue;
      }

      // 2. 中文前缀模式
      final m = _prefixRegExp.firstMatch(text);
      if (m != null) {
        final g = m.group(1)!;
        activeGender = g;
        activeSingersForAlign = null;
        final cleanedText = text.substring(m.end);
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
        aligns.add(_genderToAlign(g, leftGender, rightGender));
        continue;
      }

      // 3. 歌手名标记行
      final singers = _singerMarker(text);
      if (singers != null) {
        activeSingersForAlign = singers;
        activeGender = null;
        // 标记行文本置空，保留时间戳
        cleaned.add(line.copyWith(
          text: '',
          words: const [],
          clearTranslation: true,
          clearRoma: true,
        ));
        aligns.add(_singersToAlign(singers, leftSinger, rightSinger));
        continue;
      }

      // 4. 普通歌词行：继承最近一次标记的对齐
      cleaned.add(line);
      if (activeGender != null) {
        aligns.add(_genderToAlign(activeGender, leftGender, rightGender));
      } else if (activeSingersForAlign != null) {
        aligns.add(
            _singersToAlign(activeSingersForAlign, leftSinger, rightSinger));
      } else {
        aligns.add(DuetAlignment.defaultAlign);
      }
    }
    return DuetResult(cleaned, aligns);
  }

  /// 中文性别 → 对齐方式。
  static DuetAlignment _genderToAlign(
      String gender, String leftGender, String rightGender) {
    if (gender == '合') return DuetAlignment.center;
    if (gender == leftGender) return DuetAlignment.left;
    if (gender == rightGender) return DuetAlignment.right;
    return DuetAlignment.defaultAlign;
  }

  /// 歌手列表 → 对齐方式。
  /// - 单歌手：leftSinger=left，rightSinger=right，其他=center
  /// - 多歌手：center（合唱）
  static DuetAlignment _singersToAlign(
      List<String> singers, String? leftSinger, String? rightSinger) {
    if (singers.length > 1) return DuetAlignment.center;
    final s = singers[0];
    if (leftSinger != null && s == leftSinger) return DuetAlignment.left;
    if (rightSinger != null && s == rightSinger) return DuetAlignment.right;
    // 未分配 left/right 的单歌手（如第三个歌手独唱）：居中
    return DuetAlignment.center;
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

  /// 剔除翻译/罗马音文本开头的中文性别标记。
  static String? _stripPrefix(String? text) {
    if (text == null) return null;
    return text.replaceFirst(_prefixRegExp, '');
  }
}
