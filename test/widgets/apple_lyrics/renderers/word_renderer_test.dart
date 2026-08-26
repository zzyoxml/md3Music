import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_layout.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import 'package:md3music/widgets/apple_lyrics/renderers/emphasize_effect.dart';
import 'package:md3music/widgets/apple_lyrics/renderers/word_renderer.dart';

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
    test('非当前行（scale=0.97）：所有 word alpha 初始为 dynamicDarkAlpha=0.2', () {
      renderer.setLineState(
          isActive: false, scale: LyricLayout.inactiveScale);
      renderer.paintLine(makeCanvas(), ui.Offset.zero, line, 24);
      final alphas = renderer.wordAlphas;
      expect(alphas.length, 4);
      for (final a in alphas.values) {
        expect(a, closeTo(0.2, 1e-9));
      }
    });

    test('当前行（scale=1.0）：所有 word alpha 初始为 dynamicDarkAlpha=0.4', () {
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      renderer.paintLine(makeCanvas(), ui.Offset.zero, line, 24);
      final alphas = renderer.wordAlphas;
      expect(alphas.length, 4);
      for (final a in alphas.values) {
        expect(a, closeTo(0.4, 1e-9));
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
        expect(renderer.wordAlphas[i]!, closeTo(1.0, 0.01),
            reason: 'word $i 应趋向 brightAlpha=1.0');
      }
    });
  });

  group('isActive 切换', () {
    test('从非当前行切到当前行，alpha 从 0.2 渐变到 0.4', () {
      // 初始非当前行：scale=0.97, factor=0, dynamicDarkAlpha=0.2
      renderer.setLineState(
          isActive: false, scale: LyricLayout.inactiveScale);
      renderer.paintLine(makeCanvas(), ui.Offset.zero, line, 24);
      for (final a in renderer.wordAlphas.values) {
        expect(a, closeTo(0.2, 1e-9));
      }

      // 切到当前行：scale=1.0, factor=1, dynamicDarkAlpha=0.4
      // progress=0 时所有字未播，目标 = dynamicDarkAlpha = 0.4
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      for (int i = 0; i < 100; i++) {
        renderer.tick(0.016, 0);
      }
      for (final a in renderer.wordAlphas.values) {
        expect(a, closeTo(0.4, 0.01));
      }
    });

    test('从当前行切到非当前行，alpha 从 0.4 渐变回 0.2', () {
      // 初始当前行：所有字 alpha=0.4
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      renderer.paintLine(makeCanvas(), ui.Offset.zero, line, 24);
      for (final a in renderer.wordAlphas.values) {
        expect(a, closeTo(0.4, 1e-9));
      }

      // 切到非当前行：scale=0.97, factor=0, dynamicDarkAlpha=0.2
      // 非当前行 SOLID 模式，所有字目标 = 0.2
      renderer.setLineState(
          isActive: false, scale: LyricLayout.inactiveScale);
      for (int i = 0; i < 200; i++) {
        renderer.tick(0.016, 2000);
      }
      for (final a in renderer.wordAlphas.values) {
        expect(a, closeTo(0.2, 0.01));
      }
    });
  });

  group('scale 联动', () {
    test('scale=0.97 时 factor=0，dynamicDarkAlpha=0.2，dynamicBrightAlpha=0.2', () {
      renderer.setLineState(
          isActive: false, scale: LyricLayout.inactiveScale);
      expect(renderer.factor, closeTo(0.0, 1e-9));
      expect(renderer.dynamicDarkAlpha, closeTo(0.2, 1e-9));
      expect(renderer.dynamicBrightAlpha, closeTo(0.2, 1e-9));
    });

    test('scale=1.0 时 factor=1，dynamicDarkAlpha=0.4，dynamicBrightAlpha=1.0', () {
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      expect(renderer.factor, closeTo(1.0, 1e-9));
      expect(renderer.dynamicDarkAlpha, closeTo(0.4, 1e-9));
      expect(renderer.dynamicBrightAlpha, closeTo(1.0, 1e-9));
    });

    test('scale=0.985 时 factor=0.5，dynamicDarkAlpha=0.3，dynamicBrightAlpha=0.6', () {
      renderer.setLineState(isActive: true, scale: 0.985);
      expect(renderer.factor, closeTo(0.5, 1e-9));
      expect(renderer.dynamicDarkAlpha, closeTo(0.3, 1e-9));
      expect(renderer.dynamicBrightAlpha, closeTo(0.6, 1e-9));
    });

    test('scale 越界保护：< 0.97 时 factor 钳制为 0', () {
      renderer.setLineState(isActive: false, scale: 0.5);
      expect(renderer.factor, closeTo(0.0, 1e-9));
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
      // factor 也应回到 inactive (0)
      expect(renderer.factor, closeTo(0.0, 1e-9));
    });

    test('reset 后重新 paintLine 应重新绑定并初始化', () {
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      renderer.paintLine(makeCanvas(), ui.Offset.zero, line, 24);
      for (int i = 0; i < 50; i++) {
        renderer.tick(0.016, 2000);
      }
      renderer.reset();

      // 重新设置并绑定
      renderer.setLineState(
          isActive: false, scale: LyricLayout.inactiveScale);
      renderer.paintLine(makeCanvas(), ui.Offset.zero, line, 24);
      for (final a in renderer.wordAlphas.values) {
        expect(a, closeTo(0.2, 1e-9));
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
    test('字唱完后波浪继续推进不被截断，走完才 idle', () {
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
}
