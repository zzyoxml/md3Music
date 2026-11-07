/// 3D 封面深度算法管线（纯 Dart 移植，平台无关）。
///
/// ═══════════════════════════════════════════════════════════════════════════
/// 与 Kotlin 的逐函数对应表
/// ═══════════════════════════════════════════════════════════════════════════
/// | 本文件（depth_pipeline.dart）              | Kotlin 原函数                                   |
/// |--------------------------------------------|-------------------------------------------------|
/// | [depthGridSize]                            | DepthCoverPlugin.DEPTH_SIZE（kt:48）             |
/// | [imagenetMean]/[imagenetStd]               | MEAN / STD（kt:61-62）                            |
/// | [depthBands]/[layerFeather]                | BANDS / FEATHER（kt:64-69）                       |
/// | [maskDilateRadius]                         | MASK_DILATE_RADIUS（kt:59）                       |
/// | [normalizeDepth]                           | normalize（kt:525-534）                           |
/// | [depthStd]                                 | depthStd（kt:537-553）                            |
/// | [splitLayer]                               | splitLayer（kt:560-585）                          |
/// | [buildModelInput]                          | infer 的输入张量装配（kt:587-605，不含 ONNX 调用）|
/// | [inpaintBackground]                        | inpaintBackground（kt:387-418）                   |
/// | [grayscaleGuide]                           | inpaintBackground 的 guide 计算（kt:389-399）     |
/// | [miganImageTensor]                         | neuralRefine 的 rgb 装配（kt:455-464）            |
/// | [miganMaskTensor]                          | neuralRefine 的 maskU8 装配（kt:442-450）         |
/// | [miganOutputToArgb]                        | neuralRefine 的输出回写（kt:494-499）             |
/// | [depthToGrayArgb32]/[depthToGrayPngPixels] | generateDepth 的灰度像素装配（kt:233-238）        |
///
/// 工具集（joint bilateral / smoothstep / 前景掩码 / 膨胀 / push-pull）在
/// `depth_pipeline_tools.dart`，对应 InpaintTools.kt 与 PullPushFiller.kt：
///   jointBilateralSmooth / smoothstep / foregroundMask / dilateHole /
///   pullPushFill / sampleMaskBilinear / upsampleMaskToFull
///
/// ═══════════════════════════════════════════════════════════════════════════
/// 两个已知踩坑（Kotlin 注释原文保留，勿再犯）
/// ═══════════════════════════════════════════════════════════════════════════
/// 1. **MI-GAN 的 image 张量必须是 NCHW 平面布局**（R 平面 → G 平面 → B 平面）。
///    误用 packed/交错 RGB 会让整个洞区输出成色块噪声
///    （设备 bg_fill 取证确认；桌面验证脚本用了 `transpose(2,0,1)` 所以没暴露）。
///    → 见 [miganImageTensor]。
/// 2. **MI-GAN 的 mask 张量必须是二值**，且协议是 **255=known / 0=hole**，
///    与 [foregroundMask]/[dilateHole] 输出的「1=洞」软边掩码**正好相反**，必须反转+硬化。
///    连续软边值会让 pipeline 的 crop/blending 在过渡带产生彩色镶边
///    （桌面实测边界带误差：二值 11.98 → 软边 60.45；彩度偏差：3.77 → 10.39）。
///    → 见 [miganMaskTensor]。
///
/// ═══════════════════════════════════════════════════════════════════════════
/// ARGB32 位布局（务必先读）
/// ═══════════════════════════════════════════════════════════════════════════
/// `ARGB32 = a<<24 | r<<16 | g<<8 | b`。Kotlin 侧是 `IntArray`（**有符号** 32 位，
/// alpha>=128 时整值为负）；Dart VM 的 `int` 是 **64 位**。移植规则：
///   - 读入：先 `p & 0xFFFFFFFF` 归一为 32 位无符号形态，通道一律「右移 + `& 0xFF`」，
///     与 Kotlin `shr/ushr + and 0xFF` 取到的字节完全一致（负值输入也正确）；
///   - 写出：统一 `& 0xFFFFFFFF`，**本文件与 tools 文件的所有像素输出都是 0..2^32-1
///     的无符号 32 位**。交给有符号 32 位消费者（JNI / FFI Int32 缓冲）时由调用方转回。
///   - alpha 语义：[splitLayer] 保留源 rgb 只改 alpha（带外=0 即 `Color.TRANSPARENT`，
///     带内按 FEATHER 线性羽化）；[pullPushFill] 的 alpha 与源像素一致。
///
/// ═══════════════════════════════════════════════════════════════════════════
/// 精度与可移植性
/// ═══════════════════════════════════════════════════════════════════════════
/// 公式、分支、阈值、遍历顺序一律照抄 Kotlin，不做「改进」。唯一系统性差异是
/// Kotlin 用 `Float`（单精度）、Dart 用 `double`（双精度），故中间量舍入不同、
/// 结果相对误差约 1e-7，贴边值的阈值分支理论上可能翻转（详见 tools 文件头）。
/// 另一个边界差异：Kotlin `Float.toInt()` 对 NaN/±Inf 饱和、Dart `double.toInt()`
/// 抛异常（[splitLayer] 的 `(a*255).toInt()`、[depthToGrayArgb32] 的 `(norm*255).toInt()`
/// 与 pullPushFill 裁回同理）；有限输入下逐元素等价。
/// 唯一显式落回单精度的是 ONNX 输入：[buildModelInput] 返回 `Float32List`，
/// 写回 f32 后与 Kotlin 的 `FloatArray` **逐位一致**。
/// 缩放几何（[buildModelInput]/[grayscaleGuide]）与 `Bitmap.createScaledBitmap(..., true)`
/// 同为半像素中心对齐双线性 + 边缘 replicate，但 Skia 内部是定点运算，
/// **不能保证逐字节相同** —— 这是设计上的已知不可等价点，见各函数注释。
///
/// ═══════════════════════════════════════════════════════════════════════════
/// 改数纪律
/// ═══════════════════════════════════════════════════════════════════════════
/// **本文件所有常量 / 阈值 / 带区间均为 Kotlin 原值照抄。
/// 改任何一个数，必须重跑 `scripts/tools/depth/` 下的离线脚本实测
/// （DEPTH_SIZE 尤其要复跑 Kotlin 注释点名的 `tmp/stage1_input_size.py`），
/// 禁止凭推断改数。**
///
/// 依赖面：只有 `dart:typed_data` / `dart:math` + 同目录 tools 文件。
/// 不 import dart:ffi / dart:ui / package:ort_dart / package:flutter，
/// 因此可直接在 `flutter test` 中运行，也可被 `Isolate.run` 携带。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'depth_pipeline_tools.dart';

