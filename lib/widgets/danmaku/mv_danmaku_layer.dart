import 'dart:math';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';
import 'package:video_player/video_player.dart';

import '../../core/danmaku/danmaku_buckets.dart';
import '../../core/danmaku/danmaku_clock.dart';
import '../../core/danmaku/danmaku_entry.dart';
import '../../core/danmaku/danmaku_render_mapping.dart';
import 'scroll_danmaku_layer.dart' show kDanmakuRandomPalette;

/// MV 弹幕渲染层（PiliPlus `PlDanmaku` 模式）：
/// 把 [entries] 按 [controller] 的播放位置弹到视频上方。
///
/// 与 PiliPlus 的差异（不可照抄的环节）：其 position 来自 media_kit 高频
/// position stream；本项目 `video_player` 的 position 只有 500ms 粒度，
/// 必须用 [Ticker] + `estimatePosition` 墙钟外推。
class MvDanmakuLayer extends StatefulWidget {
  /// 当前视频控制器。切换清晰度会换实例，页面须给本 widget 传 `ObjectKey(controller)` 触发重建。
  final VideoPlayerController controller;

  /// 该视频的全部弹幕（页面只在加载完成时替换一次；**发送新弹幕不要改这个列表**）。
  final List<DanmakuEntry> entries;

  /// 弹幕总开关。关闭时不渲染 DanmakuScreen、停掉 Ticker 并清空渲染器。
  final bool enabled;

  /// 弹幕总透明度（0.1-1.0），经 [AnimatedOpacity] 生效，不触碰渲染缓存。
  final double opacity;

  /// v54：速度倍率（0.5~2.0，1.0=默认 10s 飞行时长；倍率越大 duration 越短
  /// 越快）。变更会重建渲染缓存（设置页低频操作，可接受）。
  final double speedScale;

  /// v54：全局颜色覆盖（null=跟随弹幕池 entry.color）。
  final Color? overrideColor;

  /// v54：随机颜色——每条从 [kDanmakuRandomPalette] 随机取色（优先于
  /// [overrideColor]，与歌曲弹幕同调色板同口径）。
  final bool randomColor;

  /// 渲染器就绪 / 重建时回调，供页面直接投递「自己刚发送」的弹幕。
  /// **build 期间回调：只允许赋值，禁止 setState / addDanmaku。**
  final ValueChanged<DanmakuController<String>>? onControllerCreated;

  const MvDanmakuLayer({
    super.key,
    required this.controller,
    required this.entries,
    required this.enabled,
    this.opacity = 1.0,
    this.speedScale = 1.0,
    this.overrideColor,
    this.randomColor = false,
    this.onControllerCreated,
  });

  @override
  State<MvDanmakuLayer> createState() => _MvDanmakuLayerState();
}

