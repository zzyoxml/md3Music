/// 3D 封面背景修补工具集（纯 Dart 移植）。
///
/// 逐函数对应关系（本文件）：
///   - [jointBilateralSmooth]  <- InpaintTools.jointBilateralSmooth（InpaintTools.kt:18-50）
///   - [smoothstep]            <- InpaintTools.smoothstep（InpaintTools.kt:53-56）
///   - [foregroundMask]        <- InpaintTools.fgMask（InpaintTools.kt:62-63）
///   - [dilateHole]            <- InpaintTools.dilateHole（InpaintTools.kt:70-95）
///   - [pullPushFill]          <- PullPushFiller.fill（PullPushFiller.kt:26-137）
///   - [_toLevel]              <- PullPushFiller.toLevel（PullPushFiller.kt:139-152）
///   - [_mirror]               <- PullPushFiller.mirror（PullPushFiller.kt:155-160）
///   - [sampleMaskBilinear]    <- DepthCoverPlugin.sampleMaskBilinear（DepthCoverPlugin.kt:512-522）
///   - [upsampleMaskToFull]    <- DepthCoverPlugin.inpaintBackground 内的 maskFull 放大循环（DepthCoverPlugin.kt:408-416）
///
/// ── 位布局约定（务必先读）───────────────────────────────────────────────
/// ARGB32 = `a<<24 | r<<16 | g<<8 | b`。Kotlin 侧是 `IntArray`，即**有符号** 32 位
/// （alpha>=128 时整个 Int 为负数）；Dart VM 的 `int` 是 64 位有符号整数。
/// 因此本移植遵守两条规则，保证跨平台可移植且与 Kotlin 逐位等价：
///   1. 读入时先 `pixels[i] & 0xFFFFFFFF` 归一成 32 位无符号形态（负数输入也安全：
///      算术右移 24 位后再 `& 0xFF` 取到的仍是正确的 alpha 字节）；
///   2. 写出时统一 `... & 0xFFFFFFFF`，即**输出一律是 0 .. 2^32-1 的无符号 32 位**。
///      需要再喂给有符号 32 位消费者（JNI/Flet ffi 指针）时由调用方做一次 toSigned(32)。
/// 取通道一律用「右移 + `& 0xFF`」，等价于 Kotlin 的 `shr ... and 0xFF` / `ushr 24`。
/// [pullPushFill] 的输出 alpha 与**源像素** alpha 一致（对应 Kotlin 的 `ushr 24`），
/// 修补过程不改变 alpha，只替换 rgb。
///
/// ── 精度偏差（无法逐位等价之处）────────────────────────────────────────
/// 1) Kotlin 全程用 `Float`（IEEE 单精度）+ `kotlin.math.exp`；Dart 的 `double` 是 IEEE
///    **双精度**，`dart:math.exp` 亦为双精度实现。本文件所有分支/比较/公式**逐分支照抄**，
///    但中间量（`1/(2*sigma*sigma)`、金字塔加权和、双线性权重乘积）的舍入与 Kotlin 不同，
///    结果的相对误差在 1e-7 量级。因此：
///      - `>= 0.5`、`> 1e-6`、`< lo - FEATHER` 这类**阈值分支在极罕见贴边值上可能翻转**；
///      - 不做「float32 强制回填」模拟，因为这会让 Dart 侧损失精度且偏离本语言习惯；
///      - 唯一显式落回单精度的地方是 ONNX 输入张量（`Float32List`，见 depth_pipeline.dart），
///        那一层写回 f32 后与 Kotlin 的 `FloatArray` 存储**逐位一致**。
/// 2) 网格边长：Kotlin 硬编码 `D = DEPTH_SIZE`；本移植按扁平长度开方推导（[gridSide]）。
///    对 378×378 推导值 == 378，**逐像素等价**，只是不再强制要求长度恰好为 378²。
/// 3) 非有限输入：Kotlin `Float.toInt()` 对 NaN/±Inf **饱和**，Dart `double.toInt()`
///    **抛异常**（实测确认）。有限输入下逐元素等价；详见 [pullPushFill] 裁回处的行内注释。
///
/// ── 改数纪律 ────────────────────────────────────────────────────────────
/// **本文件所有常量/阈值/带区间一律照抄 Kotlin 原值，未做任何「改进」。
/// 改任何一个数都必须重跑 `scripts/tools/depth/` 下的离线脚本实测（并对齐
/// Kotlin 注释里点名的 `tmp/stage1_input_size.py` 一类实验），禁止凭推断改数。**
///
/// 纯 Dart、平台无关：只依赖 `dart:typed_data` / `dart:math`，
/// 可直接在 `flutter test` 里跑，也可被 `Isolate.run` 使用（无线程/无 UI 依赖）。
library;

