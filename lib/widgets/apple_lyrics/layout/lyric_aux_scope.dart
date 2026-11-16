/// 歌词副行（翻译 / 罗马音）的显示范围。
///
/// 只决定「哪些行有副行」，不决定副行内容用翻译还是罗马音——后者由
/// `LyricDisplayMode` 决定，两张播放页共用一个范围设置。
enum LyricAuxScope {
  /// 仅当前行显示副行（默认，与引入本设置前的观感完全一致）。
  currentLine,

  /// 所有有副行文本的行都显示。
  allLines,

  /// 已播行（索引 < 当前行）不显示；当前行与未播行显示。
  hidePlayed,
}

/// 解析持久化字符串；未知 / null 一律回退 [LyricAuxScope.currentLine]。
LyricAuxScope auxScopeFromName(String? name) {
  switch (name) {
    case 'allLines':
      return LyricAuxScope.allLines;
    case 'hidePlayed':
      return LyricAuxScope.hidePlayed;
    default:
      return LyricAuxScope.currentLine;
  }
}

/// 设置页下拉条目名。
String auxScopeLabel(LyricAuxScope scope) {
  switch (scope) {
    case LyricAuxScope.currentLine:
      return '仅当前行';
    case LyricAuxScope.allLines:
      return '所有行';
    case LyricAuxScope.hidePlayed:
      return '已播行除外';
  }
}

/// 计算某一行副行的目标展开进度（0 = 完全收起，1 = 完全展开）。
///
/// 纯函数：不含任何动画状态，便于单测与两张播放页共用同一判定口径。
///
/// - [enabled] 为 false（副行开关关闭）时恒 0；
/// - [hasAuxText] 为 false（该行无副行文本）时恒 0；
/// - [currentLineIndex] 为 -1（尚未开唱 / 无时间轴）时：
///   [LyricAuxScope.hidePlayed] 视为「没有任何已播行」→ 全部显示；
///   [LyricAuxScope.currentLine] 则没有任何行是当前行 → 全部收起。
double resolveAuxTarget({
  required LyricAuxScope scope,
  required bool enabled,
  required bool hasAuxText,
  required int lineIndex,
  required int currentLineIndex,
}) {
  if (!enabled || !hasAuxText) return 0;
  switch (scope) {
    case LyricAuxScope.currentLine:
      return lineIndex == currentLineIndex ? 1 : 0;
    case LyricAuxScope.allLines:
      return 1;
    case LyricAuxScope.hidePlayed:
      if (currentLineIndex < 0) return 1;
      return lineIndex >= currentLineIndex ? 1 : 0;
  }
}
