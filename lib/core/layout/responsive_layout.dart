import 'package:flutter/material.dart';

enum ScreenType { compact, medium, expanded }

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
    return Scaffold(
      key: _scaffoldKey,
      appBar: widget.appBar,
      body: widget.compactBody ?? widget.body,
      floatingActionButton: widget.floatingActionButton,
      bottomNavigationBar: widget.hideNavigation
          ? null
          : NavigationBar(
              height: 56,
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
            // NavigationRail 高度必须等于视口（有界高度）：它内部含 flex 子项，
            // 若放在 SingleChildScrollView 这样的垂直滚动容器里会得到「无界高度」
            // 约束，导致 performLayout 抛 「non-zero flex + unbounded height」异常
            // → 整帧崩溃白屏（桌面宽屏必踩）。所以固定 High 为视口高度，
            // NavigationRail 内部自带滚动，无需外部 ScrollView 包裹。
            child: LayoutBuilder(
              builder: (context, constraints) {
                return ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: constraints.maxHeight,
                    maxHeight: constraints.maxHeight,
                  ),
                  child: NavigationRail(
                    selectedIndex: widget.selectedIndex,
                    onDestinationSelected: widget.onDestinationSelected,
                    destinations: widget.railDestinations,
                    leading: widget.floatingActionButton,
                    groupAlignment: 0.0,
                    labelType: NavigationRailLabelType.all,
                  ),
                );
              },
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
