import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/repositories/settings_repository.dart';
import '../../modules/player/now_playing_bar.dart';
import '../../modules/search/search_page.dart';
import '../../providers/player_provider.dart';
import '../../providers/tab_config_provider.dart';
import '../../providers/theme_provider.dart';
import '../../widgets/resizable_splitter.dart';
import '../utils/app_text_context_menu.dart';
import 'adaptive_navigator.dart';
import 'page_layout.dart';

/// 桌面音乐软件式外壳（横屏平板，见横屏平板重设计计划 4.1）。
///
/// 结构：
/// ```
/// Column [
///   (可选) header 提示条,
///   Expanded( Row [ 侧栏, 分隔条, Expanded(内容区) ] ),
///   NowPlayingBar                       // 全宽底部播放栏
/// ]
/// 内容区 = Column [ 顶部工具栏, Expanded(每 Tab 一个懒建嵌套 Navigator) ]
/// ```
///
/// - **侧栏**：复用 [TabConfigProvider] 的可见 Tab（`railDestinations` 直接取
///   图标/文字，零新增映射），固定宽度由 [ResizableSplitter] 拖拽调整并持久化
///   （[SettingsRepository.setDesktopSidebarWidth]）。
/// - **内容区**：每个 Tab 一个懒建的嵌套 [Navigator]（首次访问才构建，之后由
///   [IndexedStack] 保活）。详情页原有的 `Navigator.of(context).push(...)` 因此
///   自动落进当前 Tab 的中央内容区，无需改各调用点（见计划 4.4 A 类）。
/// - **返回**：顶部工具栏返回键与系统返回都驱动当前 Tab 的嵌套 Navigator；切换
///   Tab 时把离开的 Tab 栈复位到根（计划 4.4）。
class DesktopShell extends StatefulWidget {
  const DesktopShell({
    super.key,
    required this.visibleTabs,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.pageBuilder,
    required this.railDestinations,
    this.header,
  });

  final List<TabItem> visibleTabs;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  /// 由 tabId 构建该 Tab 的根页面（复用 `_MainLayout._buildPageForTab`）。
  final Widget Function(String tabId) pageBuilder;

  /// 复用主布局的 rail 目标（图标 + 文字），侧栏据此渲染，零新增映射。
  final List<NavigationRailDestination> railDestinations;

  /// 顶部横幅（如本地服务器未启动提示），置于整个 shell 最上方。
  final Widget? header;

  @override
  State<DesktopShell> createState() => DesktopShellState();
}
class DesktopShellState extends State<DesktopShell> {
  static const double _kMinSidebar = 200.0;
  static const double _kMaxSidebar = 380.0;
  static const double _kDefaultSidebar = 240.0;

  /// 走双栏 Master-Detail 的 Tab（计划 4.4 B 类）：选一项在右侧详情面板打开。
  /// 其余 Tab 走中央内容区导航（A 类），详情整屏 push 进中央栈。
  // 桌面版保留既有装配范围，共享形态表只作为能力来源。
  static final Set<String> _kTwoPaneTabs = kTwoPaneTabs.intersection({
    'library',
    'favorites',
  });

  final SettingsRepository _settings = SettingsRepository();

  /// 每个 Tab 的中央内容 Navigator（按 tabId 保存，跨 Tab 重排也稳定）。
  final Map<String, GlobalKey<NavigatorState>> _navKeys = {};

  /// 双栏 Tab 的右侧详情面板 Navigator（按 tabId 保存），供返回键驱动。
  final Map<String, GlobalKey<NavigatorState>> _detailKeys = {};

  /// 双栏 Tab 详情面板的前进历史（按 tabId 保存），供工具栏「前进」。
  final Map<String, ForwardHistory> _forwardHistories = {};

  /// 已访问过的 Tab（首次访问才构建其 Navigator，之后 IndexedStack 保活）。
  final Set<String> _visited = {};

  double _sidebarWidth = _kDefaultSidebar;

  @override
  void initState() {
    super.initState();
    _markVisited();
    _loadSidebarWidth();
  }

