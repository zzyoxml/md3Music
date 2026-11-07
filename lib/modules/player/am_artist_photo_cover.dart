// lib/modules/player/am_artist_photo_cover.dart
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter, TileMode;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/build_flags.dart';
import 'artist_photo_service.dart';
import 'full_player_route.dart' show playerExpansion;

/// AM 播放页歌手写真的拉取与轮播调度（纯数据，无 UI）。
///
/// 取代 09d705d「页面背景铺满」形态：写真现在只渲染在封面位置
/// （竖屏专辑 tab / 横屏与平板左栏）。两级通知语义是本页面的性能契约：
/// - [hasImages] 翻转才 [notifyListeners] → 页面级「写真 ↔ 方形封面」切换重建；
/// - 轮播 tick 只更新 [currentUrl] → 仅封面 widget 自己重绘，不牵连整页。
class ArtistPhotoController extends ChangeNotifier {
  ArtistPhotoController({ArtistPhotoService? service})
      : _service = service ?? ArtistPhotoService.instance;

  final ArtistPhotoService _service;
  final ValueNotifier<String?> _currentUrl = ValueNotifier<String?>(null);

  String _hash = '';
  List<String> _urls = const [];
  int _index = 0;
  Timer? _timer;

  /// hash → 写真 URL 列表的**进程级**缓存（上限 20 条，FIFO 逐出）。
  ///
  /// 存在的首要理由不是省流量：拖拽转场由 PlayerDragOverlay 里的**第二个**
  /// State 实例渲染页面，新实例若无缓存则写真未就绪 → 方形封面闪现
  /// （真机「下拉 fullplayer 专辑封面突然出现」）。同步命中即可消除。
  static final Map<String, List<String>> _urlCache = <String, List<String>>{};

  /// 当前已加载歌曲的 hash（'' = 未加载 / 本地歌 / 开关关）。
  String get hash => _hash;

  /// 是否实际取到写真。页面据此隐藏方形封面，避免「写真没出来、封面也没了」。
  bool get hasImages => _urls.isNotEmpty;

  /// 当前展示的图片 URL（null = 无图）。轮播 tick 只更新本 notifier。
  ValueListenable<String?> get currentUrl => _currentUrl;

  /// 切换数据源。await 完成加载；中间态（清空）在首个 await 前同步完成。
  ///
  /// **调用时机**：页面只允许在 post-frame / 事件回调里调用——清空与落地都会
  /// [notifyListeners]，在 build 期间同步调用会触发 setState-during-build。
  Future<void> setHash(String newHash, {required int intervalSeconds}) async {
    if (newHash == _hash) return;
    _stopTimer();
    _hash = newHash;
    final cached = newHash.isEmpty ? null : _urlCache[newHash];
    if (cached != null) {
      _apply(cached);
      if (cached.length > 1) _startTimer(intervalSeconds);
      return;
    }
    _apply(const <String>[]);
    if (newHash.isEmpty) return;

    final urls = await _service.load(hash: newHash);
    if (_hash != newHash) return; // 期间已再次切歌：丢弃迟到响应
    if (urls.isNotEmpty) {
      // 空结果不缓存：无图歌曲下次仍重试（写真接口偶发空响应）
      _urlCache[newHash] = urls;
      if (_urlCache.length > 20) _urlCache.remove(_urlCache.keys.first);
    }
    _apply(urls);
    if (urls.length > 1) _startTimer(intervalSeconds);
  }

  /// 首帧同步填充缓存（**不 notify、不改 [_hash]**）。
  ///
  /// 拖拽松手后路由才 push，接管的是全新 State；setHash 在 post-frame 才跑，
  /// 首帧若无图会按「加载中兜底」闪一帧方形专辑封面（真机反馈）。缓存命中
  /// 即首帧出写真；随后 post-frame 的 [setHash] 照常执行（起轮播/无缓存兜底）。
  /// 仅在完全空态生效——切歌路径 hasImages 已为 true，维持「先清后载」，
  /// 也避免 build 期间给已挂载的监听者同步推送。
  void seedFromCache(String hash) {
    if (hash.isEmpty || hasImages || _currentUrl.value != null) return;
    final urls = _urlCache[hash];
    if (urls == null || urls.isEmpty) return;
    _urls = urls;
    _index = 0;
    _currentUrl.value = urls.first;
  }

