// 封面切歌「模糊 + 纵轴翻转」过渡的纯逻辑：角度 / 模糊随时钟 t 的映射 + 3D 矩阵。
//
// 与 lyric_layout.dart 的副行翻转同构：数学部分不依赖 Flutter widget，
// 用普通单元测试钉住；widget（widgets/cover_flip_crossfade.dart）只做装配。
//
// 时钟约定：t ∈ [0, 1] 覆盖整个过渡（默认 500ms，见 [kCoverFlipDuration]）。
//   t ∈ [0, kCoverFlipSwap]  旧封面出场：模糊 0→峰值、绕纵轴 0→+90°（easeIn）
//   t ∈ [kCoverFlipSwap, 1]  新封面入场：绕纵轴 −90°→0（easeOutBack，末段过冲
//                             回弹）、模糊 峰值→0（单调 easeOut，不过冲）
// 两半场都在 |90°| 交接：平面绕纵轴转到 90° 时投影宽度严格归零，
// 交换封面不跳变，因此全程不需要不透明度交叉淡（见计划 §2.2）。
// 两半场的**符号相反**（+90 与 −90）是刻意的：整段过渡必须是同一个旋转方向
// 扫过 180°（0→+90 接 −90→0）；若两半场同号（+90 回到 0），角度在交接点反向，
// 观感变成「翻到一半又翻回来」，且新层透视与旧层同侧（详见 coverFlipNewAngle）。

import 'dart:math' as math;

import 'package:flutter/animation.dart' show Curves;
import 'package:flutter/widgets.dart' show Matrix4;

/// 半程角：90°（侧立）。
const double kCoverFlipHalfTurn = math.pi / 2;

/// 新旧封面交换时刻（占总时程的比例）。
const double kCoverFlipSwap = 0.5;

/// 翻转总时长。
///
/// 参考视频两次可测切换分别约 200ms 与 320ms；真机反馈 300ms 偏快，且新层
/// 旋转带 easeOutBack 回冲需要末段时间落定，放宽到 500ms。
const Duration kCoverFlipDuration = Duration(milliseconds: 500);

/// 透视强度（`Matrix4.setEntry(3, 2, ·)`）。
///
/// 以像素为单位的深度倒数权重：封面边长约 300~380px，翻转中离轴端
/// z ≈ 边长，0.001 → 近/远端 w ≈ 1∓0.18（约 ±18% 缩放），有立体感但不夸张。
/// 与 coverflow_page.dart 的 0.0016 同族、比副行翻转的 0.006 弱
/// （副行文字高仅 18~30px）。置 0 退化为正交压扁。
const double kCoverFlipPerspective = 0.001;

/// 模糊峰值 sigma（px）。
///
/// 参考视频中通知栏封面约 96px、视感模糊半径约 8~10px（比例 ≈0.09）；
/// 播放页封面最大约 380px，按同比例约 34。早期受「逐帧全尺寸高斯」的
/// 成本约束取保守值 24（真机反馈模糊偏弱）；改低分辨率快照后卷积成本
/// 与峰值近乎无关（≤96px 小图一次），回到设计比例值 34，拉焦幅度对齐
/// 参考视频。只影响过渡中的约 250ms 窗口。
const double kCoverFlipBlurSigma = 34.0;

/// 低于此 sigma 不过滤镜：省一层合成，且肉眼无差异。
const double kCoverFlipBlurEpsilon = 0.01;

/// 快照叠层的 alpha 映射（模糊观感曲线）。
///
/// 「清晰内容 + 峰值模糊快照 × α」是交叉淡而非真高斯：线性 α=σ/σmax 会把
/// 清晰残影拖过大半程（真机反馈「模糊度太小、变化不够剧烈」——高 α 才
/// 压住清晰层，低 α 段画面里封面仍是清晰的）。取 α=√(σ/σmax)：中段更快
/// 吞掉清晰成分，观感接近逐帧加深的高斯斜坡，端点仍 0→1 单调不过冲。
double coverFlipBlurAlpha(double sigma) {
  if (sigma <= kCoverFlipBlurEpsilon) return 0.0;
  final t = (sigma / kCoverFlipBlurSigma).clamp(0.0, 1.0);
  return math.sqrt(t);
}

/// 兜底滤镜路径的模糊等级阶梯（sigma，px）。
///
/// 过渡中 sigma 本是逐帧连续值（约 30 个唯一值），每个新值都让 ImageFiltered
/// 的模糊层整体作废重算——这是翻转窗口里的突发开销。低分辨率模糊快照（见
/// widgets/low_res_blur.dart）把逐帧卷积换成「单次小图卷积 + alpha 混合」，
/// 但快照就绪前/构建失败（内嵌封面等探测不了的源）仍要退回全分辨率滤镜：
/// 此时把 sigma 量化进本阶梯，唯一滤镜值从 ~30 个降到 ≤5 个（含 0=不挂滤镜），
/// 连续多帧复用同一 ImageFilter 值与同一份模糊层栅格。档距对齐 σmax=34 的
/// 四等分；顶档等于峰值（超上限钳到峰值）。
const List<double> kCoverFlipBlurLadder = [8.0, 17.0, 26.0, 34.0];

