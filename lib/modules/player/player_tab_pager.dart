// 播放器内容区（播放列表 / 封面 / 歌词 / 评论）：PageView + 自持 PageController 驱动。
//
// 为什么不能用 TabBarView：本 SDK 的 TabBarView **已移除 pageController 参数**，
// 内部自建 _pageController，并且只在 TabController.indexIsChanging 时才同步
// （见 flutter/lib/src/material/tabs.dart 的 _handleTabControllerAnimationTick：
//    `if (_scrollUnderwayCount > 0 || !_controller!.indexIsChanging) return;`）。
// 于是「直写 TabController.offset 让页面跟手」根本不生效——底部指示条动、内容不动。
// 要做 1:1 跟手，唯一出路是自己持有 PageController，本组件就是这个出路。
//
// 页面位置的**唯一真值是 PageController**；[TabController] 只是给底部导航条
// 指示线看的镜像，由 [_mirror] 单向写入。外头改 TabController（导航条点击）时
// 由 [_onTabControllerChanged] 反向把页面带过去。
//
// 跟手入口：
// - [dragBy]     按像素增量 1:1 拖动（底部导航条拖动、播放列表面板滑页都走它）
// - [jumpToPage] 直接定位到某个小数页（拖动过程中逐帧调用）
// - [animateToPage] / [goToPage] 松手吸附与程序化切页

import 'package:dpad/dpad.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/build_flags.dart';

/// 播放器内容区。
class PlayerTabPager extends StatefulWidget {
  const PlayerTabPager({
    super.key,
    required this.tabController,
    required this.children,
    this.physics,
  });

  /// 仅用于指示线与外部点击切页；本组件不把它当作页面位置的输入。
  final TabController tabController;

  final List<Widget> children;

  /// 透传给 PageView。控制页用手势锁在拖动滑条期间传 NeverScrollableScrollPhysics，防滑条与横滑切页抢竞技场。
  final ScrollPhysics? physics;

  @override
  State<PlayerTabPager> createState() => PlayerTabPagerState();
}

class PlayerTabPagerState extends State<PlayerTabPager> {
  late final PageController _pageController = PageController(
    initialPage: widget.tabController.index,
  );

  /// 写 TabController 时置位，避免把自己的镜像当成外部改动再同步回去。
  bool _mirroring = false;

  /// 页面移动的真实来源有三处：① [PageView] 自己的原生拖拽（歌词 / 评论页）、
  /// ② 本类的 [dragBy] / [jumpToPage]（播放列表跟手、导航条拖动）、
  /// ③ 程序化切页。三者最终都表现为 ScrollPosition 变化，所以统一在这里
  /// 镜像给指示线——**只靠主动调用处的 _mirror 会漏掉 ①**，
  /// 表现为「除播放列表外，其它页滑动时底部指示条不动」。
  void _onPageMoved() {
    if (_mirroring || !_pageController.hasClients) return;
    _mirror(page);
  }

  @override
  void initState() {
    super.initState();
    widget.tabController.addListener(_onTabControllerChanged);
    // PageController 本身就是滚动通知源：attach 后任意滚动都会回调。
    _pageController.addListener(_onPageMoved);
  }

