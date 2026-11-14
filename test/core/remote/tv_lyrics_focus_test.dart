// TvLyricsFocus 行为契约测试（纯逻辑，不依赖 kTvBuild / Flutter 绑定）。

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/remote/tv_lyrics_focus.dart';

void main() {
  group('TvLyricsFocus', () {
    test('上下键移动焦点行并按边界夹取', () {
      final focus = TvLyricsFocus(lineCount: () => 5, onSeek: (_) {});
      expect(focus.focusedIndex, isNull, reason: '未进入即无焦点行');
      focus.move(TraversalDirection.down); // 从跟随位置进入 → 取当前行（这里传 2）
      focus.enter(currentIndex: 2);
      expect(focus.focusedIndex, 2);
      focus.move(TraversalDirection.down);
      expect(focus.focusedIndex, 3);
      focus.move(TraversalDirection.up);
      focus.move(TraversalDirection.up);
      focus.move(TraversalDirection.up);
      expect(focus.focusedIndex, 0, reason: '到顶后夹取，不越界');
    });

    test('OK 提交：以焦点行时间戳 seek 一次', () {
      final seeks = <int>[];
      final focus = TvLyricsFocus(lineCount: () => 5, onSeek: seeks.add);
      focus.enter(currentIndex: 1);
      focus.enter(currentIndex: 1);
      focus.move(TraversalDirection.down);
      focus.commit(timeMsOfLine: (i) => i * 10000);
      expect(seeks.single, 20000, reason: 'seek 到第 2 行时间戳');
    });

    test('用户操作后自动跟随暂停，静默 followResumeDelay 后恢复', () {
      final focus = TvLyricsFocus(lineCount: () => 5, onSeek: (_) {});
      expect(focus.following, isTrue);
      focus.enter(currentIndex: 1);
      expect(focus.following, isFalse, reason: '操作即暂停跟随');
    });
  });
}