import 'dart:math' as math;
import 'dart:typed_data';

// MARK: 工具集常量（照抄 Kotlin）

/// joint bilateral 窗口半径（=2 → 5×5 窗）。来源 InpaintTools.kt:19 默认值。
const int bilateralRadius = 2;

/// 空间核 sigma（按像素距离）。来源 InpaintTools.kt:23 默认值 1.4f。
const double bilateralSigmaS = 1.4;

/// 色彩/引导核 sigma（按归一化亮度差 0..1）。来源 InpaintTools.kt:24 默认值 0.12f。
const double bilateralSigmaC = 0.12;

/// 前景掩码渐入阈值。来源 InpaintTools.kt:62 默认值 0.55f
/// ——与 DepthCoverPlugin 的前景带 0.65..1.00 对齐并留出羽化带。
const double fgMaskLo = 0.55;

/// 前景掩码全前景阈值。来源 InpaintTools.kt:62 默认值 0.65f。
const double fgMaskHi = 0.65;

/// 背景修补掩码膨胀半径的**生产值**（单位 = 深度网格像素）。
///
/// 来源 DepthCoverPlugin.kt:59 `MASK_DILATE_RADIUS = 4`：
/// **2026-09-26 由 2 → 4**（用户反馈前景边缘仍有残留未分离干净）。
/// 洞向外扩这么多像素，把主体过渡带（发丝 / 抗锯齿混合色）吞进洞里，
/// 让后续填充（push-pull / MI-GAN）的源只来自纯净背景；半径越大轮廓残留越少，
/// 代价是主体轮廓被多啃掉一圈。放回封面分辨率后约等于 `radius × 封面宽 / 378`
/// 像素（400 封面 ≈ ×1.06）。
///
/// ⚠ [dilateHole] 的**形参默认值照抄 Kotlin 的 2**（InpaintTools.kt:70），
/// 而生产路径恒传本常量 4（Kotlin 由 `inpaintBackground` 显式传入）。
/// 直接调用 `dilateHole(mask)` 会拿到旧的 radius=2 行为 ——
/// 请一律经 `inpaintBackground`，或显式传 `radius: holeDilateRadius`。改数必须重跑离线实测。
const int holeDilateRadius = 4;

/// [dilateHole] 的形参默认值 —— 逐字照抄 InpaintTools.kt:70 的 `radius: Int = 2`。
/// **这不是生产值**（生产值见 [holeDilateRadius] = 4），保持原值仅为不擅自改数。
const int dilateHoleDefaultRadius = 2;

/// push-pull 的镜像 pad 像素数。来源 PullPushFiller.kt:28 `val pad = 8`。
/// 作用：让金字塔 push 在图像边缘也能取到真实背景，而不是拉伸的边缘条带。
const int pullPushPad = 8;

/// pull 降采样时「视为全洞」的权重阈值。来源 PullPushFiller.kt:68 `ws > 1e-6f`。
const double _pullWeightEps = 1e-6;

/// 洞概率阈值：掩码 >=0.5 视为完全洞（权重 0）。来源 PullPushFiller.kt:145。
const double _holeKeepCenter = 0.5;

/// push 阶段「非洞像素保持原样」的权重判据。来源 PullPushFiller.kt:88。
const double _pushKeepEps = 1e-6;

// MARK: 掩码双线性采样几何

/// 网格边长（由扁平长度开方得到）。378×378 = 142884 → 378。
///
/// Kotlin 侧这些函数硬编码 `D = DepthCoverPlugin.DEPTH_SIZE`（InpaintTools.kt:11），
/// 本移植改为按输入长度推导：对 378×378 网格推导值 == 378，**逐像素等价**；
/// 好处是不要求调用方先构造 378 长度的数组。长度非完全平方数时抛错（assert）。
int gridSide(int flatLength) {
  final side = math.sqrt(flatLength.toDouble()).round();
  assert(
    side * side == flatLength,
    '深度/掩码网格长度必须是完全平方数，收到 $flatLength',
  );
  return side;
}

