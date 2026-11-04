import 'package:dpad/dpad.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../modules/player/mini_player.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/tab_config_provider.dart';
import '../../providers/theme_provider.dart';
import '../build_flags.dart';
import '../remote/tv_top_chrome_scope.dart';
import '../utils/app_haptics.dart';
import 'responsive_shell.dart';
import 'tv_nav_focus_bridge.dart';
import 'tv_player_bar_focus_bridge.dart';

/// tv: TV 版主壳层——顶部双层导航 + 内容区。
///
/// ## 结构（需求：navbar 全部移到屏幕顶部，分两层）
///
/// 1. **第一层（最上）**：账号头像+昵称胶囊（左）/ MiniPlayer（中，原组件）/
///    搜索按钮（右）。整层一个 DpadRegion：左右在三者间移动，下到第二层。
/// 2. **第二层**：原主导航（tab 栏），横向 ListView 可滚动。聚焦后左右方向键
///    直接切 tab（焦点切换即选中，无需 OK）；tab 名称与图标同行、仅当前 tab
///    显示；下键进入页面内容，上键回第一层。
///
/// ## 焦点链路（页面内 → 顶栏）
///
/// - 内容区（ResponsiveShell 的 per-tab DpadRegion）上边缘 → 第二层当前 tab；
/// - 连发层持续推动时，焦点到第二层后再按上键 → 第一层 MiniPlayer
///   （第二层 onEdge(up) → TvPlayerBarFocusBridge.focusMiniPlayer）；
/// - 第一层下键 → 第二层当前 tab；第二层下键 → 内容区
///   （ResponsiveShellState.focusActiveTabContent）。
class TvMainShell extends StatefulWidget {
  const TvMainShell({
    super.key,
    required this.visibleTabs,
    required this.selectedIndex,
    required this.railDestinations,
    required this.onDestinationSelected,
    required this.shellKey,
    required this.body,
    this.hidden = false,
  });

  final List<TabItem> visibleTabs;
  final int selectedIndex;

  /// 与 [visibleTabs] 平行的 rail 目标（icon/selectedIcon/label），由
  /// `_MainLayout` 既有 `_buildRailDestination` 产出，避免图标映射分叉。
  final List<NavigationRailDestination> railDestinations;

  final ValueChanged<int> onDestinationSelected;

  /// ResponsiveShell 的 key：第二层下边缘经它把焦点交还内容区。
  final GlobalKey<ResponsiveShellState> shellKey;

  final Widget body;

  /// 沉浸态（封面流横屏全屏）：整条顶栏让位，只留内容。
  final bool hidden;

  @override
  State<TvMainShell> createState() => _TvMainShellState();
}

class _TvMainShellState extends State<TvMainShell> {
  /// tv: 第二层 tab 项焦点节点池（每项 1 个，随本 State dispose）。
  /// 复用禁忌同 ResponsiveScaffold._tvWrapNavIcon：每次 build 新建会逐帧泄漏，
  /// 且选中态切换时节点身份变化会丢焦点。
  final Map<int, FocusNode> _tabNodes = <int, FocusNode>{};

  /// tv: 首屏 autofocus 一次性门控（只允许第一帧生效，防重挂载抢焦点）。
  bool _autofocusDone = false;

  /// 第一层头像胶囊与搜索按钮的焦点节点（MiniPlayer 的滑动区节点由
  /// MiniPlayer 自持并登记到 TvPlayerBarFocusBridge）。
  final FocusNode _accountNode = FocusNode(debugLabel: 'tv/top-account');
  final FocusNode _searchNode = FocusNode(debugLabel: 'tv/top-search');

