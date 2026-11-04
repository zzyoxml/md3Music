import 'dart:async';
import 'dart:ui' show ImageFilter, TileMode;

import 'package:flutter/material.dart';

import '../../../core/build_flags.dart' show tvBlurSigma;
import '../../../core/services/player_frame_driver.dart';
import '../../../core/widgets/app_background.dart' show kDefaultWallpaperAsset;
import '../../widgets/flowing_background_palette.dart';
import '../../widgets/flowing_gradient_painter.dart';
import 'settings_preview_frame.dart';

/// 「播放页背景」三级子页的演示卡。
///
/// 一个模拟播放页背景，把这一页的 5 个开关叠加后的最终效果一次演完：
/// 写真轮播（按 [photoIntervalSeconds] 淡切）+ 遮罩浓度
/// （[photoMaskOpacity]）+ 动态流光（[flowingEnabled]）+ 背景模糊
/// （[blurSigma]）。底部压一行「封面 + 曲名」，用来判断遮罩够不够浓、
/// 文字还认不认得出。
///
/// ## 写真用内置图片，不用渐变色块
///
/// 渐变色块没有细节，高斯模糊一上去就变成一片纯色（真机反馈「模糊一片灰
/// 看不出来效果」）。改用内置的 [kDefaultWallpaperAsset]：它有明暗层次和
/// 构图，模糊过程中能看到「从清楚到糊」的渐变，遮罩浓淡也能看出画面被
/// 压暗的程度。
///
/// 两张写真用内置默认壁纸 + 主题主色/次色渐变成对：第一张是真图（体现
/// 模糊/遮罩），第二张是色块（体现「换了一张图」的轮播切换）。
///
/// ## 口径全部对齐播放页
///
/// - 轮播淡切 800ms（[ArtistPhotoBackground] 的 AnimatedSwitcher 时长）；
/// - 遮罩色 = `colorScheme.surface.withValues(alpha: opacity)`（同源）；
/// - 模糊走 `tvBlurSigma()` 钳制 + **`tileMode: TileMode.clamp`** —— 后者是
///   必须的：Impeller 下不指定 tileMode 会用 decal，图层外透明黑被卷进卷积核，
///   四周会出一圈暗晕（full_player_am.dart:1570-1574 记的坑）；
/// - 流光**直接复用播放页 shader 不可用时的回退 painter**
///   （[FlowingGradientPainter]：静态基底 + 多层径向光斑），保证「设置页预览
///   ≈ 播放页实况」；不再用两条线性亮带近似。
///
/// ## 帧率
///
/// 轮播是**秒级**切换，用 `Timer.periodic` 算到期即可，不必挂 60fps。
/// 流光是连续动画，挂 [PlayerFrameDriver] 共享节拍（AGENTS.md §0 第 4 条），
/// 不在时自己不起 Timer。
class PlayerBackgroundPreview extends StatefulWidget {
  final bool photoEnabled;
  final int photoIntervalSeconds;
  final double photoMaskOpacity;
  final bool flowingEnabled;
  final double blurSigma;

  const PlayerBackgroundPreview({
    super.key,
    required this.photoEnabled,
    required this.photoIntervalSeconds,
    required this.photoMaskOpacity,
    required this.flowingEnabled,
    required this.blurSigma,
  });

  @override
  State<PlayerBackgroundPreview> createState() =>
      _PlayerBackgroundPreviewState();
}

/// 内置壁纸：同时用作「模糊封面背景」层与「写真」第 0 张。
///
/// 有明暗层次和构图，模糊过程中能看出「从清楚到糊」的渐变；纯渐变色块
/// 一糊就变成同一片纯色，看不出效果（真机反馈）。
const String _kPreviewWallpaper = kDefaultWallpaperAsset;

/// 演示卡用的第 1 张「写真」：渐变色块（只用来体现「轮播换了图」）。
const List<Color> _kPreviewGradient1 = <Color>[
  Color(0xFF8A4C5E),
  Color(0xFFC98A5E),
];

class _PlayerBackgroundPreviewState extends State<PlayerBackgroundPreview> {
  /// 轮播淡切时长，与播放页 [ArtistPhotoBackground] 的 AnimatedSwitcher 一致。
  static const Duration _crossfade = Duration(milliseconds: 800);

  /// 演示卡演示区高度（dp）。与 build 里传给 [SettingsPreviewFrame] 的一致。
  static const double _cardHeight = 190;

  /// 设置值标定的参考整屏高度（dp）。播放页模糊按这个尺度的画面调校。
  static const double _referenceScreenHeight = 800;