/// 深度/掩码网格的双线性采样（**半像素中心对齐**）。
///
/// 对应 Kotlin `DepthCoverPlugin.sampleMaskBilinear`（DepthCoverPlugin.kt:512-522），
/// 逐分支照抄：
///   - `x0 = fx.toInt()` 是**向零截断**（Kotlin Float.toInt() 同为向零截断），
///     截断后才 coerce 到 [0, side-1]；
///   - `tx = (fx - x0)` 用的是**已经 coerce 过的 x0**，再 coerce 到 [0,1]；
///     这两个顺序不能改，否则贴边（fx<0 或 fx>side-1）的取样值会不同。
/// `fx` / `fy` 由调用方按 `(坐标 + 0.5) * 源边长 / 目标边长 - 0.5` 生成
/// （掩码从 378 网格放大到封面分辨率的几何）。
double sampleMaskBilinear(
  List<double> mask,
  int side,
  double fx,
  double fy,
) {
  var x0 = fx.toInt();
  if (x0 < 0) {
    x0 = 0;
  } else if (x0 > side - 1) {
    x0 = side - 1;
  }
  var y0 = fy.toInt();
  if (y0 < 0) {
    y0 = 0;
  } else if (y0 > side - 1) {
    y0 = side - 1;
  }
  final x1 = (x0 + 1) <= side - 1 ? x0 + 1 : side - 1;
  final y1 = (y0 + 1) <= side - 1 ? y0 + 1 : side - 1;
  var tx = fx - x0;
  if (tx < 0) {
    tx = 0;
  } else if (tx > 1) {
    tx = 1;
  }
  var ty = fy - y0;
  if (ty < 0) {
    ty = 0;
  } else if (ty > 1) {
    ty = 1;
  }
  final row0 = y0 * side;
  final row1 = y1 * side;
  final itx = 1 - tx;
  final ity = 1 - ty;
  // 乘序与 Kotlin 一致：a = 左上*(1-tx) + 右上*tx；b = 左下*(1-tx) + 右下*tx；
  // 返回 a*(1-ty) + b*ty。
  final a = mask[row0 + x0] * itx + mask[row0 + x1] * tx;
  final b = mask[row1 + x0] * itx + mask[row1 + x1] * tx;
  return a * ity + b * ty;
}

/// 把深度网格（378×378）的掩码双线性放大到封面分辨率 `w×h`。
///
/// 对应 DepthCoverPlugin.kt:408-416 的 `maskFull` 填充循环：
/// `fy = (y + 0.5) * DEPTH_SIZE / h - 0.5`、`fx = (x + 0.5) * DEPTH_SIZE / w - 0.5`。
/// **MI-GAN 的二值掩码与 push-pull 的软掩码必须共用这一套几何**
/// （Kotlin 两处都是同一 `sampleMaskBilinear` + 同一半像素公式），
/// 否则两条修补通路的洞边界会错开一圈，回退采样出现边缘漏缝。
/// 用双线性替代最近邻的目的：消除掩码锯齿边（Kotlin 注释明示）。
Float64List upsampleMaskToFull(List<double> maskGrid, int w, int h) {
  final side = gridSide(maskGrid.length);
  final out = Float64List(w * h);
  final scaleToGrid = side.toDouble();
  for (var y = 0; y < h; y++) {
    final fy = (y + 0.5) * scaleToGrid / h - 0.5;
    final rowBase = y * w;
    for (var x = 0; x < w; x++) {
      final fx = (x + 0.5) * scaleToGrid / w - 0.5;
      out[rowBase + x] = sampleMaskBilinear(maskGrid, side, fx, fy);
    }
  }
  return out;
}

// MARK: 联合双边滤波

