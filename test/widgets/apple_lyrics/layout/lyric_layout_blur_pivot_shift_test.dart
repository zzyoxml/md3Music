import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_layout.dart';

/// 模糊层缩放中心补偿的几何契约。
///
/// 背景（本轮真机实测到的「清晰字与模糊影上下错开」）：
/// - 清晰层对**整行**（主行 + 副行×进度）绕 `y + 整行高/2` 做一次 `canvas.scale`；
/// - 模糊层是「主行图 + 副行图」两张缓存图，各自绕**自身块中心**缩放
///   （缓存图不能每帧重烘一个新 pivot）。
///
/// 两个中心相差 `d`，同一内容缩放后落点相差 `d × (1 - scale)`。补偿量由
/// [LyricLayout.blurPivotShiftMain] / [LyricLayout.blurPivotShiftAux] 给出，
/// 测试直接验证「补偿后两层落点相等」这条等式，而不是钉具体数值。
void main() {
  /// 清晰层：绕 [pivot] 缩放 [scale] 后，内容点 [q] 的落点。
  double cleared(double pivot, double q, double scale) =>
      pivot + (q - pivot) * scale;

  /// 模糊层：绕 [pivot] 缩放 [scale] 后再平移到 [dy]。
  double shifted(double pivot, double q, double scale, double dy) =>
      pivot + (q - pivot) * scale + dy;

  group('blurPivotShiftMain', () {
    test('副行收起时为零，满进度时为副行高的一半', () {
      expect(
        LyricLayout.blurPivotShiftMain(auxSubHeight: 30, auxProgress: 0),
        0,
      );
      expect(
        LyricLayout.blurPivotShiftMain(auxSubHeight: 30, auxProgress: 1),
        15,
      );
      expect(
        LyricLayout.blurPivotShiftMain(auxSubHeight: 30, auxProgress: 0.5),
        7.5,
      );
    });

    test('补偿后主行落点与清晰层严格重合（多进度 × 多缩放）', () {
      const double mainH = 36;
      const double subH = 30;
      for (final double p in <double>[0, 0.25, 0.5, 1]) {
        // 清晰层 pivot：整行中心；模糊层 pivot：主行块中心
        final double pivotClear = (mainH + subH * p) / 2;
        const double pivotBlock = mainH / 2;
        final double d = LyricLayout.blurPivotShiftMain(
          auxSubHeight: subH,
          auxProgress: p,
        );
        for (final double s in <double>[1.0, 0.95, 0.85]) {
          final double dy = d * (1 - s);
          for (final double q in <double>[0, mainH / 2, mainH]) {
            expect(
              shifted(pivotBlock, q, s, dy),
              closeTo(cleared(pivotClear, q, s), 1e-9),
              reason: 'mainH=$mainH p=$p s=$s q=$q',
            );
          }
        }
      }
    });
  });

  group('blurPivotShiftAux', () {
    test('满进度时等于 -(主行高/2 + 间隙)', () {
      final double shift = LyricLayout.blurPivotShiftAux(
        mainHeight: 36,
        auxSubHeight: 30,
        auxProgress: 1,
        auxGap: 7.5,
      );
      expect(shift, closeTo(-(18 + 7.5), 1e-9));
    });

    test('收起时相对满进度上移半个副行高', () {
      final double full = LyricLayout.blurPivotShiftAux(
        mainHeight: 36,
        auxSubHeight: 30,
        auxProgress: 1,
        auxGap: 7.5,
      );
      final double empty = LyricLayout.blurPivotShiftAux(
        mainHeight: 36,
        auxSubHeight: 30,
        auxProgress: 0,
        auxGap: 7.5,
      );
      expect(empty - full, closeTo(15, 1e-9));
    });

    test('补偿后副行落点与清晰层严格重合（多进度 × 多缩放）', () {
      const double mainH = 36;
      const double subH = 30;
      const double gap = 7.5;
      for (final double p in <double>[0.25, 0.5, 1]) {
        final double pivotClear = (mainH + subH * p) / 2;
        // 副行块中心（相对行顶）：副行顶 = mainH + gap + subH*(p-1)，再加半块
        final double pivotBlock = mainH + gap + subH * (p - 1) + subH / 2;
        final double d = LyricLayout.blurPivotShiftAux(
          mainHeight: mainH,
          auxSubHeight: subH,
          auxProgress: p,
          auxGap: gap,
        );
        for (final double s in <double>[1.0, 0.95, 0.85]) {
          final double dy = d * (1 - s);
          for (final double q in <double>[
            pivotBlock - subH / 2,
            pivotBlock,
            pivotBlock + subH / 2,
          ]) {
            expect(
              shifted(pivotBlock, q, s, dy),
              closeTo(cleared(pivotClear, q, s), 1e-9),
              reason: 'p=$p s=$s q=$q',
            );
          }
        }
      }
    });
  });

  group('auxGap', () {
    test('等于副行字号的 0.3 倍（与 auxSubHeight 的间隙项同口径）', () {
      for (final double fs in <double>[18, 24, 32, 48]) {
        expect(
          LyricLayout.auxGap(fs),
          closeTo(LyricLayout.translationFontSize(fs) * 0.3, 1e-9),
        );
      }
    });

    test('auxSubHeight 的间隙项与 auxGap 一致（防止两处口径漂移）', () {
      for (final double fs in <double>[20, 30, 40]) {
        final double oneRow = LyricLayout.auxSubHeight(fs, 1);
        final double rowsPart =
            LyricLayout.translationFontSize(fs) *
            LyricLayout.translationLineHeight;
        expect(oneRow - rowsPart, closeTo(LyricLayout.auxGap(fs), 1e-9));
      }
    });
  });
}
