import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:material_ui/material_ui.dart';

import '../core/services/player_frame_driver.dart';
import '../core/utils/artwork_color_extractor.dart';

/// 动态流光背景效果。
///
/// 参照 AMLL WebGL Mesh Gradient 背景渲染系统的简化 Flutter 实现。
/// 从专辑封面提取主色调，用多层径向渐变叠加 + 动画偏移模拟"色彩流动"。
class FlowingBackground extends StatefulWidget {
  final String? artworkUrl;
  final bool isPlaying;

  const FlowingBackground({
    super.key,
    this.artworkUrl,
    this.isPlaying = true,
  });

  @override
  State<FlowingBackground> createState() => _FlowingBackgroundState();
}

class _FlowingBackgroundState extends State<FlowingBackground>
    with WidgetsBindingObserver {
  // 时间累积通过 ValueNotifier 驱动 CustomPainter 重绘，避免每帧 setState
  // 触发 widget 重建
  final ValueNotifier<double> _timeNotifier = ValueNotifier<double>(0);

  /// 每 [_beatsPerAdvance] 个共享节拍拍推进一次（30fps 档）。
  ///
  /// 驱动源是全局共享节拍 [PlayerFrameDriver]（16ms，名义 62.5Hz），
  /// 每 2 拍推进一次即 ≈30fps（16ms × 2 = 32ms）。
  ///
  /// **为什么是拍计数器而不是「累加 dt 到阈值再清零」**：
  /// 节拍是 16ms 网格，30fps 需要 33.3ms，在该网格上凑不出整数倍。
  /// 沿用旧的 `_accumulatedDt >= 1/30; _accumulatedDt = 0` 写法要累积到 48ms
  /// 才够阈值，会**静默退化成 20.8fps**——代码看上去完全正常，只是悄悄少了 1/3 帧。
  /// 拍计数器 `++_beat` 每 2 拍恰好推进一次，不依赖定时器抖动，也不会踩这个坑。
  static const int _beatsPerAdvance = 2;

  /// 共享节拍单拍时长（秒），直接取自 [PlayerFrameDriver.step]（16ms）。
  ///
  /// 用 `static final` 而非写死常量：共享节拍若调整档位（§10.2 分档表），
  /// 这里自动跟随，不会静默失配成另一个帧率。
  static final double _beatStepSeconds =
      PlayerFrameDriver.step.inMicroseconds / Duration.microsecondsPerSecond;

  /// 单次推进 `_time` 的步长（秒）= `_beatStepSeconds × _beatsPerAdvance × 0.5`。
  ///
  /// 0.5 是原实现的流光速度倍率（约 4 秒一个周期）。
  /// 数值上 = 0.016 × 2 × 0.5 = **0.016**。
  ///
  /// 视觉速度逐项对齐原实现（单步 32ms vs 42ms，但步长同比缩小）：
  /// 原 `0.042 × 0.5 = 0.021 / 42ms` → 0.5 秒流光/秒；
  /// 新 `0.016 / 32ms`（16ms × 2 拍 × 0.5）→ 同样是 0.5 秒流光/秒。
  static final double _advanceSeconds =
      _beatStepSeconds * _beatsPerAdvance * 0.5;

  /// 是否已挂在共享节拍上（见 [_syncDriver]）。
  bool _driverBound = false;

  /// 拍计数器：每 [_beatsPerAdvance] 拍归零一次。
  ///
  /// 必须与订阅状态同生共死：[PlayerFrameDriver] 是「首订阅者启、末订阅者退」，
  /// 暂停再恢复后定时器是全新的，若不复位会带着上次的余数，恢复首帧多推一帧。
  int _beat = 0;

  /// App 是否退到后台/失去焦点（引擎不产帧，Timer 空转纯属唤醒浪费）。
  bool _lifecycleSuspended = false;

  /// [TickerMode] 是否启用：播放页被不透明路由（MV 页 / 歌曲信息页等）覆盖时
  /// Flutter 会把它关掉，见 [didChangeDependencies]。
  bool _tickerModeEnabled = true;

  /// 入场延迟（400ms）是否已走完。未走完时不订阅共享节拍。
  bool _initialDelayElapsed = false;

  // 默认流光 3 色：中性蓝灰渐变（slate）。
  // 原默认 deepPurple/indigo/teal 在黑白/低饱和封面兜底时呈现刺眼紫色，
  // 改为主流灰蓝系，低调不抢眼，与黑白封面和谐。
  List<Color> _colors = const [
    Color(0xFF4A5568),
    Color(0xFF5A6478),
    Color(0xFF2F3A50),
  ];
  String? _lastArtworkUrl;
  // dispose 标志：用于取消 _extractColors 异步任务，
  // 避免 setState 在 widget 销毁后被调用
  bool _disposed = false;

  /// 提取结果缓存（url → 流光 3 色），跨播放器往返复用。
  ///
  /// 同一封面反复进出播放器时，避免每次重新解码 + PaletteGenerator 分析；
  /// 仅缓存成功结果（失败不缓存，避免临时网络问题导致该封面永远用默认色）。
  static final Map<String, List<Color>> _paletteCache = {};

  /// 进入页面时延迟启动的 Timer（只负责放行 [_initialDelayElapsed]，不驱动帧）。
  ///
  /// 打开播放器的瞬间不立即开始全屏渐变绘制，
  /// 等路由入场动画（~300ms）结束后再流动，避免与入场动画、
  /// 模糊背景首帧叠加导致卡顿。
  Timer? _delayedStartTimer;

  /// 驱动订阅的唯一收口（幂等）。
  ///
  /// 判据四取一与：[widget.isPlaying] && [_tickerModeEnabled]（未被不透明路由覆盖）
  /// && ![_lifecycleSuspended]（App 在前台）&& [_initialDelayElapsed]（入场延迟走完）
  /// && ![_disposed]。
  ///
  /// 订阅/退订时一并复位 [_beat]：共享节拍是「首订启/末订停」，恢复后定时器全新，
  /// 不复位会让恢复首帧多推一帧。
  void _syncDriver() {
    final bool shouldRun = widget.isPlaying &&
        _tickerModeEnabled &&
        !_lifecycleSuspended &&
        _initialDelayElapsed &&
        !_disposed;
    if (shouldRun == _driverBound) return;
    if (shouldRun) {
      PlayerFrameDriver.instance.addListener(_onSharedTick);
    } else {
      PlayerFrameDriver.instance.removeListener(_onSharedTick);
    }
    _driverBound = shouldRun;
    _beat = 0;
  }

  /// 幂等退订（供 [deactivate] / [dispose] 调用）。
  ///
  /// 这两处不能依赖 `mounted` / `_syncDriver` 的判据：此时 State 可能已被移出树，
  /// `widget` 是否还有效并不可靠，直接按 [_driverBound] 标志退订最稳。
  void _unbindDriver() {
    if (!_driverBound) return;
    PlayerFrameDriver.instance.removeListener(_onSharedTick);
    _driverBound = false;
    _beat = 0;
  }

  @override
  void initState() {
    super.initState();
    // 注册生命周期监听：后台时停止定时器，前台时按 isPlaying 决定是否恢复
    WidgetsBinding.instance.addObserver(this);
    // 延迟到入场动画结束后再开跑：进入播放器瞬间避免全屏渐变绘制
    // 与路由入场动画 / 模糊背景首帧叠加导致卡顿。
    // （暂停/恢复等后续状态切换仍由 didUpdateWidget 即时处理）
    _delayedStartTimer = Timer(const Duration(milliseconds: 400), () {
      if (_disposed) return;
      _initialDelayElapsed = true;
      _syncDriver();
    });
    // 延迟到首帧渲染完成后提取颜色：
    // 立即提取会触发封面网络下载 + 图片解码 + PaletteGenerator 分析，
    // 与路由入场动画 / 首帧构建抢资源，导致点击 MiniPlayer 展开时卡顿。
    // 切歌时的提取仍在 didUpdateWidget 中立即触发（页面已稳定，无此问题）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_disposed) _extractColors();
    });
  }

  /// 共享 `Timer` 不受 `TickerMode` 约束（§10.3），必须自行同步挂起，
  /// 否则「组件不可见仍持续产帧」——本仓最常见的漏电点（§10.4.3）。
  ///
  /// 覆盖场景：播放页被 **不透明** 路由压住时，`Overlay` 会给下层条目传
  /// `tickerEnabled: false`（Flutter `widgets/overlay.dart` 中
  /// `_theatre` 计算 + `_OverlayEntryWidget` 包 `TickerMode`），
  /// 所以 push 出 MV 页 / 歌曲信息页时这里立刻变 false → 解绑驱动。
  ///
  /// 非不透明路由（对话框、底部弹窗）不会关闭 `TickerMode`，此时继续运行 ——
  /// 页面仍部分可见，可接受。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool enabled = TickerMode.valuesOf(context).enabled;
    if (enabled == _tickerModeEnabled) return;
    _tickerModeEnabled = enabled;
    _syncDriver();
  }

  @override
  void didUpdateWidget(covariant FlowingBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artworkUrl != widget.artworkUrl) {
      _extractColors();
    }
    // 播放状态变化时重新判定是否订阅共享节拍（_syncDriver 内部做幂等保护）
    if (oldWidget.isPlaying != widget.isPlaying) {
      _syncDriver();
    }
  }

  /// 响应 App 生命周期：后台时停止定时器节省功耗。
  ///
  /// 不依赖 Flutter TickerMode 的原因：部分 Android ROM 在后台仍触发 vsync，
  /// 导致 Ticker 持续运行。显式停止定时器可确保后台零功耗。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final bool suspended = state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached;
    if (suspended == _lifecycleSuspended) return;
    _lifecycleSuspended = suspended;
    _syncDriver();
  }

  /// widget 从树中移除时（如路由收起）立即解绑驱动。
  ///
  /// 关键修复：路由 dismiss 时 removeRoute 会触发子树 deactivate，
  /// 若仍在持续触发 setState，子树会保持 dirty 状态，
  /// 导致 InheritedElement.debugDeactivated 中的
  /// `_dependents.isEmpty` 断言失败（dependent 还未清理）。
  /// 在 deactivate 中提前停止可避免此竞态。
  @override
  void deactivate() {
    _delayedStartTimer?.cancel();
    _unbindDriver();
    super.deactivate();
  }

  /// 共享节拍回调：每 [_beatsPerAdvance] 拍推进一次流光时间（30fps 档）。
  void _onSharedTick() {
    // 防御性检查：State 已销毁时跳过
    if (_disposed) return;
    if (++_beat < _beatsPerAdvance) return;
    _beat = 0;
    // 不需要 setState：CustomPainter 通过 _timeNotifier 自动重绘
    _timeNotifier.value += _advanceSeconds;
  }

  Future<void> _extractColors() async {
    final url = widget.artworkUrl;
    if (url == null || url.isEmpty) return;
    if (_lastArtworkUrl == url) return;
    _lastArtworkUrl = url;

    // 跨播放器往返缓存命中：直接复用上次提取的 3 色，跳过解码 + 分析
    final cachedColors = _paletteCache[url];
    if (cachedColors != null) {
      if (mounted && !_disposed) {
        setState(() {
          _colors = cachedColors;
        });
      }
      return;
    }

    try {
      // 统一走 ArtworkColorExtractor.loadPalette：兼容 http(s) 网络封面与
      // local:// / content:// / file:// 本地封面。此前只有网络分支，本地音乐
      // （content:// / local://）与云盘歌曲（内嵌封面回填 file://）取色全部
      // 失败，永远停留在默认靛蓝+青绿兜底色，导致流光画面发青发蓝。
      // 网络封面经 CachedNetworkImageProvider 与 UI 封面共用磁盘缓存，
      // 避免流光开启时每次进播放器都重新下载封面。
      final palette = await ArtworkColorExtractor.loadPalette(url);
      // 双重检查：mounted（widget 还在树中）+ _disposed（State 未销毁）
      if (palette == null || !mounted || _disposed) return;

      // 有效候选色：palette.colors 按像素占比降序排列，
      // 过滤掉近黑、近白、低饱和的灰色，避免稀释色彩层次
      final candidates = palette.colors.where((c) {
        final hsl = HSLColor.fromColor(c);
        return hsl.saturation >= 0.15 &&
            hsl.lightness > 0.1 &&
            hsl.lightness < 0.92;
      }).toList();

      // 按色相多样性挑选 3 色：主色取占比最高的颜色，
      // 其余尽量与已选色相拉开距离，保证冷暖对比、避免整体偏蓝绿
      final picked = _pickDiverseColors(candidates);
      if (picked.isEmpty) {
        // 黑白/低饱和封面兜底：用中性蓝灰（slate），不再用刺眼的紫色。
        picked.add(const Color(0xFF4A5568));
      }

      // 候选不足 3 个时由主色派生补足（同色相、逐级压暗），不再回退固定色
      while (picked.length < 3) {
        final base = HSLColor.fromColor(picked.first);
        picked.add(base
            .withLightness(math.max(0.25, base.lightness - 0.3 * picked.length))
            .toColor());
      }
      // 按亮度降序排列：[最亮主色, 中间强调色, 最深暗部]，
      // 与三层径向渐变的绘制角色（主色/强调/深色）一一对应
      picked.sort((a, b) =>
          HSLColor.fromColor(b).lightness.compareTo(HSLColor.fromColor(a).lightness));
      // 饱和度温和归一化：低饱和封面保持灰调（不强制提饱和，避免黑白封面
      // 被拉到高饱和而变成刺眼的紫/怪色），过高则收敛避免刺眼。
      final normalized = picked
          .map((c) => HSLColor.fromColor(c)
              .withSaturation(HSLColor.fromColor(c).saturation.clamp(0.25, 0.85).toDouble())
              .toColor())
          .toList();
      // 缓存成功结果，供播放器往返时复用
      _paletteCache[url] = normalized;
      setState(() {
        _colors = normalized;
      });
    } catch (_) {}
  }

  /// 按色相多样性贪心挑选流光背景色。
  ///
  /// 第一个取像素占比最高的颜色作为主色，之后每轮挑选与已选颜色
  /// 最小色相距离最大的颜色，确保暖冷色共存，避免背景整体偏向
  /// 单一色调（如原实现回退固定蓝绿色导致画面发青）。
  List<Color> _pickDiverseColors(List<Color> candidates) {
    if (candidates.isEmpty) return <Color>[];
    final picked = <Color>[];
    final pool = List<Color>.of(candidates);
    picked.add(pool.removeAt(0));
    while (picked.length < 3 && pool.isNotEmpty) {
      Color best = pool.first;
      var bestScore = -1.0;
      for (final c in pool) {
        final hslC = HSLColor.fromColor(c);
        // 与所有已选颜色的最小色相距离（0~1，越大差异越明显）
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

  /// 两个 HSL 颜色的色相圆距（0~1，0 表示同色相，1 表示相差 180°）。
  double _hueDistance(HSLColor a, HSLColor b) {
    final diff = (a.hue - b.hue).abs() % 360;
    return math.min(diff, 360 - diff) / 180;
  }

  @override
  void dispose() {
    _disposed = true;
    _delayedStartTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _unbindDriver(); // 幂等解绑（deactivate 已解绑过则直接 return）
    _timeNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // 静态基底：整屏不透明对角线性渐变（深→中）。
        // 拆成独立 RepaintBoundary：它每个 tick 都不变，单独缓存栅格结果后，
        // 每帧只需重绘下面那个只含 3 层光斑的边界（全屏 pass 4 → 3，栅格 −25%）。
        RepaintBoundary(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  _colors[2], // colors[2] 最深
                  _colors[1], // colors[1] 中间
                ],
              ),
            ),
          ),
        ),
        // 动态层：3 层光斑，每 2 拍（≈30fps）重绘一次。
        // 保留外层 RepaintBoundary 隔离，避免整页 setState 连坐本层重绘。
        RepaintBoundary(
          child: CustomPaint(
            painter: _FlowingGradientPainter(
              colors: _colors,
              timeNotifier: _timeNotifier,
            ),
            size: Size.infinite,
          ),
        ),
      ],
    );
  }
}