/// 联合双边滤波平滑深度图。对应 `InpaintTools.jointBilateralSmooth`
/// （InpaintTools.kt:18-50），`radius=2`（5×5 窗）/ `sigmaS=1.4` / `sigmaC=0.12`。
///
/// - [norm]：归一化深度（0..1，值越大越近），行主序 `side*side`；
/// - [guide]：同网格的原图灰度引导（0..1，Rec.601 亮度），主体边缘处抑制深度跨边模糊；
/// - 输出**新数组**，不修改输入（与 Kotlin 一致）。
///
/// 与 Kotlin 的等价性说明：`ds`（空间项）只依赖 `(dx,dy)`，本实现预先算成 5×5 表；
/// 表元素与 Kotlin 内联表达式 `((dx*dx+dy*dy)) * inv2s2` 的操作数、运算顺序完全相同，
/// 因此查表值与内联值逐位一致，只是省掉每像素 25 次整数乘法。
/// `exp(-(ds + dc))` 保持**一次** exp 调用、且 `ds`/`dc` 相加顺序照抄，
/// 不拆成 `exp(-ds)*exp(-dc)`（数学等但浮点不等价）。
Float64List jointBilateralSmooth({
  required List<double> norm,
  required List<double> guide,
  int radius = bilateralRadius,
  double sigmaS = bilateralSigmaS,
  double sigmaC = bilateralSigmaC,
}) {
  final d = gridSide(norm.length);
  final out = Float64List(norm.length);
  final inv2s2 = 1.0 / (2.0 * sigmaS * sigmaS);
  final inv2c2 = 1.0 / (2.0 * sigmaC * sigmaC);
  final win = 2 * radius + 1;
  // 空间项表（按 dy-major 排布），对应 Kotlin 的 (dx,dy) 双重 for（-radius..radius）。
  // 注意 Kotlin 外层是 dy、内层是 dx，这里保持同序，累加顺序一致。
  final dsTab = Float64List(win * win);
  for (var oy = 0; oy < win; oy++) {
    final dy = oy - radius;
    for (var ox = 0; ox < win; ox++) {
      final dx = ox - radius;
      dsTab[oy * win + ox] = (dx * dx + dy * dy) * inv2s2;
    }
  }
  final last = d - 1;
  for (var y = 0; y < d; y++) {
    // 每行预折窗口内的 clamp 后行首偏移，等价于 Kotlin 的 (y+dy).coerceIn(0,D-1)*D
    final rowTab = Int32List(win);
    for (var oy = 0; oy < win; oy++) {
      var yy = y + oy - radius;
      if (yy < 0) {
        yy = 0;
      } else if (yy > last) {
        yy = last;
      }
      rowTab[oy] = yy * d;
    }
    final rowBase = y * d;
    for (var x = 0; x < d; x++) {
      final i = rowBase + x;
      final c0 = guide[i];
      var wSum = 0.0;
      var acc = 0.0;
      for (var oy = 0; oy < win; oy++) {
        final rowOff = rowTab[oy];
        final dsRow = oy * win;
        for (var ox = 0; ox < win; ox++) {
          var xx = x + ox - radius;
          if (xx < 0) {
            xx = 0;
          } else if (xx > last) {
            xx = last;
          }
          final j = rowOff + xx;
          final dg = guide[j] - c0;
          final w = math.exp(-(dsTab[dsRow + ox] + dg * dg * inv2c2));
          acc += w * norm[j];
          wSum += w;
        }
      }
      out[i] = acc / wSum;
    }
  }
  return out;
}

// MARK: 前景掩码

/// smoothstep(edge0, edge1, x)。对应 InpaintTools.kt:53-56。
/// `t = ((x - e0) / (e1 - e0)).coerceIn(0,1); return t*t*(3-2t)`。
double smoothstep(double e0, double e1, double x) {
  var t = (x - e0) / (e1 - e0);
  if (t < 0) {
    t = 0;
  } else if (t > 1) {
    t = 1;
  }
  return t * t * (3 - 2 * t);
}

/// 前景掩码：深度 >= [lo] 渐入、>= [hi] 全前景。对应 `InpaintTools.fgMask`
/// （InpaintTools.kt:62-63）。返回 `side*side` 的 0..1 网格，**1=主体/洞，0=背景**。
/// 默认阈值与 DepthCoverPlugin 的前景带（0.65..1.00）对齐并留羽化带。
Float64List foregroundMask(
  List<double> norm, {
  double lo = fgMaskLo,
  double hi = fgMaskHi,
}) {
  final out = Float64List(norm.length);
  for (var i = 0; i < norm.length; i++) {
    out[i] = smoothstep(lo, hi, norm[i]);
  }
  return out;
}

