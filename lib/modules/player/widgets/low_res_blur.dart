import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../../../widgets/player_artwork_image.dart'
    show resolvePlayerArtworkImage;

/// 翻转/背景模糊的「低分辨率快照」实现（开销更小的等效算法）。
///
/// 全分辨率高斯是过渡窗口里主要的一笔 GPU 开销：380dp 封面在 dpr 3 上是
/// 1140×1140 像素、σ=24 的核半径约 3σ≈70px。而强模糊本身不保留高频细节，
/// 标准做法（downsample → 小图小 σ → 双线性放大）在视觉上等价，像素量降约
/// 两个数量级、卷积核同步缩小。
///
/// 与逐帧滤镜的分工见 [CoverFlipCrossfade]：快照只算一次，动画期间用 alpha
/// 混合近似「逐渐变糊 / 逐渐变清」；快照不可用时才退回全分辨率 ImageFiltered。

/// 模糊快照的长边像素上限。放大后铺满目标盒时走双线性（见
/// [LowResBlurPainter]），强模糊下看不出色阶。
const double kLowResBlurMaxSide = 96.0;

/// 采用低分辨率路径的模糊强度下限（逻辑像素 sigma）。
///
/// 弱模糊（σ<30）仍保留中频结构（封面轮廓、色块边界），96px 快照放大到
/// 全屏会把双线性插值的网格/色带直接暴露出来（穿帮），肉眼可辨。强模糊
/// 下画面只剩低频色调，放大无色阶问题。低于本阈值一律走调用方的
/// 「原图 + [ImageFiltered]」全屏滤镜路径。播放页背景模糊的用户默认值
/// 恰为 30（ThemeProvider.amPlayerBlur），即默认配置享受低分辨率路径，
/// 调低强度自动回退原渲染。
const double kLowResBlurMinSigma = 30.0;

/// 从已解码的 [src] 生成目标盒（[boxLogical]，逻辑像素）用的低分辨率模糊快照。
///
/// [sigma] 与 `ImageFilter.blur` 同口径（逻辑像素）。返回的 `ui.Image` 归调用方
/// 所有，用完必须 `dispose`；[src] 属于图片缓存，本函数**不** dispose 它。
///
/// 入参非法（源为 null / 尺寸为空 / sigma ≤ 0 / 盒非正）返回 null，
/// 调用方退回滤镜路径。
///
/// 实现分两步同步离屏（都是小图，`toImageSync` 不引入异步帧）：
/// 1. 按目标盒宽高比 cover-crop 缩放进 w×h（与 `BoxFit.cover` 同裁法）；
/// 2. 对这张小图做高斯，σ 按缩放比折算 `sigmaProxy = sigma * scale`
///    （scale = min(1, kLowResBlurMaxSide / 长边)）：模糊随图像几何等比
///    缩放，放大回目标盒后的相对模糊量不变；scale 为 1（盒本来就 ≤96px）
///    时 σ 原样。
///
/// 两步都规避 Impeller decal 暗晕：第 1 步源矩形裁剪铺满画布、第 2 步 blur
/// 显式 `TileMode.clamp`（图层外透明黑卷进卷积核会在四边形成暗晕，同
/// _buildCrossfadeBlurredBackground 的既有坑）。
ui.Image? buildLowResBlurProxy(
  ui.Image? src,
  double sigma,
  Size boxLogical,
) {
  if (src == null) return null;
  if (sigma <= 0.0 || src.width <= 0 || src.height <= 0) return null;
  if (!boxLogical.width.isFinite ||
      !boxLogical.height.isFinite ||
      boxLogical.width <= 0 ||
      boxLogical.height <= 0) {
    return null;
  }
  final longSide = math.max(boxLogical.width, boxLogical.height);
  final scale = math.min(1.0, kLowResBlurMaxSide / longSide);
  final w = math.max(1, (boxLogical.width * scale).round());
  final h = math.max(1, (boxLogical.height * scale).round());

  // cover-crop 源矩形：源比目标更宽 → 裁两侧；更高 → 裁上下。
  final srcAspect = src.width / src.height;
  final dstAspect = w / h;
  final ui.Rect source;
  if (srcAspect > dstAspect) {
    final cw = src.height * dstAspect;
    source = ui.Rect.fromLTWH((src.width - cw) / 2, 0, cw, src.height.toDouble());
  } else {
    final ch = src.width / dstAspect;
    source = ui.Rect.fromLTWH(0, (src.height - ch) / 2, src.width.toDouble(), ch);
  }

  ui.Image? cropped;
  try {
    final rec1 = ui.PictureRecorder();
    ui.Canvas(rec1).drawImageRect(
      src,
      source,
      ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.low,
    );
    final pic1 = rec1.endRecording();
    cropped = pic1.toImageSync(w, h);
    pic1.dispose();

    final sigmaProxy = sigma * scale;
    final rec2 = ui.PictureRecorder();
    ui.Canvas(rec2).drawImage(
      cropped,
      ui.Offset.zero,
      ui.Paint()
        ..filterQuality = ui.FilterQuality.low
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: sigmaProxy,
          sigmaY: sigmaProxy,
          tileMode: ui.TileMode.clamp,
        ),
    );
    final pic2 = rec2.endRecording();
    final blurred = pic2.toImageSync(w, h);
    pic2.dispose();
    return blurred;
  } catch (_) {
    // 离屏失败（极端尺寸 / 引擎异常）：退 null，调用方走滤镜兜底。
    return null;
  } finally {
    cropped?.dispose();
  }
}

