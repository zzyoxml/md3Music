import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:m3e_core/m3e_core.dart';

import '../core/services/image_gallery_saver.dart';
import '../services/kugou_api/kugou_models.dart';
import 'comment_image_dismiss.dart';

/// 全屏查看评论图片。
///
/// - [PageView] 左右翻页 + [InteractiveViewer] 双指缩放；
/// - 传了 [originRect]（被点击的那张小图在屏幕上的矩形）后，单指拖动后甩出可把大图
///   缩小「甩回」评论区里的小图位置再关闭；拖动距离或甩动速度不够则回弹；
/// - 长按图片保存到系统相册（可用 [onSaveImage] 覆盖，测试即用此注入假实现）。
///
/// 不引入第三方图片浏览器依赖：`PageRoute` / `Transform` / `Listener` /
/// `InteractiveViewer` 均为 Flutter 原生。
Future<void> showCommentImageViewer(
  BuildContext context, {
  required List<CommentImage> images,
  int initialIndex = 0,
  Rect? originRect,
  Widget Function(BuildContext context, CommentImage image)? imageBuilder,
  Future<bool> Function(BuildContext context, String url)? onSaveImage,
}) async {
  if (images.isEmpty) return;
  await Navigator.of(context).push<void>(
    _CommentImageViewerRoute(
      images: images,
      initialIndex: initialIndex.clamp(0, images.length - 1),
      originRect: originRect,
      imageBuilder: imageBuilder,
      onSaveImage: onSaveImage,
    ),
  );
}

/// 全屏查看路由：透明、不自带背景板。
///
/// 不用 `showDialog`：DialogRoute 的 `barrierColor` 是静态的，遮罩无法跟随
/// 「甩回」手势淡出，也就露不出下层评论区。这里 `opaque=false` + 自绘遮罩。
class _CommentImageViewerRoute extends PageRoute<void> {
  _CommentImageViewerRoute({
    required this.images,
    required this.initialIndex,
    this.originRect,
    this.imageBuilder,
    this.onSaveImage,
  });

  final List<CommentImage> images;
  final int initialIndex;
  final Rect? originRect;
  final Widget Function(BuildContext context, CommentImage image)? imageBuilder;
  final Future<bool> Function(BuildContext context, String url)? onSaveImage;

  @override
  bool get opaque => false;

  @override
  bool get barrierDismissible => false;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Duration get reverseTransitionDuration => Duration.zero;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return _CommentImageViewer(
      images: images,
      initialIndex: initialIndex,
      originRect: originRect,
      imageBuilder: imageBuilder,
      onSaveImage: onSaveImage,
    );
  }
}

class _CommentImageViewer extends StatefulWidget {
  final List<CommentImage> images;
  final int initialIndex;
  final Rect? originRect;
  final Widget Function(BuildContext context, CommentImage image)? imageBuilder;
  final Future<bool> Function(BuildContext context, String url)? onSaveImage;

  const _CommentImageViewer({
    required this.images,
    required this.initialIndex,
    this.originRect,
    this.imageBuilder,
    this.onSaveImage,
  });

  @override
  State<_CommentImageViewer> createState() => _CommentImageViewerState();
}