/// 掩码膨胀（**分离式 max filter**：水平一趟 + 垂直一趟，等价方形结构元）。
/// 对应 InpaintTools.kt:70-95。
///
/// 洞向外扩 [radius] 像素，把主体过渡带（发丝 / 抗锯齿混合色）吞进洞里，
/// 使 push-pull 的填充源只来自纯净背景 —— 消除轮廓污染环的关键一步。
/// 边界处理照抄 Kotlin：`(x+dx).coerceIn(0, D-1)`（replicate，非环绕、非补 0）。
Float64List dilateHole(List<double> mask, {int radius = dilateHoleDefaultRadius}) {
  final d = gridSide(mask.length);
  final last = d - 1;
  final tmp = Float64List(mask.length);
  // 水平一趟
  for (var y = 0; y < d; y++) {
    final row = y * d;
    for (var x = 0; x < d; x++) {
      var m = 0.0;
      for (var dx = -radius; dx <= radius; dx++) {
        var xx = x + dx;
        if (xx < 0) {
          xx = 0;
        } else if (xx > last) {
          xx = last;
        }
        final v = mask[row + xx];
        if (v > m) m = v;
      }
      tmp[row + x] = m;
    }
  }
  // 垂直一趟
  final out = Float64List(mask.length);
  for (var y = 0; y < d; y++) {
    for (var x = 0; x < d; x++) {
      var m = 0.0;
      for (var dy = -radius; dy <= radius; dy++) {
        var yy = y + dy;
        if (yy < 0) {
          yy = 0;
        } else if (yy > last) {
          yy = last;
        }
        final v = tmp[yy * d + x];
        if (v > m) m = v;
      }
      out[y * d + x] = m;
    }
  }
  return out;
}

// MARK: Push-Pull 金字塔修补

/// 金字塔单层：rgb 分量 + 权重（洞=0）。对应 PullPushFiller 的私有 `Level`
/// （PullPushFiller.kt:15-20）。
class _PpLevel {
  _PpLevel(this.w, this.h)
      : r = Float64List(w * h),
        g = Float64List(w * h),
        b = Float64List(w * h),
        wt = Float64List(w * h);

  final int w;
  final int h;
  final Float64List r;
  final Float64List g;
  final Float64List b;
  final Float64List wt;
}

