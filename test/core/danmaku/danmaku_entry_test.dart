import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/danmaku/danmaku_entry.dart';

void main() {
  group('DanmakuEntry', () {
    test('默认值：白色滚动弹幕、非自己发送', () {
      const e = DanmakuEntry(time: Duration(seconds: 1), text: 'hello');
      expect(e.mode, DanmakuMode.scroll);
      expect(e.colorValue, 0xFFFFFF);
      expect(e.selfSend, isFalse);
      expect(e.id, '');
      expect(e.color, const Color(0xFFFFFFFF));
    });

    test('colorValue 按 0xRRGGBB 合成不透明色', () {
      const e = DanmakuEntry(
        time: Duration.zero,
        text: 'x',
        colorValue: 0xFF0000,
      );
      expect(e.color, const Color(0xFFFF0000));
    });

    test('JSON 往返保持全部字段', () {
      const e = DanmakuEntry(
        time: Duration(milliseconds: 3456),
        text: '测试弹幕',
        colorValue: 0x00FF00,
        mode: DanmakuMode.top,
        id: 'local-1',
        selfSend: true,
      );
      final back = DanmakuEntry.fromJson(e.toJson());
      expect(back.time, e.time);
      expect(back.text, e.text);
      expect(back.colorValue, e.colorValue);
      expect(back.mode, e.mode);
      expect(back.id, e.id);
      expect(back.selfSend, e.selfSend);
    });

    test('fromJson 对缺失 mode 回退为滚动，对未知 mode 回退为滚动', () {
      final a = DanmakuEntry.fromJson({'time': 0, 'text': 'x'});
      expect(a.mode, DanmakuMode.scroll);
      final b = DanmakuEntry.fromJson({'time': 0, 'text': 'x', 'mode': 'wat'});
      expect(b.mode, DanmakuMode.scroll);
    });
  });
}
