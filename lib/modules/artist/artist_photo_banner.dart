import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/build_flags.dart';
import '../../data/models/song.dart';
import '../player/artist_photo_service.dart';

/// 从候选歌曲 hash（ArtistDetailPage 传入 Song.id，即酷狗 hash）中取第一个非空值。
String? pickFirstNonEmptyHash(Iterable<String> values) {
  for (final value in values) {
    if (value.isNotEmpty) return value;
  }
  return null;
}

/// [pickArtistPhotoHash] 的结果：取图键 + 该曲是否为「本歌手独唱」。
typedef ArtistPhotoHashPick = ({String? hash, bool isSolo});

/// 为歌手页写真 banner 优选「取图键 hash」，按歌手归属可信度分档。
///
/// **为什么不能直接拿列表第一首**：写真接口 `/images/audio` 以**歌曲 hash** 为键、
/// 上游带 `show_authors=1`，返回的是「这首歌的**所有**歌手的写真」（见
/// [ArtistPhotoService.itemBelongsToArtist]）。热门排序下第一首常是合作曲，
/// 于是别人的照片会混进本歌手页轮播（本次修的缺陷）。
///
/// 分档（命中即返回，`isSolo` 标记该档是否可信）：
/// 1. **独唱 + 身份确认**：拆分后只有一个歌手名，且 `artistId` 或歌手名对得上目标
///    歌手 → 上游只可能返回该歌手的写真，最稳。
/// 2. **独唱但无从核对身份**：只有一个歌手名，而页面连 `artistId`/`artistName`
///    都拿不到（脏数据）→ 仍远好于合作曲。
/// 3. **回落**：第一个非空 hash（等价旧行为），交由 [ArtistPhotoService.load] 的
///    归属过滤兜底，`isSolo=false`。
ArtistPhotoHashPick pickArtistPhotoHash(
  Iterable<Song> songs, {
  String? artistId,
  String? artistName,
}) {
  final wantId = (artistId ?? '').trim();
  final wantName = (artistName ?? '').trim().toLowerCase();
  String? soloUnverifiedHash;
  for (final song in songs) {
    if (song.id.isEmpty) continue;
    final names = splitSongArtistNames(song.artist);
    if (names.length != 1) continue;
    final identified =
        (wantId.isNotEmpty && (song.artistId ?? '').trim() == wantId) ||
            (wantName.isNotEmpty && names.first.toLowerCase() == wantName);
    if (identified) {
      return (hash: song.id, isSolo: true);
    }
    // 页面没给出任何可比对的身份信息时才用这一档；有信息但对不上说明这首歌
    // 根本不属于本歌手（脏数据/同名他人），拿它取图反而更错。
    if (wantId.isEmpty && wantName.isEmpty) soloUnverifiedHash ??= song.id;
  }
  if (soloUnverifiedHash != null) {
    return (hash: soloUnverifiedHash, isSolo: true);
  }
  return (
    hash: pickFirstNonEmptyHash(songs.map((s) => s.id)),
    isSolo: false,
  );
}

/// 底缘羽化带高：min(160dp, 容器高 × 0.35)（AM 竖屏底带比例复用）。
double _featherBand(double height) =>
    math.min(160.0, math.max(height, 1.0) * 0.35);

double _smoothStep(double t) {
  final c = t.clamp(0.0, 1.0);
  return c * c * (3 - 2 * c);
}

/// ShaderMask modulate 的「保留原色」标记必须是白色（黑色会把 RGB 乘成 0）。
const Color _maskOpaque = Color(0xFFFFFFFF);

Color _maskColor(double alpha) => alpha >= 0.999
    ? _maskOpaque
    : (alpha <= 0.001
          ? Colors.transparent
          : _maskOpaque.withValues(alpha: alpha));

