import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../core/utils/artwork_color_extractor.dart';

/// 每个 pigment 场的运动色变体数（4 场 × 8 变体 = 32 个 motionColors）。
const int fluidMotionColourCount = 8;

/// 从封面提取的流光调色板。
///
/// - [pigments]：4 个 pigment（按亮度降序；`pigments[2]` 恒为最暗，供回退 painter
///   的静态基底使用），对齐 shader 的 `uPigment0..3`。
/// - [baseColor]：整屏底色（最暗 pigment 压暗；中性兜底 `0xFF080A0E`），
///   对齐 shader 的 `uBase`。
/// - [motionColors]：4 场 × 8 变体 = 32 个运动色，按色相/亮度档位派生，
///   shader 的 `uPigmentN` 每帧按 quintic 相位在这 8 个变体间插值。
class FlowingPalette {
  FlowingPalette({
    required this.pigments,
    required this.baseColor,
    required this.motionColors,
  })  : assert(pigments.length >= 4),
        assert(motionColors.length == 4 * fluidMotionColourCount);

  final List<Color> pigments;
  final Color baseColor;
  final List<Color> motionColors;

  /// 第 [field] 个 pigment（0..3）。
  Color pigment(int field) => pigments[field.clamp(0, 3)];

  /// 第 [field] 场第 [variant] 个运动色（variant 自动回绕 0..7）。
  Color motionColor(int field, int variant) {
    final wrap = variant % fluidMotionColourCount;
    return motionColors[field.clamp(0, 3) * fluidMotionColourCount + wrap];
  }

  /// 中性兜底（黑白/低饱和封面）：
  ///
  /// 沿用本仓既有 slate 蓝灰三色基调（`0xFF4A5568 / 0xFF5A6478 / 0xFF2F3A50`，
  /// 顺序即原 `_colors`，保证回退 painter 的光斑角色不变），补第 4 色与 base。
  /// **不要**退回原实现的刺眼紫（deepPurple/indigo/teal）。
  static final FlowingPalette fallback = FlowingPalette(
    pigments: _neutralPigments,
    baseColor: const Color(0xFF080A0E),
    motionColors: _buildMotionColors(_neutralPigments),
  );

  static const List<Color> _neutralPigments = <Color>[
    Color(0xFF4A5568),
    Color(0xFF5A6478),
    Color(0xFF2F3A50),
    Color(0xFF3C4658),
  ];
}

/// 深色模式档位的压暗系数（本仓自有口径，不对齐上游）。
///
/// 口径：AM 播放页本身恒为深色（黑色 Scaffold + 白字 + 0.35 黑蒙版），
/// 因此**只压暗流光自身**，不动蒙版与文字 —— 白字对比度只会更高。
class FlowingPaletteTone {
  FlowingPaletteTone._();

  /// pigment / motionColor 亮度系数。
  static const double pigmentLightnessScale = 0.80;

  /// pigment / motionColor 饱和度系数：压暗同时略降饱和，避免深色下发灰发脏。
  static const double pigmentSaturationScale = 0.90;

  /// base 亮度系数（比 pigment 压得更狠，拉开「底色 vs 光斑」层次）。
  ///
  /// **刻意不设亮度下限**：压暗是纯比例缩放，对任意输入都保证「不变亮」。
  /// 一旦加下限（例如 0.04），原本比下限还暗的运动色会被**抬亮**（0.035 →
  /// 0.04），深色档反而更亮，属反直觉的行为。
  static const double baseLightnessScale = 0.60;
}

/// 深色模式档：整份调色板压暗 + 降饱和，色相保持不变。
///
/// - 返回**新实例**，绝不就地改写输入（[FlowingPalette.fallback] 与
///   [FlowingPaletteCache] 里的是共享实例，改写会污染其它页面 / 其它宿主）；
/// - 不变量保持：亮度全部下降（纯比例缩放，无下限抬亮）、`base` 仍暗于全部
///   pigment（0.6 < 0.8）、4 个 pigment 仍互不相同（同一系数不改变序关系）；
/// - 调用方只应在 `Theme.brightness == Brightness.dark` 时使用；浅色模式直接
///   用原 palette，保持既有观感逐值不变。
FlowingPalette buildDeepFlowingPalette(FlowingPalette palette) {
  return FlowingPalette(
    pigments: List<Color>.unmodifiable(palette.pigments.map(_deepenPigment)),
    baseColor: _scaleHsl(
      palette.baseColor,
      lightnessScale: FlowingPaletteTone.baseLightnessScale,
      saturationScale: 1.0,
    ),
    motionColors:
        List<Color>.unmodifiable(palette.motionColors.map(_deepenPigment)),
  );
}

Color _deepenPigment(Color color) => _scaleHsl(
      color,
      lightnessScale: FlowingPaletteTone.pigmentLightnessScale,
      saturationScale: FlowingPaletteTone.pigmentSaturationScale,
    );