export 'depth_pipeline_tools.dart'
    show
        jointBilateralSmooth,
        smoothstep,
        foregroundMask,
        dilateHole,
        pullPushFill,
        sampleMaskBilinear,
        upsampleMaskToFull,
        gridSide,
        fgMaskLo,
        fgMaskHi,
        holeDilateRadius,
        dilateHoleDefaultRadius,
        bilateralRadius,
        bilateralSigmaS,
        bilateralSigmaC,
        pullPushPad;

// MARK: 管线常量（全部照抄 DepthCoverPlugin）

/// 深度推理网格边长（同时作为背景修补掩码的分辨率）。
///
/// 必须是 14 的倍数（ViT patch=14 对齐）。**2026-09-26 由 518 降到 378**：
/// 封面本身只有 400×400，518 属上采样、无信息增益却多约 1.7× 计算；实测
/// 378 在 Resize-Bilinear 回封面尺寸后与 518 的深度相关性 **0.9945**、分层 gather
/// 层一致性判据稳定（hit 99.9%），推理耗时 813ms → 377ms（**2.2× 提速**）。
/// 代价：518 档的「脸召回」23.8% → 11.0%（手掌几乎不变 63.0% → 62.0%）——
/// 已由用户确认接受。
///
/// ⚠ 尺寸与质量**非单调**（392 反而比 378 更差），改此值必须重跑
/// `tmp/stage1_input_size.py` 实测，禁止推断。（DepthCoverPlugin.kt:36-48）
const int depthGridSize = 378;