/// 底缘 alpha 从平台值 [innerAlpha] 按 smoothstep 平滑降到 0 的多采样点渐变。
/// [zoneScale]=0.8 表示羽化带 80% 处已归零，留给外层主罩收尾（防两罩同时半透生成条带）。
LinearGradient _bottomFade({
  required double height,
  double innerAlpha = 1.0,
  double zoneScale = 1.0,
  int samples = 8,
}) {
  final h = math.max(height, 1.0);
  final band = _featherBand(h);
  final start = h - band;
  final points = <double, double>{};
  void put(double yPx, double a) {
    final t = (yPx / h).clamp(0.0, 1.0);
    points[(t * 1e6).roundToDouble() / 1e6] = a;
  }
  for (var i = 0; i <= samples; i++) {
    final f = math.min(i / samples, zoneScale);
    final a = innerAlpha * (1 - _smoothStep(f / zoneScale));
    put(start + band * f, a);
  }
  put(0, innerAlpha);
  put(start, innerAlpha);
  put(h, 0);
  final ts = points.keys.toList()..sort();
  return LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [for (final t in ts) _maskColor(points[t]!)],
    stops: ts,
  );
}

/// 主淡出罩（套整个 PageView 之外）：底缘整体消融进页面背景。
@visibleForTesting
LinearGradient artistPhotoBottomFade(double height) =>
    _bottomFade(height: height);

/// 清晰层底缘罩：与主罩同带宽平滑降零（zoneScale=1.0）。
/// AM 双缘版用 0.8 错峰防条带，但单缘场景下 80% 处的提前归零会在羽化带
/// 内留下亮度折点（真机反馈「过渡区域一条细线」）；两罩同为 smoothstep
/// 时乘积曲线处处平滑，无折点。
@visibleForTesting
LinearGradient artistPhotoSharpBottomMask(double height) =>
    _bottomFade(height: height, zoneScale: 1.0);

/// 歌手详情页 header 写真 banner：PageView 轮播 + 遮罩 + 圆点指示。
///
/// 作为 flexibleSpace 的最底图（壁纸层之上、主题渐变层之下），无写真时渲染
/// 空容器，页面完全回落原样。写真按「歌曲 hash」索引，复用播放页的
/// [ArtistPhotoService]（`/images/audio`）。轮播由秒级 [Timer.periodic] 驱动，
/// 不用 Ticker（AGENTS.md §10：装饰性循环必须限帧，header 不可见时必须停表）。
///
/// **归属过滤**：写真键对应的歌曲可能是多歌手合作曲，上游会连同其他歌手的写真
/// 一起返回。故必须传 [artistId]/[artistName]，由 [ArtistPhotoService] 按条目作者
/// 归属剔除他人写真；取图键本身也应由页面用 [pickArtistPhotoHash] 优选独唱曲。
///
/// **图片顺序**：歌手头像（[fallbackUrl]）为第 0 页，其后依次是写真；写真为空时
/// 退化为单页头像，无头像时纯写真（播放页旧用法）。见 [_shown]。
class ArtistPhotoBanner extends StatefulWidget {
  final String hash;

  /// header 是否在可视区（折叠出屏后 false → 停表不产帧）。
  final bool active;

  /// 自动切换间隔（秒），页面从 ThemeProvider.artistPhotoInterval 传入。
  final int intervalSeconds;

  /// 写真上的 surface 遮罩浓度（0~1），页面从 ThemeProvider.artistPhotoOpacity 传入。
  final double scrimOpacity;

  /// 拉取张数上限。
  final int count;

  /// 底缘「恒模糊 + 分段渐变」羽化（歌手详情页 header 用；播放页旧用法保持 false）。
  final bool feather;

  /// 歌手头像（/artist/detail 的 sizable_avatar）：作为 banner 第 0 页。
  /// 写真拉到 0 张时退化为单页兜底（cover+羽化同款）；null/空 则纯写真渲染。
  final String? fallbackUrl;

  /// 写真归属过滤：目标歌手 id（可空）。与 [artistName] 一起传给
  /// [ArtistPhotoService.load]，用于把合作曲响应里**其他歌手**的写真剔除。
  final String? artistId;

  /// 写真归属过滤：目标歌手名。空且 [artistId] 也为空时不做归属过滤（旧行为）。
  final String artistName;

  /// 写真数据源；null 时取 [ArtistPhotoService.instance]（测试可注入）。
  final ArtistPhotoService? service;

  const ArtistPhotoBanner({
    super.key,
    required this.hash,
    required this.active,
    required this.intervalSeconds,
    required this.scrimOpacity,
    this.count = 8,
    this.feather = false,
    this.fallbackUrl,
    this.artistId,
    this.artistName = '',
    this.service,
    this.flipKey,
  });