  /// 轮播间隔变更（设置页改动后）：只按新间隔重起定时器。
  ///
  /// 刻意不重跑 [setHash]——那会清空当前图集并重新请求，画面要闪一下空白；
  /// 间隔是纯调度参数，重起 [Timer.periodic] 即可。无图 / 单图时无事可做
  /// （与 [_startTimer] 的启动条件保持一致）。
  void setInterval(int intervalSeconds) {
    if (_urls.length <= 1) return;
    _startTimer(intervalSeconds);
  }

  void _apply(List<String> urls) {
    final hadImages = hasImages;
    _urls = urls;
    _index = 0;
    _currentUrl.value = urls.isEmpty ? null : urls.first;
    if (hadImages != urls.isNotEmpty) notifyListeners();
  }

  void _startTimer(int intervalSeconds) {
    _stopTimer();
    // 秒级轮播：Timer 驱动，不占 Ticker（AGENTS.md 第 10 节渲染性能约定）
    _timer = Timer.periodic(Duration(seconds: intervalSeconds), (_) {
      if (_urls.length <= 1) return;
      _index = (_index + 1) % _urls.length;
      _currentUrl.value = _urls[_index]; // 只动 notifier，不 notifyListeners
    });
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _stopTimer();
    _currentUrl.dispose();
    super.dispose();
  }
}

/// 顶部羽化带高度（dp 上限）：写真上缘在这段距离内从透明渐入。
const double kAmPhotoFeatherTopHeight = 120;

/// 底部羽化带高度（dp 上限）：比顶部长，标题块叠在这段渐变之上（对照参考图）。
const double kAmPhotoFeatherBottomHeight = 200;

/// 羽化带按容器高度的比例上限：小容器（横屏/平板左栏封面只有 ~270dp 高）
/// 若沿用固定 dp，两带会吃掉 90% 画面、整幅发灰（真机反馈）。
/// 实际带高 = min(dp 上限, 容器高 × 比例)。
const double kAmPhotoFeatherTopRatio = 0.25;
const double kAmPhotoFeatherBottomRatio = 0.35;

/// 边缘消融用的统一模糊 sigma 上限（整幅同一糊度，不做分档渐变——
/// 多档遮罩带叠加会在带间产生明暗条带，真机反馈不自然）。
const double kAmPhotoFeatherBlurSigma = 16;

/// 模糊 sigma 的容器高度比例：小封面（横屏/平板左栏 ~250dp）若沿用固定
/// sigma，糊化相对画面过重、整幅发糊。sigma = clamp(h × 0.03, 6, 上限)。
const double kAmPhotoFeatherBlurRatio = 0.03;
const double kAmPhotoFeatherBlurMinSigma = 6;

/// 按容器高度换算实际模糊 sigma。
double amPhotoBlurSigma(double height) => math.min(
  math.max(height * kAmPhotoFeatherBlurRatio, kAmPhotoFeatherBlurMinSigma),
  kAmPhotoFeatherBlurSigma,
);

/// ShaderMask 遮罩的「不透明」标记色。
///
/// **必须是白色**：[BlendMode.modulate] 把子级 premultiplied 颜色与遮罩颜色
/// **逐通道相乘**，遮罩用黑色 (0,0,0,1) 会把 RGB 乘成 0 → 整个中部渲染成纯黑
/// （真机踩坑）。白色 (255,255,255,255) 才是「原样保留」。
const Color _photoMaskOpaque = Color(0xFFFFFFFF);

/// 把两条羽化带高度换算成按容器高度的 stops（0..1），并保证不交叉。
///
/// 带高取「dp 上限」与「容器高 × 比例」的较小值：竖屏大封面按 dp 走
/// （800dp 高时顶带 0.15、底带 0.25），横屏/平板小封面自动收窄。
({double top, double bottom}) _photoFeatherStops(double height) {
  final h = math.max(height, 1.0);
  final topDp = math.min(kAmPhotoFeatherTopHeight, h * kAmPhotoFeatherTopRatio);
  final bottomDp =
      math.min(kAmPhotoFeatherBottomHeight, h * kAmPhotoFeatherBottomRatio);
  return (
    top: math.min(topDp / h, 0.45),
    bottom: math.max(1 - bottomDp / h, 0.55),
  );
}