/// 背景修补掩码的膨胀半径（单位 = 深度网格像素，即 [depthGridSize]）。
///
/// 洞向外扩这么多像素，把主体过渡带（发丝 / 抗锯齿混合色）吞进洞里，
/// 让后续填充（push-pull / MI-GAN）的源只来自纯净背景；**半径越大轮廓残留越少**，
/// 代价是主体轮廓被多啃掉一圈（渲染时让出区显示修补背景的位置更靠内）。
/// 放回封面分辨率后约等于 `radius × 封面宽 / DEPTH_SIZE` 像素（400 封面 ≈ ×1.06）。
/// **2026-09-26：2 → 4**（用户反馈前景边缘仍有残留未分离干净）。
/// （DepthCoverPlugin.kt:51-59）
const int maskDilateRadius = holeDilateRadius; // == 4，单一真值在 tools 文件

/// ImageNet 归一化均值（与 fabio-sim/Depth-Anything-ONNX infer.py 一致；kt:61）。
const List<double> imagenetMean = [0.485, 0.456, 0.406];

/// ImageNet 归一化标准差（同上；kt:62）。
const List<double> imagenetStd = [0.229, 0.224, 0.225];

/// 深度带（0=远/背景，1=近/前景）。相邻带**重叠** + 羽化避免硬边（kt:64-68）。
/// `[lo, hi]`：layer0 背景 0.00..0.40 / layer1 中景 0.35..0.70 / layer2 前景 0.65..1.00。
const List<List<double>> depthBands = [
  [0.00, 0.40], // layer0 背景
  [0.35, 0.70], // layer1 中景
  [0.65, 1.00], // layer2 前景
];

/// 归一化羽化带宽（kt:69）。
const double layerFeather = 0.10;

/// `Color.TRANSPARENT` = 0x00000000（kt:578 的赋值目标）。
const int _argbTransparent = 0x00000000;

/// 灰度深度图的 alpha（kt:237 固定 0xFF）。
const int _opaqueAlpha = 0xFF;

/// Rec.601 亮度权重（与 kt:396-398 一致：0.299 R + 0.587 G + 0.114 B，再 /255）。
const double _lumaR = 0.299;
const double _lumaG = 0.587;
const double _lumaB = 0.114;

// MARK: 归一化与统计

/// min-max 归一化到 0..1（值越大越近）。对应 `normalize`（kt:525-534）。
///
/// 逐分支照抄：先扫 min/max，`range = max(区间, 1e-6)`，再逐元素 `(v - min) / range`。
/// 空输入时 min=+inf / max=-inf → range=1e-6，但输出长度为 0，与 Kotlin 行为一致。
Float64List normalizeDepth(List<double> depth) {
  var min = double.infinity;
  var max = -double.infinity;
  for (var i = 0; i < depth.length; i++) {
    final v = depth[i];
    if (v < min) min = v;
    if (v > max) max = v;
  }
  final range = math.max(max - min, 1e-6);
  final out = Float64List(depth.length);
  for (var i = 0; i < depth.length; i++) {
    out[i] = (depth[i] - min) / range;
  }
  return out;
}

