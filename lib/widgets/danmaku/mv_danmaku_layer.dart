import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';
import 'package:video_player/video_player.dart';

import '../../core/danmaku/danmaku_buckets.dart';
import '../../core/danmaku/danmaku_clock.dart';
import '../../core/danmaku/danmaku_entry.dart';
import '../../core/danmaku/danmaku_render_mapping.dart';

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

  /// 渲染器就绪 / 重建时回调，供页面直接投递「自己刚发送」的弹幕。
  /// **build 期间回调：只允许赋值，禁止 setState / addDanmaku。**
  final ValueChanged<DanmakuController<String>>? onControllerCreated;

  const MvDanmakuLayer({
    super.key,
    required this.controller,
    required this.entries,
    required this.enabled,
    this.opacity = 1.0,
    this.onControllerCreated,
  });

  @override
  State<MvDanmakuLayer> createState() => _MvDanmakuLayerState();
}

class _MvDanmakuLayerState extends State<MvDanmakuLayer>
    with SingleTickerProviderStateMixin {
  /// 显示区域/描边在 V1 内固定。`DanmakuOption` 每次变动都会销毁渲染缓存并重建，
  /// 必须用 const 实例，避免父级 setState 反复触发缓存重建。
  static const DanmakuOption _option = DanmakuOption(
    area: 0.75,
    safeArea: true,
    // MV 无字幕轨，保留底部安全区仅用于避开 Chewie 控件栏
    strokeWidth: 1.5,
  );

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
    if (widget.enabled) _ticker.start();
  }

  @override
  void didUpdateWidget(covariant MvDanmakuLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
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
    if (oldWidget.enabled != widget.enabled) {
      if (widget.enabled) {
        if (!_ticker.isActive) _ticker.start();
      } else {
        if (_ticker.isActive) _ticker.stop();
        _renderController?.clear();
      }
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

  /// 播放器周期刷新（500ms）到点：刷新外推基准。
  void _onPlayerTick() {
    final v = widget.controller.value;
    if (!v.isInitialized) return;
    if (v.position != _samplePosition) {
      _samplePosition = v.position;
      _sampleElapsed = _clock.elapsed;
      _sampled = true;
    }
  }

  /// 每帧推进：外推位置 → 桶投递 → 同步播放/暂停。
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
    if (!v.isPlaying || v.isBuffering) {
      if (controller.isRunning()) controller.pause();
      return;
    }
    if (!controller.isRunning()) controller.resume();
    for (final entry in result.due) {
      controller.addDanmaku(toContentItem(entry));
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