/// 把连续 sigma 量化进 [kCoverFlipBlurLadder]（取不小于它的最近档，单调不减；
/// 超上限钳到 [kCoverFlipBlurSigma]；低于 [kCoverFlipBlurEpsilon] 归零）。
double coverFlipQuantizeSigma(double sigma) {
  if (sigma <= kCoverFlipBlurEpsilon) return 0.0;
  for (final step in kCoverFlipBlurLadder) {
    if (sigma <= step) return step;
  }
  return kCoverFlipBlurSigma;
}

/// 旧封面出场进度 p ∈ [0, 1]（t ∈ [0, kCoverFlipSwap]，easeIn）。
double coverFlipOldProgress(double t) =>
    Curves.easeIn.transform((t / kCoverFlipSwap).clamp(0.0, 1.0));

/// 新封面「去模糊」进度 p ∈ [0, 1]（t ∈ [kCoverFlipSwap, 1]，单调 easeOut）。
///
/// 与旋转进度分开：模糊不能过冲（sigma 为负没有意义），旋转要。
double coverFlipNewBlurProgress(double t) => Curves.easeOut.transform(
  ((t - kCoverFlipSwap) / (1.0 - kCoverFlipSwap)).clamp(0.0, 1.0),
);

/// 新封面「旋转」进度 p ∈ [0, 1+]（t ∈ [kCoverFlipSwap, 1]，easeOutBack）。
///
/// 末段冲过就位角再回弹——「翻转过头的超出感」；因此返回值可以 >1
/// （约 1.1），角度随之短暂越过 0（见 [coverFlipNewAngle]）。
double coverFlipNewRotationProgress(double t) => Curves.easeOutBack.transform(
  ((t - kCoverFlipSwap) / (1.0 - kCoverFlipSwap)).clamp(0.0, 1.0),
);

/// 旧封面转角（弧度）：0 → +90°。
///
/// 符号约定：**+θ 时右边缘朝观察者**（右侧大、左侧小；`rotateY` 正方向）。
/// 真机实测确认：旧实现新层也走正角度时，观感就是「左侧小右侧大」。
/// 调用方按切歌方向整体取反（上一曲/下一曲镜像），只改这一处符号不够——
/// 新旧两层要用同一个方向系数，见 CoverFlipCrossfade.direction。
double coverFlipOldAngle(double t) =>
    kCoverFlipHalfTurn * coverFlipOldProgress(t);

/// 新封面转角（弧度）：**−90° → 0**，末段过冲回弹（可短暂为正）。
///
/// 为什么是负半程而不是 `+90°→0`：整段过渡必须是**同一个旋转方向**扫过
/// 180°——旧层 0→+90° 是「右边缘朝观察者、卡片收拢」，新层必须从 −90° 继续
/// 转到 0，两半场的角速度同向。若新层走 +90°→0，角度在交接点反向，观感是
/// 「翻到一半又翻回来」（真机反馈：像根本没翻过），并且新层透视与旧层同侧
/// （本该是左侧大、右侧小，实测成了左侧小、右侧大）。
/// 负半程入场 = 翻过 90° 后看到卡片背面，透视天然镜像。
double coverFlipNewAngle(double t) =>
    -kCoverFlipHalfTurn * (1.0 - coverFlipNewRotationProgress(t));

/// 旧封面模糊 sigma：前半程 0 → 峰值，交接后归零（窗口外不过滤镜）。
///
/// 窗口化不是为了数学好看：widget 的滤镜挂载判据是 sigma > epsilon，
/// 窗口外返回 0 才能保证「第一半场不给侧立不可见的新层挂全尺寸高斯」。
double coverFlipOldBlur(double t) => t < kCoverFlipSwap
    ? kCoverFlipBlurSigma * coverFlipOldProgress(t)
    : 0.0;

/// 新封面模糊 sigma：后半程 峰值 → 0（单调，不过冲），交接前为 0（理由同上）。
double coverFlipNewBlur(double t) => t >= kCoverFlipSwap
    ? kCoverFlipBlurSigma * (1.0 - coverFlipNewBlurProgress(t))
    : 0.0;

/// 翻转矩阵：绕锚点（由调用方 `Transform.alignment` 给出）的 3D 旋转 + 透视。
///
/// 锚点必须同时给出 x 与 y（`Alignment.center`）：透视除法绕锚点进行，
/// 只给 alignment 不给平移时投影中心在画布左上角，翻转中封面会整体漂移
/// （同 lyric_layout.dart sublineFlipAnchor 的坑）。
Matrix4 coverFlipMatrix({
  required double angle,
  double perspective = kCoverFlipPerspective,
}) {
  return Matrix4.identity()
    ..setEntry(3, 2, perspective)
    ..rotateY(angle);
}