/// 深度图标准差（**stride 4 采样**，ShengChao computeDepthStd 同款；kt:537-553）。
///
/// 无样本（空数组）返回 **0.18**；方差先 `coerceAtLeast(0)` 再开方。
double depthStd(List<double> norm) {
  var sum = 0.0;
  var sumSq = 0.0;
  var n = 0.0;
  var i = 0;
  while (i < norm.length) {
    final v = norm[i];
    sum += v;
    sumSq += v * v;
    n += 1.0;
    i += 4;
  }
  if (n == 0.0) return 0.18;
  final mean = sum / n;
  final variance = math.max(sumSq / n - mean * mean, 0.0);
  return math.sqrt(variance);
}

// MARK: 分层切割

/// 深度落在 [lo,hi] 带内的像素保留，带外按 [layerFeather] 线性羽化为透明。
/// 对应 `splitLayer`（kt:560-585）。
///
/// 输入像素为封面原分辨率（`w*h`，ARGB32，见文件头位布局说明）；
/// [norm] 是推理分辨率（[depthGridSize]×[depthGridSize]）的摊平结果，
/// 按 (x,y) 遍历封面时用**整数除法最近邻**映射回深度网格取深度（照抄 kt:568-570）：
/// `dx = (x * D / w).coerceAtMost(D - 1)`（先乘后整除，非浮点、非四舍五入）。
///
/// alpha 公式与 Kotlin 的三分支**逐分支等价**（kt:571-581）：
///   - `d < lo - FEATHER || d > hi + FEATHER` → a = 0 → 整像素写 `Color.TRANSPARENT`
///     （rgb 一并清零，**不是**只改 alpha）；
///   - `lo - FEATHER <= d < lo` → a = `(d - (lo - FEATHER)) / FEATHER`（渐入）；
///   - `hi < d <= hi + FEATHER` → a = `((hi + FEATHER) - d) / FEATHER`（渐出）；
///   - 其余 → a = 1 → 像素原样保留（不重打包，故 alpha=255 时字节完全不变）。
/// 仅当 `0 < a < 1` 时保留 rgb、把 alpha 换成 `(a*255).toInt()`（向零截断）左移 24 位。
List<int> splitLayer({
  required List<int> pixels,
  required int w,
  required int h,
  required List<double> norm,
  required double lo,
  required double hi,
  double feather = layerFeather,
}) {
  final d = depthGridSize;
  final out = Uint32List(w * h);
  final lastGrid = d - 1;
  for (var y = 0; y < h; y++) {
    final srcRow = y * w;
    final dy = _minInt((y * d) ~/ h, lastGrid);
    final gridRow = dy * d;
    for (var x = 0; x < w; x++) {
      final i = srcRow + x;
      final p = pixels[i] & 0xFFFFFFFF;
      final dx = _minInt((x * d) ~/ w, lastGrid);
      final dd = norm[gridRow + dx];
      final double a;
      if (dd < lo - feather || dd > hi + feather) {
        a = 0.0;
      } else if (dd < lo) {
        a = (dd - (lo - feather)) / feather;
      } else if (dd > hi) {
        a = ((hi + feather) - dd) / feather;
      } else {
        a = 1.0;
      }
      if (a <= 0.0) {
        out[i] = _argbTransparent; // Color.TRANSPARENT
      } else if (a < 1.0) {
        final alpha = (a * 255.0).toInt() << 24;
        out[i] = ((p & 0x00FFFFFF) | alpha) & 0xFFFFFFFF;
      } else {
        out[i] = p;
      }
    }
  }
  return out;
}

// MARK: Depth Anything V2 输入张量

