import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../cover_switch_physics.dart';

/// 封面横向切换 pager：把「上一首 / 当前 / 下一首」三张封面按横向位移排布，
/// 支持 1:1 跟手拖动、松手吸附、越界回弹。
///
/// 帧约定（对齐 AGENTS §10）：
///   * 只有拖动 / 吸附 / 回弹期间才产帧——`AnimationController` 空闲时不挂
///     Ticker，静止画面零产帧（§10.4.6）。
///   * 逐帧位移只走 `Transform.translate`：纯绘制阶段变换，**不触发布局**；
///     重建范围由 `ValueListenableBuilder` 收在本 pager 子树内（§10.4.2）。
///   * 拖动 / 吸附 / 回弹属 §10.1 的满帧例外，**禁止限帧**。
///
/// 手势归属：本组件的横滑识别器挂在封面方盒内，是外层内容区 `PageView` 的
/// 后代——同为 `HorizontalDragGestureRecognizer` 时竞技场取最先注册者（最内层），
/// 所以封面内横滑归本组件、封面外横滑仍归PageView（详见计划 §2.2）。
class CoverSwitchPager extends StatefulWidget {
  const CoverSwitchPager({
    super.key,
    required this.side,
    required this.radius,
    required this.pages,
    required this.canGoPrevious,
    required this.canGoNext,
    required this.onCommit,
    this.onDragStarted,
  });

  /// 单张封面的边长（正方形）。pager 的可视窗口也就是这个尺寸。
  final double side;

  /// 封面圆角，与外层 `ClipRRect` 既有取值保持一致。
  final double radius;

  /// 固定三张页：`[上一首, 当前, 下一首]`。不可用的一侧传 `SizedBox.shrink()`。
  final List<Widget> pages;

  /// 该侧是否可以翻页；false 时该侧边界为 0，拖动越界只做橡皮筋并回弹。
  final bool canGoPrevious;
  final bool canGoNext;

  /// 松手落点是 ±1 时上报，由调用方去真正切歌。
  final void Function(CoverSwitchIntent intent) onCommit;

  /// 拖动开始：调用方用来停掉可能的封面淡入淡出，避免两个动画叠成残影。
  final VoidCallback? onDragStarted;

  @override
  State<CoverSwitchPager> createState() => CoverSwitchPagerState();
}