/// 流光渐变绘制器（只画 3 层光斑；不透明基底见 `FlowingBackground.build`）。
///
/// 3 层径向渐变叠加，每层中心点随时间偏移，模拟色彩流动。
class _FlowingGradientPainter extends CustomPainter {
  final List<Color> colors;
  final ValueNotifier<double> timeNotifier;

  /// 每层一个常驻 Paint。
  ///
  /// 原实现每帧 `Paint() + RadialGradient() + createShader()`，30fps 下 ≈120 个
  /// 对象/秒、且每帧让 Impeller 重建渐变 effect / uniform buffer，全属零收益开销。
  /// 现在 shader 只在 `(size, colors)` 变化时重建一次（见 [_ensureShaders]），
  /// 每帧只剩 save/translate/drawRect/restore —— **零分配**。
  final Paint _paint1 = Paint();
  final Paint _paint2 = Paint();
  final Paint _paint3 = Paint();

  /// shader 缓存键：只在 size 与 colors 同时未变时复用上次的 shader。
  Size? _cachedSize;
  List<Color>? _cachedColors;

  _FlowingGradientPainter({
    required this.colors,
    required this.timeNotifier,
  }) : super(repaint: timeNotifier);

  /// 3 层光斑的半径 / 中心 alpha（与原实现逐字一致，勿"优化"）。
  static const double _radius1 = 1.4;
  static const double _radius2 = 1.2;
  static const double _radius3 = 1.1;
  static const int _alpha1 = 235;
  static const int _alpha2 = 220;
  static const int _alpha3 = 205;

