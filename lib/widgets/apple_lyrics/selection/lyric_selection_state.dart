/// 歌词选择状态（纯逻辑，无渲染依赖）。
///
/// 记录选择模式是否激活、锚点行与选中行集合，供 AppleLyricsView 的
/// 选择模式渲染与复制动作消费。选中集合支持两种来源：
/// - 长按拖动：[begin] 锚定后 [dragTo] 以「锚点行 → 目标行」连续区间整段覆盖；
/// - 点按切换：[toggle] 对单行做加入/移除（可制造不连续选择）。
///
/// 本类不持有行文本；复制文本与字数统计由调用方传入行文本列表计算。
library;

import 'dart:math' as math;

/// 歌词选择模式的状态。
class LyricSelectionState {
  /// 选择模式是否激活（长按进入，按钮/切歌退出）。
  bool isActive = false;

  /// 本次长按的锚点行索引（拖动扩展以锚点为区间一端）。
  int anchorIndex = -1;

  /// 选中行索引集合（无序；展示/复制时按行序处理）。
  final Set<int> selected = <int>{};

  /// 长按进入选择模式并选中 [lineIndex]。
  ///
  /// 再次长按会重置选择（与 Apple Music 一致：新一轮长按开新选择）。
  void begin(int lineIndex) {
    isActive = true;
    anchorIndex = lineIndex;
    selected
      ..clear()
      ..add(lineIndex);
  }

  /// 长按拖动扩展：以锚点行到 [lineIndex] 的连续区间整段替换选中集合。
  void dragTo(int lineIndex) {
    if (!isActive || anchorIndex < 0) return;
    final int lo = math.min(anchorIndex, lineIndex);
    final int hi = math.max(anchorIndex, lineIndex);
    selected
      ..clear()
      ..addAll([for (int i = lo; i <= hi; i++) i]);
  }

  /// 点按切换：未选中则加入，已选中则移除。
  void toggle(int lineIndex) {
    if (!isActive) return;
    if (!selected.remove(lineIndex)) {
      selected.add(lineIndex);
    }
  }

  /// 全选 [lineCount] 行；[lineCount] <= 0 时忽略。
  void selectAll(int lineCount) {
    if (lineCount <= 0) return;
    isActive = true;
    selected
      ..clear()
      ..addAll([for (int i = 0; i < lineCount; i++) i]);
  }

  /// 清空选中（保持选择模式激活）。
  void clearSelection() {
    selected.clear();
  }

  /// 退出选择模式并清空全部状态。
  void exit() {
    isActive = false;
    anchorIndex = -1;
    selected.clear();
  }

  /// 选中行数。
  int get selectedCount => selected.length;

  /// 选中行文本按行序用 `\n` 拼接；跳过越界与空白行（复制动作直接消费）。
  String copyText(List<String> lineTexts) {
    final List<int> sorted = selected.toList()..sort();
    return [
      for (final int i in sorted)
        if (i >= 0 && i < lineTexts.length && lineTexts[i].trim().isNotEmpty)
          lineTexts[i],
    ].join('\n');
  }

  /// [indices] 中各行文本的字符总数（顶栏「M 个字」的选中侧口径）。
  static int charCountOf(Iterable<int> indices, List<String> lineTexts) {
    int n = 0;
    for (final int i in indices) {
      if (i >= 0 && i < lineTexts.length) n += lineTexts[i].length;
    }
    return n;
  }

  /// 全部行文本的字符总数（顶栏「M/T 个字」的总数口径）。
  static int totalCharCount(List<String> lineTexts) =>
      lineTexts.fold(0, (sum, text) => sum + text.length);
}
