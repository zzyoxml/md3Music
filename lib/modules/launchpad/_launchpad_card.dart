import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart' as flutter;
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_dimens.dart';
import '../../providers/theme_provider.dart';

/// LaunchPad 网格卡片：图标 + 名称。
///
/// 长按时播放**封面流同款扭曲波**（只取长按处的一圈小范围，不做整屏过场）。
/// 时间轴（与封面流波同构，收拢 + 扩散两段）：
/// - **按下即起演**（不等系统长按识别，避免“按住没反应”的体感）：
///   前 350ms 出发前收拢——主题色光团聚拢、小白点沿径向往心飞落；
///   随后波前离开图标边缘向外扩散——破口色散弧旋转着甩开、带着光晕和
///   拖尾、高光细线、沿径向往外飞的白色流星，图标先被压扁再鼓起来；
/// - 系统长按识别（约 500ms）+ 父级 1500ms 到点后自动执行动作
///   （隐藏 tab → 启用并切换；已固定 tab → 取消固定），恰好卡在波走完那一刻；
/// - 提前松手（或被滚动等手势接管）→ 波快速回收入源，动作不执行。
///
/// **不依赖 DistortionWave / Fragment Shader / _snapshot**：整套着色器在
/// grid cell 小尺寸下会阻塞主线程（真机表现为无响应），这里纯 Canvas 复现
/// 同一套视觉语言，任意容器尺寸都安全。
class LaunchPadCard extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool hidden;
  final VoidCallback onTap;
  final VoidCallback onLongPressStart;
  final VoidCallback onLongPressEnd;

  const LaunchPadCard({
    super.key,
    required this.icon,
    required this.label,
    required this.hidden,
    required this.onTap,
    required this.onLongPressStart,
    required this.onLongPressEnd,
  });

  @override
  State<LaunchPadCard> createState() => _LaunchPadCardState();
}

