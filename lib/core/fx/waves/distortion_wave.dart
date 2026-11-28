import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import 'distortion_wave_style.dart';
import 'wave_stage.dart';

export 'distortion_wave_style.dart';
export 'wave_stage.dart';

/// 移植自 Libraries.dev Distortion waves（https://github.com/Jakubantalik/Libraries.dev，
/// MIT，Copyright (c) 2026 Jakub Antalik），经 dsh-Go 的 Dart 移植版转写。

/// 系统要求减少动画、或着色器不可用时，波换成这么长的淡入淡出。
const _plainDuration = Duration(milliseconds: 300);

Duration _seconds(double s) => Duration(microseconds: (s * Duration.microsecondsPerSecond).round());

/// 一道彩色的扭曲波：从触发它的源（按钮、屏幕一角、图标）出发，把一屏带进另一屏。
///
/// 先一切往源落一下，带着细小的白点；然后波前离开源，一道柔和的鼓包往外走，经过处
/// 抬起、弯折内容，渐进模糊和色散在波前上最强；颜色留在边缘，贴着一道细线，中间清空
/// 后再擦掉。
///
/// 翻 [isRevealed] 让波出去，翻回来让它收回源。[source] 用本组件自己的坐标。两边
/// 都要有不透明背景。系统要求减少动画时是 0.3 秒的淡入淡出。
///
/// 整个过程约 3.6 秒（竖向默认），但波前一秒左右就扫过屏幕，之后只剩边缘的颜色在
/// 淡出；过程中两边都不接收触摸，结束后 [revealed] 才接收。
class DistortionWave extends StatefulWidget {
  const DistortionWave({
    super.key,
    required this.isRevealed,
    this.source,
    this.focus,
    this.style = DistortionWaveStyle.vertical,
    this.scrub,
    this.onFinish,
    required this.content,
    required this.revealed,
    this.revealedLive = false,
  });

  /// 翻成 true 波出去，翻回 false 收回。
  final bool isRevealed;

  /// 波从哪个框出发；null 用类型默认的（底部宽按钮、左边竖条、正中图标）。
  final Rect? source;

  /// 源上被按下的位置，波按 [DistortionWaveStyle.type] 往那边偏。
  final Offset? focus;

  final DistortionWaveStyle style;

  /// 把波定在这个进度（0–1），不播动画：截图、预览用。
  final double? scrub;

  /// 波走完、边缘清空，或收回完时调用；中途被再次翻转打断的那次不调。
  final VoidCallback? onFinish;

  /// 波出发前的那一屏。
  final Widget content;

  /// 波带进来的那一屏。
  final Widget revealed;

  /// 新页实时画、不快照、不过 shader（见 [WaveStage.revealedLive]）。
  final bool revealedLive;

  /// 提前加载着色器（页面打开时调一次），第一道波就不会退成淡入淡出。
  static Future<void> precache() => WavePrograms.load();

  @override
  State<DistortionWave> createState() => _DistortionWaveState();
}