  Future<void> _loadSidebarWidth() async {
    final w = await _settings.getDesktopSidebarWidth();
    if (!mounted || w == null) return;
    setState(() => _sidebarWidth = w.clamp(_kMinSidebar, _kMaxSidebar));
  }

  void _markVisited() {
    final idx = widget.selectedIndex;
    if (idx >= 0 && idx < widget.visibleTabs.length) {
      _visited.add(widget.visibleTabs[idx].id);
    }
  }

  @override
  void didUpdateWidget(covariant DesktopShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切换 Tab：把离开的 Tab 栈复位到根（计划 4.4），并标记新 Tab 已访问。
    if (oldWidget.selectedIndex != widget.selectedIndex) {
      final leaving = oldWidget.visibleTabs;
      if (oldWidget.selectedIndex >= 0 &&
          oldWidget.selectedIndex < leaving.length) {
        final leftId = leaving[oldWidget.selectedIndex].id;
        // 复位期间抑制前进历史记录（popUntil 的 pop 不应记入前进栈），并清空。
        final hist = _forwardHistories[leftId];
        hist?.suppressRecord = true;
        hist?.invalidate();
        // 推迟到帧末：didUpdateWidget 处于 build 阶段，直接 pop 会触发
        // Navigator 在 build 期间 setState 的断言。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _navKeys[leftId]?.currentState?.popUntil((r) => r.isFirst);
          // 双栏 Tab：同时复位右侧详情面板栈（计划 4.4）。
          _detailKeys[leftId]?.currentState?.popUntil((r) => r.isFirst);
          hist?.suppressRecord = false;
        });
      }
      _markVisited();
    }
  }

  GlobalKey<NavigatorState> _navKey(String tabId) =>
      _navKeys.putIfAbsent(tabId, () => GlobalKey<NavigatorState>());

  GlobalKey<NavigatorState> _detailKey(String tabId) =>
      _detailKeys.putIfAbsent(tabId, () => GlobalKey<NavigatorState>());

  ForwardHistory _forwardHistory(String tabId) =>
      _forwardHistories.putIfAbsent(tabId, () => ForwardHistory());

  @override
  void dispose() {
    for (final h in _forwardHistories.values) {
      h.dispose();
    }
    super.dispose();
  }

  String? _currentTabId() {
    final idx = widget.selectedIndex;
    if (idx < 0 || idx >= widget.visibleTabs.length) return null;
    return widget.visibleTabs[idx].id;
  }

  /// 供根 [PopScope] 调用与工具栏返回键：优先回退当前 Tab 的详情面板栈
  /// （双栏），其次回退中央内容栈。可回退则回退并返回 true。
  Future<bool> maybePop() async {
    final tabId = _currentTabId();
    final detail = tabId == null ? null : _detailKeys[tabId]?.currentState;
    if (detail != null && await detail.maybePop()) return true;
    final nav = _activeNav();
    // 初始路由中的设置子页也有 PopScope，不能只看路由栈数量。
    return await nav?.maybePop() ?? false;
  }

  /// 当前 Tab 是否存在可回退历史（详情面板栈或中央内容栈）。
  bool _activeCanPop() {
    final tabId = _currentTabId();
    final detail = tabId == null ? null : _detailKeys[tabId]?.currentState;
    if (detail != null && detail.canPop()) return true;
    return _activeNav()?.canPop() ?? false;
  }

  /// 当前 Tab 是否有可「前进」的详情历史（仅双栏 Tab 的详情面板参与）。
  bool _activeCanGoForward() {
    final tabId = _currentTabId();
    if (tabId == null || !_kTwoPaneTabs.contains(tabId)) return false;
    return _forwardHistories[tabId]?.canGoForward ?? false;
  }

  /// 工具栏「前进」：把最近一次「后退」弹出的详情页原样重建（重放期间抑制
  /// 观察者清栈），使浏览器式前进/后退闭环。
  void _goForward() {
    final tabId = _currentTabId();
    if (tabId == null || !_kTwoPaneTabs.contains(tabId)) return;
    final hist = _forwardHistories[tabId];
    final detail = _detailKeys[tabId]?.currentState;
    if (hist == null || detail == null) return;
    final builder = hist.takeNext();
    if (builder == null) return;
    hist.replaying = true;
    detail.push(
      MaterialPageRoute(
        builder: builder,
        settings: RouteSettings(arguments: ForwardTag(builder)),
      ),
    );
    // didPush 在 push 调用栈内同步触发；帧末复位 replaying 兜底多级前进。
    WidgetsBinding.instance.addPostFrameCallback((_) => hist.replaying = false);
  }

  NavigatorState? _activeNav() {
    final idx = widget.selectedIndex;
    if (idx < 0 || idx >= widget.visibleTabs.length) return null;
    return _navKeys[widget.visibleTabs[idx].id]?.currentState;
  }

  void _onSidebarDelta(double dx) {
    setState(() {
      _sidebarWidth = (_sidebarWidth + dx).clamp(_kMinSidebar, _kMaxSidebar);
    });
  }

  void _persistSidebarWidth() {
    // ignore: discarded_futures
    _settings.setDesktopSidebarWidth(_sidebarWidth);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // 壁纸模式下这层必须透明，否则会整窗盖住 app.dart 里 `Positioned.fill`
    // 的 AppBackground 壁纸层 —— 表现为"开了自定义壁纸却完全看不到"。
    //
    // 背景模式判定用 `useBackgroundImage`（用户开关本身）：
    // `backgroundImageProvider` 在无用户图时会回落到内置默认壁纸，
    // 所以"开关开 + 未选图"仍属壁纸模式，照样该透出默认壁纸。
    final wallpaperOn = context.watch<ThemeProvider>().useBackgroundImage;
    return Material(
      color: wallpaperOn ? Colors.transparent : cs.surface,
      // 键鼠增强（计划 4.8，作为增强）：接外接键盘时的快捷键。文本框聚焦时
      // 字符键由 EditableText 消费、不冒泡到此，故搜索框输入不受影响。
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): maybePop,
          const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true):
              maybePop,
          const SingleActivator(LogicalKeyboardKey.space): () =>
              _togglePlay(context),
          const SingleActivator(LogicalKeyboardKey.mediaPlayPause): () =>
              _togglePlay(context),
          const SingleActivator(LogicalKeyboardKey.arrowRight, control: true):
              () => _skip(context, next: true),
          const SingleActivator(LogicalKeyboardKey.arrowLeft, control: true):
              () => _skip(context, next: false),
          const SingleActivator(LogicalKeyboardKey.mediaTrackNext): () =>
              _skip(context, next: true),
          const SingleActivator(LogicalKeyboardKey.mediaTrackPrevious): () =>
              _skip(context, next: false),
        },
        child: SafeArea(
          // 横屏左右安全区：侧栏 / 内容 / 底部播放栏避开异形屏/圆角屏的左右
          // cutout。上下不占用，交给内部工具栏与页面自身处理。
          top: false,
          bottom: false,
          child: Column(
            children: [
              if (widget.header != null) widget.header!,
              Expanded(
                child: Row(
                  children: [
                    SizedBox(
                      width: _sidebarWidth,
                      child: _DesktopSidebar(
                        railDestinations: widget.railDestinations,
                        selectedIndex: widget.selectedIndex,
                        onDestinationSelected: widget.onDestinationSelected,
                      ),
                    ),
                    ResizableSplitter(
                      onDelta: _onSidebarDelta,
                      onDragEnd: _persistSidebarWidth,
                    ),
                    Expanded(child: _buildContentRegion(context)),
                  ],
                ),
              ),
              const NowPlayingBar(),
            ],
          ),
        ),
      ),
    );
  }

  /// 空格 / 媒体键：切换播放/暂停（无正在播放歌曲时忽略）。
  void _togglePlay(BuildContext context) {
    final p = context.read<PlayerProvider>();
    if (p.currentSong == null) return;
    // ignore: discarded_futures
    p.isPlaying ? p.pause() : p.resume();
  }

  /// Ctrl+←/→ 或媒体上/下曲键：切歌。
  void _skip(BuildContext context, {required bool next}) {
    final p = context.read<PlayerProvider>();
    // ignore: discarded_futures
    next ? p.next() : p.previous();
  }

  Widget _buildContentRegion(BuildContext context) {
    final tabCount = widget.visibleTabs.length;
    // 顶部工具栏整块移除：它是一条独立的 56px 色带（surface + 下边框），
    // 与内容区背景割裂；而它承载的两项能力都已有更好的入口——
    //   · 前进/后退：双栏详情面板自带返回，页面级路由另有系统返回语义；
    //   · 全局搜索：各 Tab 自己的 AppBar 都有搜索入口（发现页右上角 🔍），
    //     且最终都跳同一个 `SearchPage`（见 _submitSearch 的实现）。
    // 原实现保留注释，需要时按 _DesktopToolbar 的参数恢复即可。
    //
    // _DesktopToolbar(
    //   canPop: _activeCanPop(),
    //   canGoForward: _activeCanGoForward(),
    //   onBack: maybePop,
    //   onForward: _goForward,
    //   onSubmitSearch: _submitSearch,
    // ),
    return Expanded(
      child: tabCount == 0
          ? const SizedBox.shrink()
          : IndexedStack(
              index: widget.selectedIndex.clamp(0, tabCount - 1),
              children: [
                for (final tab in widget.visibleTabs)
                  _visited.contains(tab.id)
                      ? _buildTabNavigator(tab.id)
                      : const SizedBox.shrink(),
              ],
            ),
    );
  }

  Widget _buildTabNavigator(String tabId) {
    return Navigator(
      key: _navKey(tabId),
      observers: [_ToolbarSyncObserver(_onNavChanged)],
      onGenerateRoute: (settings) => MaterialPageRoute(
        settings: settings,
        builder: (_) => _kTwoPaneTabs.contains(tabId)
            // B 类：主列表装进双栏，详情落右侧面板（计划 4.4 B）。详情面板栈
            // 由外壳注入的 key 驱动返回键，ToolbarSync 观察者刷新可用态并记录
            // 前进历史（供工具栏「前进」）。
            ? DesktopTwoPane(
                master: widget.pageBuilder(tabId),
                detailKey: _detailKey(tabId),
                history: _forwardHistory(tabId),
                detailObservers: [
                  _ToolbarSyncObserver(
                    _onNavChanged,
                    history: _forwardHistory(tabId),
                  ),
                ],
              )
            : widget.pageBuilder(tabId),
      ),
    );
  }

  /// Navigator 栈变化后刷新工具栏返回键可用态（延迟到帧末，避免导航期 setState）。
  void _onNavChanged() {
    if (mounted) setState(() {});
  }

  /// 顶部工具栏搜索框即全局搜索入口（计划 4.3）：提交查询后在当前 Tab 的
  /// 中央内容区 push 搜索页并立即执行搜索（预填 query）。
  void _submitSearch(String query) {
    final q = query.trim();
    if (q.isEmpty) return;
    _activeNav()?.push(
      MaterialPageRoute(
        builder: (_) => SearchPage(initialQuery: q),
      ),
    );
  }
}