  /// 演示卡用的中性 slate 调色板：与播放页「无封面 / 黑白封面」兜底完全一致。
  ///
  /// 深色档与播放页同源（[buildDeepFlowingPalette]）：播放页只在深色主题下压暗，
  /// 预览卡必须跟着变，否则「设置页预览 ≈ 播放页实况」这条口径就断了。
  static final FlowingPalette _deepPreviewPalette =
      buildDeepFlowingPalette(FlowingPalette.fallback);

  /// 按主题明暗取演示卡调色板（浅色 = 原兜底，深色 = 压暗档）。
  static FlowingPalette _previewPaletteFor(Brightness brightness) =>
      brightness == Brightness.dark
          ? _deepPreviewPalette
          : FlowingPalette.fallback;

  /// 演示卡 sigma 上限：再大就把内置壁纸抹成纯色，失去演示意义。
  static const double maxCardBlurSigma = 24;

  int _photoIndex = 0;
  Timer? _rotateTimer;

  /// 流光时间（秒）。由共享节拍推进，[FlowingGradientPainter] 通过 ValueNotifier
  /// 直接重绘 —— 不 setState，避免每帧重建整张演示卡。
  final ValueNotifier<double> _flowTime = ValueNotifier<double>(0);
  bool _driverBound = false;

  @override
  void initState() {
    super.initState();
    _syncRotateTimer();
    _syncFlowDriver();
  }

  @override
  void didUpdateWidget(covariant PlayerBackgroundPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.photoEnabled != widget.photoEnabled ||
        oldWidget.photoIntervalSeconds != widget.photoIntervalSeconds) {
      _syncRotateTimer();
    }
    if (oldWidget.flowingEnabled != widget.flowingEnabled) {
      _syncFlowDriver();
    }
  }

  @override
  void dispose() {
    _rotateTimer?.cancel();
    _unbindFlowDriver();
    _flowTime.dispose();
    super.dispose();
  }

  void _syncRotateTimer() {
    _rotateTimer?.cancel();
    _rotateTimer = null;
    if (!widget.photoEnabled || widget.photoIntervalSeconds <= 0) return;
    _rotateTimer = Timer.periodic(
      Duration(seconds: widget.photoIntervalSeconds),
      (_) {
        if (!mounted) return;
        setState(
          // 写真张数（0 = 内置壁纸，1 = 渐变色块）
          () => _photoIndex = (_photoIndex + 1) % 2,
        );
      },
    );
  }

  void _syncFlowDriver() {
    if (widget.flowingEnabled) {
      if (!_driverBound) {
        PlayerFrameDriver.instance.addListener(_onFlowTick);
        _driverBound = true;
      }
    } else if (_driverBound) {
      _unbindFlowDriver();
    }
  }

  void _unbindFlowDriver() {
    if (_driverBound) {
      PlayerFrameDriver.instance.removeListener(_onFlowTick);
      _driverBound = false;
    }
  }

  void _onFlowTick() {
    if (!mounted) return;
    // 播放页的流光时间由「每 2 拍推进 0.016 秒」= 0.5 秒流光/秒；
    // 演示卡每拍（16ms）推进 0.008 秒，时间流速与播放页一致（≈30fps 观感）。
    _flowTime.value += 0.008;
  }

  /// 第 [index] 张写真。
  ///
  /// 0 = 内置壁纸（有明暗层次，模糊与遮罩都看得出来）；
  /// 1 = 渐变色块（只用来体现「轮播换了图」）。
  Widget _photoLayer(int index) {
    if (index == 0) {
      return Image.asset(
        _kPreviewWallpaper,
        key: const ValueKey<int>(0),
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        // 演示卡只有约 190dp 高，限制解码宽度避免全尺寸解码的内存峰值
        cacheWidth: 600,
        errorBuilder: (_, _, _) => Container(color: Colors.grey),
      );
    }
    return Container(
      key: const ValueKey<int>(1),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: _kPreviewGradient1,
        ),
      ),
    );
  }

