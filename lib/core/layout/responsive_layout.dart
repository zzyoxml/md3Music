import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/device_provider.dart';

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
              // 公开版偏好：仅图标（alwaysHide）时高度减半紧凑显示；一旦显示文字
              // 用默认高度容纳 icon + label，避免 label 被裁剪。
              height:
                  labelBehavior == NavigationDestinationLabelBehavior.alwaysHide
                  ? 44
                  : null,
              selectedIndex: widget.selectedIndex,
              onDestinationSelected: widget.onDestinationSelected,
              destinations: widget.destinations,
            ),
    );
  }

  Widget _buildRailLayout() {
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
            child: CompactNavigationRail(
              selectedIndex: widget.selectedIndex,
              onDestinationSelected: widget.onDestinationSelected,
              destinations: widget.railDestinations,
              leading: widget.floatingActionButton,
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

/// 紧凑侧边导航栏：仅图标（24dp），图标间距 6dp（M3 NavigationRail 内置
/// 12dp 的一半），图标组整体垂直居中，tab 过多时可滚动。
///
/// 不直接用 NavigationRail 的原因：
/// - 其 destination 间距（12dp）是私有常量，公开 API 无法调小；
/// - 外包 SingleChildScrollView 会导致内部 Flexible+Align 收到无界高度，
///   groupAlignment 垂直居中失效（图标堆在顶部、下方大片空白）。
///
/// 背景与指示器颜色读取 NavigationRailTheme（背景图模式下由
/// app.dart 覆写为半透明 surface 透出壁纸）。
class CompactNavigationRail extends StatelessWidget {
  const CompactNavigationRail({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
    this.leading,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<NavigationRailDestination> destinations;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final railTheme = NavigationRailTheme.of(context);
    final colorScheme = Theme.of(context).colorScheme;

    return Material(
      color: railTheme.backgroundColor ?? colorScheme.surface,
      // 左侧安全区（横屏刘海/挖孔），与原 NavigationRail 的 SafeArea 行为一致
      child: SafeArea(
        left: true,
        top: false,
        right: false,
        bottom: false,
        child: SizedBox(
          // 仅容纳 24dp 图标 + 28dp 指示器胶囊（AGENTS.md §8.6）
          width: 34,
          child: Column(
            children: [
              if (leading != null) ...[leading!, const SizedBox(height: 8)],
              Expanded(
                // Center + SingleChildScrollView（内容小→收缩居中；内容多→撑满滚动）
                child: Center(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (int i = 0; i < destinations.length; i++)
                          _CompactRailDestination(
                            selected: selectedIndex == i,
                            icon:
                                selectedIndex == i
                                ? destinations[i].selectedIcon
                                : destinations[i].icon,
                            indicatorColor:
                                railTheme.indicatorColor ??
                                colorScheme.secondaryContainer,
                            selectedIconColor:
                                railTheme.selectedIconTheme?.color ??
                                colorScheme.onSecondaryContainer,
                            unselectedIconColor:
                                railTheme.unselectedIconTheme?.color ??
                                colorScheme.onSurfaceVariant,
                            onTap: () => onDestinationSelected(i),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CompactRailDestination extends StatelessWidget {
  const _CompactRailDestination({
    required this.selected,
    required this.icon,
    required this.indicatorColor,
    required this.selectedIconColor,
    required this.unselectedIconColor,
    required this.onTap,
  });

  final bool selected;
  final Widget icon;
  final Color indicatorColor;
  final Color selectedIconColor;
  final Color unselectedIconColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(17),
      child: Padding(
        // 上下各 3 → 相邻图标间距 6dp（M3 默认 12dp 的一半）
        padding: EdgeInsets.symmetric(vertical: 3),
        child: Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: selected
              ? ShapeDecoration(
                  color: indicatorColor,
                  shape: const StadiumBorder(),
                )
              : null,
          child: IconTheme.merge(
            data: IconThemeData(
              size: 24,
              color: selected ? selectedIconColor : unselectedIconColor,
            ),
            child: icon,
          ),
        ),
      ),
    );
  }
}
