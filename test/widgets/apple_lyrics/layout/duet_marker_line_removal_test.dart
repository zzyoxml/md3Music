/// DuetLayout：纯标记行整行移除，不为空行占位。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/layout/duet_layout.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';

void main() {
  test('中文纯标记行整行移除，正文行继承对齐且时间戳不变', () {
    final lines = <LyricLine>[
      const LyricLine(startTime: 0, duration: 1000, text: '男：第一句'),
      const LyricLine(startTime: 1000, duration: 500, text: '女：'),
      const LyricLine(startTime: 2000, duration: 1000, text: '女：第二句'),
      const LyricLine(startTime: 3000, duration: 500, text: '合：'),
      const LyricLine(startTime: 4000, duration: 1000, text: '一起唱'),
    ];

    final result = DuetLayout.process(lines, true);

    expect(
      result.cleanedLines.map((l) => l.text).toList(),
      ['第一句', '第二句', '一起唱'],
    );
    expect(
      result.cleanedLines.map((l) => l.startTime).toList(),
      [0, 2000, 4000],
    );
    expect(result.alignments, <DuetAlignment>[
      DuetAlignment.left,
      DuetAlignment.right,
      DuetAlignment.center,
    ]);
    expect(result.cleanedLines.length, result.alignments.length);
  });

  test('合唱：与歌手名标记行同样整行移除', () {
    final lines = <LyricLine>[
      const LyricLine(startTime: 0, duration: 1000, text: '男：第一句'),
      const LyricLine(startTime: 1000, duration: 500, text: '合唱：'),
      const LyricLine(startTime: 1500, duration: 1000, text: '一起唱'),
      const LyricLine(startTime: 2500, duration: 500, text: 'Taylor Swift：'),
      const LyricLine(startTime: 3000, duration: 1000, text: '末句'),
    ];

    final result = DuetLayout.process(lines, true);

    expect(
      result.cleanedLines.map((l) => l.text).toList(),
      ['第一句', '一起唱', '末句'],
    );
    expect(result.alignments.length, 3);
  });

  test('关闭对唱时保留全部原始行（零回归）', () {
    final lines = <LyricLine>[
      const LyricLine(startTime: 0, duration: 500, text: '女：'),
      const LyricLine(startTime: 500, duration: 1000, text: '女：第二句'),
    ];

    final result = DuetLayout.process(lines, false);

    expect(result.cleanedLines.length, 2);
    expect(result.cleanedLines.first.text, '女：');
    expect(result.alignments, List.filled(2, DuetAlignment.defaultAlign));
  });
}