/// 从 RGBA 字节装配 Depth Anything V2 的推理输入：
/// 双线性缩放到 `targetSize×targetSize` → NCHW float32 → `(v - mean) / std`。
/// 对应 `infer` 的张量装配部分（kt:587-605，不含 ONNX 会话调用）。
///
/// [rgba] 为每像素 4 字节（R,G,B,A 顺序，引擎/解码器约定），长度须为 `w*h*4`。
/// 通道映射照抄 kt:599-602：c=0→R、c=1→G、c=2→B，取值 `/255` 后做 ImageNet 归一化，
/// 写入偏移 `c*targetSize*targetSize` 的平面（NCHW，行主序）。
///
/// **缩放几何**：Kotlin 用 `Bitmap.createScaledBitmap(src, D, D, true)`，即 Skia
/// 双线性；本实现用同族的**半像素中心对齐**映射
/// `sx = (x + 0.5) * w / targetSize - 0.5`，边缘 replicate（clamp）且负权不出界。
/// 与 Skia 的差异：Skia 内部为定点（16.8/8.8 类）滤波系数，故本函数**不保证与
/// Android 输出逐字节相同**；两者都属于「双线性 + 中心对齐」，误差在半像素内。
/// 这是刻意保留的可移植实现，如需与设备端位图严格对齐，须用同一套离线脚本重测。
///
/// 返回 `Float32List`：写回单精度后与 Kotlin `FloatArray` 逐位一致，可直接交给
/// ONNX Runtime 的 float32 张量（长度 `3*targetSize*targetSize`）。
Float32List buildModelInput({
  required Uint8List rgba,
  required int w,
  required int h,
  int targetSize = depthGridSize,
}) {
  final plane = targetSize * targetSize;
  final data = Float32List(3 * plane);
  // 一次缩放采样出 RGB（float 0..255），再按 c 平面写归一化值 ——
  // 与 Kotlin「先 getPixels 再逐 c 遍历」结果等价（每个平面独立计算，无共享中间态）。
  final rowBuf = Float64List(targetSize * 3);
  final scaleX = w.toDouble() / targetSize;
  final scaleY = h.toDouble() / targetSize;
  for (var y = 0; y < targetSize; y++) {
    final sy = (y + 0.5) * scaleY - 0.5;
    _bilinearRgbRow(rgba, w, h, sy, targetSize, scaleX, rowBuf);
    final dstRow = y * targetSize;
    for (var x = 0; x < targetSize; x++) {
      final s = x * 3;
      final idx = dstRow + x;
      data[idx] = (rowBuf[s] / 255.0 - imagenetMean[0]) / imagenetStd[0];
      data[plane + idx] = (rowBuf[s + 1] / 255.0 - imagenetMean[1]) / imagenetStd[1];
      data[2 * plane + idx] = (rowBuf[s + 2] / 255.0 - imagenetMean[2]) / imagenetStd[2];
    }
  }
  return data;
}

/// 原图灰度引导图：缩放到深度网格后取 Rec.601 亮度 /255。
/// 对应 `inpaintBackground` 的 guide 计算（kt:389-399）。
///
/// 用途：joint bilateral 的引导 —— 以亮度差为约束权重，深度在主体边缘外不跨边模糊。
/// 缩放几何与 [buildModelInput] 同源（同一半像素中心对齐双线性），
/// 与 Kotlin 的 `createScaledBitmap(..., true)` 同上，不保证逐字节一致。
Float64List grayscaleGuide({
  required Uint8List rgba,
  required int w,
  required int h,
  int gridSize = depthGridSize,
}) {
  final out = Float64List(gridSize * gridSize);
  final rowBuf = Float64List(gridSize * 3);
  final scaleX = w.toDouble() / gridSize;
  final scaleY = h.toDouble() / gridSize;
  for (var y = 0; y < gridSize; y++) {
    final sy = (y + 0.5) * scaleY - 0.5;
    _bilinearRgbRow(rgba, w, h, sy, gridSize, scaleX, rowBuf);
    final dstRow = y * gridSize;
    for (var x = 0; x < gridSize; x++) {
      final s = x * 3;
      out[dstRow + x] = (_lumaR * rowBuf[s] +
              _lumaG * rowBuf[s + 1] +
              _lumaB * rowBuf[s + 2]) /
          255.0;
    }
  }
  return out;
}

// MARK: 背景修补管线

