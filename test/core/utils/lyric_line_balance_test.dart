/// 歌词平衡换行内核单元测试。
///
/// 内核是纯函数（宽度由调用方给出），因此不需要 Flutter 绑定与真实字体，
/// 直接断言 DP 选出的断点，与 AMLL `calcBalancedBreaks` 的语义一一对应。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/utils/lyric_line_balance.dart';

BalanceUnit u(String text, double width) => BalanceUnit(
  text: text,
  width: width,
  isSpace: text.trim().isEmpty,
);

void main() {
  group('segmentLyricUnits', () {
    test('拼接无损：分词结果原样拼回等于原文', () {
      const samples = <String>[
        'I love you forever',
        '这是一段足够长的中文歌词',
        'hello世界，你好mix，end.',
        '   ',
        '',
        "don't 停不下来，真的",
      ];
      for (final s in samples) {
        expect(segmentLyricUnits(s).join(), s, reason: '样本：$s');
      }
    });

    test('拉丁词整词成单元，空格独立成单元', () {
      expect(
        segmentLyricUnits('I love you'),
        <String>['I', ' ', 'love', ' ', 'you'],
      );
    });

    test('CJK 每字一个单元', () {
      expect(segmentLyricUnits('你好吗'), <String>['你', '好', '吗']);
    });

    test('标点附着到前一个单元，不会让视觉行以标点开头', () {
      expect(segmentLyricUnits('end.'), <String>['end.']);
      expect(segmentLyricUnits('好啊，走'), <String>['好', '啊，', '走']);
    });

    test("撇号属于词内，不把 don't 拆开", () {
      expect(segmentLyricUnits("don't"), <String>["don't"]);
    });

    test('代理对不被拆坏（emoji 与原字符逐单元拼回一致）', () {
      const text = '你🎵好';
      final units = segmentLyricUnits(text);
      expect(units.join(), text);
      expect(units.any((s) => s == '🎵'), isTrue);
    });
  });

  group('balancedRowStarts', () {
    test('总宽不超过可用宽 → 不断行', () {
      final units = <BalanceUnit>[u('aaa', 30), u('bbb', 30)];
      expect(balancedRowStarts(units, 100), <int>[0]);
    });

    test('可用宽为无穷或非法 → 不断行', () {
      final units = <BalanceUnit>[u('aaa', 30), u('bbb', 30)];
      expect(balancedRowStarts(units, double.infinity), <int>[0]);
      expect(balancedRowStarts(units, 0), <int>[0]);
      expect(balancedRowStarts(<BalanceUnit>[], 100), <int>[0]);
    });

    test('比贪心更均衡：35/35/30 在 70 宽下选 [35]+[65]，不是 [70]+[30]', () {
      final units = <BalanceUnit>[u('aaa', 35), u('bbb', 35), u('cc', 30)];
      expect(
        balancedRowStarts(units, 70),
        <int>[0, 1],
        reason: '第一行只放 aaa，第二行放 bbb+cc',
      );
      // 对照：贪心会把第一行塞满到 70
      expect(greedyRowStarts(units, 70), <int>[0, 2]);
    });

    test('断点优先落在空格处', () {
      final units = <BalanceUnit>[u('abcd', 50), u(' ', 10), u('efgh', 50)];
      expect(
        balancedRowStarts(units, 60),
        <int>[0, 2],
        reason: '应在空格后断开，新行从 efgh 开始',
      );
    });

    test('断点优先落在标点之后', () {
      // 逗号应与前字同处一行（分词已把标点附着到前一单元），换行落在其后
      final units = <BalanceUnit>[u('aa', 30), u('，', 5), u('bb', 30)];
      expect(
        balancedRowStarts(units, 35),
        <int>[0, 2],
        reason: '标点单独成行不合理：应挂到前一行尾（DP 行1=[aa，] 行2=[bb]）',
      );
    });

    test('单个单元比容器还宽时被迫独立成行', () {
      final units = <BalanceUnit>[u('Supercalifragilistic', 200), u('ab', 10)];
      expect(balancedRowStarts(units, 100), <int>[0, 1]);
    });

    test('除被迫超宽的行外，每行宽度都不超过可用宽', () {
      final units = <BalanceUnit>[
        u('aa', 25),
        u('bb', 25),
        u('cc', 25),
        u('dd', 25),
        u('e', 10),
      ];
      const maxWidth = 55.0;
      final starts = balancedRowStarts(units, maxWidth);
      for (int r = 0; r < starts.length; r++) {
        final s = starts[r];
        final e = r + 1 < starts.length ? starts[r + 1] : units.length;
        double w = 0;
        for (int i = s; i < e; i++) {
          w += units[i].width;
        }
        expect(
          w <= maxWidth || (e - s == 1),
          isTrue,
          reason: '第 $r 行宽 $w 超过 $maxWidth，且不是被迫的单元素行',
        );
      }
    });

    test('断点升序、首元素为 0、不含 n', () {
      final units = <BalanceUnit>[
        for (int i = 0; i < 12; i++) u('xx', 20),
      ];
      final starts = balancedRowStarts(units, 55);
      expect(starts.first, 0);
      for (int i = 1; i < starts.length; i++) {
        expect(starts[i] > starts[i - 1], isTrue);
        expect(starts[i] < units.length, isTrue);
      }
    });
  });

  group('greedyRowStarts（关闭平衡时必须与旧贪心逐字等价）', () {
    test('复刻旧规则：dx + width > maxWidth 且 dx > 0 才换行', () {
      // 这组宽度来自 line_renderer_test 的 KRC 用例，旧贪心得到 7 行
      final units = <BalanceUnit>[
        u('I ', 30),
        u('love', 60),
        u(' you', 60),
        u(' forever', 120),
        u(' and', 60),
        u(' always', 105),
        u(' my', 45),
        u(' dear', 75),
      ];
      expect(greedyRowStarts(units, 90), <int>[0, 2, 3, 4, 5, 6, 7]);
    });

    test('可用宽无穷 / 空列表 → [0]', () {
      expect(greedyRowStarts(<BalanceUnit>[], 100), <int>[0]);
      expect(
        greedyRowStarts(<BalanceUnit>[u('a', 10)], double.infinity),
        <int>[0],
      );
    });
  });
}