  /// tv: 供外部（header 按钮行）驱动左右翻页。
  ///
  /// banner 自己的 `Focus` 节点已 `skipTraversal`（不进 dpad 候选，见 build 内
  /// 注释），因此遥控的左右翻页改由焦点落在按钮行/歌曲行时驱动，需要外部
  /// 拿得到翻页动作。持有 [GlobalKey] 即可，无需把 PageController 往上抬。
  final GlobalKey<ArtistPhotoBannerState>? flipKey;

  @override
  State<ArtistPhotoBanner> createState() => ArtistPhotoBannerState();
}

/// banner 状态：除生命周期外额外暴露 [flipBy] 供外部驱动翻页（见
/// [ArtistPhotoBanner.flipKey]）。
class ArtistPhotoBannerState extends State<ArtistPhotoBanner> {
  List<String> _urls = const <String>[];
  late final PageController _pageController;
  int _currentIndex = 0;
  Timer? _timer;

  /// 加载令牌：hash 变更（页面改善式重选取图键）后，迟到的旧响应必须丢弃，
  /// 否则会用旧 hash 的写真覆盖新结果。与歌手详情页的 `_fetchToken` 同一手法。
  int _loadToken = 0;

  ArtistPhotoService get _service =>
      widget.service ?? ArtistPhotoService.instance;