  @override
  void initState() {
    super.initState();
    if (kTvBuild) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _autofocusDone = true;
      });
    }
  }

  @override
  void dispose() {
    for (final FocusNode node in _tabNodes.values) {
      node.dispose();
    }
    _tabNodes.clear();
    _accountNode.dispose();
    _searchNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.hidden) return widget.body;
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        _buildTopLayer(colorScheme),
        _buildTabLayer(colorScheme),
        Expanded(child: widget.body),
      ],
    );
  }

  // ── 第一层 ────────────────────────────────────────────────

  Widget _buildTopLayer(ColorScheme colorScheme) {
    // 底色口径与底部常驻条同源（壁纸档两层 20% surface，见
    // resolveMiniPlayerBackground 的说明）；非壁纸档用低容器色，让中央
    // MiniPlayer 的 surfaceContainerHigh 读作独立对象。
    final bool useBackgroundImage =
        context.watch<ThemeProvider>().useBackgroundImage;
    final Color background = useBackgroundImage
        ? colorScheme.surface.withValues(alpha: 0.2)
        : colorScheme.surfaceContainerLow;
    return TvTopChromeScope(
      child: DpadRegion(
        memoryKey: 'tv/top-layer',
        debugLabel: 'tv-top-layer',
        horizontalEdge: DpadEdgeBehavior.stop,
        verticalEdge: DpadEdgeBehavior.stop,
        onEdge: (direction) {
          // 下边缘 = 第二层 tab 栏（落在当前 tab 上）。
          if (direction == TraversalDirection.down) {
            TvNavFocusBridge.instance.focusNavItem(
              widget.selectedIndex.clamp(0, widget.visibleTabs.length - 1),
            );
          }
          // 上边缘是屏幕顶，无动作。
        },
        child: Container(
          color: background,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              _buildAccountCapsule(colorScheme),
              const SizedBox(width: 12),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      // 原 MiniPlayer 组件：TV 变体去掉下一首/桌面歌词按钮
                      // （见 mini_player.dart 的 kTvBuild 分支）。
                      child: const MiniPlayer(),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              _buildSearchButton(colorScheme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAccountCapsule(ColorScheme colorScheme) {
    final userInfo = context.watch<KugouProvider>().userInfo;
    final String? nickname = userInfo?.nickname;
    final String? avatarUrl = userInfo?.avatar;
    return DpadFocusable(
      focusNode: _accountNode,
      // 指针点击交给内容自身（本壳层无指针路径），避免与 OK 双触发。
      tapToSelect: false,
      onSelect: () =>
          Navigator.of(context, rootNavigator: true).pushNamed('/user'),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 180),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildAvatar(avatarUrl, colorScheme),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                (nickname == null || nickname.isEmpty) ? '未登录' : nickname,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAvatar(String? url, ColorScheme colorScheme) {
    if (url == null || url.isEmpty) {
      return CircleAvatar(
        radius: 15,
        backgroundColor: colorScheme.primaryContainer,
        child: Icon(
          Icons.person,
          size: 18,
          color: colorScheme.onPrimaryContainer,
        ),
      );
    }
    return CircleAvatar(
      radius: 15,
      backgroundColor: colorScheme.primaryContainer,
      backgroundImage: NetworkImage(url),
    );
  }

  Widget _buildSearchButton(ColorScheme colorScheme) {
    return DpadFocusable(
      focusNode: _searchNode,
      tapToSelect: false,
      onSelect: _openSearch,
      child: IconButton(
        visualDensity: const VisualDensity(horizontal: -3, vertical: -2),
        constraints: const BoxConstraints.tightFor(width: 44, height: 44),
        icon: const Icon(Icons.search),
        tooltip: '搜索',
        onPressed: _openSearch,
      ),
    );
  }

  void _openSearch() {
    Navigator.of(context, rootNavigator: true).pushNamed('/search');
  }

  // ── 第二层 ────────────────────────────────────────────────

  Widget _buildTabLayer(ColorScheme colorScheme) {
    return DpadRegion(
      memoryKey: 'tv/main-nav',
      debugLabel: 'tv-main-nav',
      horizontalEdge: DpadEdgeBehavior.stop,
      verticalEdge: DpadEdgeBehavior.stop,
      onEdge: (direction) {
        switch (direction) {
          case TraversalDirection.up:
            // 上边缘 = 第一层。短按上键从内容区上来时落当前 tab；持续按住时
            // 连发层会把焦点继续推到第一层 MiniPlayer（需求：页面内长按上
            // 方向键返回顶栏，焦点落 MiniPlayer）。
            TvPlayerBarFocusBridge.instance.focusMiniPlayer();
          case TraversalDirection.down:
            // 下边缘 = 页面内容（需求：从 navbar 按下方向键进入页面）。
            widget.shellKey.currentState?.focusActiveTabContent();
          default:
            break;
        }
      },
      child: Container(
        color: colorScheme.surfaceContainer,
        height: 56,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          itemCount: widget.visibleTabs.length,
          itemBuilder: (context, index) =>
              _buildTabItem(colorScheme, index),
        ),
      ),
    );
  }

  Widget _buildTabItem(ColorScheme colorScheme, int index) {
    final bool selected = index == widget.selectedIndex;
    final FocusNode node = _tabNodes.putIfAbsent(
      index,
      () => FocusNode(debugLabel: 'tv/tab-$index'),
    );
    // 登记到焦点移交桥：内容区上边缘 / _isFocusUsable 都靠它识别导航栏节点。
    TvNavFocusBridge.instance.register(index, node);
    final NavigationRailDestination destination =
        widget.railDestinations[index];
    // selectedIcon 构造时已归一（selectedIcon = selectedIcon ?? icon，恒非空，
    // 见 flutter navigation_rail.dart:1115），直接取用。
    final Widget icon = selected
        ? destination.selectedIcon
        : destination.icon;
    return TvTabBarItem(
      focusNode: node,
      autofocus: index == 0 && !_autofocusDone,
      selected: selected,
      icon: icon,
      label: widget.visibleTabs[index].label,
      onFocused: () {
        // 聚焦即选中：左右方向键直接切 tab，无需 OK 确认（需求口径）。
        if (!selected) {
          AppHaptics.tick(HapticCategory.navigation);
          widget.onDestinationSelected(index);
        }
      },
      // OK 保留为兼容入口（读屏/指针设备）：再次确认当前 tab。
      onSelect: () {
        if (!selected) widget.onDestinationSelected(index);
      },
    );
  }
}

/// tv: 第二层 tab 栏的单项（图标 + 仅当前 tab 显示的名称，同行）。
///
/// 从 TvMainShell 抽出为公开组件：焦点即选中的语义可被普通 flutter test
/// 钉住（AGENTS §12 惯例），不必拉起整壳的 Provider 链。
class TvTabBarItem extends StatelessWidget {
  const TvTabBarItem({
    super.key,
    required this.selected,
    required this.icon,
    required this.label,
    required this.onFocused,
    required this.onSelect,
    this.focusNode,
    this.autofocus = false,
  });

  final bool selected;
  final Widget icon;
  final String label;

  /// 获得焦点（= 选中该 tab）。
  final VoidCallback onFocused;

  /// OK 键（兼容入口）。
  final VoidCallback onSelect;

  final FocusNode? focusNode;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    return DpadFocusable(
      focusNode: focusNode,
      autofocus: autofocus,
      onFocusChange: (focused) {
        if (focused) onFocused();
      },
      onSelect: onSelect,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            IconTheme(
              data: IconThemeData(
                color: selected
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant,
                size: 24,
              ),
              child: icon,
            ),
            // tab 名称与图标同行，仅当前 tab 显示（需求口径）。
            if (selected) ...[
              const SizedBox(width: 6),
              Text(
                label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