double _smoothStep(double t) {
  final c = t.clamp(0.0, 1.0);
  return c * c * (3 - 2 * c);
}

Color _photoMaskColor(double alpha) => alpha >= 0.999
    ? _photoMaskOpaque
    : (alpha <= 0.001
          ? Colors.transparent
          : _photoMaskOpaque.withValues(alpha: alpha));

/// 构造「上下缘 alpha 从 0 按 smoothstep 升到 [innerAlpha]、中部保持」的遮罩渐变。
///
/// [zoneScale]：升满位置占羽化带的比例（1.0 = 到带内边界才升满；
/// 0.8 = 带内 80% 处已升满，留给外层罩收尾）。多采样点保证 S 形过渡，
/// 避免线性折点形成可见条带。
LinearGradient amPhotoEdgeFade({
  required double height,
  double innerAlpha = 1.0,
  double zoneScale = 1.0,
  int samples = 8,
}) {
  final (:top, :bottom) = _photoFeatherStops(height);
  final invBottom = 1 - bottom;
  final points = <double, double>{};
  void put(double y, double a) =>
      points[(y * 1e6).roundToDouble() / 1e6] = a;
  for (var i = 0; i <= samples; i++) {
    final f = math.min(i / samples, zoneScale);
    final a = _smoothStep(f / zoneScale) * innerAlpha;
    put(top * f, a);
    put(1 - invBottom * f, a);
  }
  put(top, innerAlpha);
  put(bottom, innerAlpha);
  put(0, 0);
  put(1, 0);
  final ys = points.keys.toList()..sort();
  return LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [for (final y in ys) _photoMaskColor(points[y]!)],
    stops: ys,
  );
}

/// 主淡出遮罩（套在整幅封面之外）：上下缘 alpha 平滑收到 0，
/// 写真（含模糊带与清晰主体）整体消融进页面背景；中部完全不透明。
@visibleForTesting
LinearGradient amPhotoMasterFade(double height) => amPhotoEdgeFade(
  height: height,
);

/// 清晰层遮罩：上下缘透明（露出统一模糊的底）、向中部 smoothstep 升满。
/// 在羽化带 80% 处升满，剩余由主淡出罩收尾——两罩不同时处于半透明，
/// 杜绝叠加条带。
@visibleForTesting
LinearGradient amPhotoSharpMask(double height) => amPhotoEdgeFade(
  height: height,
  zoneScale: 0.8,
);

/// 羽化方向。
enum AmPhotoFeather {
  /// 竖屏专辑 tab：上下缘过渡（现状）。
  vertical,

  /// 横屏/平板出血层：左、右外缘都过渡，避免栏边裁剪形成细线。
  rightEdge,
}

/// 横向上下文的双侧「外缘透明」渐变构造：左右两侧各有一条羽化带，
/// 带宽 = min(底缘 dp, w × 底缘比例)——侧缘与竖屏边缘使用同一比例，
/// 与内容区交界时平滑消融，避免边界采样细线。
///
/// 与 [_photoEdgeFade] 同样从外缘透明过渡到内容区不透明。

LinearGradient _photoEdgeFadeH({
  required double width,
  double innerAlpha = 1.0,
  double zoneScale = 1.0,
  int samples = 8,
}) {
  final w = math.max(width, 1.0);
  final band = math.min(
    kAmPhotoFeatherBottomHeight,
    w * kAmPhotoFeatherBottomRatio,
  );
  final points = <double, double>{};
  // stops 必须是 0..1 归一（LinearGradient 的硬性要求）：按 px 算位置后除以 w。
  void put(double xPx, double a) {
    final t = (xPx / w).clamp(0.0, 1.0);
    points[(t * 1e6).roundToDouble() / 1e6] = a;
  }
  for (var i = 0; i <= samples; i++) {
    final f = math.min(i / samples, zoneScale);
    put(band * f, innerAlpha * _smoothStep(f / zoneScale));
    put(w - band + band * f, innerAlpha * (1 - _smoothStep(f / zoneScale)));
  }
  put(0, 0);
  put(band, innerAlpha);
  put(w - band, innerAlpha);
  put(w, 0);
  final ts = points.keys.toList()..sort();
  return LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [for (final t in ts) _photoMaskColor(points[t]!)],
    stops: ts,
  );
}

