import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/utils/hex_color.dart';

void main() {
  group('parseHexColor', () {
    test('六位色号：带/不带 # 前缀、大小写混用、首尾空白都能解析', () {
      expect(parseHexColor('#1E88E5'), const Color(0xFF1E88E5));
      expect(parseHexColor('1e88e5'), const Color(0xFF1E88E5));
      expect(parseHexColor('  #0061A4  '), const Color(0xFF0061A4));
    });

    test('三位短写按位复制展开', () {
      expect(parseHexColor('#abc'), const Color(0xFFAABBCC));
      expect(parseHexColor('fff'), const Color(0xFFFFFFFF));
      expect(parseHexColor('000'), const Color(0xFF000000));
    });

    test('解析结果始终不透明（种子色不用透明通道）', () {
      expect(parseHexColor('#FF0000')!.toARGB32() >> 24, 0xFF);
    });

    test('非法格式一律返回 null', () {
      const bad = [
        '',
        '   ',
        '#',
        '#ff',
        '#ff00',
        '#12345',
        '#1234567', // 8 位同理：AARRGGBB 与 RRGGBBAA 有歧义，不猜
        '#abcd',
        'gg0000',
        '0x1E88E5',
        'rgb(30,136,229)',
        '12345g',
      ];
      for (final input in bad) {
        expect(parseHexColor(input), isNull, reason: '应拒绝：「$input」');
      }
    });
  });

  group('formatHexColor', () {
    test('输出大写、带 # 的六位色号', () {
      expect(formatHexColor(const Color(0xFF0061A4)), '#0061A4');
      expect(formatHexColor(const Color(0xFF1E88E5)), '#1E88E5');
    });

    test('alpha 被忽略', () {
      expect(formatHexColor(const Color(0x80FF0000)), '#FF0000');
    });

    test('高位为 0 的通道补零', () {
      expect(formatHexColor(const Color(0xFF0A010F)), '#0A010F');
    });

    test('解析与格式化互逆', () {
      const hex = ['#0061A4', '#1E88E5', '#FF0000', '#000000', '#FFFFFF'];
      for (final h in hex) {
        expect(formatHexColor(parseHexColor(h)!), h);
      }
    });
  });
}
