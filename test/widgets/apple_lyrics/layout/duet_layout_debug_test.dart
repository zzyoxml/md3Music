import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/layout/duet_layout.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';

/// 临时调试测试：验证 DuetLayout 输出对齐方式是否符合预期。
void main() {
  test('debug: DuetLayout 输出对齐方式', () {
    final lines = <LyricLine>[
      const LyricLine(startTime: 0, duration: 1000, text: '男：你好'),
      const LyricLine(startTime: 1000, duration: 1000, text: '女：你好啊'),
      const LyricLine(startTime: 2000, duration: 1000, text: '合：一起唱'),
      const LyricLine(startTime: 3000, duration: 1000, text: '无标记行'),
    ];

    final result = DuetLayout.process(lines, true);

    for (int i = 0; i < lines.length; i++) {
      print('line[$i] raw="${lines[i].text}" cleaned="${result.cleanedLines[i].text}" align=${result.alignments[i]}');
    }

    expect(result.alignments[0], DuetAlignment.left);
    expect(result.alignments[1], DuetAlignment.right);
    expect(result.alignments[2], DuetAlignment.center);
    expect(result.alignments[3], DuetAlignment.defaultAlign);
    expect(result.cleanedLines[0].text, '你好');
    expect(result.cleanedLines[1].text, '你好啊');
    expect(result.cleanedLines[2].text, '一起唱');
  });

  test('debug: 全角冒号与半角冒号', () {
    final lines = <LyricLine>[
      const LyricLine(startTime: 0, duration: 1000, text: '男:半角'),
      const LyricLine(startTime: 1000, duration: 1000, text: '女：全角'),
    ];
    final result = DuetLayout.process(lines, true);
    print('半角: raw="男:半角" cleaned="${result.cleanedLines[0].text}" align=${result.alignments[0]}');
    print('全角: raw="女：全角" cleaned="${result.cleanedLines[1].text}" align=${result.alignments[1]}');
    expect(result.alignments[0], DuetAlignment.left);
    expect(result.alignments[1], DuetAlignment.right);
  });

  test('debug: 关闭开关时全部 defaultAlign', () {
    final lines = <LyricLine>[
      const LyricLine(startTime: 0, duration: 1000, text: '男：你好'),
      const LyricLine(startTime: 1000, duration: 1000, text: '女：你好啊'),
    ];
    final result = DuetLayout.process(lines, false);
    print('关闭: align0=${result.alignments[0]} align1=${result.alignments[1]}');
    expect(result.alignments[0], DuetAlignment.defaultAlign);
    expect(result.alignments[1], DuetAlignment.defaultAlign);
  });
}
