import 'package:flutter/material.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../providers/device_provider.dart';
import '../../providers/theme_provider.dart';

enum ScreenType { compact, medium, expanded }

/// 断点值 600dp。[getScreenType] 量的是**可用宽度**（横屏手机也会越过它），
/// [isPadLayout] 量的是**最短边**（只有真正的大屏设备才越过）。
const double _compactBreakpoint = 600;
const double _mediumBreakpoint = 900;

ScreenType getScreenType(double width) {
  if (width < _compactBreakpoint) return ScreenType.compact;
  if (width < _mediumBreakpoint) return ScreenType.medium;
  return ScreenType.expanded;
}

ScreenType getScreenTypeFromContext(BuildContext context) {
  return getScreenType(MediaQuery.sizeOf(context).width);
}

/// 当前是否使用 Pad（大屏）布局：分栏播放器、网格列数偏好、居中大弹窗等。
///
/// [DeviceType.auto] 按**有效视口**最短边判定，而不是设备物理 dp：
/// 「显示大小」（[DisplayScaleScope]）调大后可用逻辑区随之变小，原生同样会跌出
/// sw600dp 资源桶、切回手机布局。两边一致才不会出现"Pad 分栏挤在手机大小的
/// 视口里"。用户在设置里手动选了手机/平板时直接服从该选择。
bool isPadLayout(BuildContext context) {
  switch (context.read<DeviceProvider>().deviceType) {
    case DeviceType.auto:
      return MediaQuery.sizeOf(context).shortestSide >= _compactBreakpoint;
    case DeviceType.phone:
      return false;
    case DeviceType.pad:
      return true;
  }
}

class ResponsiveLayout extends StatelessWidget {
  final WidgetBuilder compact;
  final WidgetBuilder? medium;
  final WidgetBuilder? expanded;

  const ResponsiveLayout({
    super.key,
    required this.compact,
    this.medium,
    this.expanded,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final screenType = getScreenType(constraints.maxWidth);
        switch (screenType) {
          case ScreenType.compact:
            return compact(context);
          case ScreenType.medium:
            return (medium ?? compact)(context);
          case ScreenType.expanded:
            return (expanded ?? medium ?? compact)(context);
        }
      },
    );
  }
}

class ResponsiveScaffold extends StatefulWidget {
  final List<NavigationDestination> destinations;
  final List<NavigationRailDestination> railDestinations;
  final List<NavigationDrawerDestination> drawerDestinations;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final Widget body;
  final Widget? compactBody;
  final Widget? mediumBody;
  final Widget? expandedBody;
  final PreferredSizeWidget? appBar;
  final Widget? floatingActionButton;

  /// 为 true 时隐藏导航栏（横屏不渲染 NavigationRail、竖屏不渲染 NavigationBar），
  /// 用于封面流页的横屏沉浸浏览。
  final bool hideNavigation;

  const ResponsiveScaffold({
    super.key,
    required this.destinations,
    required this.railDestinations,
    required this.drawerDestinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.body,
    this.compactBody,
    this.mediumBody,
    this.expandedBody,
    this.appBar,
    this.floatingActionButton,
    this.hideNavigation = false,
  });

  @override
  State<ResponsiveScaffold> createState() => _ResponsiveScaffoldState();
}