  @override
  void didUpdateWidget(PlayerTabPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tabController != widget.tabController) {
      oldWidget.tabController.removeListener(_onTabControllerChanged);
      widget.tabController.addListener(_onTabControllerChanged);
      // _syncTabLayout 在 tab 结构变化（旋转 / 切歌导致评论 tab 增删）时会
      // dispose 旧 controller 并按新的 initialIndex 新建。新实例构造时不会
      // 发通知，所以这里要主动对齐一次，否则指示线走了、页面还停在旧页。
      if (_pageController.hasClients) {
        final target = widget.tabController.index.toDouble();
        if ((target - page).abs() > 0.001) {
          _pageController.jumpTo(target * viewportWidth);
          _mirror(target);
        }
      }
    }
  }

  @override
  void dispose() {
    widget.tabController.removeListener(_onTabControllerChanged);
    _pageController
      ..removeListener(_onPageMoved)
      ..dispose();
    super.dispose();
  }

  /// 当前连续页位置（0 = 播放列表，1 = 封面，以此类推）。
  double get page {
    if (!_pageController.hasClients) {
      return widget.tabController.index.toDouble();
    }
    return _pageController.page ?? widget.tabController.index.toDouble();
  }

  /// 一页的宽度（像素）。未布局完成时返回 0，调用方需自行兜底。
  double get viewportWidth =>
      _pageController.hasClients ? _pageController.position.viewportDimension : 0;

  int get lastPage => widget.tabController.length - 1;

  // ── 对外入口 ──

  /// 按像素增量拖动，1:1 跟手，除数是**整页宽度**。
  ///
  /// 播放列表面板的跟手滑页用 [jumpToPage]（进度已由面板按页宽归一），
  /// 不走这里；本方法保留给「按整页宽度拖动就是拖过一页」的场景。
  void dragBy(double dx) {
    if (!_pageController.hasClients || viewportWidth <= 0) return;
    jumpToPage(page + dx / viewportWidth);
  }

  /// 底部导航条拖动：**一段宽 = 一页**。
  ///
  /// 导航条横跨整屏、四五段挤在一起，用整页宽作除数会让人「拖过一段却只走了
  /// 1/4 页」，手感像有阻力（约 4 倍迟滞）。段宽→页的映射是导航条自带的语义
  /// （改造前的 _onTabDragUpdate 就是除 _tabDragBtnW），这里保持一致。
  void dragBySegment(double dx, double segmentWidth) {
    if (!_pageController.hasClients || segmentWidth <= 0) return;
    jumpToPage(page + dx / segmentWidth);
  }

  /// 逐帧定位到某个（可为小数的）页位置——跟手滑页的全过程都走它。
  void jumpToPage(double target) {
    if (!_pageController.hasClients) return;
    final clamped = target.clamp(0.0, lastPage.toDouble());
    _mirror(clamped);
    // jumpTo 是像素级的；换算回页号能让 PageView 精确定位，且不触发补间。
    _pageController.jumpTo(clamped * viewportWidth);
  }

  /// 补间到某个页位置（可带小数）。
  void animateToPage(
    double target, {
    required Duration duration,
    required Curve curve,
  }) {
    if (!_pageController.hasClients) return;
    final clamped = target.clamp(0.0, lastPage.toDouble());
    _mirror(clamped);
    _pageController.animateTo(
      clamped * viewportWidth,
      duration: duration,
      curve: curve,
    );
  }

  /// 程序化切页（导航条点击、封面页点击等）。
  void goToPage(int index, {
    Duration duration = const Duration(milliseconds: 300),
    Curve curve = Curves.ease,
  }) {
    if (!_pageController.hasClients) return;
    final target = index.clamp(0, lastPage).toDouble();
    _mirror(target);
    if (duration == Duration.zero) {
      _pageController.jumpTo(target * viewportWidth);
    } else {
      _pageController.animateTo(
        target * viewportWidth,
        duration: duration,
        curve: curve,
      );
    }
  }

  /// 切页结束后把指示线精确落到整页（去掉 offset 余量）。
  void settleIndicator() {
    final i = page.round().clamp(0, lastPage).toDouble();
    _mirror(i);
  }

  /// 松手后吸附到最近的整页（底部导航条拖动用；那里拿不到速度信息）。
  void settleNearest() {
    final target = page.round().clamp(0, lastPage).toDouble();
    final distance = (target - page).abs().clamp(0.0, 1.0);
    final ms = (120 + 180 * distance).round().clamp(120, 300);
    _mirror(target);
    if (!_pageController.hasClients) return;
    _pageController.animateTo(
      target * viewportWidth,
      duration: Duration(milliseconds: ms),
      curve: Curves.easeOutCubic,
    );
  }

  // ── 内部 ──

  /// 把页面位置镜像到 TabController，供底部指示线读取。
  void _mirror(double page) {
    if (!_pageController.hasClients) return;
    // 外部（导航条点击）正在跑 TabController.animateTo 时 indexIsChanging 为真，
    // 而 offset 的 setter 带 assert(!indexIsChanging) —— 此时写入必崩。
    // 那种情况下指示线本来就由那次补间驱动，不该插手。
    if (widget.tabController.indexIsChanging) return;
    final i = page.floor().clamp(0, lastPage);
    _mirroring = true;
    try {
      widget.tabController.index = i;
      widget.tabController.offset = page - i;
    } finally {
      _mirroring = false;
    }
  }

  /// 外部（底部导航条点击 / 长按）改了 TabController，把页面带过去。
  void _onTabControllerChanged() {
    if (_mirroring || !_pageController.hasClients) return;
    final controller = widget.tabController;
    if (controller.indexIsChanging) {
      // 补间中：index 已经是目标值，但 animation.value 还停在起点，
      // 所以 offset 是负的一整页。此时**必须用 index 当目标**——
      // 若照常算 index + offset 会正好抵消回旧页，被下面的「无需移动」
      // 判断挡掉，表现就是点击图标时页面直接跳变、没有动画。
      goToPage(
        controller.index,
        duration: controller.animationDuration,
        curve: Curves.ease,
      );
      return;
    }
    final target = controller.index + controller.offset;
    if ((target - page).abs() < 0.001) return;
    jumpToPage(target);
  }

  @override
  Widget build(BuildContext context) {
    return PageView(
      controller: _pageController,
      physics: widget.physics,
      // tv: 每个 tab 页包一个带 memoryKey 的 DpadRegion（铁律 3）：PageView
      // 离屏页会被销毁，region 记忆按 key 静态持久化，焦点切回某页时恢复到
      // 该页上次聚焦的位置，而不是回落到页首。触屏构建原样返回，零变化。
      children: kTvBuild
          ? [
              for (var i = 0; i < widget.children.length; i++)
                DpadRegion(
                  memoryKey: 'tv_player_tab_page_$i',
                  child: widget.children[i],
                ),
            ]
          : widget.children,
    );
  }
}