/// 横向主淡出罩：左右外缘 smoothstep 收 0，中间内容区保持不透明。
@visibleForTesting
LinearGradient amPhotoRightFade(double width) => _photoEdgeFadeH(
  width: width,
);

/// 横向清晰罩：两侧羽化带内 80% 处已完成过渡（与主罩错开，防止条带）。
@visibleForTesting
LinearGradient amPhotoSharpMaskRight(double width) => _photoEdgeFadeH(
  width: width,
  zoneScale: 0.8,
);

/// AM 写真封面：单张图以 [BoxFit.cover] 填满容器。
///
/// 边缘处理为「**统一模糊 + alpha 过渡**」：
/// 1. 底层：整幅 [ImageFiltered] 恒定 sigma 模糊，`TileMode.clamp`
///    （decal 会把画面外透明黑卷进卷积核形成暗晕——上一版「压暗」的来源）；
/// 2. 上层：清晰原图，[amPhotoSharpMask] 使其在上下缘透明、中部升满；
/// 3. 整体再乘 [amPhotoMasterFade]，最外缘消融进页面背景。
///
/// 羽化方向由 [feather] 决定（[AmPhotoFeather.vertical] 上下缘 /
/// [AmPhotoFeather.rightEdge] 左右缘，横屏出血层用后者），罩与模糊尺寸同源。
///
/// 纯展示组件：拉取与轮播归 [ArtistPhotoController]，本 widget 只订阅
/// [currentUrl]——轮播 tick 仅重建图片子树（外层 RepaintBoundary 隔离重绘）。
/// **必须放在有界容器里**（tab 页 / SizedBox），LayoutBuilder 依赖有界高度换算羽化 stops。
class AmArtistPhotoCover extends StatelessWidget {
  const AmArtistPhotoCover({
    super.key,
    required this.currentUrl,
    this.feather = AmPhotoFeather.vertical,
    this.photoWidthFraction = 1.0,
    this.opacity = 1.0,
  }) : assert(photoWidthFraction > 0 && photoWidthFraction <= 1),
       assert(opacity >= 0 && opacity <= 1);

  /// 当前图片 URL（null = 无图，整层收缩）。
  final ValueListenable<String?> currentUrl;

  /// 羽化方向，见 [AmPhotoFeather]。
  final AmPhotoFeather feather;

  /// 图片内容占绘制区域的宽度比例；遮罩与滤镜始终覆盖整页，避免内部硬裁剪接缝。
  final double photoWidthFraction;

  /// 写真层自身的不透明度：1 = 原样，0 = 完全不可见。
  ///
  /// 对应设置页「写真背景透明度」，由调用方换算（该设置是**遮罩浓度**，
  /// 值越大写真越淡，故这里传 `1 - artistPhotoOpacity`）。
  ///
  /// 作用在**整幅写真**（含模糊底与两层羽化罩）之上，因此羽化带已经透明的
  /// 部分不会被染色 —— 若改成在外部叠一层带色遮罩，会连页面背景一起压暗。
  final double opacity;

  static Widget _photo(String url, String role) => CachedNetworkImage(
    // 同 Stack 两枚图必须不同 key：重复 ValueKey(url) 在转场位移的
    // 重建期会元素复用错乱（真机白线闪烁根因之一）。
    key: ValueKey('$url#$role'),
    imageUrl: url,
    fit: BoxFit.cover,
    width: double.infinity,
    height: double.infinity,
    // 单下划线通配符（Dart 3），避免 unnecessary_underscores lint
    placeholder: (_, _) => const SizedBox.shrink(),
    errorWidget: (_, _, _) => const SizedBox.shrink(),
  );