  @override
  void paint(Canvas canvas, Size size) {
    if (colors.isEmpty) return;

    // 从 ValueNotifier 读取当前时间（由 _onSharedTick 每 2 拍更新一次）
    final time = timeNotifier.value;

    _ensureShaders(size);

    final double hw = size.width / 2;
    final double hh = size.height / 2;

    // 层 1：主色，大幅慢速流动
    _paintLayer(
      canvas,
      size,
      _paint1,
      (2 * (0.3 + 0.3 * math.sin(time)) - 1) * hw,
      (2 * (0.3 + 0.3 * math.cos(time * 1.4)) - 1) * hh,
    );

    // 层 2：强调色，中速流动
    _paintLayer(
      canvas,
      size,
      _paint2,
      (2 * (0.7 + 0.25 * math.cos(time * 0.8)) - 1) * hw,
      (2 * (0.6 + 0.25 * math.sin(time)) - 1) * hh,
    );

    // 层 3：深色，快速流动
    _paintLayer(
      canvas,
      size,
      _paint3,
      (2 * (0.5 + 0.2 * math.sin(time * 1.2 + 1.0)) - 1) * hw,
      (2 * (0.8 + 0.2 * math.cos(time * 1.1 + 1.0)) - 1) * hh,
    );
  }

  /// 仅在 `(size, colors)` 变化时重建 3 个 shader。
  ///
  /// shader 建在**屏幕矩形**上、中心固定 [Alignment.center]，光斑的位置改由
  /// 每帧画布平移实现。这与原实现**逐像素等价**：
  /// - 原：shader 建在屏幕矩形上，中心 = `(w/2 + ax*w/2, h/2 + ay*h/2)`；
  /// - 新：shader 建在同一矩形、中心 `(w/2, h/2)`，再加 `translate(ax*w/2, ay*h/2)`；
  /// 屏幕点 `(sx, sy)` 采样到的都是到 `|(sx-dx, sy-dy) - (w/2, h/2)|` 的距离，
  /// 且 `radius × rect.shortestSide` 两者一致（同一矩形）→ 结果完全相同。
  /// 采样点可以落在 shader 矩形之外：径向渐变的 t 只取决于到中心的距离，
  /// 与采样点的位置无关（TileMode 默认 clamp，半径外一律取末端 alpha=0 的透明色）。
  void _ensureShaders(Size size) {
    if (_cachedSize == size && listEquals(_cachedColors, colors)) return;
    _cachedSize = size;
    _cachedColors = List<Color>.of(colors);
    final Rect screen = Offset.zero & size;
    _paint1.shader = _buildBlobShader(screen, colors[0], _radius1, _alpha1);
    _paint2.shader = _buildBlobShader(screen, colors[1], _radius2, _alpha2);
    _paint3.shader = _buildBlobShader(screen, colors[2], _radius3, _alpha3);
  }

