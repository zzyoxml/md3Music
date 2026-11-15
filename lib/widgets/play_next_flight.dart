import 'dart:async';
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:material_ui/material_ui.dart';

import 'smart_artwork_image.dart';

/// 「下一首播放」封面跳水动画（菜单头收缩成正圆 → 弧线俯冲 → 落到迷你条展开淡出）。
///
/// 组成：
/// - [PlayNextFlightController]：全局单例飞行状态，由歌曲行菜单触发；
/// - `PlayNextFlightLayer`（Task 2 追加）：挂在 `app.dart` 顶层 Stack
///   （PlayerCoverMorphLayer 之后）的绘制层，与 PlayerCoverMorphBus.miniRect
///   同处设计像素空间；
/// - 动画本体 `_FlightBallView`（Task 2 追加）：0.5s 贝塞尔俯冲（easeInQuad
///   加速，类自由落体）+ 0.3s 展开淡出。
///
/// 帧率约定（AGENTS §10）：这是用户点击触发的**一次性**交互动画（同路由转场
/// 档位），AnimationController 满帧驱动；动画结束即销毁，无常驻占用。
/// 顶层的 `Listenable.merge` 在本仓已实测两次不重建（见
/// player_cover_morph_layer.dart 头注释），本文件一律用嵌套 AnimatedBuilder。

/// 一次飞行的全部输入（设计像素矩形，来源见各字段注释）。
class PlayNextFlightSpec {
  final String? artworkUri;
  final String? fallbackFilePath;
  final String? songId;

  /// 起点：菜单头收缩成正圆后的屏幕矩形（探针上报，约 32×32）。
  final Rect start;

  /// 终点：MiniPlayer 封面矩形（`PlayerCoverMorphBus.miniRect`，44×44）。
  final Rect target;

  /// 屏幕宽度（设计像素，`MediaQuery.sizeOf` 在 DisplayScaleScope 内即此口径），
  /// 用于把弧线鼓包方向压向屏幕中心一侧。
  final double screenWidth;

  const PlayNextFlightSpec({
    required this.artworkUri,
    required this.fallbackFilePath,
    required this.songId,
    required this.start,
    required this.target,
    required this.screenWidth,
  });
}

/// 跳水俯冲曲线：easeInQuad（t²）—— 初速度 0、匀加速，与自由落体一致。
const Curve playNextDiveCurve = Cubic(0.55, 0.085, 0.68, 0.53);

/// 弧线鼓包幅度：飞行距离的 22%，钳制在 [24, 120] px。
const double _kArcBulgeRatio = 0.22;

/// MiniPlayer 封面圆角（与 mini_player.dart 封面 `ClipRRect(6)` 一致，
/// 展开收尾与真实封面逐像素对齐）。
const double _kTargetCoverRadius = 6.0;

/// 二次贝塞尔弧线：t=0 起点 / t=1 终点。
class PlayNextFlightPath {
  final Offset p0;
  final Offset p1;
  final Offset p2;

  PlayNextFlightPath.fromSpec(PlayNextFlightSpec spec)
      : p0 = spec.start.center,
        p2 = spec.target.center,
        p1 = _controlPoint(spec);

  /// 控制点：起终点中点沿飞行方向法线向**屏幕中心一侧**鼓出。
  static Offset _controlPoint(PlayNextFlightSpec spec) {
    final start = spec.start.center;
    final end = spec.target.center;
    final mid = Offset((start.dx + end.dx) / 2, (start.dy + end.dy) / 2);
    final delta = end - start;
    final dist = delta.distance;
    if (dist < 1.0) return mid;
    final normal = Offset(-delta.dy, delta.dx) / dist;
    final towardCenter = spec.screenWidth / 2 - mid.dx;
    final sign = normal.dx * towardCenter >= 0 ? 1.0 : -1.0;
    final bulge = (dist * _kArcBulgeRatio).clamp(24.0, 120.0);
    return mid + normal * (bulge * sign);
  }

  /// [t] ∈ [0,1] 处的弧线坐标（p0·(1-t)² + p1·2(1-t)t + p2·t²）。
  Offset evaluate(double t) {
    final u = 1.0 - t;
    return p0 * (u * u) + p1 * (2.0 * u * t) + p2 * (t * t);
  }
}

/// 飞行状态登记（全局单例）。
///
/// `spec` 非 null 时绘制层（`PlayNextFlightLayer`，Task 2）显示并驱动动画；
/// 动画结束（落地）或被新飞行顶替时置回 null。同一时刻至多一个飞行——新
/// [launch] 会先完成旧 Future（调用方收尾逻辑照常执行）再顶替。
class PlayNextFlightController {
  PlayNextFlightController._();

  static final PlayNextFlightController instance = PlayNextFlightController._();

  final ValueNotifier<PlayNextFlightSpec?> spec = ValueNotifier(null);

  Completer<void>? _completer;

  /// 启动一次飞行；返回的 Future 在动画结束（落地 / 被顶替）时完成。
  Future<void> launch(PlayNextFlightSpec newSpec) {
    _completer?.complete();
    _completer = Completer<void>();
    spec.value = newSpec;
    return _completer!.future;
  }