class _MvDanmakuLayerState extends State<MvDanmakuLayer>
    with SingleTickerProviderStateMixin {
  /// 显示区域/描边在 V1 内固定。`DanmakuOption` 每次变动都会销毁渲染缓存并重建，
  /// v54 起速度经 [DanmakuOption.duration] 表达：按 [MvDanmakuLayer.speedScale]
  /// 构建一次并缓存，只在倍率变化时重建（设置页低频，可接受）。
  static DanmakuOption _optionFor(double scale) => DanmakuOption(
        area: 0.75,
        safeArea: true,
        // MV 无字幕轨，保留底部安全区仅用于避开 Chewie 控件栏
        strokeWidth: 1.5,
        duration: (10 / scale).clamp(2.5, 20.0),
      );

  late DanmakuOption _option = _optionFor(widget.speedScale);

  /// v54：随机取色器（randomColor 模式，与歌曲弹幕同调色板）。
  final Random _random = Random();

  /// v54：本条弹幕的最终覆盖色（null=跟随弹幕池）。
  Color? _colorFor(DanmakuEntry entry) => widget.randomColor
      ? kDanmakuRandomPalette[_random.nextInt(kDanmakuRandomPalette.length)]
      : widget.overrideColor;

  late final Ticker _ticker;
  DanmakuController<String>? _renderController;
  DanmakuBuckets? _timeline;

  /// 单调时钟（v1 复查修正）：DateTime.now() 会被 NTP 同步/手动改时间打断，
  /// 造成外推跳变并被误判为回退 seek。
  late final Stopwatch _clock = Stopwatch()..start();

  /// 最近一次从播放器采样到的位置及其采样时刻，用于外推。
  Duration _samplePosition = Duration.zero;
  Duration _sampleElapsed = Duration.zero;

  /// 是否已完成过至少一次 position 采样。**未采样前严禁 feed**：
  /// 否则 `elapsed - 0` 是进程启动以来的巨大时长，会被当成播放位置。
  bool _sampled = false;

  @override
  void initState() {
    super.initState();
    _rebuildTimeline();
    widget.controller.addListener(_onPlayerTick);
    _ticker = createTicker(_onFrame);
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant MvDanmakuLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.speedScale != widget.speedScale) {
      _option = _optionFor(widget.speedScale);
    }
    if (!identical(oldWidget.entries, widget.entries)) {
      _rebuildTimeline();
    }
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onPlayerTick);
      widget.controller.addListener(_onPlayerTick);
      _samplePosition = Duration.zero;
      _sampleElapsed = Duration.zero;
      _sampled = false;
    }
    if (oldWidget.enabled != widget.enabled ||
        !identical(oldWidget.controller, widget.controller)) {
      if (!widget.enabled) _renderController?.clear();
      _syncTicker();
    }
  }

  /// 唯一收口：仅在「开启 + 已采样 + 真正在播（非缓冲）」时跑帧。
  ///
  /// 原实现只要 `enabled` 就常驻跑，暂停/缓冲只在 [_onFrame] 里早退 —— 早退
  /// 省不掉 Ticker 每 vsync 的 `scheduleFrame`（§10.4.6）。顺带把渲染器的
  /// 跑/停从 [_onFrame] 挪到这里：停止外推时一并停掉弹幕滚动，避免暂停期间
  /// 弹幕继续飘。
  void _syncTicker() {
    final v = widget.controller.value;
    final bool shouldRun = widget.enabled &&
        v.isInitialized &&
        v.isPlaying &&
        !v.isBuffering &&
        _sampled;
    if (shouldRun == _ticker.isActive) return;
    if (shouldRun) {
      _ticker.start();
    } else {
      _ticker.stop();
      final controller = _renderController;
      if (controller != null && controller.isRunning()) controller.pause();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onPlayerTick);
    _ticker.dispose();
    super.dispose();
  }

  void _rebuildTimeline() {
    _timeline = DanmakuBuckets(widget.entries);
  }

  /// 播放器周期刷新（500ms）到点：刷新外推基准，并按播放态起停帧驱动。
  void _onPlayerTick() {
    final v = widget.controller.value;
    if (!v.isInitialized) return;
    if (v.position != _samplePosition) {
      _samplePosition = v.position;
      _sampleElapsed = _clock.elapsed;
      _sampled = true;
    }
    _syncTicker();
  }

  /// 每帧推进：外推位置 → 桶投递 → 同步播放/暂停。
  ///
  /// 只在 [Ticker] 运行时被调用，而 [_syncTicker] 已把「播放中且非缓冲」作为
  /// 跑帧条件；这里仍保留一次防御性判断（控制器状态可能晚一拍到达）。
  void _onFrame(Duration _) {
    if (!widget.enabled || !_sampled) return;
    final controller = _renderController;
    final timeline = _timeline;
    if (controller == null || timeline == null) return;

    final v = widget.controller.value;
    if (!v.isInitialized) return;

    // 缓冲期 isPlaying 仍为 true 而 position 冻结，继续外推会让弹幕
    // 相对画面提前出现 → 缓冲期按暂停处理。
    final position = estimatePosition(
      base: _samplePosition,
      wallClock: _clock.elapsed,
      sampleClock: _sampleElapsed,
      isPlaying: v.isPlaying && !v.isBuffering,
    );

    final result = timeline.feed(position);
    if (result.reset) {
      // 真 seek（回退超过 DanmakuBuckets.backwardTolerance）：清屏重放。
      // 若真机日志中频繁出现本行，说明容差偏小、抖动被误判为 seek。
      debugPrint('[MvDanmaku] 时间轴回退（判定为 seek），清屏');
      controller.clear();
    }
    if (!v.isPlaying || v.isBuffering) return;
    // 渲染器可能在本层开始播放之后才创建（build 期间回调），此处幂等自愈
    if (!controller.isRunning()) controller.resume();
    for (final entry in result.due) {
      controller.addDanmaku(toContentItem(entry,
          overrideColor: _colorFor(entry)));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      return const SizedBox.shrink();
    }
    // PiliPlus 模式（其 lib/pages/danmaku/view.dart:174-188）：
    // AnimatedOpacity 管总透明度，opacity==0 时 Flutter 跳过子树绘制，
    // 且不触碰 DanmakuOption 渲染缓存。
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: widget.opacity.clamp(0.0, 1.0),
        duration: const Duration(milliseconds: 100),
        child: DanmakuScreen<String>(
          createdController: (e) {
            _renderController = e;
            widget.onControllerCreated?.call(e);
          },
          option: _option,
        ),
      ),
    );
  }
}