  /// 实际渲染的图片集：歌手头像（fallbackUrl）为第 0 页，其后是写真。
  ///
  /// 三种形态：头像+写真 → 头像置首、写真依次接后（自动轮播从头像切到写真）；
  /// 写真为空 → 单页头像兜底（天然不轮播）；无头像 → 纯写真（播放页旧用法）。
  List<String> get _shown {
    final avatar = widget.fallbackUrl;
    if (avatar == null || avatar.isEmpty) return _urls;
    // 头像与写真同为酷狗图床，同源 URL 可能重复：已在写真列表中则不前置，
    // 避免相邻两页放同一张图。
    if (_urls.contains(avatar)) return _urls;
    if (_urls.isEmpty) return <String>[avatar];
    return <String>[avatar, ..._urls];
  }

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _load();
  }

  @override
  void didUpdateWidget(covariant ArtistPhotoBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hash != widget.hash ||
        oldWidget.artistId != widget.artistId ||
        oldWidget.artistName != widget.artistName) {
      _load();
    } else if (oldWidget.active != widget.active ||
        oldWidget.intervalSeconds != widget.intervalSeconds) {
      _syncTimer();
    }
  }

  Future<void> _load() async {
    _stopTimer();
    final token = ++_loadToken;
    final urls = await _service.load(
      hash: widget.hash,
      count: widget.count,
      artistId: widget.artistId,
      artistName: widget.artistName,
    );
    if (kDebugMode) {
      debugPrint('[ArtistPhotoBanner] hash=${widget.hash} urls=${urls.length}');
    }
    if (!mounted || token != _loadToken) return;
    setState(() {
      _urls = urls;
      _currentIndex = 0;
    });
    if (_pageController.hasClients) _pageController.jumpToPage(0);
    _syncTimer();
  }

  /// 启停收口：仅「header 可见 + 多于 1 张」时产帧，其余状态一律停表
  /// （AGENTS.md §10.4：不可见/静止不得持续 tick）。
  void _syncTimer() {
    final shouldRun = widget.active && _shown.length > 1;
    if (shouldRun && _timer == null) {
      _timer = Timer.periodic(
        Duration(seconds: widget.intervalSeconds),
        (_) => _advance(),
      );
    } else if (!shouldRun && _timer != null) {
      _stopTimer();
    }
  }

  void _advance() {
    if (!mounted || !_pageController.hasClients) return;
    // 用户正在拖动/回弹时跳过本次自动切换，避免手势打架
    if (_pageController.position.isScrollingNotifier.value) return;
    _pageController.animateToPage(
      (_currentIndex + 1) % _shown.length,
      duration: const Duration(milliseconds: 800),
      curve: Curves.easeInOutCubic,
    );
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _stopTimer();
    _pageController.dispose();
    super.dispose();
  }

  /// TV 遥控：左右键翻写真页（照片总数取 PageView 的 itemCount 同源变量 `_shown`）。
  KeyEventResult _handleTvKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.arrowLeft &&
        key != LogicalKeyboardKey.arrowRight) {
      return KeyEventResult.ignored;
    }
    if (!_pageController.hasClients) return KeyEventResult.ignored;
    flipBy(key == LogicalKeyboardKey.arrowLeft ? -1 : 1);
    return KeyEventResult.handled;
  }

  /// tv: 遥控左右翻写真页（由外部按钮行调用，见 [ArtistPhotoBanner.flipKey]）。
  ///
  /// 与 [_handleTvKey] 同源的公开入口：banner 自己的 `Focus` 已排除出 dpad
  /// 遍历候选，收不到按键，翻页改由外部调用本方法驱动。
  void flipBy(int delta) {
    if (!_pageController.hasClients) return;
    if (_shown.length <= 1) return;
    final current = _pageController.page?.round() ?? 0;
    final target = (current + delta).clamp(0, _shown.length - 1);
    if (target == current) return;
    _pageController.animateToPage(
      target,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  Widget _page(int index, double h) {
    final url = _shown[index];
    Widget image({required String role, int? memCacheWidth}) =>
        CachedNetworkImage(
          key: widget.feather ? ValueKey('$url#$role') : null,
          imageUrl: url,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          memCacheWidth: memCacheWidth,
          placeholder: (_, _) => const SizedBox.shrink(),
          errorWidget: (_, _, _) => const SizedBox.shrink(),
        );
    if (!widget.feather) return image(role: 'plain', memCacheWidth: 800);
    return Stack(
      fit: StackFit.expand,
      children: [
        // 模糊底：32px 宽解码 + cover 放大（bilinear 即模糊）。
        // 不用 ImageFiltered——滤镜层在 ClipRect 边界留 1px 接缝（真机细线）。
        image(role: 'blur', memCacheWidth: 32),
        // 清晰层：底缘按遮罩渐隐露出模糊底
        ShaderMask(
          blendMode: BlendMode.modulate,
          shaderCallback: (rect) =>
              artistPhotoSharpBottomMask(rect.height).createShader(rect),
          child: image(role: 'sharp', memCacheWidth: 800),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_shown.isEmpty) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final h = constraints.maxHeight;
        Widget photos = kTvBuild
            // TV：左右方向键在轮播内翻写真页（遥控无手势翻页路径）。
            //
            // `skipTraversal: true` 是必需的（2026-10-05 真机取证）：本节点包住
            // 整个 `PageView`，矩形就是**全幅 banner**，面积大、位置最靠上，
            // dpad 从下方歌曲列表按上键时它总能进入候选并胜出（tmp 探针 2e 实测
            // 落点=banner_focus，三按钮全部落空）。更糟的是本节点的
            // `onKeyEvent` 只吞左右键，上下键一律 `ignored` → 焦点一旦落上来
            // 就彻底困死，右上角 AppBar 按钮与中间三按钮全都再也走不到。
            //
            // 排除出遍历后：翻页改由落在三按钮/歌曲行时的左右键驱动
            // （`ArtistPhotoHeader` 把 `onHorizontalFlip` 透传给按钮行），
            // 本节点退化为不参与遍历的按键接收者。
            ? Focus(
                skipTraversal: true,
                onKeyEvent: _handleTvKey,
                child: PageView.builder(
                  controller: _pageController,
                  itemCount: _shown.length,
                  onPageChanged: (index) => setState(() => _currentIndex = index),
                  itemBuilder: (context, index) => _page(index, h),
                ),
              )
            : PageView.builder(
                controller: _pageController,
                itemCount: _shown.length,
                onPageChanged: (index) => setState(() => _currentIndex = index),
                itemBuilder: (context, index) => _page(index, h),
              );
        if (widget.feather) {
          // 主淡出：写真（含模糊带与清晰主体）整体在底缘消融进页面背景。
          // ClipRect 由外层 ArtistPhotoHeader 负责（ShaderMask 的 saveLayer
          // 边界同样需要裁剪祖先兜底）。
          photos = ShaderMask(
            blendMode: BlendMode.modulate,
            shaderCallback: (rect) =>
                artistPhotoBottomFade(rect.height).createShader(rect),
            child: photos,
          );
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            photos,
            if (widget.scrimOpacity > 0)
              // IgnorePointer：ColoredBox 吸收命中测试，不穿透 PageView 收不到横滑
              IgnorePointer(
                child: Container(
                  color: colorScheme.surface
                      .withValues(alpha: widget.scrimOpacity),
                ),
              ),
          ],
        );
      },
    );
  }
}