  /// 仅供测试隔离使用。
  @visibleForTesting
  void reset() {
    spec.value = null;
    _completer?.complete();
    _completer = null;
  }

  void _finish() {
    spec.value = null;
    _completer?.complete();
    _completer = null;
  }
}

/// 顶层 Stack 绘制层：挂在 `PlayerCoverMorphLayer` **之后**（永远画在最上面，
/// 球要越过菜单/遮罩/迷你条）。`spec` 为 null 时零开销。
class PlayNextFlightLayer extends StatelessWidget {
  const PlayNextFlightLayer({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PlayNextFlightSpec?>(
      valueListenable: PlayNextFlightController.instance.spec,
      builder: (context, spec, _) {
        if (spec == null) return const SizedBox.shrink();
        return Positioned.fill(
          child: IgnorePointer(
            // ValueKey(spec)：spec 无 == 重载、按实例判等——新 launch 必然换 key，
            // 旧视图整体卸载（其中未完成的 controller 随 dispose 销毁），
            // 新视图从 t=0 重新开始，无需任何"接续"逻辑。
            child: _FlightBallView(key: ValueKey<PlayNextFlightSpec>(spec), spec: spec),
          ),
        );
      },
    );
  }
}

class _FlightBallView extends StatefulWidget {
  final PlayNextFlightSpec spec;

  const _FlightBallView({super.key, required this.spec});

  @override
  State<_FlightBallView> createState() => _FlightBallViewState();
}

class _FlightBallViewState extends State<_FlightBallView>
    with TickerProviderStateMixin {
  // 跳水 0.5s（easeIn 加速）→ 展开淡出 0.3s（easeOut 收尾）。规格见文件头。
  late final AnimationController _diveCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  );
  late final AnimationController _expandCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  );
  late final CurvedAnimation _dive =
      CurvedAnimation(parent: _diveCtrl, curve: playNextDiveCurve);
  late final CurvedAnimation _expand =
      CurvedAnimation(parent: _expandCtrl, curve: Curves.easeOutCubic);
  late final CurvedAnimation _fade =
      CurvedAnimation(parent: _expandCtrl, curve: Curves.easeOut);

  late final PlayNextFlightPath _path =
      PlayNextFlightPath.fromSpec(widget.spec);

  /// 84px 解码缓存封面：与菜单头同一 decodeWidth（84·dpr），命中同一份
  /// ImageCache，起飞帧零加载。圆角由外层窗口统一裁剪（圆角在飞行期可插值）。
  late final Widget _ballChild = SmartArtworkImage(
    artworkUri: widget.spec.artworkUri,
    fallbackFilePath: widget.spec.fallbackFilePath,
    songId: widget.spec.songId,
    size: 84,
    borderRadius: 0,
  );

  @override
  void initState() {
    super.initState();
    _diveCtrl.addStatusListener(_onDiveStatus);
    _expandCtrl.addStatusListener(_onExpandStatus);
    _diveCtrl.forward();
  }

  void _onDiveStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) _expandCtrl.forward();
  }

  void _onExpandStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      PlayNextFlightController.instance._finish();
    }
  }

  @override
  void dispose() {
    _diveCtrl.removeStatusListener(_onDiveStatus);
    _expandCtrl.removeStatusListener(_onExpandStatus);
    _dive.dispose();
    _expand.dispose();
    _fade.dispose();
    _diveCtrl.dispose();
    _expandCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scrim = Theme.of(context).colorScheme.scrim;
    return Stack(
      children: [
        // 逐帧只重建这一个子树：位置由俯冲曲线驱动，尺寸/圆角/透明度由展开曲线驱动。
        // 嵌套 AnimatedBuilder 而非 Listenable.merge（本仓实测 merge 不重建，
        // 见 player_cover_morph_layer.dart 头注释）。
        AnimatedBuilder(
          animation: _dive,
          builder: (context, _) {
            // 展开阶段 _dive 恒为 1（Interval 外钳制不存在——这里用双控制器，
            // dive 完成后不再 tick，value 停在 1.0）。
            final center = _path.evaluate(_dive.value);
            return AnimatedBuilder(
              animation: _expandCtrl,
              builder: (context, _) {
                final e = _expand.value;
                final startSize = widget.spec.start.width;
                final targetSize = widget.spec.target.width;
                final size = lerpDouble(startSize, targetSize, e)!;
                final radius =
                    lerpDouble(startSize / 2, _kTargetCoverRadius, e)!;
                final opacity = (1.0 - _fade.value).clamp(0.0, 1.0);
                return Positioned(
                  key: const ValueKey('play_next_flight_ball'),
                  left: center.dx - size / 2,
                  top: center.dy - size / 2,
                  width: size,
                  height: size,
                  child: Opacity(
                    opacity: opacity,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(radius),
                        boxShadow: [
                          BoxShadow(
                            color: scrim.withValues(alpha: 0.24),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(radius),
                        child: FittedBox(child: _ballChild),
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
      ],
    );
  }
}