/// Push-Pull 金字塔插值修补（Gortler et al. 2006；Facebook 3D Photos 同类思路）。
/// 逐分支对应 `PullPushFiller.fill`（PullPushFiller.kt:26-137）。
///
/// 输入：原图像素（ARGB32，`w*h`，见文件头位布局说明）+ 同分辨率前景掩码
/// （`mask[y*w+x] ∈ 0..1` 为洞的概率，**1=洞**）；
/// 输出：修补后的整幅背景图（洞被周围背景像素按金字塔加权填充，非洞像素原样保留，
/// alpha 与源像素一致）。
///
/// 优点：O(n)、零依赖、大洞也能平滑填充；代价是填充区偏平滑 —— 对音乐封面视差
/// 场景足够（洞只在小幅位移时露出，平滑填充远优于透明洞 / 轮廓拉伸）。
///
/// 四步照抄：① 镜像 pad 8；② pull 逐层 2× 降采样（洞像素权重 0）；
/// ③ push 自顶向下双线性回填洞像素；④ 裁回原尺寸输出。
List<int> pullPushFill({
  required List<int> pixels,
  required int w,
  required int h,
  required List<double> mask,
}) {
  // 1) 镜像 pad 8px：让 push 在边缘也能用真实背景而非拉伸（防边缘条带）
  const pad = pullPushPad;
  final pw = w + 2 * pad;
  final ph = h + 2 * pad;
  final pPix = Uint32List(pw * ph);
  final pMask = Float64List(pw * ph);
  for (var y = 0; y < ph; y++) {
    final sy = _mirror(y - pad, h);
    final srcRow = sy * w;
    final dstRow = y * pw;
    for (var x = 0; x < pw; x++) {
      final sx = _mirror(x - pad, w);
      final si = srcRow + sx;
      final di = dstRow + x;
      pPix[di] = pixels[si] & 0xFFFFFFFF;
      pMask[di] = mask[si];
    }
  }

  // 2) Pull：逐层 2× 降采样，洞像素权重 0
  final levels = <_PpLevel>[_toLevel(pPix, pMask, pw, ph)];
  while (levels.last.w > 1 || levels.last.h > 1) {
    final up = levels.last;
    final upW = up.w;
    final upH = up.h;
    final ur = up.r;
    final ug = up.g;
    final ub = up.b;
    final uw = up.wt;
    final nw = (up.w + 1) ~/ 2;
    final nh = (up.h + 1) ~/ 2;
    final lo = _PpLevel(nw, nh);
    for (var y = 0; y < nh; y++) {
      final rowBase = y * nw;
      for (var x = 0; x < nw; x++) {
        var r = 0.0;
        var g = 0.0;
        var b = 0.0;
        var ws = 0.0;
        for (var dy = 0; dy <= 1; dy++) {
          // coerceAtMost：奇数尺寸时最后一行/列复用上一行/列
          final uy = (y * 2 + dy) <= upH - 1 ? y * 2 + dy : upH - 1;
          final uRow = uy * upW;
          for (var dx = 0; dx <= 1; dx++) {
            final ux = (x * 2 + dx) <= upW - 1 ? x * 2 + dx : upW - 1;
            final ui = uRow + ux;
            final wgt = uw[ui];
            r += ur[ui] * wgt;
            g += ug[ui] * wgt;
            b += ub[ui] * wgt;
            ws += wgt;
          }
        }
        final li = rowBase + x;
        if (ws > _pullWeightEps) {
          lo.r[li] = r / ws;
          lo.g[li] = g / ws;
          lo.b[li] = b / ws;
        }
        // 注意：ws<=eps 时 rgb 保持 0（Float64List 默认值），与 Kotlin FloatArray 一致
        lo.wt[li] = ws / 4.0;
      }
    }
    levels.add(lo);
  }

  // 3) Push：自顶向下回填洞像素（双线性插值上层），非洞像素保持原样
  for (var li = levels.length - 2; li >= 0; li--) {
    final lo = levels[li];
    final up = levels[li + 1];
    final isBase = li == 0;
    final loW = lo.w;
    final loH = lo.h;
    final upW = up.w;
    final upH = up.h;
    final ur = up.r;
    final ug = up.g;
    final ub = up.b;
    final uw = up.wt;
    final lr = lo.r;
    final lg = lo.g;
    final lb = lo.b;
    final lwt = lo.wt;
    final upLastX = upW - 1;
    final upLastY = upH - 1;
    for (var y = 0; y < loH; y++) {
      // 上层坐标（双线性）：pull 用 x_up = (x_down - 0.5)/2 的格边对齐几何
      final fy = (y - 0.5) / 2.0;
      var y0 = fy.toInt();
      if (y0 < 0) {
        y0 = 0;
      } else if (y0 > upLastY) {
        y0 = upLastY;
      }
      final y1 = (y0 + 1) <= upLastY ? y0 + 1 : upLastY;
      var ty = fy - y0;
      if (ty < 0) {
        ty = 0;
      } else if (ty > 1) {
        ty = 1;
      }
      final ity = 1 - ty;
      final r0 = y0 * upW;
      final r1 = y1 * upW;
      final rowBase = y * loW;
      for (var x = 0; x < loW; x++) {
        final i = rowBase + x;
        final keep = lwt[i];
        // 非底层：只回填完全洞（羽化像素在下采样层保持原值，避免漂移）
        if (keep >= 1.0 - _pushKeepEps || (!isBase && keep > _pushKeepEps)) {
          continue;
        }
        final fx = (x - 0.5) / 2.0;
        var x0 = fx.toInt();
        if (x0 < 0) {
          x0 = 0;
        } else if (x0 > upLastX) {
          x0 = upLastX;
        }
        final x1 = (x0 + 1) <= upLastX ? x0 + 1 : upLastX;
        var tx = fx - x0;
        if (tx < 0) {
          tx = 0;
        } else if (tx > 1) {
          tx = 1;
        }
        final itx = 1 - tx;
        final i00 = r0 + x0;
        final i01 = r0 + x1;
        final i10 = r1 + x0;
        final i11 = r1 + x1;
        // 与 Kotlin `pick` 逐因子同序：v*(1-tx)*(1-ty) + v*tx*(1-ty) + v*(1-tx)*ty + v*tx*ty
        final pr = ur[i00] * itx * ity +
            ur[i01] * tx * ity +
            ur[i10] * itx * ty +
            ur[i11] * tx * ty;
        final pg = ug[i00] * itx * ity +
            ug[i01] * tx * ity +
            ug[i10] * itx * ty +
            ug[i11] * tx * ty;
        final pb = ub[i00] * itx * ity +
            ub[i01] * tx * ity +
            ub[i10] * itx * ty +
            ub[i11] * tx * ty;
        if (isBase && keep > _pushKeepEps) {
          // 底层羽化像素：原色（主体边缘污染源）与填充色按 keep 混合，
          // 消除轮廓硬边环 —— 这是「主体外轮廓条带」的直接修复点
          lr[i] = lr[i] * keep + pr * (1 - keep);
          lg[i] = lg[i] * keep + pg * (1 - keep);
          lb[i] = lb[i] * keep + pb * (1 - keep);
        } else {
          lr[i] = pr;
          lg[i] = pg;
          lb[i] = pb;
        }
        // 继承上层有效权重（>0 即可继续下传；全洞金字塔顶 wt=0 则保持 0，
        // 最终裁回输出时洞像素为 0,0,0 —— 仅发生在全图皆洞的极端输入）
        lwt[i] = uw[i00];
      }
    }
  }

  // 4) 裁回原尺寸输出
  final base = levels[0];
  final out = Uint32List(w * h);
  for (var y = 0; y < h; y++) {
    final srcRow = y * w;
    final baseRow = (y + pad) * pw;
    for (var x = 0; x < w; x++) {
      final bi = baseRow + (x + pad);
      // alpha 取源像素（Kotlin `ushr 24`）；64 位 int 下 `>>` 后 `& 0xFF` 等价
      final a = (pixels[srcRow + x] >> 24) & 0xFF;
      // ⚠ 已知不可逐位等价点（仅污染输入才触发）：Kotlin 的 `Float.toInt()` 对
      // NaN/±Inf **饱和**（NaN→0、+Inf→Int.MAX、-Inf→Int.MIN，再 coerceIn(0,255)）；
      // Dart 的 `double.toInt()` 对非有限值抛 UnsupportedError（实测确认）。
      // 因此 mask 若含 NaN（上游模型失败）时 Kotlin 出黑像素、Dart 抛异常。
      // 有限输入下两者逐元素等价，故此处不加兜底（改数/加判据都属行为变更，需实测）。
      final r = _clampByte(base.r[bi].toInt());
      final g = _clampByte(base.g[bi].toInt());
      final b = _clampByte(base.b[bi].toInt());
      out[srcRow + x] = ((a << 24) | (r << 16) | (g << 8) | b) & 0xFFFFFFFF;
    }
  }
  return out;
}