/// 把低分辨率模糊快照双线性铺满绘制到目标盒，并按 [alpha] 调制不透明度
/// （drawImageRect 的源像素与 Paint.color 相乘，白色 × alpha 即纯调制，
/// 省去 Opacity 合成层）。
///
/// 必须显式 `FilterQuality.low`：`Paint()` 默认最近邻，会把 20~30 倍的放大
/// 变成色块（渲染性能规范 §10.4 第 15 条）。
class LowResBlurPainter extends CustomPainter {
  LowResBlurPainter(this.image, this.alpha);

  final ui.Image image;
  final double alpha;

  @override
  void paint(ui.Canvas canvas, Size size) {
    final a = (alpha.clamp(0.0, 1.0) * 255).round();
    canvas.drawImageRect(
      image,
      ui.Rect.fromLTWH(
        0,
        0,
        image.width.toDouble(),
        image.height.toDouble(),
      ),
      ui.Offset.zero & size,
      ui.Paint()
        ..isAntiAlias = true
        ..filterQuality = ui.FilterQuality.low
        ..color = ui.Color.fromARGB(a, 255, 255, 255),
    );
  }

  @override
  bool shouldRepaint(covariant LowResBlurPainter oldDelegate) =>
      oldDelegate.image != image || oldDelegate.alpha != alpha;
}

/// 用低分辨率模糊快照渲染的封面（替代「全分辨率原图 + 逐变更 [ImageFiltered]」）。
///
/// 播放页背景（_buildCrossfadeBlurredBackground）每切歌都要对**全屏**尺寸做
/// 一次用户 σ（默认 30）的高斯：那是切歌瞬间与封面翻转并发的最大一笔模糊突发。
/// 本 widget 把同一模糊改在小图（≤[kLowResBlurMaxSide]px）上卷积一次，铺满显示
/// （双线性放大）——强模糊背景视觉上等价，像素量降约两个数量级。
///
/// - **切歌（URI 变化）**：旧快照继续顶显示直到新快照就绪（淡入窗口内背景
///   同为旧图模糊，无闪白、无全屏卷积）；新目标**解析不了或已失败且不在
///   构建中**时立即撤掉旧快照改走 [fallback]——绝不把上一张封面永久铺在
///   当前层上（本地内嵌封面 local:// 探测不了，正是这条的兜底对象）。
/// - sigma 变化（用户调强度）重建快照：卷积只在 ≤96px 小图上，亚毫秒级，
///   取代原来「每次变更全屏重卷积」；重建窗口继续显示旧强度快照，无闪白。
/// - 盒子宽高比变化超过 2%（旋转/分栏）同样重建：快照的 cover-crop 是按
///   当时比例裁的。
/// - **强度闸门**：[blurSigma] 低于 [kLowResBlurMinSigma]（30）一律走
///   [fallback]——弱模糊保留中频结构，96px 快照放大后插值网格会穿帮。
///   本 widget 内部兜底该闸门，调用方也应据此跳过包装（见
///   _buildCrossfadeBlurredBackground）。
class LowResBlurCover extends StatefulWidget {
  const LowResBlurCover({
    super.key,
    required this.artworkUri,
    required this.blurSigma,
    required this.fallback,
  });

  final String? artworkUri;

  /// 目标模糊强度（逻辑像素 sigma，调用方已做 tvBlurSigma 钳制，>0）。
  final double blurSigma;

  /// 无可用快照时的回退渲染（原图 + 滤镜路径）。
  final Widget fallback;

  @override
  State<LowResBlurCover> createState() => _LowResBlurCoverState();
}

class _LowResBlurCoverState extends State<LowResBlurCover> {
  ui.Image? _proxy;

  /// 快照归属的封面 URI、卷积 σ 与构建时的盒子宽高比（显示与重建判定用）。
  String? _proxyUri;
  double _proxySigma = 0;
  double _proxyAspect = 0;

