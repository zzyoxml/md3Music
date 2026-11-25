import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'distortion_wave_style.dart';
import 'wave_stage.dart';

/// 页面内的一次性扭曲波：切换前抓到的那一帧压在页面上，波前从 [source] 扩散，
/// 扫过处露出下面**已经切好的**新状态。
///
/// 正向（进）：[image] 是切之前的源屏，走 content 镜片在波前前方扭曲；新状态实时
/// 画在底下（[revealedLive]）。
///
/// [reverse] 为 true（退，回缩）：[image]（切之前的源屏）走 content 镜片压在
/// 波前**后方**，随波前收拢缩进源头、尾段淡出；覆盖层其余部分透明，底下**实时的**
/// 新页面直接透出（歌词/流光全程不被冻结）。时长用 `duration / returnSpeed`，
/// 进度走回程缓动。源点应是**回缩完成后**封面所在的矩形（目的屏坐标），
/// 不是触发时刻的。
///
/// 用在同一个页面里的状态切换（长按封面进 Zen 这类）：这种切换没有路由，也就没有
/// 「上一页」可截 —— 所以由调用方在切换状态**之前**自己截一帧传进来，本组件只负责
/// 演出与收尾。
///
/// [image] 归本组件所有：被换掉或 [WaveReveal] 出栈时释放。
/// 整段过场 [IgnorePointer]，触摸直接落到下面那一页（新状态本来就是可交互的）。
class WaveReveal extends StatefulWidget {
  const WaveReveal({
    super.key,
    required this.image,
    required this.onDone,
    this.source,
    this.style,
    this.reverse = false,
  });

  /// 切换前的那一帧（调用方用 `RenderRepaintBoundary.toImageSync` 抓）。
  final ui.Image image;

  /// 演完（含边缘色与细线）时回调，调用方据此把本组件摘掉。
  final VoidCallback onDone;

  /// 波从哪个框出发（屏幕坐标）；null 用类型默认值（屏幕正中一个 64 的圆）。
  /// 反向时这是**回缩的终点**（目的屏坐标）。
  final Rect? source;

  /// null 用 [DistortionWaveStyle.screenCenter]。
  final DistortionWaveStyle? style;

  /// 反向回缩（见类注释）：退出 Zen 这类「往回收」的切换用它。
  final bool reverse;

  /// 提前加载着色器（播放页 initState 调一次），第一次长按就不退成直接切换。
  static Future<void> precache() => WavePrograms.load();

  @override
  State<WaveReveal> createState() => _WaveRevealState();
}

class _WaveRevealState extends State<WaveReveal> with SingleTickerProviderStateMixin {
  late final DistortionWaveStyle _style = widget.style ?? DistortionWaveStyle.screenCenter;
  late final AnimationController _controller = AnimationController(vsync: this);

  /// 反向时给 [WaveStage] 的进度视图：控制器 0→1 正跑，舞台看到的进度按
  /// 「波前行程随时间**匀速**回撤」反解（见 [reverseStageProgress]）—— 画面
  /// 变化铺满整个光效时长，而不是被两层缓动压进前 1/4。
  late final Animation<double> _stageProgress = widget.reverse
      ? _ReverseProgress(_controller, _style)
      : _controller;

  /// 系统要求减少动画 / 着色器还没就绪：不演波，直接把新状态露出来。
  var _skipped = false;

  /// 只起跑一次。起跑要读 MediaQuery，那在 initState 里还不允许。
  var _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduced || WavePrograms.ready == null) {
      // 着色器没就绪时也不硬演：宁可一次干净的直接切换，也不要半截淡入淡出。
      _skipped = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onDone();
      });
      return;
    }
    // 反向（回缩）用回程时长：duration / returnSpeed，与刷刷路由的退出一致。
    final seconds = widget.reverse
        ? _style.duration / _style.returnSpeed
        : _style.duration;
    _controller
      ..duration = Duration(microseconds: (seconds * Duration.microsecondsPerSecond).round())
      ..forward().whenCompleteOrCancel(() {
        if (mounted) widget.onDone();
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    widget.image.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_skipped) return const SizedBox.shrink();
    return IgnorePointer(
      child: WaveStage(
        progress: _stageProgress,
        style: _style,
        palette: _style.paletteFor(Theme.of(context).colorScheme),
        programs: WavePrograms.ready,
        pixelRatio: MediaQuery.devicePixelRatioOf(context),
        source: widget.source,
        // 两个方向都是：旧帧走 content 镜片（正向压在波前前方=外侧，反向压在
        // 波前后方=内侧），revealed 槽留空 —— 覆盖层其余部分透明，底下实时的
        // 新页面直接透出来（歌词/流光不被冻结）。
        contentImage: widget.image,
        revealed: const SizedBox.shrink(),
        revealedLive: true,
        reverse: widget.reverse,
      ),
    );
  }
}

/// 反向回缩的舞台进度映射（回归测试锚点）：τ 为控制器值（0→1 正跑）。
///
/// p = 1 − easing(τ)：τ=0 → p=1（波前在屏幕外，源屏定格满屏）；τ=1 → p=0
/// （波前收进源头）。路由层与 `WaveFront` 内部各过一遍缓动，行程前段快后段慢
/// —— 匀速版（easing⁻¹ 反解）试过，观感生硬，已按用户要求撤掉。
@visibleForTesting
double reverseStageProgress(double tau, DistortionWaveStyle style) {
  final t = tau.clamp(0.0, 1.0);
  return 1.0 - style.easing(t);
}

/// 把父动画按回程缓动倒过来的只读视图。监听者原样转发 —— [WaveStage] 只读
/// value 并把本对象当 Listenable 用。
class _ReverseProgress extends Animation<double> {
  _ReverseProgress(this._parent, this._style);

  final Animation<double> _parent;
  final DistortionWaveStyle _style;

  @override
  double get value => reverseStageProgress(_parent.value, _style);

  @override
  AnimationStatus get status => switch (_parent.status) {
    AnimationStatus.dismissed => AnimationStatus.completed,
    AnimationStatus.completed => AnimationStatus.dismissed,
    AnimationStatus.forward => AnimationStatus.reverse,
    AnimationStatus.reverse => AnimationStatus.forward,
  };

  @override
  void addListener(VoidCallback listener) => _parent.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _parent.removeListener(listener);

  @override
  void addStatusListener(AnimationStatusListener listener) =>
      _parent.addStatusListener(listener);

  @override
  void removeStatusListener(AnimationStatusListener listener) =>
      _parent.removeStatusListener(listener);
}