class _LaunchPadCardState extends State<LaunchPadCard>
    with SingleTickerProviderStateMixin {
  /// 波整段时长：正好等于「系统长按识别约 500ms + 父级动作定时器 1500ms」，
  /// 波走完的那一刻动作落地。
  static const Duration _waveDuration = Duration(milliseconds: 2000);

  /// 提前松手后的回缩时长。
  static const Duration _retractDuration = Duration(milliseconds: 280);

  /// 波覆盖层边长（图标盘 52 的外围一圈，格子内的小范围）。
  static const double _waveExtent = 84;

  /// 大色块模式「图标盘 + 与标签间隙」的总高基准（52 + 8），按格内可用
  /// 高度反解缩放系数 s 用：矮格里整体收缩，避免「图标 + 标签」列溢出。
  static const double _blockIconSlotHeight = 52 + AppSpacing.sm;

  /// 大色块模式标签预留：单行约 20dp + 余量。
  static const double _blockLabelReserve = 24;

  late final flutter.AnimationController _ctrl;
  /// 手指是否还压在卡片上（Listen 原始指针事件，跟手势竞技场的裁决无关）。
  bool _down = false;

  /// 图标盘 GlobalKey：量图标盘真实尺寸，作为波的半径基准（scale）。
  final flutter.GlobalKey _iconKey = flutter.GlobalKey();
  /// 整卡 GlobalKey：量卡片几何中心作为波锚点——布局是「图标+文字整组居中」，
  /// 图标本身位于格心偏上，若以图标为锚，波整体偏上；用户要波在卡片正中。
  final flutter.GlobalKey _cardKey = flutter.GlobalKey();
  /// Windows 桌面格子大，波可再放大一档（移动端保持原尺寸）。
  static const double _windowsWaveBoost = 1.35;
  /// 全屏波层：画在根 Overlay 上，不受卡片 ClipRRect / 相邻格子遮挡。
  flutter.OverlayEntry? _waveEntry;

  @override
  void initState() {
    super.initState();
    _ctrl = flutter.AnimationController(
      vsync: this,
      duration: _waveDuration,
    )
      ..addListener(() {
        if (mounted) setState(() {}); // 图标按压反馈（lift）需要
      })
      ..addStatusListener((status) {
        // 波走完（正常放完 / 提前松手回缩进源）即撤掉全屏层。
        if (status == flutter.AnimationStatus.completed ||
            status == flutter.AnimationStatus.dismissed) {
          _removeWave();
        }
      });
  }

  @override
  void dispose() {
    _removeWave();
    _ctrl.dispose();
    super.dispose();
  }

  /// 波锚点 = 整卡几何中心（屏幕坐标）；半径基准 = 图标盘实际尺寸 / 52dp。
  /// 锚点与尺度分开：布局是「图标+文字整组居中」，图标偏上，但波要在格心；
  /// 波的圈仍贴着图标大小起步，不至于脱离图标观感。
  ({flutter.Offset center, double scale}) _waveGeometry() {
    final cardCtx = _cardKey.currentContext;
    final cardBox = cardCtx?.findRenderObject() as flutter.RenderBox?;
    final iconCtx = _iconKey.currentContext;
    final iconBox = iconCtx?.findRenderObject() as flutter.RenderBox?;
    if (cardBox == null || !cardBox.attached ||
        iconBox == null || !iconBox.attached) {
      return (center: flutter.Offset.zero, scale: 1.0);
    }
    final boost = Platform.isWindows ? _windowsWaveBoost : 1.0;
    return (
      center: cardBox.localToGlobal(cardBox.size.center(flutter.Offset.zero)),
      scale: iconBox.size.width / 52.0 * boost,
    );
  }

  /// 插入全屏波层：锚点 = 整卡几何中心，画在根 Overlay 最上层。
  void _showWave(flutter.Offset center, double scale) {
    _removeWave();
    final cs = Theme.of(context).colorScheme;
    final hsl = flutter.HSLColor.fromColor(cs.primary);
    final dark = cs.brightness == Brightness.dark;
    Color side(double hue) => flutter.HSLColor.fromAHSL(
          1.0,
          hue,
          hsl.saturation,
          dark
              ? math.min(0.68, hsl.lightness + 0.02)
              : math.max(0.38, hsl.lightness - 0.12),
        ).toColor();
    final left = side((hsl.hue - 42 + 360) % 360);
    final right = side((hsl.hue + 42) % 360);
    final main = cs.primary;

    final entry = flutter.OverlayEntry(
      builder: (ctx) => flutter.Positioned.fill(
        // AnimatedBuilder 只重建这一层 CustomPaint，不触发整页 layout；
        // 波是跟手交互，满帧由 _ctrl 驱动，符合项目帧率分档。
        child: flutter.AnimatedBuilder(
          animation: _ctrl,
          builder: (context, _) => flutter.CustomPaint(
            painter: _DistortionPainter(
              progress: _ctrl.value,
              mainColor: main,
              leftColor: left,
              rightColor: right,
              scale: scale,
              center: center,
            ),
          ),
        ),
      ),
    );
    flutter.Overlay.of(context, rootOverlay: true).insert(entry);
    _waveEntry = entry;
  }

  void _removeWave() {
    _waveEntry?.remove();
    _waveEntry = null;
  }

  /// 按下：波从 0 起演（正在回缩就先掐断重新来）。
  void _press() {
    if (_down) return;
    _down = true;
    _ctrl.stop();
    _ctrl.value = 0;
    _ctrl.duration = _waveDuration;
    final geo = _waveGeometry();
    // 系统要求减少动画时不播装饰性波（动作照常执行）。
    if (!(MediaQuery.maybeDisableAnimationsOf(context) ?? false)) {
      _showWave(geo.center, geo.scale);
    }
    _ctrl.forward();
  }

  /// 松手：满行程时波恰好放完，正好留给动作；若还在半路，快速回缩进源。
  void _lift() {
    if (!_down) return;
    _down = false;
    if (_ctrl.value <= 0.002) {
      _ctrl.stop();
      _removeWave();
      return;
    }
    _ctrl.stop();
    _ctrl.duration = _retractDuration;
    _ctrl.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    // 图标的物理节奏：收拢段被轻轻压扁，扩散段鼓起来浮起（同波的 squash/swell）。
    final p = _ctrl.value.clamp(0.0, 1.0);
    double lift = 1;
    if (p < _gatherRatio) {
      lift = 1 - 0.03 * math.sin(math.pi * _smooth01(p / _gatherRatio));
    } else {
      final x = ((p - _gatherRatio) / (1 - _gatherRatio)).clamp(0.0, 1.0);
      lift = 1 + 0.055 * math.sin(math.pi * x);
    }

    // 全尺寸自适应：按格子实际宽度等比缩放，上限跟随当前格子高度（1.6），
    // 窄屏一格很窄时收敛到 1.0，避免图标溢出格子压到邻居。
    final tp = context.watch<ThemeProvider>();
    final wallpaper = tp.useBackgroundImage;
    // 关自定义壁纸 → 回到最初「大色块」样式：整卡 surfaceContainerLow 实色块、
    // 图标 36 基准 + primary 着色；开壁纸 → 透明浮图标（壁纸透出，图标不垫底盘）。
    final blockMode = !wallpaper;

    // 图标倍数按平台：Android 1.25x、Windows 2x，其余 1x（仅壁纸模式生效）。
    final iconFactor = Platform.isAndroid
        ? 1.25
        : (Platform.isWindows ? 2.0 : 1.0);

    return LayoutBuilder(
      builder: (context, constraints) {
        final s =
            (constraints.maxWidth / _waveExtent).clamp(1.0, 1.35);
        // 大色块模式「图标盘 + 间隙 + 标签」要装进格子内：宽度档上限 1.35 的
        // 整套在安卓竖屏正方形格（≈118dp）会超可用高度（盘≈70+间隙+标签≈101
        // > ≈97）→ Column 溢出。按格内可用高度再收一档 s（矮格整体收敛，
        // Windows 大格仍由宽度档 1.35 决定，不变外观）；壁纸浮层不受此约束。
        final double sBlock;
        if (blockMode) {
          final hBudget = constraints.maxHeight -
              _blockLabelReserve -
              2 * (AppSpacing.sm * 1.35);
          sBlock =
              math.min(s, (hBudget / _blockIconSlotHeight).clamp(0.6, 1.35));
        } else {
          sBlock = s;
        }
        // 图标 + 底盘：先画——波从它上面扫过去，半径基准取自它
        // （锚点是整卡中心，见 _waveGeometry）。
        // 大色块模式：整卡已是实色块，不垫小底盘，图标 36 基准 + primary
        // 着色（一周前最初样式）；壁纸模式：透明底盘，图标直接浮在壁纸上。
        final iconWidget = Transform.scale(
          key: _iconKey,
          scale: lift,
          child: Container(
            width: 52 * sBlock,
            height: 52 * sBlock,
            decoration: BoxDecoration(
              // 大色块模式不垫底盘；壁纸模式也透明。
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(12 * sBlock),
            ),
            child: Center(
              child: Icon(widget.icon,
                  size: blockMode
                      ? 36 * sBlock
                      : 26 * sBlock * iconFactor,
                  color: blockMode
                      ? cs.primary
                      : (widget.hidden
                          ? cs.onSurfaceVariant
                          : cs.onPrimaryContainer)),
            ),
          ),
        );
        return ClipRRect(
          key: _cardKey,
          borderRadius: AppRadius.lgAll,
          child: Material(
            // 大色块模式：整卡实色；壁纸模式：透明（图标浮在壁纸上）。
            color: blockMode ? cs.surfaceContainerLow : Colors.transparent,
            child: Listener(
              // 原始指针事件独立于手势竞技场：按下即起演、松手即回缩，
              // 不受滚动接管 / 长按识别时序影响。
              behavior: HitTestBehavior.opaque,
              onPointerDown: (_) => _press(),
              onPointerUp: (_) => _lift(),
              onPointerCancel: (_) => _lift(),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onTap,
                onLongPressStart: (_) => widget.onLongPressStart(),
                onLongPressEnd: (_) => widget.onLongPressEnd(),
                onLongPressCancel: () => widget.onLongPressEnd(),
                child: Padding(
                  padding: EdgeInsets.all(AppSpacing.sm * sBlock),
                  // 大色块模式：Column 把「图标 + 标签」视作整体居中——
                  // 图标在上、标签在下、整组视觉重心居中（同最初大色块样式；
                  // 此前写死 84*s 的图标槽在安卓矮格里还会溢出）。
                  // 壁纸模式：Stack 叠放——图标在整格正中心、标签沉底不占布局
                  // 高度（浮层观感），全屏波锚定整卡几何中心。
                  child: blockMode
                      ? Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            iconWidget,
                            Gap(AppSpacing.sm * sBlock),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: AppSpacing.xs),
                              child: Text(
                                widget.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                      fontWeight: FontWeight.w600,
                                      color: widget.hidden
                                          ? cs.onSurfaceVariant
                                          : cs.onSurface,
                                    ),
                              ),
                            ),
                          ],
                        )
                      : Stack(
                          alignment: Alignment.center,
                          children: [
                            iconWidget,
                            // 标签沉底：图标不为其让位，格心即图标心（即波心）。
                            Positioned(
                              left: AppSpacing.xs,
                              right: AppSpacing.xs,
                              bottom: 0,
                              child: Text(
                                widget.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                      fontWeight: FontWeight.w600,
                                      color: widget.hidden
                                          ? cs.onSurfaceVariant
                                          : cs.onSurface,
                                    ),
                              ),
                            ),
                            // 波已移到全屏 Overlay（见 _showWave）——
                            // 锚定整卡几何中心、不受卡片裁剪、盖在所有格子之上。
                          ],
                        ),
                ), // Padding
              ), // GestureDetector
            ), // Listener
          ), // Material
        ); // ClipRRect
      },
    ); // LayoutBuilder
  }
}