  /// 正在构建的目标 URI（null = 无在飞构建）。
  String? _buildingUri;

  /// 已解析失败的封面 URI：该封面永久走 fallback，不再反复排期。
  String? _failedUri;

  double _width = 0;
  double _height = 0;
  double _dpr = 1;

  @override
  void dispose() {
    _proxy?.dispose();
    _proxy = null;
    super.dispose();
  }

  /// 快照是否达标可显示：强度必须 ≥ 闸门——用户将模糊调低到闸门以下时，
  /// 旧的高 σ 快照必须撤掉走全分辨率滤镜，否则「调低模糊、背景却仍是
  /// 强糊」，且 _scheduleBuild 不再排期重建，会永久停留。
  ///
  /// 位图本身**不随闸门关闭而释放**（≤96px，约 37KB）：用户把强度调回
  /// ≥30 且 σ 与快照一致时可直接复用，免一次重建；最终随 dispose 回收。
  bool get _proxyAllowed =>
      _proxy != null && widget.blurSigma >= kLowResBlurMinSigma;

  /// 当前快照与目标是否完全匹配（同封面、σ 相同、盒子比例变化 ≤2%）。
  bool get _proxyMatchesTarget {
    if (!_proxyAllowed || _proxyUri != widget.artworkUri) return false;
    if (_proxySigma != widget.blurSigma) return false;
    final aspect = _height > 0 ? _width / _height : 0;
    return (aspect - _proxyAspect).abs() <= aspect * 0.02;
  }

  void _scheduleBuild() {
    final uri = widget.artworkUri;
    if (uri == null || uri.isEmpty) return;
    final sigma = widget.blurSigma;
    if (!sigma.isFinite || sigma < kLowResBlurMinSigma) return;
    if (_width <= 0 || _height <= 0) return;
    // 同 URI 已失败：永久 fallback（内嵌封面等探测不了的源，一次尝试即定论）。
    if (_failedUri == uri) return;
    if (_proxyMatchesTarget) return;
    if (_buildingUri == uri) return;
    _buildingUri = uri;
    final box = Size(_width, _height);
    final dpr = _dpr;
    // post-frame：解析与小卷积挪出当前 build 帧，不与同帧的页面工作叠峰。
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final src = await resolvePlayerArtworkImage(
        artworkUri: uri,
        settledLogicalWidth: box.width,
        devicePixelRatio: dpr,
      );
      // src 是缓存借用（与 prewarmPlayerArtworkTexture 同口径），**不 dispose**。
      if (!mounted || _buildingUri != uri) return;
      _buildingUri = null;
      final proxy = buildLowResBlurProxy(src, sigma, box);
      if (!mounted) {
        proxy?.dispose();
        return;
      }
      setState(() {
        if (proxy == null) {
          // 源解析不了/离屏失败：撤掉旧封面快照走 fallback——绝不把上一张
          // 封面永久铺在当前层上（本地内嵌封面正是这种情况）。
          _failedUri = uri;
          _releaseProxy();
        } else if (widget.artworkUri == uri) {
          _releaseProxy();
          _proxy = proxy;
          _proxyUri = uri;
          _proxySigma = sigma;
          _proxyAspect = box.height > 0 ? box.width / box.height : 0;
        } else {
          // 等待途中又切歌：本次结果作废，由新目标的在飞构建接管。
          proxy.dispose();
        }
      });
    });
  }

  void _releaseProxy() {
    _proxy?.dispose();
    _proxy = null;
    _proxyUri = null;
    _proxySigma = 0;
    _proxyAspect = 0;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth.isFinite && constraints.maxWidth > 0) {
          _width = constraints.maxWidth;
        }
        if (constraints.maxHeight.isFinite && constraints.maxHeight > 0) {
          _height = constraints.maxHeight;
        }
        _dpr = MediaQuery.devicePixelRatioOf(context);
        _scheduleBuild();
        final uri = widget.artworkUri;
        if (_proxyAllowed && _proxyUri == uri) {
          // 同封面的快照（σ/比例重建窗口）继续顶显示，新快照就绪即替换。
          return CustomPaint(painter: LowResBlurPainter(_proxy!, 1.0));
        }
        if (_proxyAllowed && uri != null && _buildingUri == uri) {
          // 切歌在飞窗口（约 1~2 帧，淡入低 α 段）：旧封面模糊顶显示，无闪白。
          return CustomPaint(painter: LowResBlurPainter(_proxy!, 1.0));
        }
        // 无快照 / 切歌但新目标不可解析：原图 + 滤镜路径，与未优化行为一致。
        return widget.fallback;
      },
    );
  }
}
