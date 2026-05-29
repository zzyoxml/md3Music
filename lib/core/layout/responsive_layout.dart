import 'package:flutter/material.dart';

enum ScreenType {
  compact,
  medium,
  expanded,
}

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
  });

  @override
  State<ResponsiveScaffold> createState() => _ResponsiveScaffoldState();
}

class _ResponsiveScaffoldState extends State<ResponsiveScaffold> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final screenType = getScreenType(constraints.maxWidth);
        switch (screenType) {
          case ScreenType.compact:
            return _buildCompactLayout();
          case ScreenType.medium:
            return _buildMediumLayout();
          case ScreenType.expanded:
            return _buildExpandedLayout();
        }
      },
    );
  }

  Widget _buildCompactLayout() {
    return Scaffold(
      key: _scaffoldKey,
      appBar: widget.appBar,
      body: widget.compactBody ?? widget.body,
      floatingActionButton: widget.floatingActionButton,
      bottomNavigationBar: NavigationBar(
        selectedIndex: widget.selectedIndex,
        onDestinationSelected: widget.onDestinationSelected,
        destinations: widget.destinations,
      ),
    );
  }

  Widget _buildMediumLayout() {
    return Scaffold(
      key: _scaffoldKey,
      appBar: widget.appBar,
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: widget.selectedIndex,
            onDestinationSelected: widget.onDestinationSelected,
            destinations: widget.railDestinations,
            leading: widget.floatingActionButton,
          ),
          VerticalDivider(
            thickness: 1,
            width: 1,
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          Expanded(
            child: widget.mediumBody ?? widget.body,
          ),
        ],
      ),
    );
  }

  Widget _buildExpandedLayout() {
    return Scaffold(
      key: _scaffoldKey,
      appBar: widget.appBar,
      body: Row(
        children: [
          NavigationDrawer(
            selectedIndex: widget.selectedIndex,
            onDestinationSelected: (index) {
              widget.onDestinationSelected(index);
            },
            children: [
              ...widget.drawerDestinations,
            ],
          ),
          VerticalDivider(
            thickness: 1,
            width: 1,
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          Expanded(
            child: widget.expandedBody ?? widget.mediumBody ?? widget.body,
          ),
        ],
      ),
    );
  }
}