/// 按 HSL 缩放亮度/饱和度（色相与 alpha 不动），结果保证落在色域内。
Color _scaleHsl(
  Color color, {
  required double lightnessScale,
  required double saturationScale,
}) {
  final hsl = HSLColor.fromColor(color);
  return HSLColor.fromAHSL(
    hsl.alpha,
    hsl.hue,
    (hsl.saturation * saturationScale).clamp(0.0, 1.0).toDouble(),
    (hsl.lightness * lightnessScale).clamp(0.0, 1.0).toDouble(),
  ).toColor();
}

/// 从 [extracted]（按像素占比降序的候选色）派生流光调色板。
///
/// 保留本仓既有取色口径：
/// - 过滤近黑 / 近白 / 低饱和；
/// - 色相多样性贪心（避免整体偏蓝绿）；
/// - 饱和度温和归一化到 0.25~0.85（低饱和封面保持灰调，过高收敛避免刺眼）；
/// - 候选不足时由已选主色派生补足（同色相逐级压暗），不退回固定色。
///
/// 黑白/低饱和封面（无合格候选）直接返回 [FlowingPalette.fallback] 的 slate 基调。
FlowingPalette buildFlowingPalette(List<Color> extracted) {
  final candidates = extracted.where((c) {
    final hsl = HSLColor.fromColor(c);
    return hsl.saturation >= 0.15 && hsl.lightness > 0.1 && hsl.lightness < 0.92;
  }).toList();
  if (candidates.isEmpty) return FlowingPalette.fallback;

  // 按色相多样性挑选 3 色：主色取占比最高的颜色，其余尽量与已选色相拉开距离。
  final picked = _pickDiverseColors(candidates);
  while (picked.length < 3) {
    // 由"上一个"派生而不是永远由主色派生：主色较暗时不会退化成同明度重复色。
    final seed = HSLColor.fromColor(picked[picked.length - 1]);
    picked.add(
      seed.withLightness(math.max(0.08, seed.lightness - 0.22)).toColor(),
    );
  }
  // 按亮度降序：[最亮主色, 中间强调色, 最深暗部] —— 与三层径向光斑的角色对应。
  picked.sort((a, b) => HSLColor.fromColor(b)
      .lightness
      .compareTo(HSLColor.fromColor(a).lightness));
  final normalized = picked
      .map((c) => HSLColor.fromColor(c)
          .withSaturation(
              HSLColor.fromColor(c).saturation.clamp(0.25, 0.85).toDouble())
          .toColor())
      .toList();
  final pigments = _ensureFourPigments(normalized);
  final darkest = HSLColor.fromColor(pigments[2]);
  final base = darkest
      .withLightness(math.max(0.05, darkest.lightness - 0.45))
      .toColor();
  return FlowingPalette(
    pigments: List<Color>.unmodifiable(pigments),
    baseColor: base,
    motionColors: _buildMotionColors(pigments),
  );
}

/// 色相多样性贪心：首个取占比最高者，之后每轮取"与已选最小色相距离"最大者。
List<Color> _pickDiverseColors(List<Color> candidates) {
  final picked = <Color>[];
  final pool = List<Color>.of(candidates);
  picked.add(pool.removeAt(0));
  while (picked.length < 3 && pool.isNotEmpty) {
    Color best = pool.first;
    var bestScore = -1.0;
    for (final c in pool) {
      final hslC = HSLColor.fromColor(c);
      var minDist = double.infinity;
      for (final p in picked) {
        final d = _hueDistance(hslC, HSLColor.fromColor(p));
        if (d < minDist) minDist = d;
      }
      if (minDist > bestScore) {
        bestScore = minDist;
        best = c;
      }
    }
    picked.add(best);
    pool.remove(best);
  }
  return picked;
}

/// 两个 HSL 颜色的色相圆距（0~1，0 同色相、1 相差 180°）。
double _hueDistance(HSLColor a, HSLColor b) {
  final diff = (a.hue - b.hue).abs() % 360;
  return math.min(diff, 360 - diff) / 180;
}

/// 把 [ordered]（1~3 色）补到 4 个互不相同的 pigment。
///
/// 单色封面是常见输入（纯色专辑封面），必须以"错色相 + 压暗"派生，不能重复同一颜色。
List<Color> _ensureFourPigments(List<Color> ordered) {
  final out = List<Color>.of(ordered);
  var attempts = 0;
  while (out.length < 4 && attempts < 32) {
    attempts++;
    final seed = HSLColor.fromColor(out[out.length - 1]);
    final hue = (seed.hue + 18.0 * attempts) % 360;
    final lightness = math.max(0.08, seed.lightness - 0.18 * attempts);
    final saturation =
        (seed.saturation * (1 - 0.04 * attempts)).clamp(0.08, 0.85).toDouble();
    final candidate =
        HSLColor.fromAHSL(1, hue, saturation, lightness).toColor();
    if (out.every((c) => c != candidate)) out.add(candidate);
  }
  // 理论上到不了这里；防御性补齐，保证 length 恒为 4（无 NaN、在色域内）。
  while (out.length < 4) {
    out.add(HSLColor.fromColor(out.last)
        .withLightness(0.02 + out.length * 0.02)
        .toColor());
  }
  return out;
}

