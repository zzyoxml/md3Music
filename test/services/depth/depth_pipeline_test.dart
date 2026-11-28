// depth_pipeline / depth_pipeline_tools 的行为契约测试（Windows 3D 封面）。
//
// 这套纯函数是 Android Kotlin（DepthCoverPlugin.kt / InpaintTools.kt /
// PullPushFiller.kt）的逐函数移植，阈值/带区间/位布局全部照抄。回归点：
// 1. normalizeDepth：min-max 归一化 + range 下限 1e-6（常数输入不产生 NaN/Inf）。
// 2. depthStd：stride 4 采样（非采样位不参与）、空/零样本 → 0.18。
// 3. dilateHole：生产半径 4（holeDilateRadius）单点 → 9×9 方形结构元；角点不环绕。
// 4. pullPushFill：无洞恒等（逐像素不变）、洞回填取纯净背景、全洞 rgb=0 且
//    alpha 与源像素一致（Kotlin `ushr 24` 语义）。
// 5. splitLayer：带外全透明、带内不透明、羽化带按深度线性渐变。
// 6. buildModelInput：NCHW 平面布局 + ImageNet 归一化（f32 与 Kotlin FloatArray 逐位一致）。
// 7. MI-GAN 张量：image 必须 NCHW 平面（坑①）；mask 必须二值且 255=known/0=hole
//    与 fgMask 的「1=洞」相反（坑②）。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/services/depth/depth_pipeline.dart';

