import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/selection/lyric_selection_state.dart';

/// LyricSelectionState 单元测试
///
/// 覆盖：长按进入 / 拖动扩展区间 / 点按切换 / 全选清除退出 /
/// 复制文本拼接 / 字数统计口径。
void main() {
  group('LyricSelectionState', () {
    const texts = ['一', '二二', '三三三', '四四四四'];

    test('begin 激活并选中单行，新一轮长按重置旧选择', () {
      final s = LyricSelectionState();
      s.begin(2);
      expect(s.isActive, isTrue);
      expect(s.anchorIndex, 2);
      expect(s.selected, {2});

      s.dragTo(0); // 2..0 → 0..2
      s.begin(3); // 新一轮长按重置
      expect(s.selected, {3});
      expect(s.anchorIndex, 3);
    });

    test('dragTo 以锚点为端点生成连续区间（正向与反向）', () {
      final s = LyricSelectionState();
      s.begin(1);
      s.dragTo(3);
      expect(s.selected, {1, 2, 3});

      s.begin(3);
      s.dragTo(0);
      expect(s.selected, {0, 1, 2, 3});
    });

    test('toggle 制造不连续选择并可移除', () {
      final s = LyricSelectionState();
      s.begin(1);
      s.toggle(4);
      expect(s.selected, {1, 4});
      s.toggle(4);
      expect(s.selected, {1});
    });

    test('selectAll / clearSelection / exit 语义', () {
      final s = LyricSelectionState();
      s.selectAll(4);
      expect(s.selected, {0, 1, 2, 3});
      s.selectAll(0); // 空歌词忽略
      expect(s.selected, {0, 1, 2, 3});
      s.clearSelection();
      expect(s.selected, isEmpty);
      expect(s.isActive, isTrue, reason: '清除只清集合，不退出模式');
      s.exit();
      expect(s.isActive, isFalse);
      expect(s.anchorIndex, -1);
      expect(s.selected, isEmpty);
    });

    test('copyText 按行序拼接并跳过越界与空白行', () {
      final s = LyricSelectionState();
      s.selectAll(5);
      expect(s.copyText(['b', 'a', '  ', 'c', 'd']), 'b\na\nc\nd');
    });

    test('未激活时 dragTo/toggle 无效果', () {
      final s = LyricSelectionState();
      s.dragTo(1);
      s.toggle(1);
      expect(s.selected, isEmpty);
    });

    test('字数统计口径（选中 / 总数）', () {
      expect(LyricSelectionState.totalCharCount(texts), 10);
      expect(LyricSelectionState.charCountOf({1, 3}, texts), 6);
      expect(LyricSelectionState.charCountOf({99}, texts), 0);
    });
  });
}