/// 演示卡用的实际 sigma：设置值按卡片高度等比缩放。
  ///
  /// 设置值 0~200 是按**整屏**（约 800dp 高）调的；演示卡只有约 190dp 高，
  /// 同一 sigma 在矮卡上的相对模糊强度是整屏的约 4 倍，上限值下会把内置壁纸
  /// 彻底抹成一片纯色 —— 真机反馈「模糊一片灰看不出来效果」。
  ///
  /// 按 [SettingsPreviewFrame] 卡片实际高度（[_cardHeight]）与参考整屏高度
  /// 的比例缩放，让任意一档在卡上都保留可辨的层次。
  double _scaledSigma() {
    final raw = tvBlurSigma(widget.blurSigma);
    final scale = _referenceScreenHeight / _cardHeight;
    return (raw / scale).clamp(0.0, maxCardBlurSigma);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // 与播放页同一判据：深色主题压暗、浅色主题保持原观感
    final flowPalette =
        _previewPaletteFor(Theme.of(context).brightness);

    return SettingsPreviewFrame(
      title: '播放页背景预览',
      subtitle: '模糊 ${widget.blurSigma.round()}'
          '${widget.photoEnabled ? ' · 遮罩 ${(widget.photoMaskOpacity * 100).round()}%' : ''}',
      footnote: '底层为模糊封面背景（受模糊滑杆控制）；'
          '开启写真后其上叠一层清晰写真，只受遮罩与轮播间隔控制',
      height: 190,
      background: colorScheme.surfaceContainerHighest,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // ── 第 1 层：模糊的封面背景 ──
          // 与播放页结构一致（full_player_am.dart:1558-1576）：这层**恒存在**，
          // 与「歌手写真背景轮播」开关无关，只受「播放页背景模糊」控制。
          // 写真开关关闭时用户看到的就是这一层 —— 所以关闭开关也有东西可看，
          // 模糊滑杆也仍然看得出效果（此前把这层与写真层混为一层，导致开关
          // 一关整张卡只剩一片中性灰，怎么拖模糊都没反应）。
          //
          // sigma 按卡片高度缩放：设置值 0~200 按整屏（约 800dp）标定，
          // 演示卡仅 190dp 高，同一 sigma 在矮卡上相对强度是整屏的约 4 倍，
          // 上限值下会把图抹成纯色（真机反馈「模糊一片灰看不出来效果」）。
          _CoverLayer(sigma: _scaledSigma(), colorScheme: colorScheme),
          // ── 第 2 层：歌手写真（开启时才叠上来，且保持清晰）──
          // 播放页写真层不加模糊（full_player_am.dart:2134-2163 与
          // am_artist_photo_cover 同源），它只受遮罩浓度与轮播间隔影响。
          if (widget.photoEnabled)
            AnimatedSwitcher(
              duration: _crossfade,
              child: _photoLayer(_photoIndex),
            ),
          // ── 第 3 层：动态流光 ──
          // 直接复用播放页 shader 不可用时的回退 painter（静态基底 + 多层径向
          // 光斑），保证「设置页预览 ≈ 播放页实况」；不再用两条线性亮带近似。
          if (widget.flowingEnabled)
            IgnorePointer(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // 静态基底：与播放页回退路径同源（最深 + 中间两个 pigment）
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          flowPalette.pigments[2],
                          flowPalette.pigments[1],
                        ],
                      ),
                    ),
                  ),
                  CustomPaint(
                    painter: FlowingGradientPainter(
                      colors: flowPalette.pigments,
                      timeNotifier: _flowTime,
                    ),
                  ),
                ],
              ),
            ),
          // ── 第 4 层：遮罩（浓度 = 写真背景透明度；越大写真越淡、文字越清楚）──
          if (widget.photoEnabled)
            ColoredBox(
              color: colorScheme.surface.withValues(
                alpha: widget.photoMaskOpacity.clamp(0.0, 1.0),
              ),
            ),
          // 顶层：模拟封面 + 曲名（压在遮罩上，用来看可读性）
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Icon(
                        Icons.music_note,
                        size: 20,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '示例歌曲名',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colorScheme.onSurface,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            '示例歌手 · 专辑',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colorScheme.onSurfaceVariant,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 演示卡用的「流光」已改为复用 [FlowingGradientPainter]（见 build 第 3 层），
/// 原先两条线性渐变带的近似实现（`_FlowingBandPainter`）已删除。

  /// 播放页背景的底层：模糊的封面图。
///
/// 与播放页同源（full_player_am.dart:1558-1576）：这层**恒存在**，与
/// 「歌手写真背景轮播」开关无关，只受「播放页背景模糊」控制。写真开启时它
/// 退到写真层下面当日景，写真关闭时它就是用户看到的全部背景。
///
/// sigma 为 0 时仍渲染原图（清晰），与播放页 `ImageFilter.blur(0)` 一致。
class _CoverLayer extends StatelessWidget {
  final double sigma;
  final ColorScheme colorScheme;

  const _CoverLayer({required this.sigma, required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    return ImageFiltered(
      // tvBlurSigma 钳制 + TileMode.clamp：Impeller 下不指定 tileMode 会用
      // decal，图层外透明黑被卷进卷积核 → 四周一圈暗晕（full_player_am.dart:1570-1574）。
      imageFilter: ImageFilter.blur(
        sigmaX: sigma,
        sigmaY: sigma,
        tileMode: TileMode.clamp,
      ),
      child: Image.asset(
        _kPreviewWallpaper,
        key: const ValueKey<String>('cover'),
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        // 演示卡只有约 190dp 高，限制解码宽度避免全尺寸解码的内存峰值
        cacheWidth: 600,
        errorBuilder: (_, _, _) =>
            Container(color: colorScheme.surfaceContainerHigh),
      ),
    );
  }
}