class _ResponsiveScaffoldState extends State<ResponsiveScaffold> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  /// 每个 tab 胶囊回弹动画的 key（竖屏 NavigationBar 用 icon，横屏
  /// NavigationRail 的 icon / selectedIcon 各占一个 key 槽位）。
  late List<GlobalKey<_CapsuleBounceState>> _bounceKeys;
  late List<GlobalKey<_CapsuleBounceState>> _selectedBounceKeys;

  @override
  void initState() {
    super.initState();
    _bounceKeys = _initBounceKeys(widget.railDestinations.length);
    _selectedBounceKeys = _initBounceKeys(widget.railDestinations.length);
  }

  @override
  void didUpdateWidget(covariant ResponsiveScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    final count = widget.railDestinations.length;
    if (_bounceKeys.length != count) {
      _bounceKeys = _initBounceKeys(count);
      _selectedBounceKeys = _initBounceKeys(count);
    }
  }

  List<GlobalKey<_CapsuleBounceState>> _initBounceKeys(int count) {
    return List.generate(count, (_) => GlobalKey<_CapsuleBounceState>());
  }

  /// 点击 destination 完成后的统一入口：先触发该 tab 胶囊自驱动的水平
  /// 超出回弹（点击已选中项时），再转发原生选择回调（不改变原有切换行为；
  /// 切换选中项时胶囊由 _CapsuleBounce 的 didUpdateWidget 自动播放）。
  void _handleDestinationSelected(int index) {
    _bounceKeys[index].currentState?.playBounce();
    _selectedBounceKeys[index].currentState?.playBounce();
    widget.onDestinationSelected(index);
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;

    // 横屏（手机/平板）使用侧边导航栏，导航项垂直居中；
    // 竖屏（手机/平板）使用底部导航栏。
    if (isLandscape) {
      return _buildRailLayout();
    }
    return _buildCompactLayout();
  }

  Widget _buildCompactLayout() {
    // labelBehavior 由主题设置控制（NavigationBarThemeData.labelBehavior，
    // 跟随设置页「底部导航栏文字」三档切换）。
    final labelBehavior = Theme.of(context).navigationBarTheme.labelBehavior;
    return Scaffold(
      key: _scaffoldKey,
      appBar: widget.appBar,
      body: widget.compactBody ?? widget.body,
      floatingActionButton: widget.floatingActionButton,
      bottomNavigationBar: widget.hideNavigation
          ? null
          : NavigationBar(
              // 仅图标（alwaysHide）时高度减半紧凑显示（44）；
              // 显示文字（始终显示/仅当前页）时用 64 紧凑高度，
              // 比默认 80 更矮但仍能容纳 icon + label。
              height:
                  labelBehavior == NavigationDestinationLabelBehavior.alwaysHide
                  ? 44
                  : 64,
              selectedIndex: widget.selectedIndex,
              onDestinationSelected: _handleDestinationSelected,
              // 每个 tab 的图标外包自定义胶囊（选中时显示，点击/切换后
              // 胶囊水平超出回弹，图标不动）
              destinations: [
                for (int i = 0; i < widget.destinations.length; i++)
                  NavigationDestination(
                    icon: _CapsuleBounce(
                      key: _bounceKeys[i],
                      selected: widget.selectedIndex == i,
                      child: widget.destinations[i].icon,
                    ),
                    label: widget.destinations[i].label,
                  ),
              ],
            ),
    );
  }

  Widget _buildRailLayout() {
    // 横屏侧栏文字跟随设置页「底部导航栏文字」三档
    //（NavigationBarThemeData.labelBehavior，与竖屏 NavigationBar 同源），
    // 映射到原生 NavigationRail 的 labelType。
    // null（主题未显式设置）按始终显示处理，与竖屏分支的默认行为一致。
    final labelBehavior =
        Theme.of(context).navigationBarTheme.labelBehavior ??
        NavigationDestinationLabelBehavior.alwaysShow;
    final labelType = switch (labelBehavior) {
      NavigationDestinationLabelBehavior.alwaysShow =>
        NavigationRailLabelType.all,
      NavigationDestinationLabelBehavior.onlyShowSelected =>
        NavigationRailLabelType.selected,
      NavigationDestinationLabelBehavior.alwaysHide => NavigationRailLabelType.none,
    };
    return Scaffold(
      key: _scaffoldKey,
      appBar: widget.appBar,
      body: Row(
        children: [
          // Visibility(maintainState) 内部用 Offstage 隐藏：元素树结构保持稳定，
          // hideNavigation 切换时 body（Expanded 子项）不会卸载重建，避免页面
          // dispose→重建死循环导致横屏无法滑动/点击。
          Visibility(
            visible: !widget.hideNavigation,
            maintainState: true,
            child: NavigationRail(
              selectedIndex: widget.selectedIndex,
              onDestinationSelected: _handleDestinationSelected,
              // 每个 tab 的图标外包自定义胶囊（icon 与 selectedIcon 各占一个
              // key 槽位，同一时刻只有其一在树中；选中时显示胶囊，
              // 点击/切换后胶囊水平超出回弹，图标不动）
              destinations: [
                for (int i = 0; i < widget.railDestinations.length; i++)
                  NavigationRailDestination(
                    icon: _CapsuleBounce(
                      key: _bounceKeys[i],
                      selected: widget.selectedIndex == i,
                      child: widget.railDestinations[i].icon,
                    ),
                    selectedIcon: _CapsuleBounce(
                      key: _selectedBounceKeys[i],
                      selected: widget.selectedIndex == i,
                      child: widget.railDestinations[i].selectedIcon,
                    ),
                    label: widget.railDestinations[i].label,
                  ),
              ],
              leading: widget.floatingActionButton,
              labelType: labelType,
              // 原生胶囊已由 theme 关闭（indicatorColor transparent），
              // 胶囊统一由 _CapsuleBounce 绘制
              indicatorColor: Colors.transparent,
              // 图标组垂直居中排列（groupAlignment 0 = 居中，-1 = 顶部）。
              // tab 过多时 NavigationRail 内部自动滚动。宽度/间距均为原生固定规格。
              groupAlignment: 0.0,
            ),
          ),
          Visibility(
            visible: !widget.hideNavigation,
            maintainState: true,
            child: VerticalDivider(
              thickness: 1,
              width: 1,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          Expanded(child: widget.mediumBody ?? widget.body),
        ],
      ),
    );
  }
}

/// 选中指示器胶囊（外观与 M3 原生胶囊一致：secondaryContainer 实心
/// StadiumBorder）+ 点击/切换后胶囊自驱动的水平方向超出回弹。
///
/// - 选中且未启用背景图时显示胶囊（背景图模式下隐藏，与原生覆写一致）；
/// - 胶囊回弹动画仅作用于胶囊本身（Transform.scaleX 包裹胶囊背景），
///   图标保持不动；
/// - 动画由 **MD3E spatial spring**（dampingRatio 0.6 / stiffness 200，
///   与 m3e_core 弹簧一致）驱动：快速拉伸超出（1 → 1.2，过冲）后弹回
///   （1.2 → 1，过冲振荡收敛），自驱动播完；
/// - 不包任何手势/监听，避免与 NavigationBar / NavigationRail 自身的点击
///   竞争；动画由父级（_handleDestinationSelected 点击）或本组件
///   didUpdateWidget（selected false→true 切换）触发。
class _CapsuleBounce extends StatefulWidget {
  const _CapsuleBounce({
    super.key,
    required this.selected,
    required this.child,
  });

  final bool selected;
  final Widget child;

  @override
  State<_CapsuleBounce> createState() => _CapsuleBounceState();
}

class _CapsuleBounceState extends State<_CapsuleBounce>
    with SingleTickerProviderStateMixin {
  /// 回弹段 spring：**m3e_core 官方 MD3E 预设**（[M3EMotion.standardPopup]：
  /// stiffness 1000 / damping 0.6，专为弹出类小部件设计的 bouncy 回弹），
  /// 过冲 ~9.5%，收敛干净，无需手调参数。
  static final _bounceMotion = M3EMotion.standardPopup.toMotion();

  /// 拉伸段固定时长（spring 无固定时长，拉伸用短 animateTo 保证节奏可控）。
  static const Duration _stretchDuration = Duration(milliseconds: 80);

  /// 动画控制器 value 直接表示胶囊水平缩放（1.0 静止）。
  /// 值域覆盖 spring 的运动范围（拉伸过冲到 ~1.25、回弹过冲到 ~0.95）；
  /// 注意 AnimationController 默认值域 [0,1] 会把超出值 clamp 掉，必须显式放宽。
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      lowerBound: 0.8,
      upperBound: 1.4,
    );
    _controller.value = 1.0;
  }

  @override
  void didUpdateWidget(covariant _CapsuleBounce oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 从未选中 → 选中（tab 切换）：胶囊出现时自动播放一次回弹
    if (!oldWidget.selected && widget.selected) {
      playBounce();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 播放一次完整脉冲：固定短时长快速拉伸超出（1→1.2，80ms），
  /// 完成后 spring 回弹（1.2→1.0，m3e_core 官方预设过冲收敛）。
  void playBounce() {
    _controller.stop();
    _controller
        .animateTo(1.2, duration: _stretchDuration, curve: Curves.easeOutCubic)
        .then((_) {
      // 拉伸完成后 spring 弹回（过冲振荡收敛）
      if (mounted) {
        _controller.animateWith(
          _bounceMotion.createSimulation(start: 1.2, end: 1.0),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // 背景图模式下隐藏胶囊（与原生覆写行为一致）
    final useBackgroundImage =
        context.watch<ThemeProvider>().useBackgroundImage;
    final showCapsule = widget.selected && !useBackgroundImage;

    // 胶囊尺寸与 M3 NavigationIndicator 一致（64×32）
    return SizedBox(
      width: 64,
      height: 32,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 胶囊背景：点击后水平超出回弹（scaleX spring 动画仅作用于此层）
          AnimatedBuilder(
            animation: _controller,
            builder: (context, child) => Transform.scale(
              scaleX: _controller.value,
              alignment: Alignment.center,
              child: Container(
                width: 64,
                height: 32,
                decoration: showCapsule
                    ? ShapeDecoration(
                        color: colorScheme.secondaryContainer,
                        shape: const StadiumBorder(),
                      )
                    : null,
              ),
            ),
          ),
          // 图标：保持不动
          widget.child,
        ],
      ),
    );
  }
}