/// 背景修补结果。对应 Kotlin 私有 `InpaintResult`（kt:380）。
///
/// - [filled]：原图分辨率（`w*h`）的修补后像素，ARGB32 无符号 32 位，alpha 同源像素；
/// - [maskGrid]：膨胀后的前景掩码（`1=洞`，深度网格分辨率 [depthGridSize]²），
///   供 MI-GAN 二值掩码装配复用（[miganMaskTensor]）。
class InpaintResult {
  InpaintResult({required this.filled, required this.maskGrid});

  final List<int> filled;
  final Float64List maskGrid;
}

/// 背景修补管线（generate / generateDepth 共用）。对应 `inpaintBackground`（kt:387-418）。
///
/// 顺序逐行照抄：原图灰度引导 → [jointBilateralSmooth]（5×5，σs=1.4，σc=0.12）
/// → [foregroundMask]（lo=0.55 / hi=0.65）→ [dilateHole]（radius=[maskDilateRadius]）
/// → 掩码双线性放大到封面分辨率（半像素中心对齐，与 MI-GAN 同一几何）
/// → [pullPushFill]。
///
/// [rgba] 是封面解码后的 RGBA 字节（`w*h*4`），[norm] 是 [normalizeDepth] 的输出。
InpaintResult inpaintBackground({
  required Uint8List rgba,
  required int w,
  required int h,
  required List<double> norm,
  List<int>? pixels,
}) {
  // 引导图：原图灰度下采样到深度网格
  final guide = grayscaleGuide(rgba: rgba, w: w, h: h);
  final smoothDepth = jointBilateralSmooth(norm: norm, guide: guide);
  // 掩码膨胀：洞向外扩 MASK_DILATE_RADIUS 像素，把主体过渡带吞进洞里，
  // 填充源只来自纯净背景 —— 消除轮廓污染环
  final maskGrid = dilateHole(
    foregroundMask(smoothDepth),
    radius: maskDilateRadius,
  );
  // 双线性放大（替代最近邻，消除掩码锯齿边）
  final maskFull = upsampleMaskToFull(maskGrid, w, h);
  // Kotlin 直接拿 Bitmap.getPixels 的 ARGB；这里允许上层传入已拆包的像素数组，
  // 缺省则从 RGBA 字节构造（等价 getPixels 的结果）。
  final srcPix = pixels ?? rgbaToArgb32(rgba, w, h);
  return InpaintResult(
    filled: pullPushFill(pixels: srcPix, w: w, h: h, mask: maskFull),
    maskGrid: maskGrid,
  );
}

/// RGBA 字节 → ARGB32 无符号 32 位数组。等价 Kotlin `Bitmap.getPixels`（ARGB_8888）。
///
/// ⚠ 通道映射必须逐个盯住：`a=rgba[s+3] / r=rgba[s] / g=rgba[s+1] / b=rgba[s+2]`。
/// 2026-10-28 实测踩坑：B 通道曾误取 `rgba[s]`（=R），蓝通道被红覆盖，
/// 分层图整体发红紫（像素读回来是 `(r,g,r)`）。
List<int> rgbaToArgb32(Uint8List rgba, int w, int h) {
  final n = w * h;
  final out = Uint32List(n);
  for (var i = 0; i < n; i++) {
    final s = i * 4;
    out[i] = ((rgba[s + 3] << 24) |
            (rgba[s] << 16) |
            (rgba[s + 1] << 8) |
            rgba[s + 2]) &
        0xFFFFFFFF;
  }
  return out;
}

// MARK: MI-GAN 输入/输出装配

