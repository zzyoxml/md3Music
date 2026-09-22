import 'dart:ui' show Color;

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/danmaku/danmaku_entry.dart';
import 'package:md3music/core/danmaku/danmaku_render_mapping.dart';

void main() {
  group('toItemType', () {
    test('三种模式映射到 canvas_danmaku 的对应类型', () {
      expect(toItemType(DanmakuMode.scroll), DanmakuItemType.scroll);
      expect(toItemType(DanmakuMode.top), DanmakuItemType.top);
      expect(toItemType(DanmakuMode.bottom), DanmakuItemType.bottom);
    });
  });

  group('toContentItem', () {
    test('文本、颜色、类型、selfSend、extra(id) 全部透传', () {
      const e = DanmakuEntry(
        time: Duration(milliseconds: 100),
        text: '你好',
        colorValue: 0xFF0000,
        mode: DanmakuMode.bottom,
        id: 'local-123',
        selfSend: true,
      );
      final item = toContentItem(e);
      expect(item.text, '你好');
      expect(item.color, const Color(0xFFFF0000));
      expect(item.type, DanmakuItemType.bottom);
      expect(item.selfSend, isTrue);
      expect(item.extra, 'local-123');
    });
  });
}
