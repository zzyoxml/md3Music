/// 「背景增透」赋色模式（LyricFillStyle.backgroundBloom）的颜色处理纯函数。
///
/// 把从歌词背后实拍背景（模糊封面 / 流光背景 + 蒙版层）低频取样到的
/// 条带平均色，经「提亮 + 增加饱和度」处理后交给字内渐变的过曝曲线：
/// 光前沿处保持提亮后的背景色芯、已播后方白化、未播前方回落原有混色，
/// 整体光学观感为"背后背景色过曝后偏向白色"。
///
/// 本文件不含任何 widget / 平台依赖，取样与生命周期由 AppleLyricsView
/// 负责，便于单测锁定数学口径。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// 提亮幅度（HSL Lightness 增量）。过曝偏白感主要由过曝曲线承担，
/// 本值只负责把深色底上的取样色抬到"可见且像过曝"的区间。
const double kBgBloomLightnessBoost = 0.16;

/// 提亮后的明度上限。接近但不取满值：纯白核由过曝曲线的白化段产出，
/// 直接把 L 拉到 1.0 会让"前沿原色芯"失去颜色信息。
const double kBgBloomMaxLightness = 0.94;

/// 饱和度增量。近灰背景（< [kBgBloomGraySaturationFloor]）不抬饱和，
/// 避免给灰色凭空造出假色相。
const double kBgBloomSaturationBoost = 0.18;

/// 近灰判定下限：饱和度低于此值的背景按灰色处理，只提亮不加饱和。
const double kBgBloomGraySaturationFloor = 0.10;

/// 对取样背景色做「提亮 + 增加饱和度」（HSL 空间，色相不变）。
///
/// - 亮度：L + [kBgBloomLightnessBoost]，上界 [kBgBloomMaxLightness]；
/// - 饱和度：S ≥ [kBgBloomGraySaturationFloor] 时 + [kBgBloomSaturationBoost]
///   并夹到 (0, 1]；低于阈值视为近灰，只提亮。
/// - 返回 0xRRGGBB（不含 alpha；歌词文字透明度由既有 alpha 曲线控制）。
int processBgBloomColor(int rgb) {
  final hsl = HSLColor.fromColor(Color.fromARGB(255, _r(rgb), _g(rgb), _b(rgb)));
  final double l =
      (hsl.lightness + kBgBloomLightnessBoost).clamp(0.0, kBgBloomMaxLightness);
  final bool grayish = hsl.saturation < kBgBloomGraySaturationFloor;
  final double s = grayish
      ? hsl.saturation
      : (hsl.saturation + kBgBloomSaturationBoost).clamp(0.0, 1.0);
  final Color out = hsl.withLightness(l).withSaturation(s).toColor();
  return out.toARGB32() & 0xFFFFFF;
}

/// RGBA 字节序列的矩形区域平均 RGB（RGBA4 通道，行主序）。
///
/// - [x0], [y0] 含，[x1], [y1] 不含；越界部分**裁剪**（只采样图内交集）；
/// - 裁剪后面积为 0（如整行不在图内）返回 null，调用方保留旧取样；
/// - 非有限坐标同样返回 null。
({int r, int g, int b})? averageRgbaRegion(
  Uint8List rgba,
  int width,
  int height, {
  required int x0,
  required int y0,
  required int x1,
  required int y1,
}) {
  if (rgba.length < width * height * 4) return null;
  if (!(width > 0 && height > 0)) return null;
  final int xl = _trimCoord(x0, 0, width);
  final int yt = _trimCoord(y0, 0, height);
  final int xr = _trimCoord(x1, 0, width);
  final int yb = _trimCoord(y1, 0, height);
  if (xr <= xl || yb <= yt) return null;
  int sr = 0, sg = 0, sb = 0, n = 0;
  for (int y = yt; y < yb; y++) {
    final int rowBase = y * width * 4;
    for (int x = xl; x < xr; x++) {
      final int i = rowBase + x * 4;
      sr += rgba[i];
      sg += rgba[i + 1];
      sb += rgba[i + 2];
      n++;
    }
  }
  if (n == 0) return null;
  return (r: sr ~/ n, g: sg ~/ n, b: sb ~/ n);
}

int _r(int rgb) => (rgb >> 16) & 0xFF;
int _g(int rgb) => (rgb >> 8) & 0xFF;
int _b(int rgb) => rgb & 0xFF;

/// 裁剪一维矩形边界到 [lo, hi]（矩形端采用半开区间语义由调用方保证）。
int _trimCoord(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);