/// 桌面侧栏：复用 rail 目标渲染的可见 Tab 列表（图标 + 文字）。
class _DesktopSidebar extends StatelessWidget {
  const _DesktopSidebar({
    required this.railDestinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
  });

  final List<NavigationRailDestination> railDestinations;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    // 壁纸模式下半透明，让底层 AppBackground 壁纸透出（与外壳同一处理）。
    final wallpaperOn = context.watch<ThemeProvider>().useBackgroundImage;
    return Material(
      color: wallpaperOn
          ? cs.surfaceContainerLow.withValues(alpha: 0.2)
          : cs.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Row(
              children: [
                Icon(Icons.music_note, color: cs.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'MD3Music',
                    style: textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: railDestinations.length,
              itemBuilder: (context, i) {
                final selected = i == selectedIndex;
                final dest = railDestinations[i];
                return _SidebarItem(
                  icon: selected
                      ? dest.selectedIcon
                      : dest.icon,
                  label: dest.label,
                  selected: selected,
                  onTap: () => onDestinationSelected(i),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final Widget icon;
  final Widget label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fg = selected ? cs.onSecondaryContainer : cs.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected ? cs.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(24),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                IconTheme.merge(
                  data: IconThemeData(color: fg),
                  child: icon,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: DefaultTextStyle.merge(
                    style: TextStyle(
                      color: selected ? cs.onSecondaryContainer : cs.onSurface,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    child: label,
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

/// 顶部工具栏：后退/前进 + 标题 + 全局搜索框（计划 4.3）。
class _DesktopToolbar extends StatelessWidget {
  const _DesktopToolbar({
    required this.canPop,
    required this.canGoForward,
    required this.onBack,
    required this.onForward,
    required this.onSubmitSearch,
  });

  final bool canPop;
  final bool canGoForward;
  final VoidCallback onBack;
  final VoidCallback onForward;
  final ValueChanged<String> onSubmitSearch;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(bottom: BorderSide(color: cs.outlineVariant, width: 1)),
      ),
      child: Row(
        children: [
          // 后退 / 前进箭头已移除（用户反馈在桌面布局下多余且占位）：
          // 双栏详情面板本身有返回入口，页面级路由另有系统返回语义，
          // 工具栏再挂一对浏览器式箭头既冗余又把搜索框挤到右侧。
          // 原实现保留注释，需要时按canPop / canGoForward 恢复。
          //
          // IconButton(
          //   icon: const Icon(Icons.arrow_back),
          //   tooltip: '后退',
          //   onPressed: canPop ? onBack : null,
          // ),
          // IconButton(
          //   icon: const Icon(Icons.arrow_forward),
          //   tooltip: '前进',
          //   onPressed: canGoForward ? onForward : null,
          // ),
          // 不再在工具栏显示标题：各 Tab 页自带 AppBar 已提供标题，
          // 工具栏再显示一份会与页面标题重复（问题⑤）。留白撑开搜索框到右侧。
          const Spacer(),
          SizedBox(width: 260, child: _SearchField(onSubmit: onSubmitSearch)),
        ],
      ),
    );
  }
}

/// 顶部工具栏可编辑搜索框：输入后回车提交，在中央内容区展示搜索结果。
class _SearchField extends StatefulWidget {
  const _SearchField({required this.onSubmit});
  final ValueChanged<String> onSubmit;

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final q = _controller.text.trim();
    if (q.isEmpty) return;
    widget.onSubmit(q);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            Icon(Icons.search, size: 20, color: cs.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _controller,
                contextMenuBuilder: buildAppTextContextMenu,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _submit(),
                style: Theme.of(context).textTheme.bodyMedium,
                decoration: InputDecoration(
                  isCollapsed: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  border: InputBorder.none,
                  hintText: '搜索音乐、歌手、歌单',
                  hintStyle: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 监听嵌套 Navigator 栈变化，通知外壳刷新工具栏返回键可用态；若注入了
/// [history]（仅双栏详情面板），还负责回收/失效前进历史。
class _ToolbarSyncObserver extends NavigatorObserver {
  _ToolbarSyncObserver(this.onChanged, {this.history});
  final VoidCallback onChanged;
  final ForwardHistory? history;

  void _schedule() =>
      WidgetsBinding.instance.addPostFrameCallback((_) => onChanged());

  @override
  void didPush(Route route, Route? previousRoute) {
    // 正向导航（非前进重放）令既有前进栈失效，符合浏览器语义。
    if (history != null && !history!.replaying) history!.invalidate();
    _schedule();
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    // 「后退」弹出带标签的详情页 → 记入前进栈，供工具栏「前进」重建。
    final tag = route.settings.arguments;
    if (history != null && tag is ForwardTag) history!.recordBack(tag.builder);
    _schedule();
  }

  @override
  void didRemove(Route route, Route? previousRoute) => _schedule();

  @override
  void didReplace({Route? newRoute, Route? oldRoute}) => _schedule();
}