  /// 居中的径向光斑渐变（中心固定在屏幕中心，位置靠画布平移）。
  Shader _buildBlobShader(Rect screen, Color color, double radius, int alpha) {
    return RadialGradient(
      center: Alignment.center,
      radius: radius,
      colors: [
        color.withAlpha(alpha),
        color.withAlpha(0),
      ],
      stops: const [0.0, 1.0],
    ).createShader(screen);
  }

  /// 把已建好 shader 的光斑画到 (dx, dy) 偏移处：save/translate/draw/restore。
  ///
  /// 绘制矩形取**恰好铺满整屏**的那个：画布已按 (dx,dy) 平移，局部矩形 R 的
  /// 实际覆盖区是 `R + (dx,dy)`，令其等于屏幕矩形 `(0,0,w,h)` 即
  /// `R = (0,0,w,h).shift(-(dx,dy))`。这样每帧绘制面积恒为 **1× 屏面**——
  /// 既不漏画（外扩法会画到 ~3.9× 屏面、多一遍无效填充），也无需任何缓存字段。
  void _paintLayer(
      Canvas canvas, Size size, Paint paint, double dx, double dy) {
    canvas.save();
    canvas.translate(dx, dy);
    canvas.drawRect(
        Rect.fromLTWH(-dx, -dy, size.width, size.height), paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _FlowingGradientPainter oldDelegate) {
    // time 变化由 Listenable (super(repaint: timeNotifier)) 自动驱动重绘，
    // 这里只需检查 colors 是否变化以触发 painter 重建（_extractColors 后）
    // 用 listEquals 避免逐元素比较的样板代码
    return !listEquals(colors, oldDelegate.colors);
  }
}