  @override
  Widget build(BuildContext context) {
    // 写真整体不透明度（设置页「写真背景透明度」由调用方换算后传入）。
    // 包在整幅写真之外，而非在外部叠一层带色遮罩——后者会把页面背景一起压暗。
    if (opacity >= 1.0) return _buildPhoto();
    return Opacity(opacity: opacity, child: _buildPhoto());
  }

  Widget _buildPhoto() {
    return ValueListenableBuilder<String?>(
      valueListenable: currentUrl,
      builder: (context, url, _) {
        if (url == null) return const SizedBox.shrink();
        return RepaintBoundary(
          // 转场位移中（expansion∈(0,1)）跳过模糊底渲染：Impeller 的
          // ImageFiltered 在祖先 Transform 逐帧重栅格化时，与清晰层的采样
          // 错位会在清晰罩升满分界处闪出一条亮线（真机反馈：位移即现、静止
          // 即无）。位移期间页面本就在淡入淡出，去模糊无感知；静止（两端）恢复。
          child: ValueListenableBuilder<double>(
            valueListenable: playerExpansion,
            builder: (context, expansion, _) {
              final blurActive = expansion <= 0.0 || expansion >= 1.0;
              return LayoutBuilder(
                builder: (context, constraints) {
                  final h = constraints.maxHeight;
                  final w = constraints.maxWidth * photoWidthFraction;
                  Rect photoShaderRect(Rect rect) => Rect.fromLTWH(
                    rect.left, rect.top, w, rect.height,
                  );
                  Widget photoLayer(String role) => photoWidthFraction == 1.0
                      ? _photo(url, role)
                      : Align(
                          alignment: Alignment.centerLeft,
                          child: SizedBox(
                            width: w,
                            height: h,
                            child: _photo(url, role),
                          ),
                        );
                  // 按方向选出两枚罩、模糊参考边与 key：竖屏用高度（上下缘），
                  // 横屏出血层用宽度（右缘）。key 两档互不冲突，测试按 key 定位。
                  final (
                    masterShader: Shader Function(Rect) master,
                    sharpShader: Shader Function(Rect) sharp,
                    blurRef: double blurRef,
                    masterKey: Key masterKey,
                    sharpKey: Key sharpKey,
                  ) = switch (feather) {
                    AmPhotoFeather.vertical => (
                      masterShader: (Rect rect) =>
                          amPhotoMasterFade(h).createShader(rect),
                      sharpShader: (Rect rect) =>
                          amPhotoSharpMask(h).createShader(rect),
                      blurRef: h,
                      masterKey: const Key('amArtistPhotoMasterFade'),
                      sharpKey: const Key('amArtistPhotoSharpMask'),
                    ),
                    AmPhotoFeather.rightEdge => (
                      masterShader: (Rect rect) =>
                          amPhotoRightFade(w).createShader(photoShaderRect(rect)),
                      sharpShader: (Rect rect) =>
                          amPhotoSharpMaskRight(w).createShader(photoShaderRect(rect)),
                      blurRef: w,
                      masterKey: const Key('amArtistPhotoRightFade'),
                      sharpKey: const Key('amArtistPhotoSharpRight'),
                    ),
                  };
                  final sigma = amPhotoBlurSigma(blurRef);
                  return ClipRect(
                    // ImageFiltered 的滤镜层在 TabBarView 平移时会逃出页面裁剪，
                    // 模糊底左右宽出清晰图 → 穿帮（真机反馈）。显式 ClipRect 收口。
                    child: ShaderMask(
                      key: masterKey,
                      blendMode: BlendMode.modulate,
                      shaderCallback: master,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          // 1. 统一模糊底：只在清晰层透明的羽化带露出。
                          //    转场位移中整体跳过（白线根因二），静止两端恢复。
                          if (blurActive)
                            ImageFiltered(
                              imageFilter: ImageFilter.blur(
                                sigmaX: tvBlurSigma(sigma),
                                sigmaY: tvBlurSigma(sigma),
                                tileMode: TileMode.clamp,
                              ),
                              child: photoLayer('blur'),
                            ),
                          // 2. 清晰层：羽化带让位给模糊底
                          ShaderMask(
                            key: sharpKey,
                            blendMode: BlendMode.modulate,
                            shaderCallback: sharp,
                            child: photoLayer('sharp'),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        );
      },
    );
  }
}
