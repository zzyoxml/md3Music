import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/utils/lyric_bg_bloom.dart';

/// 「背景增透」颜色处理的单元测试（utils/lyric_bg_bloom.dart）。
///
/// 锁定两件事：
/// 1. processBgBloomColor 的提亮 / 加饱和口径与钳位（近灰不加饱和、
///    近白不出色域、色相保持不变）；
/// 2. averageRgbaRegion 的区域均值、越界钳位与空区域 / 短缓冲返回 null。
void main() {
  /// Color 分量（0~1 double）→ 0~255 整数（本文件断言口径统一）。
  int channel255(double v) => (v * 255).round();

  group('processBgBloomColor', () {
    test('近灰背景：只提亮不加饱和（避免给灰色造出假色相）', () {
      const int gray = 0x808080;
      final int out = processBgBloomColor(gray);
      final hsl = HSLColor.fromColor(Color(out | 0xFF000000));
      // 输入饱和度 0，输出必须仍为 0
      expect(hsl.saturation, closeTo(0.0, 1e-9));
      // L = 128/255 + 0.16 = 0.66196…
      expect(hsl.lightness, closeTo(128 / 255 + 0.16, 1e-3));
      // 三通道等值仍是灰
      final c = Color(out | 0xFF000000);
      expect(channel255(c.r), equals(channel255(c.g)));
      expect(channel255(c.g), equals(channel255(c.b)));
    });

    test('中饱和色：L+0.16、S+0.18、色相不变', () {
      // 0xDD9955：HSL(30°, 2/3, 0.6)
      const int orange = 0xDD9955;
      final int out = processBgBloomColor(orange);
      final hsl = HSLColor.fromColor(Color(out | 0xFF000000));
      expect(hsl.hue, closeTo(30.0, 1e-6));
      expect(hsl.lightness, closeTo(0.76, 1e-3));
      // RGB 8bit 量化回读 HSL 有 ~0.6% 的往返误差，容差放宽到 2e-2
      expect(hsl.saturation, closeTo(2 / 3 + 0.18, 2e-2));
    });

    test('深色背景：同样按增量抬亮（不因暗就跳过）', () {
      // 0x116611：r=b=17，g=102 → HSL(120°, ≈0.714, ≈0.233)
      final int out = processBgBloomColor(0x116611);
      final hsl = HSLColor.fromColor(Color(out | 0xFF000000));
      expect(hsl.hue, closeTo(120.0, 1e-6));
      expect(hsl.lightness, closeTo((0.4 + 17 / 255) / 2 + 0.16, 1e-3));
      expect(hsl.saturation,
          closeTo(0.333333 / 0.466667 + 0.18, 1e-2));
    });

    test('近白背景：明度钳在 0.94 附近，不出高光色域', () {
      const int white = 0xFFFFFF;
      final int out = processBgBloomColor(white);
      final c = Color(out | 0xFF000000);
      final hsl = HSLColor.fromColor(c);
      // 0.94 经 RGB 8bit 量化回读为 240/255≈0.9412，容差 0.005
      expect(hsl.lightness, closeTo(0.94, 5e-3));
      // 每个通道 ≤ 240（0.94×255≈239.7）
      for (final v in [c.r, c.g, c.b]) {
        expect(channel255(v), lessThanOrEqualTo(240));
      }
    });

    test('端点回归：纯黑输入不被压暗、输出三通道恒在 0~255', () {
      final int out = processBgBloomColor(0x000000);
      final c = Color(out | 0xFF000000);
      for (final v in [c.r, c.g, c.b]) {
        expect(channel255(v), inInclusiveRange(0, 255));
      }
      // 黑的 HSL L=0 → +0.16 = 0.16，通道应约 41
      expect(channel255(c.r), closeTo(0.16 * 255, 1));
    });
  });

  group('averageRgbaRegion', () {
    /// 2×2 合成位图（RGBA，行主序）：
    ///   (0,0)=(10,20,30)  (1,0)=(40,50,60)
    ///   (0,1)=(70,80,90)  (1,1)=(100,110,120)
    late Uint8List rgba2x2;

    setUp(() {
      rgba2x2 = Uint8List.fromList(<int>[
        10, 20, 30, 77,
        40, 50, 60, 88,
        70, 80, 90, 99,
        100, 110, 120, 110,
      ]);
    });

    test('整幅区域均值 = 四像素均值（alpha 不参与）', () {
      final avg = averageRgbaRegion(rgba2x2, 2, 2,
          x0: 0, y0: 0, x1: 2, y1: 2);
      if (avg == null) {
        fail('整幅区域均值不应为空');
      }
      expect(avg.r, 55);
      expect(avg.g, 65);
      expect(avg.b, 75);
    });

    test('单列区域：按覆盖像素求均值', () {
      final avg = averageRgbaRegion(rgba2x2, 2, 2,
          x0: 0, y0: 0, x1: 1, y1: 2);
      if (avg == null) {
        fail('单列区域均值不应为空');
      }
      expect(avg.r, 40); // (10+70)/2
      expect(avg.g, 50);
      expect(avg.b, 60);
    });

    test('越界坐标按边界钳位，等效于整幅', () {
      final avg = averageRgbaRegion(rgba2x2, 2, 2,
          x0: -5, y0: -5, x1: 10, y1: 10);
      if (avg == null) {
        fail('钳位后区域不应为空');
      }
      expect(avg.r, 55);
      expect(avg.g, 65);
      expect(avg.b, 75);
    });

    test('钳位后面积为 0（区域整体越界）→ null', () {
      expect(
        averageRgbaRegion(rgba2x2, 2, 2, x0: 2, y0: 0, x1: 5, y1: 2),
        isNull,
      );
      expect(
        averageRgbaRegion(rgba2x2, 2, 2, x0: 0, y0: 2, x1: 2, y1: 5),
        isNull,
      );
    });

    test('缓冲短于声明尺寸 → null（不越界读取）', () {
      expect(
        averageRgbaRegion(Uint8List.fromList(<int>[1, 2, 3, 4]), 2, 2,
          x0: 0, y0: 0, x1: 2, y1: 2),
        isNull,
      );
    });
  });
}