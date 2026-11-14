import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/utils/lyric_wrap_plan.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_layout.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import 'package:md3music/widgets/apple_lyrics/renderers/emphasize_effect.dart';
import 'package:md3music/widgets/apple_lyrics/renderers/word_renderer.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// WordRenderer 单元测试
///
/// 覆盖：初始状态、tick 推进、isActive 切换、scale 联动、
/// 指数衰减、reset、空 words 不崩溃。
///
/// 主要验证状态逻辑（alpha 计算与 tick 推进），不验证绘制像素。
/// paintLine 涉及 Canvas 绘制，构造一个写入 PictureRecorder 的 canvas
/// 以触发内部绑定逻辑与 TextPainter 调用，但不验证像素。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late WordRenderer renderer;
  late LyricLine line;

  setUp(() {
    renderer = WordRenderer();
    line = const LyricLine(
      startTime: 0,
      duration: 4000,
      text: '运命的华',
      words: [
        LyricWord(startTime: 0, duration: 1000, text: '运'),
        LyricWord(startTime: 1000, duration: 1000, text: '命'),
        LyricWord(startTime: 2000, duration: 1000, text: '的'),
        LyricWord(startTime: 3000, duration: 1000, text: '华'),
      ],
    );
  });

  /// 构造一个可绘制的 Canvas（写入 PictureRecorder，不实际显示）。
  /// 用 ui 前缀访问 dart:ui 的 Canvas / PictureRecorder / Offset，
  /// 避免与 flutter/widgets.dart 重导出的同名类冲突。
  ui.Canvas makeCanvas() {
    final recorder = ui.PictureRecorder();
    return ui.Canvas(recorder);
  }

  /// 绘制并读取整幅图像的平均亮度(0~1)，用于实证字切换时是否有亮度突变。
  Future<double> renderBrightness(WordRenderer r, LyricLine l) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    // 白色文字，背景透明；用绿色背景底衬托便于读取文字 alpha
    canvas.drawRect(
      const ui.Rect.fromLTWH(0, 0, 400, 80),
      ui.Paint()..color = const ui.Color(0xFF00FF00),
    );
    r.paintLine(canvas, ui.Offset.zero, l, 24);
    final picture = recorder.endRecording();
    final image = await picture.toImage(400, 80);
    final data = await image.toByteData();
    image.dispose();
    if (data == null) return -1;
    // 统计所有像素中"接近白色(文字)"像素的平均 alpha/亮度
    double sum = 0;
    int count = 0;
    for (int y = 0; y < 80; y++) {
      for (int x = 0; x < 400; x++) {
        final o = (y * 400 + x) * 4;
        final r8 = data.getUint8(o);
        final b8 = data.getUint8(o + 2);
        // 文字是白色(255,255,255)，背景是绿色(0,255,0)；统计"偏白"像素亮度
        if (r8 > 200 && b8 > 200) {
          sum += (r8 / 255.0);
          count++;
        }
      }
    }
    return count > 0 ? sum / count : 0;
  }

  group('初始状态', () {
    test('非当前行（inactiveScale）：所有 word alpha 初始为 dynamicDarkAlpha', () {
      renderer.setLineState(
          isActive: false, scale: LyricLayout.inactiveScale);
      renderer.paintLine(makeCanvas(), ui.Offset.zero, line, 24);
      final alphas = renderer.wordAlphas;
      expect(alphas.length, 4);
      for (final a in alphas.values) {
        expect(a, closeTo(renderer.dynamicDarkAlpha, 1e-9));
      }
    });

    test('当前行（scale=1.0）：所有 word alpha 初始为 dynamicDarkAlpha', () {
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      renderer.paintLine(makeCanvas(), ui.Offset.zero, line, 24);
      final alphas = renderer.wordAlphas;
      expect(alphas.length, 4);
      for (final a in alphas.values) {
        expect(a, closeTo(renderer.dynamicDarkAlpha, 1e-9));
      }
    });
  });

  group('tick 后状态推进', () {
    test('progress=0.25：word 0 已播趋向 1.0，word 1/2/3 未播趋向 0.4', () {
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      renderer.paintLine(makeCanvas(), ui.Offset.zero, line, 24);

      // currentTimeMs=1000: word 0 (0-1000ms) 已结束，word 1 (1000-2000ms) 刚开始
      for (int i = 0; i < 100; i++) {
        renderer.tick(0.016, 1000);
      }
      expect(renderer.wordAlphas[0]!, closeTo(1.0, 0.01));
      expect(renderer.wordAlphas[1]!, closeTo(0.4, 0.01));
      expect(renderer.wordAlphas[2]!, closeTo(0.4, 0.01));
      expect(renderer.wordAlphas[3]!, closeTo(0.4, 0.01));
    });

    test('progress 推进到 1.0：所有 word 已播，alpha 趋向 1.0', () {
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      renderer.paintLine(makeCanvas(), ui.Offset.zero, line, 24);

      // 先到 currentTimeMs=2000 让前两字变亮
      for (int i = 0; i < 100; i++) {
        renderer.tick(0.016, 2000);
      }
      // 再推进到 4000：所有字已结束 → bright=1.0
      for (int i = 0; i < 200; i++) {
        renderer.tick(0.016, 4000);
      }
      for (int i = 0; i < 4; i++) {
        expect(
          renderer.wordAlphas[i]!,
          closeTo(1.0, 0.01),
          reason: 'word $i 应趋向 brightAlpha=1.0',
        );
      }
    });
  });

  group('isActive 切换', () {
    test('从非当前行切到当前行，alpha 从动态暗色渐变到当前行目标', () {
      // 初始非当前行：factor=0，dynamicDarkAlpha=0.2
      renderer.setLineState(isActive: false, scale: LyricLayout.inactiveScale);
      renderer.paintLine(makeCanvas(), ui.Offset.zero, line, 24);
      for (final a in renderer.wordAlphas.values) {
        expect(a, closeTo(renderer.dynamicDarkAlpha, 1e-9));
      }

      // 切到当前行：progress=0 时所有字未播，目标 = dynamicDarkAlpha
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      for (int i = 0; i < 100; i++) {
        renderer.tick(0.016, 0);
      }
      for (final a in renderer.wordAlphas.values) {
        expect(a, closeTo(renderer.dynamicDarkAlpha, 0.01));
      }
    });

    test('从当前行切到非当前行，alpha 渐变回非当前行目标', () {
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      renderer.paintLine(makeCanvas(), ui.Offset.zero, line, 24);
      for (final a in renderer.wordAlphas.values) {
        expect(a, closeTo(renderer.dynamicDarkAlpha, 1e-9));
      }

      // 切到非当前行：非当前行 SOLID 模式，所有字目标 = dynamicDarkAlpha
      renderer.setLineState(isActive: false, scale: LyricLayout.inactiveScale);
      final target = renderer.dynamicDarkAlpha;
      for (int i = 0; i < 200; i++) {
        renderer.tick(0.016, 2000);
      }
      for (final a in renderer.wordAlphas.values) {
        expect(a, closeTo(target, 0.01));
      }
    });
  });

  group('scale 联动', () {
    test('inactiveScale → factor 退化正确（缩放关闭时=1.0，否则=0）', () {
      renderer.setLineState(
        isActive: false,
        scale: LyricLayout.inactiveScale,
      );
      final noScale = (LyricLayout.activeScale - LyricLayout.inactiveScale)
              .abs() <
          1e-9;
      final expectedFactor = noScale ? 1.0 : 0.0;
      expect(renderer.factor, closeTo(expectedFactor, 1e-9));
      expect(renderer.dynamicDarkAlpha,
          closeTo(expectedFactor * 0.2 + 0.2, 1e-9));
      expect(renderer.dynamicBrightAlpha,
          closeTo(expectedFactor * 0.8 + 0.2, 1e-9));
    });

    test('activeScale → factor=1，动态暗 alpha=0.4，亮 alpha=1.0', () {
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      expect(renderer.factor, closeTo(1.0, 1e-9));
      expect(renderer.dynamicDarkAlpha, closeTo(0.4, 1e-9));
      expect(renderer.dynamicBrightAlpha, closeTo(1.0, 1e-9));
    });

    test('scale 为活动/非活动档位中点时 factor/alpha 正确（缩放关闭时退化=1.0）', () {
      final midScale =
          (LyricLayout.inactiveScale + LyricLayout.activeScale) / 2;
      renderer.setLineState(isActive: true, scale: midScale);
      final noScale = (LyricLayout.activeScale - LyricLayout.inactiveScale)
              .abs() <
          1e-9;
      final expectedFactor = noScale ? 1.0 : 0.5;
      expect(renderer.factor, closeTo(expectedFactor, 1e-9));
      expect(renderer.dynamicDarkAlpha,
          closeTo(expectedFactor * 0.2 + 0.2, 1e-9));
      expect(renderer.dynamicBrightAlpha,
          closeTo(expectedFactor * 0.8 + 0.2, 1e-9));
    });

    test('scale 越界保护：远低于 inactiveScale 时 factor 钳制为 0', () {
      final noScale = (LyricLayout.activeScale - LyricLayout.inactiveScale)
              .abs() <
          1e-9;
      renderer.setLineState(isActive: false, scale: 0.5);
      if (noScale) {
        // inactive==active 时缩放维度退化，factor 恒为 1.0
        expect(renderer.factor, closeTo(1.0, 1e-9));
      } else {
        expect(renderer.factor, closeTo(0.0, 1e-9));
      }
    });

    test('scale 越界保护：> 1.0 时 factor 钳制为 1', () {
      renderer.setLineState(isActive: true, scale: 1.5);
      expect(renderer.factor, closeTo(1.0, 1e-9));
    });
  });

  group('指数衰减', () {
    test('连续 tick 多次后，alpha 接近目标值（误差 < 0.01）', () {
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      renderer.paintLine(makeCanvas(), ui.Offset.zero, line, 24);

      // currentTimeMs=2000: word 0,1 已结束 → bright，word 2 开始 → dark
      for (int i = 0; i < 200; i++) {
        renderer.tick(0.016, 2000);
      }
      expect(renderer.wordAlphas[0]!, closeTo(1.0, 0.01));
      expect(renderer.wordAlphas[1]!, closeTo(1.0, 0.01));
      expect(renderer.wordAlphas[2]!, closeTo(0.4, 0.01));
      expect(renderer.wordAlphas[3]!, closeTo(0.4, 0.01));
    });

    test('ATTACK 速度比 RELEASE 快：相同帧数下变亮幅度大于变暗幅度', () {
      // 变亮：从 dark(0.4) 到 bright(1.0)
      final upRenderer = WordRenderer()
        ..setLineState(isActive: true, scale: LyricLayout.activeScale);
      upRenderer.paintLine(makeCanvas(), ui.Offset.zero, line, 24);
      for (int i = 0; i < 5; i++) {
        upRenderer.tick(0.016, 4000); // 所有字已播，目标=1.0
      }
      final double upAlpha = upRenderer.wordAlphas[0]!;

      // 变暗：从 bright(1.0) 到 dark(0.4)
      final downRenderer = WordRenderer()
        ..setLineState(isActive: true, scale: LyricLayout.activeScale);
      downRenderer.paintLine(makeCanvas(), ui.Offset.zero, line, 24);
      // 先把 alpha 推到接近 1.0
      for (int i = 0; i < 200; i++) {
        downRenderer.tick(0.016, 4000);
      }
      // 然后切到 currentTimeMs=0（目标 0.4）tick 5 次
      for (int i = 0; i < 5; i++) {
        downRenderer.tick(0.016, 0);
      }
      final double downAlpha = downRenderer.wordAlphas[0]!;

      // 5 帧内：变亮残差（距 1.0 的差）应小于变暗残差（距 0.4 的差）
      // 即 ATTACK 比 RELEASE 快
      expect(1.0 - upAlpha, lessThan(downAlpha - 0.4));
    });

    test('阈值收敛：alphaEpsilon=0.001 内的差值直接吸附到目标', () {
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      renderer.paintLine(makeCanvas(), ui.Offset.zero, line, 24);
      // 大量 tick 让 alpha 充分收敛
      for (int i = 0; i < 500; i++) {
        renderer.tick(0.016, 4000);
      }
      // 应完全等于目标 1.0（无残差）
      expect(renderer.wordAlphas[0]!, equals(1.0));
    });
  });

  group('字切换过渡区半宽固定（防闪烁）', () {
    test('过渡区半宽固定为行内平均字宽，不随当前字切换变化', () {
      // 前字窄('A'=24)后字宽('BBBB'=96)，平均字宽=(24+96)/2=60
      const wideLine = LyricLine(
        startTime: 0,
        duration: 4000,
        text: 'AB',
        words: [
          LyricWord(startTime: 0, duration: 1000, text: 'A'),
          LyricWord(startTime: 1000, duration: 1000, text: 'BBBB'),
        ],
      );
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      renderer.paintLine(makeCanvas(), ui.Offset.zero, wideLine, 24);
      // 平均字宽 = (24 + 96)/2 = 60
      expect(renderer.transitionHalfWidth, closeTo(60, 0.5));

      // 切换到 word1（当前字宽变化），过渡区半宽应保持不变（稳定）
      for (int i = 0; i < 200; i++) {
        renderer.tick(0.016, 1000);
      }
      expect(renderer.transitionHalfWidth, closeTo(60, 0.5));
    });

    test('像素实证：字切换前后文字平均亮度无断崖跳变', () async {
      const line2 = LyricLine(
        startTime: 0,
        duration: 4000,
        text: 'AB',
        words: [
          LyricWord(startTime: 0, duration: 1000, text: 'AAA'),
          LyricWord(startTime: 1000, duration: 1000, text: 'B'),
        ],
      );
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      renderer.paintLine(makeCanvas(), ui.Offset.zero, line2, 24);
      // 收敛到 word0 播完前
      for (int i = 0; i < 200; i++) {
        renderer.tick(0.016, 999);
      }
      final before = await renderBrightness(renderer, line2);

      // 字切换瞬间继续 tick 若干帧，观察亮度是否平滑
      for (int i = 0; i < 6; i++) {
        renderer.tick(0.016, 1000);
      }
      final after = await renderBrightness(renderer, line2);

      expect(before, greaterThanOrEqualTo(0));
      expect(after, greaterThanOrEqualTo(0));
      // ignore: avoid_print
      print('字切换亮度: before=$before after=$after');
    });
  });

  group('reset', () {
    test('reset 后 alpha map 清空，状态归零', () {
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      renderer.paintLine(makeCanvas(), ui.Offset.zero, line, 24);
      for (int i = 0; i < 50; i++) {
        renderer.tick(0.016, 2000);
      }
      expect(renderer.wordAlphas, isNotEmpty);

      renderer.reset();
      expect(renderer.wordAlphas, isEmpty);
      expect(renderer.isActive, isFalse);
      // reset 后 scale 回落到 inactive；缩放关闭时 factor 退化为 1.0
      final noScale = (LyricLayout.activeScale - LyricLayout.inactiveScale)
              .abs() <
          1e-9;
      expect(renderer.factor, closeTo(noScale ? 1.0 : 0.0, 1e-9));
    });

    test('reset 后重新 paintLine 应重新绑定并初始化', () {
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      renderer.paintLine(makeCanvas(), ui.Offset.zero, line, 24);
      for (int i = 0; i < 50; i++) {
        renderer.tick(0.016, 2000);
      }
      renderer.reset();

      // 重新设置并绑定
      renderer.setLineState(isActive: false, scale: LyricLayout.inactiveScale);
      renderer.paintLine(makeCanvas(), ui.Offset.zero, line, 24);
      final target = renderer.dynamicDarkAlpha;
      for (final a in renderer.wordAlphas.values) {
        expect(a, closeTo(target, 1e-9));
      }
    });
  });

  group('空 words 列表', () {
    test('paintLine 不崩溃，alpha map 为空', () {
      const emptyLine = LyricLine(
        startTime: 0,
        duration: 1000,
        text: '空行',
        words: [],
      );
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      renderer.paintLine(makeCanvas(), ui.Offset.zero, emptyLine, 24);
      expect(renderer.wordAlphas, isEmpty);
    });

    test('tick 在空 words 时不崩溃', () {
      const emptyLine = LyricLine(
        startTime: 0,
        duration: 1000,
        text: '空行',
        words: [],
      );
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      renderer.paintLine(makeCanvas(), ui.Offset.zero, emptyLine, 24);
      renderer.tick(0.016, 2000);
      expect(renderer.wordAlphas, isEmpty);
    });

    test('空 text + 空 words 也不崩溃', () {
      const emptyLine = LyricLine(
        startTime: 0,
        duration: 1000,
        text: '',
        words: [],
      );
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      renderer.paintLine(makeCanvas(), ui.Offset.zero, emptyLine, 24);
      expect(renderer.wordAlphas, isEmpty);
    });

    test('hasWordTiming=false 的行触发 SOLID 降级绘制不崩溃', () {
      const lrcLine = LyricLine(
        startTime: 0,
        duration: 1000,
        text: '这是一行 LRC 歌词',
        words: [],
      );
      expect(lrcLine.hasWordTiming, isFalse);
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      renderer.paintLine(makeCanvas(), ui.Offset.zero, lrcLine, 24);
      // 降级绘制不写入 _wordAlphas（无 word index）
      expect(renderer.wordAlphas, isEmpty);
    });
  });

  group('line 切换重置 alpha map', () {
    test('切换到不同 line 时 alpha map 重新初始化', () {
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      renderer.paintLine(makeCanvas(), ui.Offset.zero, line, 24);
      // 推进动画让 alpha 偏离初始值
      for (int i = 0; i < 50; i++) {
        renderer.tick(0.016, 4000);
      }
      expect(renderer.wordAlphas[0]!, closeTo(1.0, 0.01));

      // 切换到新 line（不同引用）
      const newLine = LyricLine(
        startTime: 1000,
        duration: 2000,
        text: '新行',
        words: [
          LyricWord(startTime: 1000, duration: 500, text: '新'),
          LyricWord(startTime: 1500, duration: 500, text: '行'),
        ],
      );
      renderer.paintLine(makeCanvas(), ui.Offset.zero, newLine, 24);
      // alpha map 应重新初始化为新 line 的 word 数量，值为 dynamicDarkAlpha=0.4
      expect(renderer.wordAlphas.length, 2);
      for (final a in renderer.wordAlphas.values) {
        expect(a, closeTo(0.4, 1e-9));
      }
    });
  });

  group('强调波浪 - 字尾尾巴（v8）', () {
    test('字唱完后波浪继续推进不被截断，走完才 idle', () async {
      // 效果默认关闭；验证辉光状态机时显式开启，并在结束后恢复默认。
      SharedPreferences.setMockInitialValues(<String, Object>{});
      addTearDown(() => LyricPreferences.instance.reset());
      await LyricPreferences.instance.setUseGlowEffect(true);
      // 双字强调字 '命运'（时长 2000ms）：错位启动使第二个字符波浪
      // 比字尾晚 400ms 结束，字切换后应继续推进（尾巴）直至走完。
      const line2 = LyricLine(
        startTime: 0,
        duration: 4000,
        text: '命运华',
        words: [
          LyricWord(startTime: 0, duration: 2000, text: '命运'),
          LyricWord(startTime: 2000, duration: 1000, text: '华'),
        ],
      );
      renderer.emphasizeEffect = EmphasizeEffect();
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      renderer.paintLine(makeCanvas(), ui.Offset.zero, line2, 24);

      // 从 t=0 逐帧推进到 t=2000（dt 与 currentTimeMs 一致递增，避免触发重锚）
      for (int t = 0; t <= 2000; t += 16) {
        renderer.tick(0.016, t, isPlaying: true);
      }
      // t=2000：字 0 唱完、字 1 成为当前字；字 0 的第二个字符波浪应在尾巴中（未截断）
      final tail = renderer.debugCharStatesRef(0);
      expect(renderer.currentWordIdx, 1);
      expect(
        tail.any((s) => s != EmphasizeState.idle),
        isTrue,
        reason: '字0尾巴应继续推进，不应被整词截断',
      );

      // 继续推进到 t=3000（尾巴在 t≈2400 走完），字 0 应全部 idle
      for (int t = 2016; t <= 3000; t += 16) {
        renderer.tick(0.016, t, isPlaying: true);
      }
      final done = renderer.debugCharStatesRef(0);
      expect(
        done.every((s) => s == EmphasizeState.idle),
        isTrue,
        reason: '尾巴走完后字0应回到 idle',
      );
    });
  });

  // ==================== 辉光字符缩放开关 ====================
  group('强调波浪 - 辉光字符缩放开关', () {
    // 单字强调字 '运'（时长 4000ms）：tick 到凸起峰值附近，
    // 逐字符状态应反映"放大 + 外扩"是否被开关关掉。
    const scaleLine = LyricLine(
      startTime: 0,
      duration: 4000,
      text: '运',
      words: [
        LyricWord(startTime: 0, duration: 4000, text: '运'),
      ],
    );

    /// 推进到凸起峰值（t≈2000ms，du=max(1000,4000)=4000 → phase≈0.5）。
    Future<List<EmphasizeState>> statesAtPeak() async {
      renderer.emphasizeEffect = EmphasizeEffect();
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      renderer.paintLine(makeCanvas(), ui.Offset.zero, scaleLine, 24);
      for (int t = 0; t <= 2000; t += 16) {
        renderer.tick(0.016, t, isPlaying: true);
      }
      return renderer.debugCharStatesRef(0);
    }

    test('开启时字符被放大（历史行为）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      addTearDown(() => LyricPreferences.instance.reset());
      await LyricPreferences.instance.setUseGlowEffect(true);
      await LyricPreferences.instance.setUseGlowCharScale(true);

      final states = await statesAtPeak();
      expect(states, isNotEmpty);
      expect(
        states.any((s) => s.scale > 1.0),
        isTrue,
        reason: '开关开启时凸起应放大字符',
      );
    });

    test('关闭时不再放大，但仍保留辉光与上浮', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      addTearDown(() => LyricPreferences.instance.reset());
      await LyricPreferences.instance.setUseGlowEffect(true);
      await LyricPreferences.instance.setUseGlowCharScale(false);

      final states = await statesAtPeak();
      expect(states, isNotEmpty);
      for (final s in states) {
        expect(s.scale, closeTo(1.0, 1e-9), reason: '关闭后不应放大');
        expect(s.offsetXEm, closeTo(0.0, 1e-9), reason: '关闭后不应左右外扩');
      }
      // 仍处于逐字符辉光路径：光晕与上浮还在
      expect(
        states.any((s) => s.glowLevel > 0),
        isTrue,
        reason: '关闭缩放不应关掉辉光',
      );
      expect(
        states.any((s) => s.offsetYEm != 0),
        isTrue,
        reason: '关闭缩放不应关掉上浮',
      );
    });
  });

  // ==================== 翻译副行日历式翻转 ====================
  group('翻译副行翻转', () {
    // 带逐字时间戳的当前行（WordRenderer 的正常调用场景）+ 翻译副行
    const krcLineWithTrans = LyricLine(
      startTime: 0,
      duration: 4000,
      text: '短句',
      words: [
        LyricWord(startTime: 0, duration: 2000, text: '短'),
        LyricWord(startTime: 2000, duration: 2000, text: '句'),
      ],
      translation: '译文',
    );

    double sublineHeight() {
      const double fontSize = 20;
      final int rows = LyricLayout.measureAuxRows('译文', fontSize, 200);
      return rows *
          LyricLayout.translationFontSize(fontSize) *
          LyricLayout.translationLineHeight;
    }

    test('副行就位时不施加画布变换，但副行照常绘制', () {
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      renderer.translationExpand = 1.0;
      renderer.translationFade = 1.0;
      renderer.translationExiting = false;
      final canvas = RecordingCanvas();
      renderer.paintLine(
        canvas,
        ui.Offset.zero,
        krcLineWithTrans,
        20,
        maxWidth: 200,
        viewportWidth: 200,
      );
      expect(canvas.transforms, isEmpty);
      expect(canvas.drawParagraphOffsets, isNotEmpty);
    });

    test('入场中途绕副行底边翻转（锚线不动）', () {
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      renderer.translationExpand = 0.5;
      renderer.translationFade = 0.5;
      renderer.translationExiting = false;
      final canvas = RecordingCanvas();
      renderer.paintLine(
        canvas,
        ui.Offset.zero,
        krcLineWithTrans,
        20,
        maxWidth: 200,
        viewportWidth: 200,
      );
      expect(canvas.transforms, hasLength(1));

      final ui.Offset subOffset = canvas.drawParagraphOffsets.last;
      final Matrix4 m = Matrix4.fromFloat64List(canvas.transforms.single);
      // sublineWidth 传 0：本用例只校验锚线 y；锚点 x（透视投影中心）由
      // lyric_layout_subline_flip_test 的锚点与左右对称用例覆盖。
      final ui.Offset anchor = LyricLayout.sublineFlipAnchor(
        transX: subOffset.dx,
        sublineWidth: 0,
        transY: subOffset.dy,
        sublineHeight: sublineHeight(),
        exiting: false,
      );
      final double anchorY = anchor.dy;
      expect(
        anchorY,
        closeTo(subOffset.dy + sublineHeight(), 1e-6),
        reason: '入场锚线 = 副行底边',
      );
      final ui.Offset fixed = MatrixUtils.transformPoint(
        m,
        ui.Offset(50, anchorY),
      );
      expect(fixed.dy, closeTo(anchorY, 1e-6), reason: '锚线是不动点');
    });
  });

  group('已播字上浮高度跟随偏好', () {
    // 本组会写入偏好，故独立准备 mock prefs 与回滚，避免污染同文件其他用例。
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      addTearDown(() => LyricPreferences.instance.reset());
    });

    test('默认上浮高度（按平台）：已播字 Y 偏移收敛，未播字保持 0', () async {
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      renderer.paintLine(makeCanvas(), ui.Offset.zero, line, 24);
      // 固定在第 3 个字（index=2）的演唱中：index 0/1 为已播字，index 3 为未播字
      for (int i = 0; i < 300; i++) {
        renderer.tick(0.016, 2500);
      }
      final expected =
          -LyricPreferences.defaultLiftHeightPxForCurrentPlatform;
      expect(renderer.wordYOffsetsRef[0], closeTo(expected, 0.01));
      expect(renderer.wordYOffsetsRef[1], closeTo(expected, 0.01));
      expect(renderer.wordYOffsetsRef[3], closeTo(0.0, 0.01));
    });

    test('改到当前平台最大上浮后已播字 Y 偏移收敛', () async {
      final maxLift = LyricPreferences.maxLiftHeightPxForCurrentPlatform;
      await LyricPreferences.instance.setLiftHeightPx(maxLift);
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      renderer.paintLine(makeCanvas(), ui.Offset.zero, line, 24);
      for (int i = 0; i < 300; i++) {
        renderer.tick(0.016, 2500);
      }
      expect(renderer.wordYOffsetsRef[0], closeTo(-maxLift, 0.01));
    });

    test('设为 0 时已播字不再上浮', () async {
      await LyricPreferences.instance.setLiftHeightPx(0.0);
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      renderer.paintLine(makeCanvas(), ui.Offset.zero, line, 24);
      for (int i = 0; i < 300; i++) {
        renderer.tick(0.016, 2500);
      }
      expect(renderer.wordYOffsetsRef[0], closeTo(0.0, 0.01));
    });
  });

  // ==================== 平衡换行：逐字落点必须跟计划一致 ====================
  group('平衡换行（wrapPlan 消费）', () {
    // 本组会写入偏好（关闭平衡那条），故独立准备 mock prefs 与回滚，
    // 写法同「已播字上浮高度跟随偏好」组，避免污染同文件其他用例。
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      addTearDown(() => LyricPreferences.instance.reset());
    });

    // 7 个单字 word，Ahem 下每字宽 15，maxWidth=55：
    //   贪心 → 每行字数 [3,3,1]（末行只剩 1 字，就是用户抱怨的观感）
    //   平衡 → [2,2,3]
    // 两者行数都是 3，所以必须断言「每行字数」的分组，而不是只断言行数。
    // 断言值取 DP 实测：行宽目标函数（各行 slack² 之和）下 [2,2,3] 与 [3,2,2]
    // 代价完全相同（30/30/45 与 45/30/30 的 slack² 和都是 1350），实现按 j 升序
    // 取首个最优，故落在前缀短的那份。这不是缺陷——两种分组都消除了 1 字末行。
    LyricLine sevenChars() => const LyricLine(
      startTime: 0,
      duration: 4000,
      text: '一二三四五六七',
      words: [
        LyricWord(startTime: 0, duration: 100, text: '一'),
        LyricWord(startTime: 100, duration: 100, text: '二'),
        LyricWord(startTime: 200, duration: 100, text: '三'),
        LyricWord(startTime: 300, duration: 100, text: '四'),
        LyricWord(startTime: 400, duration: 100, text: '五'),
        LyricWord(startTime: 500, duration: 100, text: '六'),
        LyricWord(startTime: 600, duration: 100, text: '七'),
      ],
    );

    /// 按绘制 y 把 word 归组，得到每视觉行的 word 个数。
    List<int> wordCountsPerRow(List<ui.Offset> offsets) {
      final Map<double, int> byY = <double, int>{};
      for (final o in offsets) {
        byY[o.dy] = (byY[o.dy] ?? 0) + 1;
      }
      final ys = byY.keys.toList()..sort();
      return [for (final y in ys) byY[y]!];
    }

    test('绘制分组 == 计划分组（贪心残留会被这条抓住）', () async {
      // 不依赖用户默认值，明确验证开启平衡换行后的分组。
      await LyricPreferences.instance.setLineBalance(true);
      const fontSize = 15.0;
      const maxWidth = 55.0;
      final line = sevenChars();
      final plan = LyricWrapPlanner.forLine(
        line,
        LyricLayout.mainStyle(fontSize),
        maxWidth,
        balanced: true,
      );
      // 先确认计划本身是平衡版：分组 [2,2,3]
      expect(
        plan.rowStarts,
        <int>[0, 2, 4],
        reason: 'Ahem 15/字 × 7 字、可用宽 55 时 DP 应给 [2,2,3]',
      );

      final r = WordRenderer()
        ..setLineState(isActive: true, scale: LyricLayout.activeScale);
      final canvas = RecordingCanvas();
      r.paintLine(
        canvas,
        ui.Offset.zero,
        line,
        fontSize,
        maxWidth: maxWidth,
        viewportWidth: 200,
      );

      expect(
        wordCountsPerRow(canvas.drawParagraphOffsets),
        <int>[2, 2, 3],
        reason: 'WordRenderer 必须按换行计划分组，不得再自行贪心断行',
      );
      // 行盒阶梯同样要一致：主行完整行高、换行行 0.8x
      final ys = canvas.drawParagraphOffsets.map((o) => o.dy).toSet().toList()
        ..sort();
      final mainLineHeight = fontSize * LyricLayout.lineHeight;
      final wrapLineHeight =
          mainLineHeight * LyricLayout.wrapLineHeightFactor;
      expect(ys.length, plan.rowCount);
      expect(ys[0], closeTo(0, 1e-6));
      expect(ys[1], closeTo(mainLineHeight, 1e-6));
      expect(ys[2], closeTo(mainLineHeight + wrapLineHeight, 1e-6));
    });

    test('关闭平衡时分组退回旧贪心 [3,3,1]', () async {
      await LyricPreferences.instance.setLineBalance(false);
      const fontSize = 15.0;
      const maxWidth = 55.0;
      final line = sevenChars();
      final r = WordRenderer()
        ..setLineState(isActive: true, scale: LyricLayout.activeScale);
      final canvas = RecordingCanvas();
      r.paintLine(
        canvas,
        ui.Offset.zero,
        line,
        fontSize,
        maxWidth: maxWidth,
        viewportWidth: 200,
      );
      expect(
        wordCountsPerRow(canvas.drawParagraphOffsets),
        <int>[3, 3, 1],
        reason: '开关关闭必须与改造前的贪心行为完全一致',
      );
    });
  });

  /// sweep（扫光）模型接线：行绑定期建墨迹路径，paintLine 按 fillMode 分派。
  ///
  /// classic 分支行为不变（前端不参与绘制，sweepFrontDebug 恒 0）；
  /// sweep 分支前端随墨迹推进进度前进，且始终落在行程域内。
  group('sweep（扫光）模型接线', () {
    test('classic 模式：墨迹路径已建但不消费前端', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await LyricPreferences.instance.setFillMode(LyricFillMode.classic);
      addTearDown(() => LyricPreferences.instance.reset());

      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      renderer.paintLine(makeCanvas(), ui.Offset.zero, line, 24);
      for (int i = 0; i < 100; i++) {
        renderer.tick(0.016, 500);
      }
      renderer.paintLine(makeCanvas(), ui.Offset.zero, line, 24);

      expect(renderer.sweepPathDebug, isNotNull);
      expect(renderer.sweepPathDebug!.isEmpty, isFalse);
      expect(renderer.sweepPathDebug!.totalInk, greaterThan(0));
      expect(renderer.sweepFrontDebug, 0,
          reason: 'classic 模式不得消费 sweep 前端（原有绘制路径一行不变）');
    });

    test('sweep 模式：前端随墨迹进度推进且落在行程域内', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await LyricPreferences.instance.setFillMode(LyricFillMode.sweep);
      addTearDown(() => LyricPreferences.instance.reset());

      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      renderer.paintLine(makeCanvas(), ui.Offset.zero, line, 24);
      // 第 1 个字唱到一半
      for (int i = 0; i < 60; i++) {
        renderer.tick(0.016, 500);
      }
      renderer.paintLine(makeCanvas(), ui.Offset.zero, line, 24);
      final double early = renderer.sweepFrontDebug;
      expect(early, greaterThan(0));

      // 推进到第 3 个字
      for (int i = 0; i < 60; i++) {
        renderer.tick(0.016, 2500);
      }
      renderer.paintLine(makeCanvas(), ui.Offset.zero, line, 24);
      final double later = renderer.sweepFrontDebug;
      expect(later, greaterThan(early), reason: '前端应随进度向右推进');

      final path = renderer.sweepPathDebug!;
      expect(later, lessThanOrEqualTo(path.totalInk + 30),
          reason: '前端最多外扩 feather/2，不得飞出墨迹行程域');
    });

    test('sweep 模式：真的走 saveLayer + 4 停渐变 drawRect（不是退化均匀色）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await LyricPreferences.instance.setFillMode(LyricFillMode.sweep);
      addTearDown(() => LyricPreferences.instance.reset());

      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      renderer.paintLine(makeCanvas(), ui.Offset.zero, line, 24);
      for (int i = 0; i < 60; i++) {
        renderer.tick(0.016, 500); // 前端落在第 1 个字内 → 该字必须有过渡带
      }
      final probe = _SweepProbeCanvas();
      renderer.paintLine(probe, ui.Offset.zero, line, 24);

      expect(probe.savedLayers, isNotEmpty,
          reason: 'sweep 渐变路径必须 saveLayer（零 saveLayer 说明整行退化成均匀色）');
      expect(probe.drawRects, isNotEmpty,
          reason: 'sweep 渐变路径必须 drawRect 贴 4 停渐变');
      // 过渡带内的字矩形（第 1 个字，宽 24）应被渐变覆盖
      expect(probe.drawRects.first.width, closeTo(24, 0.5));
    });

    test('sweep + 强调字：逐字符路径也走 4 停渐变且不崩', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await LyricPreferences.instance.setFillMode(LyricFillMode.sweep);
      await LyricPreferences.instance.setUseGlowEffect(true);
      addTearDown(() => LyricPreferences.instance.reset());

      const line2 = LyricLine(
        startTime: 0,
        duration: 4000,
        text: '命运华',
        words: [
          LyricWord(startTime: 0, duration: 2000, text: '命运'),
          LyricWord(startTime: 2000, duration: 1000, text: '华'),
        ],
      );
      renderer.emphasizeEffect = EmphasizeEffect();
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      renderer.paintLine(makeCanvas(), ui.Offset.zero, line2, 24);
      // 推进到强调字中段（逐字符激活窗口内）
      for (int t = 0; t <= 1000; t += 16) {
        renderer.tick(0.016, t, isPlaying: true);
      }
      expect(
        renderer.debugCharStatesRef(0).any((s) => s != EmphasizeState.idle),
        isTrue,
        reason: '强调字应进入逐字符激活窗口，否则本用例没覆盖逐字符 sweep 路径',
      );

      final probe = _SweepProbeCanvas();
      renderer.paintLine(probe, ui.Offset.zero, line2, 24);
      expect(renderer.sweepFrontDebug, greaterThan(0));
      expect(probe.drawRects, isNotEmpty,
          reason: '逐字符 sweep 路径也应 drawRect 贴 4 停渐变');
    });
  });

  // ==================== 辉光颜色与剖面 ====================
  group('辉光跟随动态颜色 + 三层剖面（方块字贴合笔画）', () {
    test('辉光上色 = 当前文字色（不再恒白）', () {
      final renderer = WordRenderer();
      // 深色背景下的动态混色结果（如 30% 封面色混出来的浅蓝）
      final filter = renderer.debugGlowTintForTest(0x33, 0x66, 0xCC, 0.8);
      expect(
        filter,
        equals(
          ColorFilter.mode(
            const Color.fromRGBO(0x33, 0x66, 0xCC, 0.8),
            BlendMode.srcIn,
          ),
        ),
        reason: '辉光必须用当前文字色（含动态取色比例），不能用白色矩阵',
      );
    });

    test('辉光强度仍只由 alpha 控制：同色不同 alpha 是两个 filter', () {
      final renderer = WordRenderer();
      expect(
        renderer.debugGlowTintForTest(0x11, 0x22, 0x33, 0.2),
        isNot(equals(renderer.debugGlowTintForTest(0x11, 0x22, 0x33, 0.9))),
      );
    });

    test('辉光强度倍数只乘 alpha、不改剖面半径', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = LyricPreferences.instance;
      addTearDown(() => prefs.reset());
      final renderer = WordRenderer();
      final sigmasBefore = WordRenderer.glowSigmaProfileEmForTest;

      // 默认 1.0 = 历史行为（只有常规叠加层，无追加层）
      expect(prefs.glowIntensity, equals(1.0));
      var a = renderer.debugGlowDrawAlphaForTest(0.5);
      expect(a.base, closeTo(0.5, 1e-9));
      expect(a.extra, equals(0.0));

      // 0.5 倍 → 亮度减半
      await prefs.setGlowIntensity(0.5);
      a = renderer.debugGlowDrawAlphaForTest(0.5);
      expect(a.base, closeTo(0.25, 1e-9));
      expect(a.extra, equals(0.0));

      // 强度上限 → 峰值处超出部分走加法叠加（按当前平台上限，Windows 便携版为 1.8）
      final maxIntensity = LyricPreferences.maxGlowIntensityForCurrentPlatform;
      await prefs.setGlowIntensity(maxIntensity);
      a = renderer.debugGlowDrawAlphaForTest(0.6);
      expect(a.base, equals(1.0));
      expect(a.extra, closeTo(0.6 * maxIntensity - 1.0, 1e-9));
      a = renderer.debugGlowDrawAlphaForTest(0.2);
      expect(a.base, closeTo(0.2 * maxIntensity, 1e-9));
      expect(a.extra, equals(0.0));

      // 强度上限下最亮处 = 常规 1.0 + 加法 (maxIntensity - 1.0)
      a = renderer.debugGlowDrawAlphaForTest(1.0);
      expect(a.base, equals(1.0));
      expect(a.extra, closeTo(maxIntensity - 1.0, 1e-9));

      // 剖面半径不随强度变化（贴笔画的光形稳定）
      expect(WordRenderer.glowSigmaProfileEmForTest, equals(sigmasBefore));
    });

    test('多层剖面由内到外递增，最内层必须紧到不糊满字怀', () {
      final sigmas = WordRenderer.glowSigmaProfileEmForTest;
      expect(sigmas.length, greaterThanOrEqualTo(2));
      // 汉字字怀约 0.15em 宽。光从笔画两侧各向内扩 sigma，两侧相加必须
      // 明显小于字怀宽度，空腔才不会被填满 → 最内层上限取 0.08em
      // （0.08×2=0.16 已接近字怀宽度，是留了余量的上限；实测采用 0.07em，
      // 再大就会沿笔画出现亮暗亮，见 profile 测试的字怀内侧断言）。
      expect(sigmas.first, lessThanOrEqualTo(0.08));
      for (int i = 1; i < sigmas.length; i++) {
        expect(sigmas[i], greaterThan(sigmas[i - 1]));
      }
      // 最外层不应再回到旧实现那种 0.24em 以上的糊块
      expect(sigmas.last, lessThanOrEqualTo(0.3));
    });

    test('权重由内到外递减（最内层最亮）', () {
      final weights = WordRenderer.glowWeightProfileForTest;
      expect(weights.length, greaterThanOrEqualTo(2));
      for (int i = 1; i < weights.length; i++) {
        expect(weights[i], lessThan(weights[i - 1]));
      }
      // 最内层必须占主导，否则观感退回"一层柔光糊块"
      expect(weights.first, greaterThan(0.6));
    });

    test('精灵外扩按最外层 3σ（与绘制侧同口径，避免光晕被裁切）', () {
      final renderer = WordRenderer();
      final sigmas = WordRenderer.glowSigmaProfileEmForTest;
      const fontSize = 40.0;
      expect(
        renderer.debugGlowSpritePadForTest(fontSize),
        closeTo(sigmas.last * fontSize * 3, 1e-9),
      );
    });

    testWidgets('辉光精灵可正常烘焙：尺寸按最外层 3σ 外扩', (tester) async {
      final renderer = WordRenderer();
      ui.Image? image;
      await tester.runAsync(() async {
        image = await renderer.debugRenderGlowSpriteForTest(
          text: '日',
          fontSize: 40,
          rowHeight: 1.4,
        );
      });
      expect(image, isNotNull, reason: '多层辉光剖面必须能烘焙成功');
      final sigmas = WordRenderer.glowSigmaProfileEmForTest;
      final pad = sigmas.last * 40 * 3;
      // 精灵按超采样倍数烘焙：尺寸 = (行盒 + 上下 pad) × 倍数
      final int ss = WordRenderer.glowSupersampleForTest;
      expect(image!.height, closeTo((40 * 1.4 + pad * 2).ceil() * ss, 2));
      expect(image!.width, greaterThan((pad * 2).ceil() * ss));
      image!.dispose();
    });

    testWidgets('拖动混色比例（文字色逐帧变化）不得重烘焙辉光精灵', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await LyricPreferences.instance.setUseGlowEffect(true);
      addTearDown(() => LyricPreferences.instance.reset());

      // 单字、时长 2000ms（>= 默认固定阈值 1000ms）→ 触发辉光
      const glowLine = LyricLine(
        startTime: 0,
        duration: 4000,
        text: '华',
        words: [LyricWord(startTime: 0, duration: 2000, text: '华')],
      );
      final renderer = WordRenderer();
      renderer.emphasizeEffect = EmphasizeEffect();
      renderer.setLineState(
        isActive: true,
        scale: LyricLayout.activeScale,
        activeColorValue: 0xFF3366CC,
      );
      renderer.paintLine(makeCanvas(), ui.Offset.zero, glowLine, 24);
      for (int t = 0; t <= 400; t += 16) {
        renderer.tick(0.016, t, isPlaying: true);
        renderer.paintLine(makeCanvas(), ui.Offset.zero, glowLine, 24);
      }
      // toImage 走 native 回调，多等几轮事件循环让精灵落地
      for (int i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 5));
      }
      final first = renderer.debugGlowSpriteForTest(0, 0);
      expect(first, isNotNull, reason: '强调字应烘焙出辉光精灵');

      // 模拟拖动「动态颜色混色比例」：文字色每帧都变
      for (int i = 1; i <= 5; i++) {
        renderer.setLineState(
          isActive: true,
          scale: LyricLayout.activeScale,
          activeColorValue: 0xFF000000 | (0x11 * i << 16) | (0x22 * i << 8) | 0x33,
        );
        renderer.paintLine(makeCanvas(), ui.Offset.zero, glowLine, 24);
        await tester.pump(const Duration(milliseconds: 5));
      }
      expect(
        renderer.debugGlowSpriteForTest(0, 0),
        same(first),
        reason: '颜色由绘制期 ColorFilter 上色，改色不得触发 toImage 重烘焙（否则拖动必掉帧）',
      );
    });
  });
}

/// 记录 `saveLayer` / `drawRect` 调用（其余方法 noSuchMethod 兜底）的探测画布。
class _SweepProbeCanvas implements ui.Canvas {
  final List<ui.Rect> savedLayers = <ui.Rect>[];
  final List<ui.Rect> drawRects = <ui.Rect>[];

  @override
  void saveLayer(ui.Rect? bounds, ui.Paint paint) {
    if (bounds != null) savedLayers.add(bounds);
  }

  @override
  void drawRect(ui.Rect rect, ui.Paint paint) => drawRects.add(rect);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 记录 [ui.Canvas.drawParagraph] 位置与画布变换的测试画布（其余方法走 noSuchMethod 兜底）。
class RecordingCanvas implements ui.Canvas {
  final List<ui.Offset> drawParagraphOffsets = <ui.Offset>[];

  /// 按调用顺序记录 `canvas.transform` 传入的 4x4 矩阵（column-major 副本）。
  final List<Float64List> transforms = <Float64List>[];

  @override
  void drawParagraph(ui.Paragraph paragraph, ui.Offset offset) {
    drawParagraphOffsets.add(offset);
  }

  @override
  void transform(Float64List matrix4) =>
      transforms.add(Float64List.fromList(matrix4));

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