class _CommentImageViewerState extends State<_CommentImageViewer>
    with TickerProviderStateMixin {
  /// 图片在测试与生产共用的定位 key（长按保存要按它）。
  static const Key imageKey = ValueKey('comment-image-viewer-image');

  late final PageController _pageController;

  /// 打开动画：0 = 还在评论区小图位置，1 = 全屏。
  late final AnimationController _openCtl;

  /// 甩出动画：0 = 全屏，1 = 已落到评论区小图位置。
  late final AnimationController _dismissCtl;

  /// 回弹动画：把手势位移拉回 0。
  late final AnimationController _returnCtl;

  /// 三个控制器合并成一个 Listenable，避免每次 build 都新建 merge 对象。
  late final Listenable _visual;

  /// 当前拖动位移（只驱动变换子树重建，不整页 setState）。
  final ValueNotifier<Offset> _drag = ValueNotifier(Offset.zero);

  /// 图片是否处于放大态：放大后平移交给 InteractiveViewer，避免手势竞争。
  final ValueNotifier<bool> _zoomed = ValueNotifier(false);

  late int _index;

  /// 最近一次布局给出的页面尺寸（甩出时用来重算矩形）。
  Size _viewport = Size.zero;

  /// 动画起点/终点矩形（甩出或回弹时冻结，避免中途换算导致跳变）。
  Rect? _animFrom;
  Rect? _landing;

  /// 回弹进行中标志。
  bool _returning = false;

  /// 正在跟踪的那根手指（null = 没在甩）。
  int? _dragPointer;

  /// 甩出速度估算：自己攒 `VelocityTracker`，不必依赖手势竞技场。
  final Map<int, VelocityTracker> _trackers = <int, VelocityTracker>{};

  bool _dismissing = false;
  bool _popping = false;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _pageController = PageController(initialPage: _index);
    _openCtl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      value: widget.originRect == null ? 1 : 0,
    );
    _dismissCtl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    );
    _returnCtl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    _visual = Listenable.merge([_openCtl, _dismissCtl, _returnCtl]);
    if (widget.originRect != null) {
      // 首帧先把大图摆在小图位置，再放大，避免「先全屏再缩小回来」的二次动画。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openCtl.forward();
      });
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    _openCtl.dispose();
    _dismissCtl.dispose();
    _returnCtl.dispose();
    _drag.dispose();
    _zoomed.dispose();
    super.dispose();
  }

  /// 图片在全屏时的矩形（按上游给的宽高比做 contain，与 `BoxFit.contain` 落位一致）。
  Rect get _fullRect => CommentImageDismiss.containRect(
        Rect.fromLTWH(0, 0, _viewport.width, _viewport.height),
        widget.images[_index].aspectRatio,
      );

  /// 遮罩与顶部栏的不透明度：全屏为 1，甩出过程线性降到 0。
  double get _fullness =>
      _dismissing ? 1 - _dismissCtl.value : _openCtl.value;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewport = constraints.biggest;
        return Stack(
          fit: StackFit.expand,
          children: [
            AnimatedBuilder(
              animation: _visual,
              builder: (context, _) => ColoredBox(
                color: Colors.black.withValues(alpha: 0.87 * _fullness),
              ),
            ),
            _buildImageLayer(),
            _buildTopBar(),
          ],
        );
      },
    );
  }

  Widget _buildImageLayer() {
    // 用 `Listener` 拿原始指针事件而不是手势识别器：`InteractiveViewer` 内部的
    // `ScaleGestureRecognizer` 会在单指移动时也参与竞技场并可能先 accept，
    // 外层再挂 `VerticalDragGestureRecognizer` 就有概率抢不到手势。
    // `Listener` 不参与竞技场，只旁听，翻页 / 双指缩放完全不受影响。
    // tv: 不适用（全屏查看器的点按关闭/长按保存/拖拽下滑是纯手势交互，
    // TV 上系统返回键即可退出查看器）
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _close,
        onLongPress: _saveCurrent,
        child: ValueListenableBuilder<Offset>(
          valueListenable: _drag,
          child: _buildPages(),
          // 拖动位移由 _matrixFor() 统一折进矩阵，这里**不能**再叠一层
          // Transform.translate（会与 draggedRect 的位移重复计算，拖快一倍）。
          builder: (context, drag, child) => AnimatedBuilder(
            animation: _visual,
            child: child,
            builder: (context, _) => Transform(
              // 不传 alignment：默认 null = 绕子节点原点变换，
              // 与 CommentImageDismiss.rectToRect 的「同一页面坐标系」契约一致。
              transform: _matrixFor(),
              child: child,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPages() {
    return PageView.builder(
      controller: _pageController,
      itemCount: widget.images.length,
      onPageChanged: (i) {
        _zoomed.value = false;
        setState(() => _index = i);
      },
      itemBuilder: (context, i) => ValueListenableBuilder<bool>(
        valueListenable: _zoomed,
        builder: (context, zoomed, child) => InteractiveViewer(
          maxScale: 4,
          // 放大后平移交给 InteractiveViewer；未放大时单指竖向手势用于「甩回小图」，
          // 两者因此不会在同一场手势里竞争。
          panEnabled: zoomed,
          onInteractionUpdate: (details) {
            final next = details.scale > 1.01;
            if (_zoomed.value != next) _zoomed.value = next;
          },
          child: child!,
        ),
        child: Center(child: _buildImage(context, widget.images[i])),
      ),
    );
  }

  Widget _buildTopBar() {
    return AnimatedBuilder(
      animation: _visual,
      builder: (context, _) => Opacity(
        opacity: _fullness,
        child: Stack(
          children: [
            Positioned(
              top: MediaQuery.paddingOf(context).top + 12,
              left: 0,
              right: 0,
              child: Center(
                child: Text(
                  '${_index + 1}/${widget.images.length}',
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            ),
            Positioned(
              top: MediaQuery.paddingOf(context).top + 4,
              right: 8,
              child: IconButton(
                key: const ValueKey('comment-image-viewer-close'),
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: _close,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 当前应施加到页面上的变换：把「全屏时图片所在矩形」映射到「此刻目标矩形」。
  Matrix4 _matrixFor() {
    final full = _fullRect;
    if (_dismissing) {
      final from = _animFrom ?? full;
      final to = _landing ?? full;
      final t = Curves.easeInCubic.transform(_dismissCtl.value);
      return CommentImageDismiss.rectToRect(
        from: full,
        to: Rect.lerp(from, to, t) ?? from,
      );
    }
    if (_returning) {
      final from = _animFrom ?? full;
      final t = Curves.easeOut.transform(_returnCtl.value);
      return CommentImageDismiss.rectToRect(
        from: full,
        to: Rect.lerp(from, full, t) ?? from,
      );
    }
    return CommentImageDismiss.rectToRect(
      from: full,
      to: CommentImageDismiss.draggedRect(full: full, drag: _drag.value),
    );
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_dismissing || _returning) return;
    if (_dragPointer != null) {
      // 第二根手指按下 = 用户要双指缩放：立刻放弃本次甩回拖动并回弹
      if (event.pointer != _dragPointer) {
        _trackers.remove(_dragPointer);
        _dragPointer = null;
        _springBack();
      }
      return;
    }
    // 放大态的平移归 InteractiveViewer，单指不再驱动甩回
    if (_zoomed.value) return;
    _dragPointer = event.pointer;
    _trackers[event.pointer] = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.position);
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _dragPointer) return;
    // 只旁听**竖向**位移：横向手势完全留给 PageView 翻页。若把横向 delta 也计入
    // 甩出判定，一次 400px 的翻页滑动会 distance≥120 误触发「甩回关闭」——
    // 与本组件「左右滑动翻页仍正常」的行为契约直接冲突。
    _drag.value += Offset(0, event.delta.dy);
    _trackers[event.pointer]?.addPosition(event.timeStamp, event.position);
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _dragPointer) return;
    final raw = _trackers.remove(event.pointer)?.getVelocity() ?? Velocity.zero;
    // 速度同样只取竖向分量：横向甩动是翻页，不是甩回。
    final velocity =
        Velocity(pixelsPerSecond: Offset(0, raw.pixelsPerSecond.dy));
    _dragPointer = null;
    if (CommentImageDismiss.shouldDismiss(drag: _drag.value, velocity: velocity)) {
      _dismiss();
    } else {
      _springBack();
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer != _dragPointer) return;
    _trackers.remove(_dragPointer);
    _dragPointer = null;
    _springBack();
  }

  Future<void> _dismiss() async {
    if (_dismissing) return;
    _dismissing = true;
    final full = _fullRect;
    // 起点 = 松手瞬间的位置（含拖动位移）；把位移折进起点后立刻清零 _drag，
    // 两处状态在同一次重建里换算，画面不会出现跳帧。
    _animFrom = CommentImageDismiss.draggedRect(full: full, drag: _drag.value);
    _drag.value = Offset.zero;
    _landing = widget.originRect ?? CommentImageDismiss.fallbackLanding(full);
    await _dismissCtl.forward(from: 0);
    if (mounted) _close();
  }

  void _springBack() {
    if (_drag.value == Offset.zero) return;
    _animFrom = CommentImageDismiss.draggedRect(full: _fullRect, drag: _drag.value);
    _returning = true;
    _returnCtl.forward(from: 0).whenComplete(() {
      _returning = false;
      _animFrom = null;
      _drag.value = Offset.zero;
    });
  }

  Future<void> _saveCurrent() async {
    final handler =
        widget.onSaveImage ?? ImageGallerySaver.saveImageToGalleryWithFeedback;
    await handler(context, widget.images[_index].url);
  }

  void _close() {
    if (_popping) return;
    _popping = true;
    Navigator.of(context).pop();
  }

  Widget _buildImage(BuildContext context, CommentImage image) {
    final custom = widget.imageBuilder;
    return KeyedSubtree(
      key: imageKey,
      child: custom != null
          ? custom(context, image)
          : CachedNetworkImage(
              imageUrl: image.url,
              fit: BoxFit.contain,
              memCacheWidth: 1080,
              // 加载指示器统一用 m3e_core（与项目其它加载态一致）；黑底上取白色
              placeholder: (_, _) => const Center(
                child: M3ELoadingIndicator(
                  constraints: BoxConstraints.tightFor(width: 24, height: 24),
                  color: Colors.white,
                ),
              ),
              errorWidget: (_, _, _) => const Icon(
                Icons.broken_image_outlined,
                color: Colors.white54,
                size: 40,
              ),
            ),
    );
  }
}