/// 出发前收拢段占整段时长的比例（350ms / 2000ms，同 center 型波 anticipation 的压缩版）。
const double _gatherRatio = 0.175;
/// 收拢阶段飞向中心的小白点数（对应波的 gatherDots，数量收敛版）。
const int _gatherDotCount = 8;
/// 扩散后沿径向外甩的白点数（对应波的 particleCount，数量收敛版）。
const int _sparkCount = 9;
/// 环半径范围：从图标边缘（盘半径 26）起步，扩到覆盖层边距内的最大一圈。
const double _ringMin = 26.5;
const double _ringMax = 40.0;

double _smooth(double a, double b, double x) {
  if (b <= a) return x >= b ? 1.0 : 0.0;
  final t = ((x - a) / (b - a)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

double _smooth01(double x) => _smooth(0, 1, x);

double _hash(double i, double n, double salt) {
  final x = math.sin(i * 12.9898 + n * 78.233 + salt * 37.719) * 43758.5453;
  return x - x.floorToDouble();
}

/// 与波系统 [DistortionWaveEasing] 同源的缓动：起步猛、收尾慢
/// （cubic-bezier 0.22,1 → 0.36,1）。两个 y 控制点都在 1，y 可直接化简；
/// x 单调，二分求 s 满足 x(s)=t。
double _coverFlowY(double t) {
  var lo = 0.0;
  var hi = 1.0;
  var s = t.clamp(0.0, 1.0);
  for (var i = 0; i < 28; i++) {
    final v =
        3 * (1 - s) * (1 - s) * s * 0.22 +
        3 * (1 - s) * s * s * 0.36 +
        s * s * s;
    if (v < t) {
      lo = s;
    } else {
      hi = s;
    }
    s = (lo + hi) / 2;
  }
  return 3 * s * (1 - s) + s * s * s;
}

/// 扭曲波画笔：在图标周围一圈小范围复现封面流过场——收拢 + 破口色散弧 +
/// 光晕拖尾 + 高光细线 + 径向流星。
class _DistortionPainter extends flutter.CustomPainter {
  final double progress; // 0→1（按下起的线性进度，分段由内部按 [_gatherRatio] 切）
  final Color mainColor; // 主通道（primary）
  final Color leftColor; // 左支色散（主色相 -42°）
  final Color rightColor; // 右支色散（主色相 +42°）
  /// 波锚点：整卡几何中心（全屏 Overlay 坐标系），不是图标中心——布局
  /// 「图标+文字整组居中」时图标偏上，以图标为锚会让整道波偏上。
  final flutter.Offset center;
  /// 展示缩放：图标盘实际尺寸 / 设计基准 52dp（Windows 另有放大系数）。
  /// 波的所有半径按此缩放，让波前贴着图标边缘起步。
  final double scale;

  _DistortionPainter({
    required this.progress,
    required this.mainColor,
    required this.leftColor,
    required this.rightColor,
    required this.scale,
    required this.center,
  });

  @override
  void paint(flutter.Canvas canvas, flutter.Size size) {
    final p = progress.clamp(0.0, 1.0);
    if (p <= 0.001 || p >= 0.999) return;
    // 全屏画布：平移到整卡几何中心后，内部仍用「52dp 图标盘」的设计基准绘制，
    // 整体按 scale 缩放。锚点是格心 → 整道波居中不偏。
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(scale);

    if (p < _gatherRatio) {
      _paintGather(canvas, flutter.Offset.zero, p);
      canvas.restore();
      return;
    }
    _paintFront(canvas, flutter.Offset.zero, p);
    canvas.restore();
  }

  /// 出发前收拢：光团向中心聚拢，白点沿径向往心飞落。
  void _paintGather(flutter.Canvas canvas, flutter.Offset center, double p) {
    final k = _smooth01(p / _gatherRatio);
    final tSec = p * 2.0;

    // 聚拢的光团：一大片柔光收成一个亮点。
    canvas.drawCircle(
      center,
      5.0 + 9.0 * (1 - k),
      Paint()
        ..color = mainColor.withValues(alpha: (k * 0.30).clamp(0.0, 1.0))
        ..maskFilter =
            const flutter.MaskFilter.blur(flutter.BlurStyle.normal, 12),
    );
    // 中心亮核。
    canvas.drawCircle(
      center,
      7.0 - 3.5 * k,
      Paint()
        ..color = Color.fromRGBO(255, 255, 255, (k * 0.55).clamp(0.0, 1.0))
        ..maskFilter =
            const flutter.MaskFilter.blur(flutter.BlurStyle.normal, 5),
    );

    // 白点：每颗以自己的速度往心飞，每一跳里亮起又灭掉，落点随收拢进度收敛。
    for (var i = 0; i < _gatherDotCount; i++) {
      final fi = i.toDouble();
      final angle = _hash(fi, 3, 4) * 2 * math.pi;
      final speed = 2.2 + 2.6 * _hash(fi, 9, 1);
      final phase = _hash(fi, 9, 2) * 2 * math.pi;
      final s = (tSec * speed + phase) % 1;
      final hop = math.sin(s * math.pi);
      final conv = math.min(1, k * 1.15 + 0.1 * _hash(fi, 9, 3));
      final dist = 31 - (31 - 3.5) * conv + 1.5 * math.sin(s * 2 * math.pi + phase);
      final br = 0.4 + 0.6 * _hash(fi, 9, 5);
      final tw = 0.6 + 0.4 * math.sin(tSec * 9 + phase);
      final a = k * hop * br * tw;
      if (a <= 0.02) continue;
      // 流星朝向运动方向（向内）。
      _streak(
        canvas,
        center,
        angle,
        dist,
        3.0,
        1.2,
        Color.fromRGBO(255, 255, 255, a.clamp(0.0, 1.0)),
        inward: true,
      );
    }
  }

  /// 波前离开源：破口色散弧旋转着甩开 + 光晕拖尾 + 高光细线 + 径向流星。
  void _paintFront(flutter.Canvas canvas, flutter.Offset center, double p) {
    final x = ((p - _gatherRatio) / (1 - _gatherRatio)).clamp(0.0, 1.0);
    final moved = _coverFlowY(x);
    final r = _ringMin + (_ringMax - _ringMin) * moved;
    // 环浓度：急起浓，末段淡出（对应波的 rim：急起、linger 后擦掉）。
    final rim = _smooth(0, 0.07, moved) * (1 - _smooth(0.74, 1, moved));
    final tSec = p * 2.0;

    // 外光晕（波前的柔光，跟着环走）。
    canvas.drawCircle(
      center,
      r + 4,
      Paint()
        ..color = mainColor.withValues(
            alpha: ((rim * 0.24) + (1 - moved) * 0.05).clamp(0.0, 1.0))
        ..maskFilter = const flutter.MaskFilter.blur(flutter.BlurStyle.normal, 8),
    );

    // 拖尾两道虚影（模糊副本）：让环有向前甩开的动感，而不是静态圆。
    canvas.drawCircle(
      center,
      r - 6,
      Paint()
        ..style = flutter.PaintingStyle.stroke
        ..strokeWidth = 1.3
        ..color = leftColor.withValues(alpha: (rim * 0.15).clamp(0.0, 1.0)),
    );
    canvas.drawCircle(
      center,
      r - 11,
      Paint()
        ..style = flutter.PaintingStyle.stroke
        ..strokeWidth = 1.1
        ..color = leftColor.withValues(alpha: (rim * 0.09).clamp(0.0, 1.0)),
    );

    // 主弧宽度：中段最鼓，两端收细 —— 对应波的 swell / 弧宽度变化。
    final w = 1.6 + 3.2 * math.sin(moved * math.pi);
    const spans = <double>[2.05, 2.5, 1.7]; // 三段破口弧，弧长错开
    const spins = <double>[-0.6, 0.9, -1.1]; // 各段自转方向/速度不同
    for (var i = 0; i < spans.length; i++) {
      final fi = i.toDouble();
      final span = spans[i];
      final spin = spins[i] * math.min(tSec, 2.4);
      final start = _hash(fi, 5, 1) * 2 * math.pi + spin;
      final tf = 0.72 + 0.45 * _hash(fi, 5, 3); // 每段厚薄不同
      final radius = r + (i - 1) * 1.3; // 半径交错，成层次
      for (final ch in _channels) {
        canvas.save();
        canvas.translate(ch.dx, 0);
        canvas.drawArc(
          Rect.fromCircle(center: center, radius: radius),
          start,
          span,
          false,
          Paint()
            ..style = flutter.PaintingStyle.stroke
            ..strokeWidth = w * tf * ch.widthMul
            ..strokeCap = flutter.StrokeCap.round
            ..color = ch.color.withValues(alpha: (rim * ch.alphaMul * tf).clamp(0.0, 1.0))
            ..maskFilter = ch.blur
                ? flutter.MaskFilter.blur(flutter.BlurStyle.normal, w * 0.45)
                : null,
        );
        canvas.restore();
      }
    }

    // 高光细线：压在颜色环略外侧，波前的高光描边（对应波的 hairline）。
    canvas.drawCircle(
      center,
      r + 1.8,
      Paint()
        ..style = flutter.PaintingStyle.stroke
        ..strokeWidth = 1.05
        ..color = Color.fromRGBO(
            255, 255, 255, (rim * 0.8).clamp(0.0, 1.0)),
    );

    // 流星：贴着波前的快、拖尾的慢，沿径向向外甩，一边闪一边淡。
    for (var j = 0; j < _sparkCount; j++) {
      final fj = j.toDouble();
      final angle = _hash(fj, 7, 1) * 2 * math.pi;
      final pace = 0.45 + 0.55 * _hash(fj, 7, 2);
      final br = 0.3 + 0.7 * _hash(fj, 7, 3);
      final rate = 7 + 10 * _hash(fj, 7, 4);
      final phase = _hash(fj, 7, 5) * 2 * math.pi;
      final wobPhase = _hash(fj, 7, 8) * 6.28;
      final tw = 0.5 + 0.5 * math.sin(tSec * rate + phase);
      final lifeF = 1 - _smooth(0.72, 1, moved);
      final ramp = _smooth(0, 0.12, x);
      final push = 5 * pace * math.max(0, x - 0.15);
      final dist = _ringMin + (r - _ringMin) * pace + push +
          2.0 * math.sin(tSec * 4 + wobPhase) * (1 - pace);
      final a = br * tw * ramp * lifeF;
      if (a <= 0.015) continue;
      _streak(
        canvas,
        center,
        angle,
        dist,
        3.2 + 5 * pace,
        1.1 + 0.7 * pace,
        Color.fromRGBO(255, 255, 255, a.clamp(0.0, 1.0)),
        inward: false,
      );
    }
  }

  /// 一段白色小流星：[angle] 方向上距 [dist] 处、长度 [len]、宽 [width]。
  /// [inward] 为 true 表示朝内飞（收拢段），否则朝外甩（扩散段）。
  void _streak(
    flutter.Canvas canvas,
    flutter.Offset center,
    double angle,
    double dist,
    double len,
    double width,
    Color color,
    {required bool inward}
  ) {
    final d = Offset(math.cos(angle), math.sin(angle)) * (inward ? -1 : 1);
    final mid = center + d * dist;
    canvas.drawLine(
      mid - d * (len / 2),
      mid + d * (len / 2),
      Paint()
        ..strokeWidth = width
        ..strokeCap = flutter.StrokeCap.round
        ..color = color,
    );
  }

  /// 色散三通道：左 / 主 / 右，主通道带发光模糊、侧通道细而锐。
  /// 每帧重建仅三条，开销可忽略。
  List<_Channel> get _channels => [
        _Channel(color: leftColor, dx: -2.2, alphaMul: 0.32, widthMul: 0.7, blur: false),
        _Channel(color: mainColor, dx: 0, alphaMul: 0.95, widthMul: 1.0, blur: true),
        _Channel(color: rightColor, dx: 2.2, alphaMul: 0.32, widthMul: 0.7, blur: false),
      ];

  @override
  bool shouldRepaint(_DistortionPainter old) =>
      old.progress != progress ||
      old.mainColor != mainColor ||
      old.leftColor != leftColor ||
      old.rightColor != rightColor ||
      old.scale != scale ||
      old.center != center;
}

class _Channel {
  final Color color;
  final double dx;
  final double alphaMul;
  final double widthMul;
  final bool blur;

  const _Channel({
    required this.color,
    required this.dx,
    required this.alphaMul,
    required this.widthMul,
    required this.blur,
  });
}