/// 打包像素 → 金字塔底层。对应 `PullPushFiller.toLevel`（PullPushFiller.kt:139-152）。
/// 洞概率 >=0.5 → 权重 0；0..0.5 羽化区线性降权（`((0.5-hole)*2).coerceIn(0,1)`）。
_PpLevel _toLevel(Uint32List pPix, Float64List pMask, int w, int h) {
  final lv = _PpLevel(w, h);
  final n = pPix.length;
  for (var i = 0; i < n; i++) {
    final p = pPix[i];
    final hole = pMask[i];
    var keep = (_holeKeepCenter - hole) * 2.0;
    if (keep < 0) {
      keep = 0;
    } else if (keep > 1) {
      keep = 1;
    }
    lv.r[i] = ((p >> 16) & 0xFF).toDouble();
    lv.g[i] = ((p >> 8) & 0xFF).toDouble();
    lv.b[i] = (p & 0xFF).toDouble();
    lv.wt[i] = keep;
  }
  return lv;
}

/// 镜像坐标折返（-1 → 0，w → w-1）。对应 `PullPushFiller.mirror`（kt:155-160）。
int _mirror(int v, int size) {
  var x = v;
  if (x < 0) {
    x = -x - 1;
  }
  if (x >= size) {
    x = 2 * size - x - 1;
  }
  if (x < 0) {
    return 0;
  }
  if (x > size - 1) {
    return size - 1;
  }
  return x;
}

/// `coerceIn(0,255)`：截断取整后的分量夹回字节范围（对应 Kotlin 同名调用）。
int _clampByte(int v) {
  if (v < 0) return 0;
  if (v > 255) return 255;
  return v;
}
