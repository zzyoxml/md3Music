import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import 'package:md3music/widgets/apple_lyrics/renderers/emphasize_effect.dart';

/// EmphasizeEffect 单元测试
///
/// 覆盖（对应任务说明 1~10）：
/// 1. shouldEmphasize 触发条件（CJK / 非 CJK / 时长 / 长度）
/// 2. computeState 在 t=0 时接近 idle
/// 3. computeState 在 t=0.5 时 scale 接近最大值（约 1.12）
/// 4. computeState 在 t=1 时 scale 回到 1.0
/// 5. computeState 在 t<0 时返回 idle
/// 6. computeState 在 t>1 时返回 idle
/// 7. 末尾字加强：isLastWord=true 时 scale 更大
/// 8. 字符错位 delay：wordIndex=2 活跃时刻晚于 wordIndex=0
/// 9. cubicBezier 函数端点与中点
/// 10. blur 封顶 0.8、amount 封顶 1.2
void main() {
  late EmphasizeEffect effect;

  setUp(() {
    effect = EmphasizeEffect();
  });

  /// 构造默认测试 word：startTime=0, duration=1000ms, text='运'（CJK 单字）。
  LyricWord makeWord({
    int startTime = 0,
    int duration = 1000,
    String text = '运',
  }) {
    return LyricWord(
      startTime: startTime,
      duration: duration,
      text: text,
    );
  }

  group('shouldEmphasize', () {
    test('CJK 字时长 1000ms → true', () {
      final word = makeWord(duration: 1000, text: '运');
      expect(EmphasizeEffect.shouldEmphasize(word), isTrue);
    });

    test('CJK 字时长 500ms → false（duration < 1000）', () {
      final word = makeWord(duration: 500, text: '运');
      expect(EmphasizeEffect.shouldEmphasize(word), isFalse);
    });

    test('CJK 字时长刚好 999ms → false（边界）', () {
      final word = makeWord(duration: 999, text: '运');
      expect(EmphasizeEffect.shouldEmphasize(word), isFalse);
    });

    test('非 CJK 字 7 字符 1500ms → true', () {
      final word = makeWord(duration: 1500, text: 'abcdefg');
      expect(EmphasizeEffect.shouldEmphasize(word), isTrue);
    });

    test('非 CJK 字 8 字符 1500ms → false（长度 > 7）', () {
      final word = makeWord(duration: 1500, text: 'abcdefgh');
      expect(EmphasizeEffect.shouldEmphasize(word), isFalse);
    });

    test('非 CJK 字 1 字符 1000ms → true（长度下界）', () {
      final word = makeWord(duration: 1000, text: 'a');
      expect(EmphasizeEffect.shouldEmphasize(word), isTrue);
    });

    test('非 CJK 字 7 字符 500ms → false（duration 不够）', () {
      final word = makeWord(duration: 500, text: 'abcdefg');
      expect(EmphasizeEffect.shouldEmphasize(word), isFalse);
    });

    test('CJK 多字符 2000ms → true（任意长度）', () {
      final word = makeWord(duration: 2000, text: '運命の華');
      expect(EmphasizeEffect.shouldEmphasize(word), isTrue);
    });

    test('平假名字 1200ms → true', () {
      final word = makeWord(duration: 1200, text: 'は');
      expect(EmphasizeEffect.shouldEmphasize(word), isTrue);
    });

    test('片假名字 1200ms → true', () {
      final word = makeWord(duration: 1200, text: 'カ');
      expect(EmphasizeEffect.shouldEmphasize(word), isTrue);
    });

    test('韩文字 1200ms → true', () {
      final word = makeWord(duration: 1200, text: '한');
      expect(EmphasizeEffect.shouldEmphasize(word), isTrue);
    });

    test('空文本 → false', () {
      const word = LyricWord(startTime: 0, duration: 1000, text: '');
      expect(EmphasizeEffect.shouldEmphasize(word), isFalse);
    });
  });

  group('shouldEmphasize - 纯符号过滤', () {
    test('下划线 _ 1500ms → false（纯符号）', () {
      final word = makeWord(duration: 1500, text: '_');
      expect(EmphasizeEffect.shouldEmphasize(word), isFalse);
    });

    test('连字符 - 1500ms → false（纯符号）', () {
      final word = makeWord(duration: 1500, text: '-');
      expect(EmphasizeEffect.shouldEmphasize(word), isFalse);
    });

    test('反斜杠 \\ 1500ms → false（纯符号）', () {
      final word = makeWord(duration: 1500, text: r'\');
      expect(EmphasizeEffect.shouldEmphasize(word), isFalse);
    });

    test('顿号 、 1500ms → false（CJK 标点属纯符号）', () {
      final word = makeWord(duration: 1500, text: '、');
      expect(EmphasizeEffect.shouldEmphasize(word), isFalse);
    });

    test('at 符号 @ 1500ms → false（纯符号）', () {
      final word = makeWord(duration: 1500, text: '@');
      expect(EmphasizeEffect.shouldEmphasize(word), isFalse);
    });

    test('星号 * 1500ms → false（纯符号）', () {
      final word = makeWord(duration: 1500, text: '*');
      expect(EmphasizeEffect.shouldEmphasize(word), isFalse);
    });

    test('省略号 … 1500ms → false（纯符号）', () {
      final word = makeWord(duration: 1500, text: '…');
      expect(EmphasizeEffect.shouldEmphasize(word), isFalse);
    });

    test('破折号 — 1500ms → false（纯符号）', () {
      final word = makeWord(duration: 1500, text: '—');
      expect(EmphasizeEffect.shouldEmphasize(word), isFalse);
    });

    test('波浪号 ～ 1500ms → false（纯符号）', () {
      final word = makeWord(duration: 1500, text: '～');
      expect(EmphasizeEffect.shouldEmphasize(word), isFalse);
    });

    test('多符号组合 --- 1500ms → false（纯符号）', () {
      final word = makeWord(duration: 1500, text: '---');
      expect(EmphasizeEffect.shouldEmphasize(word), isFalse);
    });

    test('含字母的混合内容 a- 1500ms → true（非纯符号）', () {
      final word = makeWord(duration: 1500, text: 'a-');
      expect(EmphasizeEffect.shouldEmphasize(word), isTrue);
    });

    test('含数字的混合内容 1. 1500ms → true（非纯符号）', () {
      final word = makeWord(duration: 1500, text: '1.');
      expect(EmphasizeEffect.shouldEmphasize(word), isTrue);
    });

    test('含 CJK 的混合内容 你好。 1500ms → true（非纯符号）', () {
      final word = makeWord(duration: 1500, text: '你好。');
      expect(EmphasizeEffect.shouldEmphasize(word), isTrue);
    });
  });

  group('shouldEmphasize - 歌手标签过滤', () {
    test('男： 1500ms → false（带冒号单字标签）', () {
      final word = makeWord(duration: 1500, text: '男：');
      expect(EmphasizeEffect.shouldEmphasize(word), isFalse);
    });

    test('女: 1500ms → false（半角冒号）', () {
      final word = makeWord(duration: 1500, text: '女:');
      expect(EmphasizeEffect.shouldEmphasize(word), isFalse);
    });

    test('合： 1500ms → false', () {
      final word = makeWord(duration: 1500, text: '合：');
      expect(EmphasizeEffect.shouldEmphasize(word), isFalse);
    });

    test('(男) 1500ms → false（括号包裹标签）', () {
      final word = makeWord(duration: 1500, text: '(男)');
      expect(EmphasizeEffect.shouldEmphasize(word), isFalse);
    });

    test('（女） 1500ms → false（全角括号）', () {
      final word = makeWord(duration: 1500, text: '（女）');
      expect(EmphasizeEffect.shouldEmphasize(word), isFalse);
    });

    test('合唱： 1500ms → false（多字标签带冒号）', () {
      final word = makeWord(duration: 1500, text: '合唱：');
      expect(EmphasizeEffect.shouldEmphasize(word), isFalse);
    });

    test('男声 1500ms → false（多字标签无冒号）', () {
      final word = makeWord(duration: 1500, text: '男声');
      expect(EmphasizeEffect.shouldEmphasize(word), isFalse);
    });

    test('女声 1500ms → false', () {
      final word = makeWord(duration: 1500, text: '女声');
      expect(EmphasizeEffect.shouldEmphasize(word), isFalse);
    });

    test('合唱 1500ms → false（多字标签无冒号）', () {
      final word = makeWord(duration: 1500, text: '合唱');
      expect(EmphasizeEffect.shouldEmphasize(word), isFalse);
    });

    test('男 1500ms → true（单字无冒号不过滤，避免误伤正常歌词）', () {
      // 单字标签必须带冒号或括号才过滤，"男" 单独出现可能是正常歌词字
      final word = makeWord(duration: 1500, text: '男');
      expect(EmphasizeEffect.shouldEmphasize(word), isTrue);
    });

    test('女 1500ms → true（单字无冒号不过滤）', () {
      final word = makeWord(duration: 1500, text: '女');
      expect(EmphasizeEffect.shouldEmphasize(word), isTrue);
    });

    test('合 1500ms → true（单字无冒号不过滤，如"合欢花"中的合）', () {
      final word = makeWord(duration: 1500, text: '合');
      expect(EmphasizeEffect.shouldEmphasize(word), isTrue);
    });
  });

  group('shouldSkipEmphasizeForLine - 行级元数据过滤', () {
    LyricLine makeLine(String text) =>
        LyricLine(startTime: 0, duration: 2000, text: text);

    test('作词：李宗盛 → true（元数据行）', () {
      expect(EmphasizeEffect.shouldSkipEmphasizeForLine(makeLine('作词：李宗盛')), isTrue);
    });

    test('作曲:黄韵玲 → true（半角冒号）', () {
      expect(EmphasizeEffect.shouldSkipEmphasizeForLine(makeLine('作曲:黄韵玲')), isTrue);
    });

    test('编曲：陈志远 → true', () {
      expect(EmphasizeEffect.shouldSkipEmphasizeForLine(makeLine('编曲：陈志远')), isTrue);
    });

    test('制作人：林迈可 → true', () {
      expect(EmphasizeEffect.shouldSkipEmphasizeForLine(makeLine('制作人：林迈可')), isTrue);
    });

    test('混音：XXX → true', () {
      expect(EmphasizeEffect.shouldSkipEmphasizeForLine(makeLine('混音：张三')), isTrue);
    });

    test('OP：环球音乐 → true', () {
      expect(EmphasizeEffect.shouldSkipEmphasizeForLine(makeLine('OP：环球音乐')), isTrue);
    });

    test('OP: Universal → true（半角冒号）', () {
      expect(EmphasizeEffect.shouldSkipEmphasizeForLine(makeLine('OP: Universal')), isTrue);
    });

    test('空行 → true', () {
      expect(EmphasizeEffect.shouldSkipEmphasizeForLine(makeLine('')), isTrue);
    });

    test('纯空白行 → true', () {
      expect(EmphasizeEffect.shouldSkipEmphasizeForLine(makeLine('   ')), isTrue);
    });

    test('月亮代表我的心 → false（正常歌词）', () {
      expect(EmphasizeEffect.shouldSkipEmphasizeForLine(makeLine('月亮代表我的心')), isFalse);
    });

    test('I love you → false（英文歌词）', () {
      expect(EmphasizeEffect.shouldSkipEmphasizeForLine(makeLine('I love you')), isFalse);
    });

    test('男：你好 → false（对唱歌词行，不跳过整行）', () {
      // 男：你好 不应整行跳过，只应跳过 "男：" 这个 word → 字级与行级过滤分工
      expect(EmphasizeEffect.shouldSkipEmphasizeForLine(makeLine('男：你好')), isFalse);
    });

    test('  作词：李宗盛  → true（带前后空格）', () {
      expect(EmphasizeEffect.shouldSkipEmphasizeForLine(makeLine('  作词：李宗盛  ')), isTrue);
    });
  });

  group('computeState - 字内进度 t', () {
    test('t=0 时 scale=1.0, glowLevel≈0, shadowBlur≈0（接近 idle）', () {
      // duration=1000ms：
      //   amount = (1000/2000)^3 * 0.6 = 0.125 * 0.6 = 0.075
      //   blur  = (1000/3000) * 0.5 = 0.16667
      //   transX = bezIn(0) = 0
      //   scale = 1 + 0 * 0.1 * 0.075 = 1.0
      //   glowLevel = 0 * 0.075 = 0
      //   shadowBlurEm = min(0.3, 0.16667 * 0.3) = 0.05
      final word = makeWord(duration: 1000, text: '运');
      final state = effect.computeState(
        word: word,
        currentTimeMs: 0,
        isLastWord: false,
        wordIndex: 0,
        anchorCharCount: 1,
      );
      expect(state.scale, closeTo(1.0, 1e-9));
      expect(state.glowLevel, closeTo(0.0, 1e-9));
      expect(state.shadowBlurEm, closeTo(0.05, 1e-9));
    });

    test('t=0.5 时 scale 接近最大值 1.12（duration=10000ms 触发 amount 封顶）', () {
      // duration=10000ms：
      //   amount = sqrt(10000/2000) * 0.6 = sqrt(5) * 0.6 ≈ 1.3416，封顶 1.2
      //   blur  = (10000/3000) * 0.5 ≈ 1.6667，封顶 0.8
      //   transX = bezOut((1-0.5)*2) = bezOut(1) = 1.0
      //   scale = 1 + 1.0 * 0.1 * 1.2 = 1.12
      //   glowLevel = 1.0 * 1.2 = 1.2
      //   shadowBlurEm = min(0.3, 0.8 * 0.3) = 0.24
      final word = makeWord(duration: 10000, text: '运');
      final state = effect.computeState(
        word: word,
        currentTimeMs: 5000,
        isLastWord: false,
        wordIndex: 0,
        anchorCharCount: 1,
      );
      expect(state.scale, closeTo(1.12, 1e-9));
      expect(state.glowLevel, closeTo(1.2, 1e-9));
      expect(state.shadowBlurEm, closeTo(0.24, 1e-9));
    });

    test('t=1 时 scale 回到 1.0', () {
      // t=1.0：transX = bezOut((1-1)*2) = bezOut(0) = 0
      // scale = 1 + 0 * 0.1 * amount = 1.0
      final word = makeWord(duration: 1000, text: '运');
      final state = effect.computeState(
        word: word,
        currentTimeMs: 1000,
        isLastWord: false,
        wordIndex: 0,
        anchorCharCount: 1,
      );
      expect(state.scale, closeTo(1.0, 1e-9));
      expect(state.glowLevel, closeTo(0.0, 1e-9));
    });

    test('t<0 时返回 idle（字未激活）', () {
      // startTime=1000, currentTimeMs=500：t = (500-1000)/1000 = -0.5
      final word = makeWord(startTime: 1000, duration: 1000, text: '运');
      final state = effect.computeState(
        word: word,
        currentTimeMs: 500,
        isLastWord: false,
        wordIndex: 0,
        anchorCharCount: 1,
      );
      expect(state, equals(EmphasizeState.idle));
      expect(state.scale, 1.0);
      expect(state.glowLevel, 0.0);
      expect(state.shadowBlurEm, 0.0);
    });

    test('t>1 时返回 idle（字已结束）', () {
      // startTime=0, duration=1000, currentTimeMs=2000：t = (2000-0)/1000 = 2.0
      final word = makeWord(duration: 1000, text: '运');
      final state = effect.computeState(
        word: word,
        currentTimeMs: 2000,
        isLastWord: false,
        wordIndex: 0,
        anchorCharCount: 1,
      );
      expect(state, equals(EmphasizeState.idle));
    });
  });

  group('computeState - 末尾字加强', () {
    test('isLastWord=true 时 scale 大于 isLastWord=false 时', () {
      // duration=1000ms, t=0.5：
      //   isLastWord=false：amount=0.075, scale=1+1*0.1*0.075=1.0075
      //   isLastWord=true ：amount=0.075*1.6=0.12, scale=1+1*0.1*0.12=1.012
      final word = makeWord(duration: 1000, text: '运');
      final stateFalse = effect.computeState(
        word: word,
        currentTimeMs: 500,
        isLastWord: false,
        wordIndex: 0,
        anchorCharCount: 1,
      );
      final stateTrue = effect.computeState(
        word: word,
        currentTimeMs: 500,
        isLastWord: true,
        wordIndex: 0,
        anchorCharCount: 1,
      );
      expect(stateTrue.scale, greaterThan(stateFalse.scale));
      // 同时验证 glowLevel 也加强
      expect(stateTrue.glowLevel, greaterThan(stateFalse.glowLevel));
    });
  });

  group('computeState - 字符错位 delay', () {
    test('wordIndex=2 的字活跃时刻晚于 wordIndex=0 的字', () {
      // duration=1000ms, anchorCharCount=1：
      //   wordIndex=0：wordDe = 0 + (1000/2.5/1)*0 = 0
      //     → currentTimeMs=0 时 t=0（激活）
      //   wordIndex=2：wordDe = 0 + (1000/2.5/1)*2 = 800
      //     → currentTimeMs=0 时 t=(0-800)/1000=-0.8（未激活，idle）
      final word = makeWord(duration: 1000, text: '运');
      final state0 = effect.computeState(
        word: word,
        currentTimeMs: 0,
        isLastWord: false,
        wordIndex: 0,
        anchorCharCount: 1,
      );
      final state2 = effect.computeState(
        word: word,
        currentTimeMs: 0,
        isLastWord: false,
        wordIndex: 2,
        anchorCharCount: 1,
      );
      // wordIndex=0 已激活，wordIndex=2 仍为 idle
      expect(state0, isNot(equals(EmphasizeState.idle)));
      expect(state2, equals(EmphasizeState.idle));
    });

    test('wordIndex=2 在 wordDe+duration 时刻激活（验证 delay 计算正确）', () {
      // wordIndex=2：wordDe = 800, 字内 t=0 应在 currentTimeMs=800
      final word = makeWord(duration: 1000, text: '运');
      final state = effect.computeState(
        word: word,
        currentTimeMs: 800,
        isLastWord: false,
        wordIndex: 2,
        anchorCharCount: 1,
      );
      // t=0，transX=0，scale=1.0 但非 idle
      expect(state, isNot(equals(EmphasizeState.idle)));
      expect(state.scale, closeTo(1.0, 1e-9));
    });

    test('anchorCharCount 越大 delay 越小（相邻字激活间隔更短）', () {
      // duration=1000ms, wordIndex=1：
      //   anchorCharCount=1：wordDe = 0 + (1000/2.5/1)*1 = 400
      //   anchorCharCount=4：wordDe = 0 + (1000/2.5/4)*1 = 100
      // anchorCharCount=4 时字更早激活
      final word = makeWord(duration: 1000, text: '运');
      // 在 currentTimeMs=200：
      //   anchorCharCount=1：t = (200-400)/1000 = -0.2（idle）
      //   anchorCharCount=4：t = (200-100)/1000 = 0.1（激活）
      final state1 = effect.computeState(
        word: word,
        currentTimeMs: 200,
        isLastWord: false,
        wordIndex: 1,
        anchorCharCount: 1,
      );
      final state4 = effect.computeState(
        word: word,
        currentTimeMs: 200,
        isLastWord: false,
        wordIndex: 1,
        anchorCharCount: 4,
      );
      expect(state1, equals(EmphasizeState.idle));
      expect(state4, isNot(equals(EmphasizeState.idle)));
    });
  });

  group('cubicBezier', () {
    test('t=0 返回 0', () {
      expect(EmphasizeEffect.cubicBezier(0, 0.2, 0.4, 0.58, 1.0), closeTo(0.0, 1e-9));
    });

    test('t=1 返回 1', () {
      expect(EmphasizeEffect.cubicBezier(1, 0.2, 0.4, 0.58, 1.0), closeTo(1.0, 1e-9));
    });

    test('t=0.5 返回值在 (0, 1) 之间', () {
      final v = EmphasizeEffect.cubicBezier(0.5, 0.2, 0.4, 0.58, 1.0);
      expect(v, greaterThan(0.0));
      expect(v, lessThan(1.0));
      // 验证精确值：3*0.25*0.5*0.2 + 3*0.5*0.25*0.4 + 0.125 = 0.075+0.15+0.125 = 0.35
      expect(v, closeTo(0.35, 1e-9));
    });

    test('bezIn 与 bezOut 在 t=0/1 端点一致（均为 0 或 1）', () {
      // bezIn(0) = 0, bezIn(1) = 1
      expect(EmphasizeEffect.cubicBezier(0, 0.2, 0.4, 0.58, 1.0), closeTo(0.0, 1e-9));
      expect(EmphasizeEffect.cubicBezier(1, 0.2, 0.4, 0.58, 1.0), closeTo(1.0, 1e-9));
      // bezOut(0) = 0, bezOut(1) = 1
      expect(EmphasizeEffect.cubicBezier(0, 0.3, 0.0, 0.58, 1.0), closeTo(0.0, 1e-9));
      expect(EmphasizeEffect.cubicBezier(1, 0.3, 0.0, 0.58, 1.0), closeTo(1.0, 1e-9));
    });

    test('bezier 单调递增（p1/p2 均在 [0,1] 且 p1<=p2 时）', () {
      // 在 [0,1] 上取 21 个点，验证后一个值 >= 前一个值
      double prev = 0;
      for (int i = 0; i <= 20; i++) {
        final t = i / 20;
        final v = EmphasizeEffect.cubicBezier(t, 0.2, 0.4, 0.58, 1.0);
        expect(v, greaterThanOrEqualTo(prev));
        prev = v;
      }
    });
  });

  group('blur 与 amount 封顶', () {
    test('amount 封顶 1.2：duration=10000ms 时 scale=1.12（非 1.134）', () {
      // duration=10000ms：amount 原始 = sqrt(5)*0.6 ≈ 1.3416，封顶 1.2
      // 若未封顶：scale = 1 + 1*0.1*1.3416 = 1.13416
      // 封顶后 ：scale = 1 + 1*0.1*1.2 = 1.12
      // 验证 scale=1.12 证明 amount 被封顶为 1.2
      final word = makeWord(duration: 10000, text: '运');
      final state = effect.computeState(
        word: word,
        currentTimeMs: 5000,
        isLastWord: false,
        wordIndex: 0,
        anchorCharCount: 1,
      );
      expect(state.scale, closeTo(1.12, 1e-9));
      // glowLevel = transX * amount = 1.0 * 1.2 = 1.2（也证明 amount 封顶）
      expect(state.glowLevel, closeTo(1.2, 1e-9));
    });

    test('blur 封顶 0.8：duration=6000ms 时 shadowBlurEm=0.24（非 0.3）', () {
      // duration=6000ms：blur 原始 = (6000/3000)*0.5 = 1.0，封顶 0.8
      // 若未封顶：shadowBlurEm = min(0.3, 1.0*0.3) = 0.3
      // 封顶后 ：shadowBlurEm = min(0.3, 0.8*0.3) = 0.24
      // 验证 shadowBlurEm=0.24（< 0.3）证明 blur 被封顶为 0.8
      final word = makeWord(duration: 6000, text: '运');
      final state = effect.computeState(
        word: word,
        currentTimeMs: 3000,
        isLastWord: false,
        wordIndex: 0,
        anchorCharCount: 1,
      );
      expect(state.shadowBlurEm, closeTo(0.24, 1e-9));
      expect(state.shadowBlurEm, lessThan(0.3));
    });

    test('blur 未封顶时（duration=3000ms）shadowBlurEm=0.15', () {
      // duration=3000ms：blur = (3000/3000)*0.5 = 0.5（未封顶）
      // shadowBlurEm = min(0.3, 0.5*0.3) = 0.15
      final word = makeWord(duration: 3000, text: '运');
      final state = effect.computeState(
        word: word,
        currentTimeMs: 1500,
        isLastWord: false,
        wordIndex: 0,
        anchorCharCount: 1,
      );
      expect(state.shadowBlurEm, closeTo(0.15, 1e-9));
    });
  });

  group('reset', () {
    test('reset 不崩溃且为空实现', () {
      // 无状态类，reset 仅作 API 占位
      effect.reset();
      // 验证 computeState 仍可正常工作
      final word = makeWord(duration: 1000, text: '运');
      final state = effect.computeState(
        word: word,
        currentTimeMs: 500,
        isLastWord: false,
        wordIndex: 0,
        anchorCharCount: 1,
      );
      expect(state, isNot(equals(EmphasizeState.idle)));
    });
  });

  group('边界保护', () {
    test('duration=0 返回 idle（避免除零）', () {
      const word = LyricWord(startTime: 0, duration: 0, text: '运');
      final state = effect.computeState(
        word: word,
        currentTimeMs: 0,
        isLastWord: false,
        wordIndex: 0,
        anchorCharCount: 1,
      );
      expect(state, equals(EmphasizeState.idle));
    });

    test('anchorCharCount=0 返回 idle（避免除零）', () {
      final word = makeWord(duration: 1000, text: '运');
      final state = effect.computeState(
        word: word,
        currentTimeMs: 500,
        isLastWord: false,
        wordIndex: 0,
        anchorCharCount: 0,
      );
      expect(state, equals(EmphasizeState.idle));
    });
  });

  group('EmphasizeState 值对象', () {
    test('idle 常量正确', () {
      expect(EmphasizeState.idle.scale, 1.0);
      expect(EmphasizeState.idle.glowLevel, 0.0);
      expect(EmphasizeState.idle.shadowBlurEm, 0.0);
    });

    test('相等性：相同字段相等', () {
      const a = EmphasizeState(scale: 1.1, glowLevel: 0.5, shadowBlurEm: 0.2);
      const b = EmphasizeState(scale: 1.1, glowLevel: 0.5, shadowBlurEm: 0.2);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('不等性：任一字段不同则不等', () {
      const a = EmphasizeState(scale: 1.1, glowLevel: 0.5, shadowBlurEm: 0.2);
      const b = EmphasizeState(scale: 1.2, glowLevel: 0.5, shadowBlurEm: 0.2);
      expect(a, isNot(equals(b)));
    });

    test('toString 包含三字段', () {
      const s = EmphasizeState(scale: 1.1, glowLevel: 0.5, shadowBlurEm: 0.2);
      final str = s.toString();
      expect(str.contains('1.1'), isTrue);
      expect(str.contains('0.5'), isTrue);
      expect(str.contains('0.2'), isTrue);
    });
  });
}