/// MI-GAN（Phase B 神经细化）的 image 张量：`[1,3,H,W]` uint8 **NCHW 平面**。
/// 对应 `neuralRefine` 的 rgb 装配（kt:455-464）。
///
/// ⚠ 必须是 R 平面 → G 平面 → B 平面（`plane = w*h` 为平面步长）。
/// 误用交错 packed RGB 会让整个洞区输出为色块噪声（设备 bg_fill 取证确认）。
/// 长度 `w*h*3`；alpha 不参与（MI-GAN 只处理 RGB）。
Uint8List miganImageTensor(Uint8List rgba, int w, int h) {
  final plane = w * h;
  final rgb = Uint8List(plane * 3);
  for (var i = 0; i < plane; i++) {
    final s = i * 4;
    rgb[i] = rgba[s]; // R 平面
    rgb[plane + i] = rgba[s + 1]; // G 平面
    rgb[2 * plane + i] = rgba[s + 2]; // B 平面
  }
  return rgb;
}

/// MI-GAN 的 mask 张量：`[1,1,H,W]` uint8 **二值**，**255=known / 0=hole**。
/// 对应 `neuralRefine` 的 maskU8 装配（kt:442-450）。
///
/// - 输入 [maskGrid] 是 [inpaintBackground] 的 `maskGrid`（1=洞，深度网格分辨率）；
/// - 放大几何与 push-pull **完全一致**（同一个 [sampleMaskBilinear] + 半像素中心对齐），
///   否则两条修补通路的洞边界会错开一圈；
/// - 判据照抄 `hole >= 0.5 → 0(hole)，否则 255(known)`：与 fgMask 的语义相反，
///   此处**已反转**；
/// - ⚠ 官方要求掩码必须二值（"must be binary"）：连续值会让 pipeline 的
///   crop/blending 在过渡带产生彩色镶边（桌面实测边界带误差 二值 11.98 → 软边 60.45，
///   彩度偏差 3.77 → 10.39），故此处硬阈值化，不要改成软过渡。
Uint8List miganMaskTensor(List<double> maskGrid, int w, int h) {
  final side = gridSide(maskGrid.length);
  final out = Uint8List(w * h);
  final scaleToGrid = side.toDouble();
  for (var y = 0; y < h; y++) {
    final fy = (y + 0.5) * scaleToGrid / h - 0.5;
    final rowBase = y * w;
    for (var x = 0; x < w; x++) {
      final fx = (x + 0.5) * scaleToGrid / w - 0.5;
      final hole = sampleMaskBilinear(maskGrid, side, fx, fy);
      out[rowBase + x] = hole >= 0.5 ? 0 : 255;
    }
  }
  return out;
}

/// 把 MI-GAN 输出 `[1,3,H,W]` uint8（NCHW）回写成 ARGB32 数组（alpha=255）。
/// 对应 `neuralRefine` 的输出读取（kt:494-499）。
///
/// 语义照抄：非洞区像素与原图完全一致（桌面验证洞外差异 = 0），故上层**整体覆盖**
/// `filled`；输出长度 `w*h`。若模型输出的洞外像素与源图不符，说明上游张量装配踩坑。
List<int> miganOutputToArgb(Uint8List nchw, int w, int h) {
  final plane = w * h;
  final out = Uint32List(plane);
  for (var i = 0; i < plane; i++) {
    final r = nchw[i];
    final g = nchw[plane + i];
    final b = nchw[2 * plane + i];
    out[i] = ((_opaqueAlpha << 24) | (r << 16) | (g << 8) | b) & 0xFFFFFFFF;
  }
  return out;
}

// MARK: 深度图灰度像素

/// 归一化深度 → 灰度 ARGB32（R=G=B=gray，A=255）。
/// 对应 `generateDepth` 的 `pixels` 装配（kt:233-238）。
///
/// 灰度取法照抄：`g = (norm[i] * 255f).toInt().coerceIn(0, 255)` —— **向零截断**
/// 而非四舍五入（所以 0.999 归一化值 → 254）。用 ARGB 承载灰度（A=255）的原因：
/// Kotlin 侧 `Bitmap.Config.ALPHA_8` 无法 `compress` 成 PNG（ShengChao
/// DepthEngine.swift:111-132 同构做法）。
List<int> depthToGrayArgb32(List<double> norm) {
  final n = norm.length;
  final out = Uint32List(n);
  for (var i = 0; i < n; i++) {
    final g = _clampByte((norm[i] * 255.0).toInt());
    out[i] = ((_opaqueAlpha << 24) | (g << 16) | (g << 8) | g) & 0xFFFFFFFF;
  }
  return out;
}