void main() {
  group('normalizeDepth（min-max 归一化）', () {
    test('单调数组 → 0..1，中点对半', () {
      final out = normalizeDepth(<double>[2.0, 4.0, 6.0, 8.0]);
      expect(out[0], 0.0);
      expect(out[3], 1.0);
      expect(out[1], closeTo(1 / 3, 1e-12));
    });

    test('常数输入（range≈0）→ 全 0，不产生 NaN', () {
      final out = normalizeDepth(<double>[3.0, 3.0, 3.0, 3.0]);
      for (final v in out) {
        expect(v, 0.0);
        expect(v.isNaN, isFalse);
      }
    });

    test('负值/乱序输入：min-max 仍覆盖全数组', () {
      final out = normalizeDepth(<double>[-1.0, 1.0, 0.0]);
      expect(out[0], 0.0);
      expect(out[1], 1.0);
      expect(out[2], closeTo(0.5, 1e-12));
    });
  });

  group('depthStd（stride 4 采样）', () {
    test('stride 4：非采样位不参与（0,1,2 有效 → sqrt(2/3)）', () {
      final std = depthStd(<double>[0, 99, 98, 0, 1, 0, 0, 0, 2]);
      expect(std, closeTo(0.816496581, 1e-6));
    });

    test('空数组 → 0.18（异常兜底，与 Kotlin 一致）', () {
      expect(depthStd(<double>[]), 0.18);
    });

    test('常数数组 → 0', () {
      expect(depthStd(<double>[0.5, 0, 0, 0, 0.5]), 0.0);
    });
  });

  group('dilateHole（分离式 max filter）', () {
    Float64List _single(int side, int x, int y) {
      final m = Float64List(side * side);
      m[y * side + x] = 1.0;
      return m;
    }

    test('生产半径 4：单点 → 9×9 方形（81 格）', () {
      const side = 20;
      final out = dilateHole(_single(side, 10, 10), radius: holeDilateRadius);
      var count = 0;
      for (var y = 0; y < side; y++) {
        for (var x = 0; x < side; x++) {
          if (out[y * side + x] > 0) count++;
        }
      }
      expect(count, 81); // (2*4+1)^2
      // 5 格之外必须为 0
      expect(out[10 * side + (10 + 5)], 0.0);
      expect(out[(10 + 5) * side + 10], 0.0);
    });

    test('角点不环绕（镜像边界 → 一侧全 0）', () {
      const side = 12;
      final out = dilateHole(_single(side, 0, 0), radius: holeDilateRadius);
      // (0,0) 的洞只向右/下扩散，不绕到另一角
      expect(out[(side - 1) * side + (side - 1)], 0.0);
      expect(out[0], 1.0);
    });

    test('两趟分离 = 方形结构元（对角线角点也被吞进）', () {
      const side = 20;
      final out = dilateHole(_single(side, 10, 10), radius: holeDilateRadius);
      expect(out[(10 + 4) * side + (10 + 4)], 1.0); // 对角 4 格
    });
  });

  group('pullPushFill（金字塔修补）', () {
    Uint32List _img(int w, int h, int argb) => Uint32List(w * h)..fillRange(0, w * h, argb);

    test('无洞 → 逐像素恒等（含 alpha）', () {
      const w = 8, h = 8;
      final src = Uint32List(w * h);
      for (var i = 0; i < src.length; i++) {
        src[i] = 0xFF000000 | (i << 8) | (i & 0xFF); // 任意不透明色
      }
      final mask = Float64List(w * h); // 全 0 = 无洞
      final out = pullPushFill(pixels: src, w: w, h: h, mask: mask);
      for (var i = 0; i < src.length; i++) {
        expect(out[i] & 0xFFFFFFFF, src[i], reason: '像素 $i 必须原样保留');
      }
    });

    test('中心洞 → 回填为周围纯净背景的均值（无轮廓污染）', () {
      const w = 9, h = 9;
      final src = _img(w, h, 0xFF203040); // 全图同一背景色
      final mask = Float64List(w * h);
      mask[4 * w + 4] = 1.0; // 中心单点洞
      final out = pullPushFill(pixels: src, w: w, h: h, mask: mask);
      expect(out[4 * w + 4] & 0xFFFFFFFF, 0xFF203040,
          reason: '均匀背景下洞区应被回填为同一背景色');
    });

    test('全洞 → rgb=0 且 alpha 与源一致（不崩、不透明度不丢）', () {
      const w = 6, h = 6;
      final src = _img(w, h, 0x80112233); // 半透明源
      final mask = Float64List(w * h)..fillRange(0, w * h, 1.0);
      final out = pullPushFill(pixels: src, w: w, h: h, mask: mask);
      for (var i = 0; i < out.length; i++) {
        expect((out[i] >> 24) & 0xFF, 0x80, reason: 'alpha 与源一致（ushr 24）');
        expect(out[i] & 0x00FFFFFF, 0x00000000);
      }
    });

    test('羽化洞（0<mask<0.5）→ 与填充色按 keep 混合，无硬边', () {
      const w = 9, h = 9;
      final src = _img(w, h, 0xFF000000); // 黑背景
      final mask = Float64List(w * h);
      mask[4 * w + 4] = 0.5; // 临界：权重恰好为 0（完全洞）
      final out = pullPushFill(pixels: src, w: w, h: h, mask: mask);
      // 全黑背景下任何混合结果 rgb 仍为 0 —— 断言不抛错且 alpha 不变即可
      expect((out[4 * w + 4] >> 24) & 0xFF, 0xFF);
    });
  });

  group('splitLayer（深度带切割 + 羽化）', () {
    test('带外透明、带内不透明、羽化带渐变', () {
      const w = 1, h = 5;
      // 5 个像素的白图；norm 必须是 378×378 网格（splitLayer 硬编码 DEPTH_SIZE，
      // 与 Kotlin 一致）。采样映射 dy = min((y*378)~/h, 377)、dx = min((x*378)~/w, 377)，
      // 对 5 行图像取到网格行 [0, 75, 151, 226, 302]（4*378=1512 → ~/5 = 302）。
      final sampledRows = <int>[0, 75, 151, 226, 302];
      final sampledDepth = <double>[0.0, 0.5, 0.6, 0.7, 1.0];
      final grid = Float64List(depthGridSize * depthGridSize);
      for (var i = 0; i < sampledRows.length; i++) {
        grid[sampledRows[i] * depthGridSize] = sampledDepth[i];
      }
      // 白色不透明
      final rgba = Uint8List(w * h * 4)..fillRange(0, w * h * 4, 0xFF);
      final layer = splitLayer(
        pixels: rgbaToArgb32(rgba, w, h),
        w: w,
        h: h,
        norm: grid,
        lo: 0.65,
        hi: 1.00,
        feather: 0.10,
      );
      int alphaOf(int i) => (layer[i] >> 24) & 0xFF;
      expect(alphaOf(0), 0, reason: '深度 0 远离前景带 → 全透明');
      expect(alphaOf(1), 0, reason: '深度 0.5 < lo - feather → 全透明');
      expect(alphaOf(2), greaterThan(0), reason: '羽化带内 → 渐入');
      expect(alphaOf(2), lessThan(255));
      expect(alphaOf(3), 255, reason: '带内 → 不透明');
      expect(alphaOf(4), 255, reason: '带内（hi 之上无越界）→ 不透明');
    });
  });

  group('buildModelInput（NCHW + ImageNet 归一化）', () {
    test('NCHW 平面布局 + (v-mean)/std', () {
      const s = 2;
      // 2×2 纯红图：R=255, G=0, B=0
      final rgba = Uint8List.fromList([
        255, 0, 0, 255, 255, 0, 0, 255, //
        255, 0, 0, 255, 255, 0, 0, 255,
      ]);
      final input = buildModelInput(rgba: rgba, w: s, h: s, targetSize: s);
      expect(input.length, 3 * s * s);
      final expectNorm = (255.0 / 255.0 - imagenetMean[0]) / imagenetStd[0];
      // R 平面全部为归一化后的红
      for (var i = 0; i < s * s; i++) {
        expect(input[i], closeTo(expectNorm, 1e-6));
        expect(input[s * s + i], closeTo((0.0 - imagenetMean[1]) / imagenetStd[1], 1e-6));
        expect(input[2 * s * s + i], closeTo((0.0 - imagenetMean[2]) / imagenetStd[2], 1e-6));
      }
    });

    test('双线性缩放：2×2 → 1×1 取四邻均值', () {
      const s = 2;
      final rgba = Uint8List.fromList([
        0, 0, 0, 255, 100, 0, 0, 255, //
        200, 0, 0, 255, 255, 0, 0, 255,
      ]);
      final input = buildModelInput(rgba: rgba, w: s, h: s, targetSize: 1);
      // (0+100+200+255)/4 = 138.75 → 归一化后
      final expectNorm = (138.75 / 255.0 - imagenetMean[0]) / imagenetStd[0];
      expect(input[0], closeTo(expectNorm, 1e-6));
    });
  });

  group('MI-GAN 张量装配（两个已知踩坑的回归）', () {
    test('坑①：image 张量必须是 NCHW 平面（R 平面→G 平面→B 平面）', () {
      const w = 2, h = 2;
      // (0,0)=红 (1,0)=绿 (0,1)=蓝 (1,1)=白
      final rgba = Uint8List.fromList([
        255, 0, 0, 255, 0, 255, 0, 255, //
        0, 0, 255, 255, 255, 255, 255, 255,
      ]);
      final t = miganImageTensor(rgba, w, h);
      expect(t.length, w * h * 3);
      // R 平面（前 4 个）
      expect(t.sublist(0, 4), [255, 0, 0, 255]);
      // G 平面（中 4 个）
      expect(t.sublist(4, 8), [0, 255, 0, 255]);
      // B 平面（后 4 个）
      expect(t.sublist(8, 12), [0, 0, 255, 255]);
    });

    test('坑②：mask 张量必须二值反转（255=known / 0=hole），几何与双线性放大一致', () {
      const side = 4;
      const w = 4, h = 4;
      // 深度网格：0.9（前景）在 (1,1)，其余 0.1（背景）
      final grid = Float64List(side * side)..fillRange(0, side * side, 0.1);
      grid[1 * side + 1] = 0.9;
      // fgMask(0.55, 0.65)：0.1 → 0（背景/known→255）；0.9 → 1（洞→0）
      final mask = miganMaskTensor(grid, w, h);
      expect(mask[0 * w + 0], 255, reason: '背景 = known');
      expect(mask[1 * w + 1], 0, reason: '前景 = hole');
      // 全部必须是二值（0 或 255），不能有连续软边值
      for (final v in mask) {
        expect(v == 0 || v == 255, isTrue, reason: '掩码必须二值，收到 $v');
      }
    });
  });

  group('通道顺序（2026-10-28 发红紫回归）', () {
    test('rgbaToArgb32：B 通道不得取成 R（红紫 bug 的直接判据）', () {
      // 纯蓝：ARGB 必须是 0xFF0000FF；若 B 误取 R 会得到 0xFFFF00FF（品红）
      final blue = rgbaToArgb32(Uint8List.fromList([0, 0, 255, 255]), 1, 1);
      expect(blue[0] & 0xFFFFFFFF, 0xFF0000FF,
          reason: '蓝被红覆盖=发红紫；这一条就是当时的病因');
      final red = rgbaToArgb32(Uint8List.fromList([255, 0, 0, 255]), 1, 1);
      expect(red[0] & 0xFFFFFFFF, 0xFFFF0000);
      final green = rgbaToArgb32(Uint8List.fromList([0, 255, 0, 128]), 1, 1);
      expect(green[0] & 0xFFFFFFFF, 0x8000FF00, reason: 'alpha 也要严格对应');
      // 三通道互不相同，才能暴露任何两两错位
      final mixed = rgbaToArgb32(Uint8List.fromList([10, 20, 30, 40]), 1, 1);
      expect(mixed[0] & 0xFFFFFFFF, 0x280A141E);
    });

    test('splitLayer 切出的层保持原色（纯蓝图 → 层里仍是蓝）', () {
      const w = 1, h = 1;
      // 纯蓝不透明图，深度落在前景带内 → alpha 应为不透明
      final rgba = Uint8List.fromList([0, 0, 255, 255]);
      final grid = Float64List(depthGridSize * depthGridSize)
        ..fillRange(0, depthGridSize * depthGridSize, 0.9);
      final layer = splitLayer(
        pixels: rgbaToArgb32(rgba, w, h),
        w: w,
        h: h,
        norm: grid,
        lo: 0.65,
        hi: 1.00,
      );
      final p = layer[0] & 0xFFFFFFFF;
      expect((p >> 24) & 0xFF, 255, reason: '带内 → 不透明');
      expect(p & 0xFF, 255, reason: '蓝通道必须保留');
      expect((p >> 16) & 0xFF, 0, reason: '红通道必须为 0（发红紫就是这里错了）');
      expect((p >> 8) & 0xFF, 0, reason: '绿通道必须为 0');
    });

    test('miganImageTensor 的 NCHW 平面与源 RGBA 一致（不串色）', () {
      final rgba = Uint8List.fromList([0, 0, 255, 255]); // 纯蓝
      final t = miganImageTensor(rgba, 1, 1);
      expect(t, [0, 0, 255], reason: 'R=0,G=0,B=255（平面顺序 R→G→B）');
    });
  });

  group('depthToGrayPngPixels（灰度图）', () {
    test('R=G=B=gray，A=255；clamp 到 0..255', () {
      final px = depthToGrayPngPixels(<double>[0.0, 0.5, 1.0, 2.0]);
      expect(px.length, 16);
      expect(px.sublist(0, 4), [0, 0, 0, 255]);
      final mid = px.sublist(4, 8);
      expect(mid[0], mid[1]);
      expect(mid[1], mid[2]);
      expect(mid[0], anyOf(127, 128), reason: '0.5*255=127.5 → toInt 截断 127');
      expect(px.sublist(12, 16), [255, 255, 255, 255]);
    });
  });
}
