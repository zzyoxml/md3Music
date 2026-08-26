import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_layout.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import 'package:md3music/widgets/apple_lyrics/renderers/line_renderer.dart';

/// LineRenderer 单元测试
///
/// 覆盖：初始状态、setLineState、tick 指数衰减、变亮比变暗快、reset、paintLine 不崩溃、
/// 整行模式无 mask 渐变（与 WordRenderer 区分）。
///
/// 主要验证状态逻辑（alpha 计算与 tick 推进），不验证绘制像素。
/// paintLine 涉及 Canvas 绘制，构造一个写入 PictureRecorder 的 canvas
/// 以触发内部 TextPainter 调用，但不验证像素。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LineRenderer renderer;
  late LyricLine line;

  setUp(() {
    renderer = LineRenderer();
    line = const LyricLine(
      startTime: 0,
      duration: 4000,
      text: '这是一行 LRC 歌词',
      words: [], // 整行模式：无 word 时间戳
    );
  });

  /// 构造一个可绘制的 Canvas（写入 PictureRecorder，不实际显示）。
  /// 用 ui 前缀访问 dart:ui 的 Canvas / PictureRecorder / Offset，
  /// 避免与 flutter/widgets.dart 重导出的同名类冲突。
  ui.Canvas makeCanvas() {
    final recorder = ui.PictureRecorder();
    return ui.Canvas(recorder);
  }

  // ==================== 1. 初始状态 ====================
  group('初始状态', () {
    test('currentAlpha 初始值为 0.2（SOLID 非当前行暗态）', () {
      expect(renderer.currentAlpha, closeTo(0.2, 1e-9));
    });

    test('isActive 初始为 false', () {
      expect(renderer.isActive, isFalse);
    });

    test('targetAlpha 初始为 0.2', () {
      expect(renderer.targetAlpha, closeTo(0.2, 1e-9));
    });

    test('hasWordTiming=false 的行确实没有逐字时间戳', () {
      expect(line.hasWordTiming, isFalse);
    });
  });

  // ==================== 2. setLineState(isActive=true) ====================
  group('setLineState(isActive=true)', () {
    test('targetAlpha 变为 1.0', () {
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      expect(renderer.targetAlpha, closeTo(1.0, 1e-9));
      expect(renderer.isActive, isTrue);
    });

    test('tick 后 currentAlpha 趋向 1.0', () {
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      for (int i = 0; i < 100; i++) {
        renderer.tick(0.016);
      }
      expect(renderer.currentAlpha, closeTo(1.0, 0.01));
    });
  });

  // ==================== 3. setLineState(isActive=false) ====================
  group('setLineState(isActive=false)', () {
    test('targetAlpha 变为 0.2', () {
      // 先设为 active 让 targetAlpha=1.0
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      // 再切回 inactive
      renderer.setLineState(
          isActive: false, scale: LyricLayout.inactiveScale);
      expect(renderer.targetAlpha, closeTo(0.2, 1e-9));
      expect(renderer.isActive, isFalse);
    });

    test('tick 后 currentAlpha 趋向 0.2', () {
      // 先 active 并 tick 让 currentAlpha 接近 1.0
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      for (int i = 0; i < 100; i++) {
        renderer.tick(0.016);
      }
      // 切回 inactive 并 tick（RELEASE 速度较慢，多 tick 一些）
      renderer.setLineState(
          isActive: false, scale: LyricLayout.inactiveScale);
      for (int i = 0; i < 300; i++) {
        renderer.tick(0.016);
      }
      expect(renderer.currentAlpha, closeTo(0.2, 0.01));
    });
  });

  // ==================== 4. 指数衰减 ====================
  group('指数衰减', () {
    test('连续 tick 后 currentAlpha 接近目标值（误差 < 0.01）', () {
      // 变亮到 1.0
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      for (int i = 0; i < 200; i++) {
        renderer.tick(0.016);
      }
      expect(renderer.currentAlpha, closeTo(1.0, 0.01));

      // 变暗到 0.2
      renderer.setLineState(
          isActive: false, scale: LyricLayout.inactiveScale);
      for (int i = 0; i < 500; i++) {
        renderer.tick(0.016);
      }
      expect(renderer.currentAlpha, closeTo(0.2, 0.01));
    });

    test('阈值收敛：alphaEpsilon=0.001 内直接吸附到目标', () {
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      // 大量 tick 让 alpha 充分收敛
      for (int i = 0; i < 500; i++) {
        renderer.tick(0.016);
      }
      // 应完全等于目标 1.0（无残差）
      expect(renderer.currentAlpha, equals(1.0));
    });

    test('tick(0) 不推进', () {
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      final alphaBefore = renderer.currentAlpha;
      renderer.tick(0);
      expect(renderer.currentAlpha, equals(alphaBefore));
    });

    test('tick(负值) 不推进', () {
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      final alphaBefore = renderer.currentAlpha;
      renderer.tick(-0.1);
      expect(renderer.currentAlpha, equals(alphaBefore));
    });

    test('单次大 dt 推进也能逼近目标', () {
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      // 一次大步长 tick（模拟长时间未刷新），decay 趋近 1，alpha 几乎到目标
      renderer.tick(1.0);
      expect(renderer.currentAlpha, closeTo(1.0, 0.01));
    });
  });

  // ==================== 5. 变亮比变暗快 ====================
  group('变亮比变暗快', () {
    test('从 0.2 到 1.0 的过渡时间 < 从 1.0 到 0.2 的过渡时间', () {
      // 测量变亮所需 tick 数：从初始 0.2 到 closeTo(1.0, 0.01)
      final upRenderer = LineRenderer();
      upRenderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      int upTicks = 0;
      while ((upRenderer.currentAlpha - 1.0).abs() >= 0.01) {
        upRenderer.tick(0.016);
        upTicks++;
        if (upTicks > 10000) break; // 安全保护
      }

      // 测量变暗所需 tick 数：从 1.0 到 closeTo(0.2, 0.01)
      final downRenderer = LineRenderer();
      downRenderer.setLineState(
          isActive: true, scale: LyricLayout.activeScale);
      // 先让 alpha 充分变亮到 1.0
      for (int i = 0; i < 500; i++) {
        downRenderer.tick(0.016);
      }
      // 切到 inactive 开始计时
      downRenderer.setLineState(
          isActive: false, scale: LyricLayout.inactiveScale);
      int downTicks = 0;
      while ((downRenderer.currentAlpha - 0.2).abs() >= 0.01) {
        downRenderer.tick(0.016);
        downTicks++;
        if (downTicks > 10000) break; // 安全保护
      }

      // 变亮 tick 数应远小于变暗 tick 数（ATTACK=50 vs RELEASE=7）
      expect(upTicks, lessThan(downTicks));
    });

    test('相同帧数下变亮残差小于变暗残差', () {
      // 变亮：5 帧
      final upRenderer = LineRenderer();
      upRenderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      for (int i = 0; i < 5; i++) {
        upRenderer.tick(0.016);
      }
      final double upAlpha = upRenderer.currentAlpha;
      // 变亮残差：距 1.0 的差
      final double upResidual = 1.0 - upAlpha;

      // 变暗：5 帧（从充分变亮的 1.0 开始）
      final downRenderer = LineRenderer();
      downRenderer.setLineState(
          isActive: true, scale: LyricLayout.activeScale);
      for (int i = 0; i < 500; i++) {
        downRenderer.tick(0.016);
      }
      downRenderer.setLineState(
          isActive: false, scale: LyricLayout.inactiveScale);
      for (int i = 0; i < 5; i++) {
        downRenderer.tick(0.016);
      }
      final double downAlpha = downRenderer.currentAlpha;
      // 变暗残差：距 0.2 的差
      final double downResidual = downAlpha - 0.2;

      // 5 帧内变亮残差应小于变暗残差（ATTACK 比 RELEASE 快）
      expect(upResidual, lessThan(downResidual));
    });
  });

  // ==================== 6. reset ====================
  group('reset', () {
    test('reset 后 currentAlpha 回到初始值 0.2', () {
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      for (int i = 0; i < 100; i++) {
        renderer.tick(0.016);
      }
      // 确认 alpha 已偏离初始值
      expect(renderer.currentAlpha, closeTo(1.0, 0.01));

      renderer.reset();
      expect(renderer.currentAlpha, closeTo(0.2, 1e-9));
      expect(renderer.isActive, isFalse);
      expect(renderer.targetAlpha, closeTo(0.2, 1e-9));
    });

    test('reset 后重新 setLineState 与 tick 仍正常工作', () {
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      for (int i = 0; i < 50; i++) {
        renderer.tick(0.016);
      }
      renderer.reset();

      // 重新激活
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      for (int i = 0; i < 100; i++) {
        renderer.tick(0.016);
      }
      expect(renderer.currentAlpha, closeTo(1.0, 0.01));
    });
  });

  // ==================== 7. paintLine 不崩溃 ====================
  group('paintLine', () {
    test('正常整行绘制不崩溃', () {
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      renderer.paintLine(makeCanvas(), ui.Offset.zero, line, 24);
    });

    test('非当前行绘制不崩溃', () {
      renderer.setLineState(
          isActive: false, scale: LyricLayout.inactiveScale);
      renderer.paintLine(makeCanvas(), ui.Offset.zero, line, 24);
    });

    test('空文本不崩溃', () {
      const emptyLine = LyricLine(
        startTime: 0,
        duration: 1000,
        text: '',
        words: [],
      );
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      renderer.paintLine(makeCanvas(), ui.Offset.zero, emptyLine, 24);
    });

    test('tick 推进后再绘制不崩溃', () {
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      for (int i = 0; i < 50; i++) {
        renderer.tick(0.016);
      }
      renderer.paintLine(makeCanvas(), ui.Offset.zero, line, 24);
    });

    test('使用非零 offset 绘制不崩溃', () {
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      renderer.paintLine(makeCanvas(), const ui.Offset(100, 200), line, 24);
    });
  });

  // ==================== 附加：整行模式无 mask 渐变 ====================
  group('整行模式无 mask 渐变（与 WordRenderer 区分）', () {
    test('整行 alpha 在 active 时趋向 1.0（高亮）', () {
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      for (int i = 0; i < 200; i++) {
        renderer.tick(0.016);
      }
      // 整行模式 active 目标是 1.0，不是 WordRenderer 的 dynamicBrightAlpha=0.4~1.0
      expect(renderer.currentAlpha, closeTo(1.0, 0.01));
    });

    test('整行 alpha 在 inactive 时保持 0.2（SOLID 暗态）', () {
      renderer.setLineState(
          isActive: false, scale: LyricLayout.inactiveScale);
      // 即使 tick，alpha 仍保持 0.2（目标也是 0.2，无变化）
      for (int i = 0; i < 100; i++) {
        renderer.tick(0.016);
      }
      expect(renderer.currentAlpha, closeTo(0.2, 1e-9));
    });

    test('scale 参数影响 alpha 计算（与 WordRenderer 公式一致）', () {
      // isActive=true，scale 不同 → dynamicBrightAlpha 不同
      // factor = clamp01((scale - 0.97) / 0.03)
      // dynamicBrightAlpha = factor * 0.8 + 0.2
      final r1 = LineRenderer()
        ..setLineState(isActive: true, scale: LyricLayout.activeScale); // factor=1 → 1.0
      final r2 = LineRenderer()
        ..setLineState(isActive: true, scale: LyricLayout.inactiveScale); // factor=0 → 0.2
      final r3 = LineRenderer()
        ..setLineState(isActive: true, scale: 0.985); // factor=0.5 → 0.6

      for (int i = 0; i < 100; i++) {
        r1.tick(0.016);
        r2.tick(0.016);
        r3.tick(0.016);
      }
      // r1: scale=1.0 → dynamicBright=1.0
      expect(r1.currentAlpha, closeTo(1.0, 0.01));
      // r2: scale=0.97 → dynamicBright=0.2
      expect(r2.currentAlpha, closeTo(0.2, 0.01));
      // r3: scale=0.985 → dynamicBright=0.6
      expect(r3.currentAlpha, closeTo(0.6, 0.01));
    });
  });

  // ==================== 8. 多行自动换行 ====================
  group('多行自动换行', () {
    test('换行行从主行底开始且用 0.8x 行高（不重叠）', () {
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      // 窄视口强制换行成多行：Ahem 测试字体每字符宽 = fontSize = 15，
      // maxWidth=60 → 每视觉行 4 字，14 字 → 4 行
      const longLine = LyricLine(
        startTime: 0,
        duration: 4000,
        text: '这是一段足够长的中文歌词用于测试自动换行',
        words: [],
      );
      final canvas = RecordingCanvas();
      renderer.paintLine(canvas, ui.Offset.zero, longLine, 15, maxWidth: 60);
      final ys = canvas.drawParagraphOffsets.map((o) => o.dy).toList();
      // 确认确实换行成多行
      expect(ys.length, greaterThanOrEqualTo(3),
          reason: '长文本在窄视口下应自动换行为多行');
      final double mainLineHeight = 15 * LyricLayout.lineHeight;
      final double wrapLineHeight =
          mainLineHeight * LyricLayout.wrapLineHeightFactor;
      // 第 1 行（主行）：完整行高，从 offset.dy=0 开始
      expect(ys[0], closeTo(0, 1e-6));
      // 第 2 行：从主行底开始（不再是 0.8x 处，避免与主行行盒重叠）
      expect(ys[1], closeTo(mainLineHeight, 1e-6),
          reason: '第 2 行应从主行底部开始');
      // 第 3 行：再 +0.8x 行高（换行行之间紧凑但不重叠）
      if (ys.length > 2) {
        expect(ys[2], closeTo(mainLineHeight + wrapLineHeight, 1e-6),
            reason: '第 3 行应在第 2 行基础上加 0.8x 行高');
      }
    });

    test('KRC 行按 word 累加换行（与当前行行数一致）', () {
      // 构造含英文/空格的 KRC 行：Ahem 下每字符宽 = fontSize = 15，
      // maxWidth=90 时逐字 6 字/行；该行 18 字符 → word 累加与 TextPainter 均 3 行
      // （用单词更宽的中英混合验证 word 累加路径生效）。
      const krcLine = LyricLine(
        startTime: 0,
        duration: 4000,
        text: 'I love you forever and always my dear',
        words: [
          LyricWord(startTime: 0, duration: 100, text: 'I '),
          LyricWord(startTime: 100, duration: 100, text: 'love'),
          LyricWord(startTime: 200, duration: 100, text: ' you'),
          LyricWord(startTime: 300, duration: 100, text: ' forever'),
          LyricWord(startTime: 400, duration: 100, text: ' and'),
          LyricWord(startTime: 500, duration: 100, text: ' always'),
          LyricWord(startTime: 600, duration: 100, text: ' my'),
          LyricWord(startTime: 700, duration: 100, text: ' dear'),
        ],
      );
      renderer.setLineState(isActive: true, scale: LyricLayout.activeScale);
      // maxWidth=90：word 累加与 TextPainter 在空格/多词场景行数可能不同，
      // LineRenderer 必须与 measureLineHeight（word 累加）一致。
      final canvas = RecordingCanvas();
      renderer.paintLine(canvas, ui.Offset.zero, krcLine, 15, maxWidth: 90);
      final ys = canvas.drawParagraphOffsets.map((o) => o.dy).toList();
      // 逐 word 拼接行（word 累加），与 _wordAccumulateRowStarts 相同的逻辑：
      // 每行文本在窄宽度下拆行，断言行数 >= 2 且第 2 行从主行底开始
      expect(ys.length, greaterThanOrEqualTo(2),
          reason: 'KRC 长行应自动换行为多行');
      final double mainLineHeight = 15 * LyricLayout.lineHeight;
      expect(ys[1], closeTo(mainLineHeight, 1e-6),
          reason: 'KRC 行第 2 行也应从主行底开始');
      // 关键断言：与 WordRenderer 当前行行数一致（此处用 word 累加行数直接断言）
      final int wordRows = _wordAccumulateForTest(krcLine, 15, 90);
      expect(ys.length, wordRows,
          reason: 'LineRenderer 非当前行行数必须等于 word 累加行数（当前行/测量）');
    });
  });
}

/// 测试用：复刻 measureLineHeight 的 word 累加行数计算（与渲染一致）。
int _wordAccumulateForTest(LyricLine line, double fontSize, double maxWidth) {
  double dx = 0;
  int rows = 1;
  for (final w in line.words) {
    final tp = TextPainter(
      text: TextSpan(
        text: w.text,
        style: TextStyle(
            fontSize: fontSize, height: LyricLayout.lineHeight),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final ww = tp.width;
    if (dx + ww > maxWidth && dx > 0) {
      dx = 0;
      rows++;
    }
    dx += ww;
  }
  return rows;
}

/// 记录 [ui.Canvas.drawParagraph] 位置的测试画布（其余方法走 noSuchMethod 兜底）。
///
/// 用于断言自动换行时每个视觉行的绘制 y 位置，验证行盒模型不重叠。
class RecordingCanvas implements ui.Canvas {
  final List<ui.Offset> drawParagraphOffsets = <ui.Offset>[];

  @override
  void drawParagraph(ui.Paragraph paragraph, ui.Offset offset) {
    drawParagraphOffsets.add(offset);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