/// 归一化深度 → 灰度 PNG 像素（RGBA 字节，R=G=B=gray，A=255）。
/// 与 [depthToGrayArgb32] 同一取整规则，供上层直接编码 PNG；长度 `n*4`。
Uint8List depthToGrayPngPixels(List<double> norm) {
  final n = norm.length;
  final out = Uint8List(n * 4);
  for (var i = 0; i < n; i++) {
    final g = _clampByte((norm[i] * 255.0).toInt());
    final s = i * 4;
    out[s] = g;
    out[s + 1] = g;
    out[s + 2] = g;
    out[s + 3] = _opaqueAlpha;
  }
  return out;
}

// MARK: 内部双线性采样

/// 按目标行做一行双线性 RGB 采样（结果写入 [rowBuf]，长度 `targetSize*3`）。
///
/// 几何（半像素中心对齐 + 边缘 replicate）：
///   `sx = (x + 0.5) * w / targetSize - 0.5`，`x0 = floor(sx)` 后 clamp 到 `[0, w-2]`
///   之外的贴边情形用 `x1 = min(x0+1, w-1)`、`tx = clamp(sx - x0, 0, 1)`。
/// 这里先 floor 再 clamp（Skia 语义），与 [sampleMaskBilinear] 的
/// 「向零截断后 clamp、tx 用已 clamp 的 x0」略有不同：那是掩码放大用的 Kotlin
/// 自定义采样器，必须原样保留；本函数只服务于「对齐 createScaledBitmap」的降采样。
void _bilinearRgbRow(
  Uint8List rgba,
  int w,
  int h,
  double sy,
  int targetSize,
  double scaleX,
  Float64List rowBuf,
) {
  final y0 = _floorClamp(sy, h - 1);
  final y1 = _minInt(y0 + 1, h - 1);
  var ty = sy - y0;
  if (ty < 0) {
    ty = 0;
  } else if (ty > 1) {
    ty = 1;
  }
  final ity = 1 - ty;
  final rowBase0 = y0 * w;
  final rowBase1 = y1 * w;
  for (var x = 0; x < targetSize; x++) {
    final fx = (x + 0.5) * scaleX - 0.5;
    final x0 = _floorClamp(fx, w - 1);
    final x1 = _minInt(x0 + 1, w - 1);
    var tx = fx - x0;
    if (tx < 0) {
      tx = 0;
    } else if (tx > 1) {
      tx = 1;
    }
    final itx = 1 - tx;
    final p00 = (rowBase0 + x0) * 4;
    final p01 = (rowBase0 + x1) * 4;
    final p10 = (rowBase1 + x0) * 4;
    final p11 = (rowBase1 + x1) * 4;
    final dst = x * 3;
    for (var c = 0; c < 3; c++) {
      final v = rgba[p00 + c] * itx * ity +
          rgba[p01 + c] * tx * ity +
          rgba[p10 + c] * itx * ty +
          rgba[p11 + c] * tx * ty;
      rowBuf[dst + c] = v;
    }
  }
}

int _minInt(int a, int b) => a < b ? a : b;

/// 双线性用的向下取整 + 夹到 `[0, max]`（负坐标贴边时取 0，即边缘 replicate）。
int _floorClamp(double v, int max) {
  final f = v.floor();
  if (f < 0) return 0;
  if (f > max) return max;
  return f;
}

int _clampByte(int v) {
  if (v < 0) return 0;
  if (v > 255) return 255;
  return v;
}