class _DistortionWaveState extends State<DistortionWave> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, value: widget.isRevealed ? 1 : 0)
    ..addStatusListener((_) => setState(() {}));
  WavePrograms? _programs = WavePrograms.ready;
  Offset? _heldFocus;
  var _atRest = true;
  var _run = 0;

  bool get _reduceMotion => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  @override
  void initState() {
    super.initState();
    if (_programs == null) {
      unawaited(
        WavePrograms.load().then((programs) {
          if (mounted && programs != null) setState(() => _programs = programs);
        }),
      );
    }
  }

  @override
  void didUpdateWidget(DistortionWave oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isRevealed != widget.isRevealed) _start(widget.isRevealed);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _start(bool revealing) {
    // 波跟着偏的那个触点只在静止时采：中途换会让屏幕上的一切跳一下。
    if (_atRest) _heldFocus = widget.focus;
    _atRest = false;
    final run = ++_run;
    final style = widget.style;
    final TickerFuture going;
    if (_reduceMotion) {
      going = revealing
          ? _controller.animateTo(1, duration: _plainDuration)
          : _controller.animateBack(0, duration: _plainDuration);
    } else if (revealing) {
      going = _controller.animateTo(1, duration: _seconds(style.duration));
    } else {
      // 收回也走着色的缓动：它生命的最后一段画面上东西不多，可以走得快，收起来
      // 才对得上那一下点击。
      going = _controller.animateBack(0, duration: _seconds(style.duration / style.returnSpeed), curve: style.easing);
    }
    unawaited(
      going.then((_) {
        if (_run != run) return;
        _atRest = true;
        widget.onFinish?.call();
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scrub = widget.scrub;
    // 看不见的那一面不动。
    final contentShown = scrub == null ? !_controller.isCompleted : scrub < 1;
    final revealedShown = scrub == null ? !_controller.isDismissed : scrub > 0;
    return WaveStage(
      progress: scrub == null ? _controller : AlwaysStoppedAnimation(scrub),
      style: widget.style,
      palette: widget.style.paletteFor(Theme.of(context).colorScheme),
      programs: _programs,
      pixelRatio: MediaQuery.devicePixelRatioOf(context),
      source: widget.source,
      focus: scrub == null ? _heldFocus : widget.focus,
      plain: _reduceMotion,
      content: TickerMode(enabled: contentShown, child: widget.content),
      revealed: TickerMode(enabled: revealedShown, child: widget.revealed),
      revealedLive: widget.revealedLive,
    );
  }
}

/// 用扭曲波推入的整页路由：波从 [source] 出发，把底下那一页带进 [builder] 这一页；
/// 返回时收回源。
///
/// 底下那一页在过场开始后的第一帧截成图（之前那一帧什么都不画，露出底下真实的
/// 页面），收回时再截一次。所以推入前，底下那一页上不要盖着正在退场的弹层，否则
/// 弹层会在第二帧突然消失；要从弹层里切页，先等弹层关完再推。
///
/// 系统要求减少动画、或着色器还没加载好（[DistortionWave.precache]）时，是 0.3 秒
/// 的淡入淡出；底下不是整页（[PageRoute]）、截不到图时，在原时长里只做淡入淡出。
/// 新页在波前扫过整屏后（竖向默认约 1.3 秒）就接收触摸，不等边缘的颜色淡完。
class DistortionWaveRoute<T> extends PageRoute<T> {
  DistortionWaveRoute({
    required this.builder,
    this.style = DistortionWaveStyle.vertical,
    this.source,
    this.focus,
    this.revealedLive = false,
    super.settings,
    super.fullscreenDialog,
  }) {
    unawaited(WavePrograms.load());
  }

  final WidgetBuilder builder;
  final DistortionWaveStyle style;

  /// 波从哪个框出发，用导航器的坐标（通常就是全屏坐标）；null 用类型默认的。
  final Rect? source;

  /// 源上被按下的位置。
  final Offset? focus;

  /// 新页实时画、不快照、不过 shader（带视频的页面用这一档，见 [WaveStage.revealedLive]）。
  final bool revealedLive;

  Route<dynamic>? _previous;
  late bool _plain;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => _plain ? _plainDuration : _seconds(style.duration);

  @override
  Duration get reverseTransitionDuration => _plain ? _plainDuration : _seconds(style.duration / style.returnSpeed);

  /// 每次都重新问：系统设置可能在页面打开期间被改。
  bool get _plainNow => WavePrograms.ready == null || _reduceMotionOf(navigator!.context);

  static bool _reduceMotionOf(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  @override
  AnimationController createAnimationController() {
    _plain = _plainNow;
    return super.createAnimationController();
  }

  @override
  bool didPop(T? result) {
    _plain = _plainNow;
    controller!.reverseDuration = reverseTransitionDuration;
    return super.didPop(result);
  }

  @override
  void didChangePrevious(Route<dynamic>? previousRoute) {
    _previous = previousRoute;
    super.didChangePrevious(previousRoute);
  }

  /// 下面那一页不动：它由波带着走。
  @override
  bool canTransitionFrom(TransitionRoute<dynamic> previousRoute) => false;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) =>
      Semantics(scopesRoute: true, explicitChildNodes: true, child: builder(context));

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => _WaveRouteTransition(route: this, animation: animation, child: child);
}

class _WaveRouteTransition extends StatefulWidget {
  const _WaveRouteTransition({required this.route, required this.animation, required this.child});

  final DistortionWaveRoute<dynamic> route;
  final Animation<double> animation;
  final Widget child;

  @override
  State<_WaveRouteTransition> createState() => _WaveRouteTransitionState();
}

class _WaveRouteTransitionState extends State<_WaveRouteTransition> {
  late final _progress = _RouteProgress(widget.animation, widget.route.style.easing);

  /// 底下那一页，波出发时的样子。
  ui.Image? _outgoing;
  var _cannotCapture = false;

  @override
  void initState() {
    super.initState();
    widget.animation.addStatusListener(_onStatus);
    _onStatus(widget.animation.status);
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_onStatus);
    _progress.dispose();
    _outgoing?.dispose();
    super.dispose();
  }

  void _onStatus(AnimationStatus status) {
    if (widget.route._plain) return;
    switch (status) {
      // 底下那一页从下一帧起会重新被画（路由这会儿还不是不透明的）：等那一帧
      // 出来再截。
      case AnimationStatus.forward || AnimationStatus.reverse:
        WidgetsBinding.instance.addPostFrameCallback((_) => _capture());
      case AnimationStatus.completed:
        // 藏起来，等返回时重新截。
        final outgoing = _outgoing;
        if (outgoing == null) return;
        setState(() => _outgoing = null);
        outgoing.dispose();
      case AnimationStatus.dismissed:
        break;
    }
  }

  void _capture() {
    if (!mounted) return;
    final previous = widget.route._previous;
    final page = previous is PageRoute ? previous.subtreeContext?.findRenderObject() : null;
    setState(() {
      if (page is! RenderRepaintBoundary || !page.hasSize) {
        _cannotCapture = true;
        return;
      }
      _outgoing?.dispose();
      _outgoing = page.toImageSync(pixelRatio: MediaQuery.devicePixelRatioOf(context));
    });
  }

  @override
  Widget build(BuildContext context) {
    final route = widget.route;
    return WaveStage(
      progress: _progress,
      style: route.style,
      palette: route.style.paletteFor(Theme.of(context).colorScheme),
      programs: WavePrograms.ready,
      pixelRatio: MediaQuery.devicePixelRatioOf(context),
      source: route.source,
      focus: route.focus,
      plain: route._plain || _cannotCapture,
      contentImage: _outgoing,
      revealed: widget.child,
      revealedLiveOnceCrossed: true,
      revealedLive: route.revealedLive,
    );
  }
}

/// 波在这一条路由上的进度：出去时是线性的；回来时走着色的缓动，从掉头那一刻的
/// 位置算起。
class _RouteProgress extends Animation<double> with AnimationWithParentMixin<double> {
  _RouteProgress(this.parent, this.easing) {
    parent.addStatusListener(_onStatus);
  }

  @override
  final Animation<double> parent;
  final Curve easing;

  var _reversing = false;

  /// 方向最后一次翻转时的进度和父动画的值。
  var _from = 0.0;
  var _start = 0.0;

  void _onStatus(AnimationStatus status) {
    final reversing = status == AnimationStatus.reverse;
    if (reversing == _reversing || status.isCompleted || status.isDismissed) return;
    _from = value;
    _start = parent.value;
    _reversing = reversing;
  }

  void dispose() => parent.removeStatusListener(_onStatus);

  @override
  double get value {
    final t = parent.value;
    if (_reversing) {
      if (_start <= 0) return 0;
      return _from * (1 - easing.transform(((_start - t) / _start).clamp(0.0, 1.0)));
    }
    if (_start >= 1) return 1;
    return _from + (1 - _from) * ((t - _start) / (1 - _start)).clamp(0.0, 1.0);
  }
}