/// 32 个运动色：每场以自身 pigment 为基准，按色相/饱和度/亮度档位派生 8 个变体。
///
/// 所有值都经 clamp（hue 取模、saturation 0.05~0.92、lightness 0.03~0.92），
/// 保证落在合法色域内且无 NaN；派生是"每封面一次"的工作，不在逐帧路径。
List<Color> _buildMotionColors(List<Color> pigments) {
  final colors = List<Color>.filled(
      4 * fluidMotionColourCount, const Color(0xFF000000));
  for (var field = 0; field < 4; field++) {
    final base = HSLColor.fromColor(pigments[field]);
    for (var variant = 0; variant < fluidMotionColourCount; variant++) {
      final index = (variant + field * 3) % fluidMotionColourCount;
      final hue = (base.hue + _motionHueSteps[index]) % 360;
      final saturation =
          (base.saturation + _motionSatSteps[index]).clamp(0.05, 0.92).toDouble();
      final lightness =
          (base.lightness + _motionLightSteps[index]).clamp(0.03, 0.92).toDouble();
      colors[field * fluidMotionColourCount + variant] =
          HSLColor.fromAHSL(1, hue < 0 ? hue + 360 : hue, saturation, lightness)
              .toColor();
    }
  }
  return List<Color>.unmodifiable(colors);
}

const List<double> _motionHueSteps = <double>[-14, -7, 0, 7, 14, 20, -20, 10];
const List<double> _motionLightSteps = <double>[
  -0.10, -0.05, 0, 0.05, 0.10, 0.16, -0.15, 0.13,
];
const List<double> _motionSatSteps = <double>[0, 0.03, -0.03, 0.06, -0.06, 0.02, -0.02, 0.05];

/// 封面取色 loader（可注入，便于单测不依赖真实图片解码）。
typedef FlowingArtworkColorLoader = Future<List<Color>?> Function(String url);

/// url → [FlowingPalette] 的 LRU 缓存（跨播放器往返复用，避免重复解码）。
///
/// 只缓存成功结果：解码/分析失败返回 [FlowingPalette.fallback] 且**不**入缓存，
/// 避免临时网络问题让该封面永远停留在兜底色。并发请求同一 url 会复用同一个
/// Future（不会重复解码）。
class FlowingPaletteCache {
  FlowingPaletteCache({
    this.maximumEntries = 24,
    this.loader,
  }) : assert(maximumEntries > 0);

  /// 生产用全局实例（widget 层引用它，等价原 `_paletteCache`）。
  static final FlowingPaletteCache instance = FlowingPaletteCache();

  final int maximumEntries;

  /// 可注入的取色 loader（null = 走 [ArtworkColorExtractor.loadPalette]）。
  final FlowingArtworkColorLoader? loader;
  final Map<String, FlowingPalette> _cache = <String, FlowingPalette>{};
  final Map<String, Future<FlowingPalette>> _pending =
      <String, Future<FlowingPalette>>{};
  int _loadCount = 0;

  /// 实际执行 loader（解码 + 取色）的次数（诊断/测试用）。
  int get loadCount => _loadCount;

  int get length => _cache.length;

  /// 仅查缓存，不触发解码。
  FlowingPalette? peek(String url) {
    final cached = _cache.remove(url);
    if (cached == null) return null;
    _cache[url] = cached; // LRU：命中即刷新热度
    return cached;
  }

  /// 取 [url] 的调色板；未命中时异步解码一次并缓存成功结果。
  Future<FlowingPalette> paletteFor(String url) {
    final cached = peek(url);
    if (cached != null) return Future<FlowingPalette>.value(cached);
    final pending = _pending[url];
    if (pending != null) return pending;
    final request = _extract(url);
    _pending[url] = request;
    request.whenComplete(() {
      if (identical(_pending[url], request)) _pending.remove(url);
    });
    return request;
  }

  Future<FlowingPalette> _extract(String url) async {
    _loadCount++;
    try {
      final colors = await (loader ?? _loadArtworkColors)(url);
      if (colors == null || colors.isEmpty) return FlowingPalette.fallback;
      final palette = buildFlowingPalette(colors);
      _remember(url, palette);
      return palette;
    } catch (_) {
      return FlowingPalette.fallback;
    }
  }

  void _remember(String url, FlowingPalette palette) {
    _cache.remove(url);
    _cache[url] = palette;
    while (_cache.length > maximumEntries) {
      _cache.remove(_cache.keys.first);
    }
  }

  /// 清空缓存（测试 / 全局取色失效时）。
  void clear() {
    _cache.clear();
    _pending.clear();
  }
}

/// 默认 loader：统一走 [ArtworkColorExtractor.loadPalette]（网络/本地/内嵌封面
/// 三种来源都在其内部处理），与 UI 封面共用同一份磁盘缓存。
Future<List<Color>?> _loadArtworkColors(String url) async {
  final palette = await ArtworkColorExtractor.loadPalette(url);
  return palette?.colors.toList(growable: false);
}