class CoverSwitchPagerState extends State<CoverSwitchPager>
    with SingleTickerProviderStateMixin {
  /// 相邻封面之间的间隙。
  static const double _gap = 14.0;

  /// 提交后等 provider 真正切歌的守卫时长。
  ///
  /// 覆盖「队尾非循环 / 一起听听众被拦 / 链接解析全失败」——这些情况下
  /// `next()` 根本不会换歌，已推进的画面必须弹回，否则封面身份与真实歌曲不一致。
  /// 取值需大于一次在线曲目解析的常见耗时，又不能让用户一直盯着错位封面。
  static const Duration _commitGuard = Duration(milliseconds: 1600);

  late final AnimationController _motion = AnimationController.unbounded(
    vsync: this,
  );

  /// 逐帧读取的进度（唯一真值）。用 `ValueNotifier` 而非 `AnimatedBuilder`：
  /// 重建范围精确收在 pager 的 `ValueListenableBuilder` 内。
  final ValueNotifier<double> _progress = ValueNotifier<double>(0);

  bool _dragging = false;
  CoverSwitchIntent? _pendingIntent;
  Timer? _pendingGuard;

  double get _pitch => widget.side + _gap;

  double get _minProgress => widget.canGoPrevious ? -1 : 0;

  double get _maxProgress => widget.canGoNext ? 1 : 0;

  /// 当前进度，测试与调用方读取用。
  double get progress => _progress.value;

  /// 是否已静止（没有正在跑的吸附/回弹）。
  bool get isSettled => !_motion.isAnimating;

  /// 是否有「已经推进、还没等到 provider 换歌」的提交在等守卫。
  bool get hasPendingCommit => _pendingIntent != null;

  @override
  void initState() {
    super.initState();
    _motion.addListener(_onMotionTick);
  }

  @override
  void didUpdateWidget(covariant CoverSwitchPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 边长/边界变化（转屏、转屏后邻居增删）时，旧进度可能落在新边界之外，
    // 直接归零最稳：此时列表与布局都已换过，任何保留值都是错的。
    if (oldWidget.side != widget.side ||
        oldWidget.canGoPrevious != widget.canGoPrevious ||
        oldWidget.canGoNext != widget.canGoNext) {
      resetToIdle();
    }
  }

  @override
  void dispose() {
    _pendingGuard?.cancel();
    _motion
      ..removeListener(_onMotionTick)
      ..dispose();
    _progress.dispose();
    super.dispose();
  }

  void _onMotionTick() {
    _progress.value = _motion.value;
  }

  // ── 对外入口 ──

  /// 真实切歌后播放滑入：先把进度瞬移到 `-direction`
  /// （此刻视口显示的仍是刚播完那张封面，画面零跳变，见计划 §2.1 的不变式），
  /// 再补间回 0，新封面从右侧（direction=+1）或左侧（direction=-1）滑入。
  void playChange(int direction) {
    _clearPending();
    _dragging = false;
    _motion.stop();
    _motion.value = -direction.toDouble();
    _settleTo(0);
  }

  /// 真实切歌后校正页引用：相对下标平移了 [delta]，进度同步平移 [delta]，
  /// 保证同一件内容画在同一像素上（逐像素连续）。
  ///
  /// 拖动途中收到外部切歌同样适用（手指继续控制同一件内容）；`|delta| != 1`
  /// 表示页列表结构已不是「相邻一页」，此时取消拖动并归零。
  void rebase(int delta) {
    _clearPending();
    if (_dragging) {
      if (delta.abs() != 1) {
        _dragging = false;
        _motion.stop();
        _settleTo(0);
        return;
      }
    }
    _motion.stop();
    _motion.value = _progress.value - delta;
    _settleTo(0);
  }

  /// 方向未知的切歌（歌单点歌 / 一起听同步 / 冷启动恢复）：不滑动，直接归零。
  void resetToIdle() {
    _clearPending();
    _dragging = false;
    _motion.stop();
    _motion.value = 0;
  }

  // ── 内部 ──

  void _clearPending() {
    _pendingGuard?.cancel();
    _pendingGuard = null;
    _pendingIntent = null;
  }

  /// 吸附/回弹到 [target]。
  ///
  /// [velocityPxPerSec] 是**沿进度方向**的释放速度（正 = 朝下一首）。
  /// 只有 `_onDragEnd` 会带速度；`rebase` / `playChange` / 取消 / 守卫回弹
  /// 都不带（从静止起步，走同一根弹簧）。
  void _settleTo(double target, {double velocityPxPerSec = 0}) {
    final double distance = (target - _motion.value).abs();
    if (distance < 0.001 &&
        velocityPxPerSec.abs() < kCoverFlingVelocityPxPerSec) {
      _motion.value = target;
      return;
    }
    // 把释放速度带进弹簧：`animateTo` 的起始速度恒为 0，会把手指出来的动量在
    // 松手瞬间清零、再被缓动曲线重新加速——这个「速度断崖」就是手感生涩的
    // 直接来源。弹簧是过阻尼的（见 kCoverSettleSpring），带速度也不过冲。
    _motion.animateWith(
      coverSettleSimulation(
        from: _motion.value,
        to: target,
        velocity: _pitch > 0 ? velocityPxPerSec / _pitch : 0,
      ),
    );
  }

  void _commit(
    CoverSwitchIntent intent,
    double target, {
    double velocityPxPerSec = 0,
  }) {
    _pendingIntent = intent;
    _settleTo(target, velocityPxPerSec: velocityPxPerSec);
    _pendingGuard?.cancel();
    _pendingGuard = Timer(_commitGuard, () {
      if (_pendingIntent != intent) return;
      // provider 没有真正切歌：把推进的画面弹回来（见 0.3 异常矩阵）。
      _pendingIntent = null;
      _pendingGuard = null;
      _settleTo(0);
    });
    widget.onCommit(intent);
  }

  void _onDragStart(DragStartDetails _) {
    widget.onDragStarted?.call();
    _motion.stop();
    _dragging = true;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    _motion.value = coverDragProgress(
      progress: _motion.value,
      dx: details.delta.dx,
      pitch: _pitch,
      minProgress: _minProgress,
      maxProgress: _maxProgress,
    );
  }

  void _onDragEnd(DragEndDetails details) {
    _dragging = false;
    // primaryVelocity 是「手指速度」（右移为正），进度方向与之相反，
    // 所以取负后就是「沿进度方向的 px/s」——与压实现在同一量纲，
    // 甩动阈值常量 `kCoverFlingVelocityPxPerSec` 才对得上。
    final double velocityPxPerSec = -(details.primaryVelocity ?? 0);
    final double target = coverSettleTarget(
      progress: _motion.value,
      velocityPxPerSec: velocityPxPerSec,
      minProgress: _minProgress,
      maxProgress: _maxProgress,
    );
    final CoverSwitchIntent? intent = coverSwitchIntentForTarget(target);
    if (intent == null) {
      _settleTo(target, velocityPxPerSec: velocityPxPerSec);
      return;
    }
    _commit(intent, target, velocityPxPerSec: velocityPxPerSec);
  }

  void _onDragCancel() {
    _dragging = false;
    _settleTo(_motion.value.clamp(_minProgress, _maxProgress));
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: _onDragStart,
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      onHorizontalDragCancel: _onDragCancel,
      child: ClipRRect(
        // 窗口裁剪 = 封面方盒：静止态相邻页完全在窗口外（与视频一致），
        // 拖动时相邻页从窗口边缘滑进来，中间露出一段页面背景。
        borderRadius: BorderRadius.circular(widget.radius),
        child: SizedBox.square(
          dimension: widget.side,
          child: ValueListenableBuilder<double>(
            valueListenable: _progress,
            builder: (context, progress, _) => Stack(
              clipBehavior: Clip.hardEdge,
              alignment: Alignment.center,
              children: [
                for (int offset = -1; offset <= 1; offset++)
                  Transform.translate(
                    offset: Offset(
                      coverSlideOffset(
                        offset: offset,
                        progress: progress,
                        pitch: _pitch,
                      ),
                      0,
                    ),
                    child: SizedBox.square(
                      // 帧键供测试量取「卡片框」的真实位置：视差让卡内图像与卡片框
                      // 不再重合，两者必须能分别量。
                      // **键必须在 Transform 的子级上**：`RenderTransform` 自身的 box
                      // 报的是变换前位置（位移只在它到子级的那一段生效），把键挂在
                      // Transform 上量出来永远是视口中央。
                      key: ValueKey<String>('cover-frame-$offset'),
                      dimension: widget.side,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(widget.radius),
                        child: Transform.translate(
                          // 视差：卡片框照滑，卡内图像按 kCoverParallaxLag 滞后 ——
                          // 图像只以 (1 - lag) 的速度跟着框走，就有纵深。
                          // 纯绘制阶段变换，不触发布局；且方向朝视口中央，让出来的
                          // 空白只落在卡片背对视口那半边（整块在视口外），不必放大封面。
                          offset: Offset(
                            coverParallaxOffset(
                              offset: offset,
                              progress: progress,
                              pitch: _pitch,
                            ),
                            0,
                          ),
                          child: widget.pages[offset + 1],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
