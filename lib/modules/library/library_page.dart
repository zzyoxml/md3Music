import 'package:dpad/dpad.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../core/build_flags.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/layout/page_title_alignment.dart';
import '../../core/layout/tv_fab_focus_bridge.dart';
import '../../core/utils/app_text_context_menu.dart';
import '../../core/utils/app_toast.dart';
import '../../core/utils/tab_snap_physics.dart';
import '../../providers/library_provider.dart';
import '../../providers/local_favorites_provider.dart';
import '../player/full_player_route.dart';
import 'albums_page.dart';
import 'artists_page.dart';
import 'folders_page.dart';
import 'songs_page.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _searchController = TextEditingController();
  late FocusNode _searchFocusNode;

  /// tv: 扫描入口 FAB 的焦点节点。显式持有一份，好让内容区下边缘能把焦点
  /// 移交过来——FAB 贴在右下角，几何上既不在末行下方、水平投影也不重叠，
  /// dpad 的两条候选判定都不成立（详见 [TvFabFocusBridge] 头注释）。
  final FocusNode _tvFabNode = FocusNode(debugLabel: 'library_scan_fab');

  /// tv: 扫描弹层首项（扫描音乐）的焦点节点。显式持有一份，弹层打开后由
  /// [_tvEnsureSheetFocus] 主动请求焦点——`autofocus` 在 m3e 弹层这种延迟挂载
  /// 的路由里不可靠（2026-10-05 真机实测：焦点落到末行开关上）。
  final FocusNode _tvScanMenuFirstNode =
      FocusNode(debugLabel: 'scan_menu_rescan');

  /// [_tvEnsureSheetFocus] 的自锁标记，保证只请求一次焦点。
  bool _tvScanMenuFocusRequested = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    _searchFocusNode = FocusNode();
    if (kTvBuild) TvFabFocusBridge.instance.register(_tvFabNode);
    // 监听 FullPlayer 展开状态：展开时取消搜索框焦点，防止返回时自动弹输入法
    playerExpansion.addListener(_onPlayerExpansionChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 页面加载后立即取消搜索框焦点，防止输入法自动弹出
      _searchFocusNode.unfocus();
      final provider = context.read<LibraryProvider>();
      // 1. 先恢复上次扫描结果（缓存），让用户立即看到歌曲列表
      provider.loadSavedSongs();
      // 2. 加载已配置的扫描目录
      provider.loadScanFolders();
    });
  }

  /// FullPlayer 展开时取消搜索框焦点，避免返回后输入法自动弹出
  void _onPlayerExpansionChanged() {
    if (playerExpansion.value > 0.5) {
      _searchFocusNode.unfocus();
    }
  }

  /// 功能操作不应保留输入焦点；在新路由记忆旧焦点前同步清除。
  void _dismissSearchFocus() {
    _searchFocusNode.unfocus();
    FocusManager.instance.primaryFocus?.unfocus();
    FocusManager.instance.applyFocusChangesIfNeeded();
  }

  @override
  void dispose() {
    playerExpansion.removeListener(_onPlayerExpansionChanged);
    if (kTvBuild) TvFabFocusBridge.instance.unregister(_tvFabNode);
    _tabController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _tvFabNode.dispose();
    _tvScanMenuFirstNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final libraryProvider = context.watch<LibraryProvider>();
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final hasMusic = libraryProvider.hasMusic;
    final isScanning = libraryProvider.isScanning;

    return Scaffold(
      appBar: AppBar(
        centerTitle: centerPageTitle(context, tabId: 'library'),
        title: Text(
          '本地音乐',
          style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
        bottom: hasMusic || isScanning
            ? PreferredSize(
                preferredSize: const Size.fromHeight(108),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 搜索栏
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.lg,
                        vertical: AppSpacing.xs,
                      ),
                      child: TextField(
                        controller: _searchController,
                        focusNode: _searchFocusNode,
                        contextMenuBuilder: buildAppTextContextMenu,
                        // 手机触摸默认不会取消输入焦点，显式覆盖以保护所有非输入操作。
                        onTapOutside: (_) => _dismissSearchFocus(),
                        onTap: () {
                          // 点击搜索框时请求焦点并弹出键盘
                          _searchFocusNode.requestFocus();
                        },
                        decoration: InputDecoration(
                          hintText: '搜索本地音乐',
                          prefixIcon: const Icon(Icons.search, size: 20),
                          suffixIcon: _searchController.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear, size: 20),
                                  onPressed: () {
                                    _searchController.clear();
                                    libraryProvider.clearSearch();
                                  },
                                )
                              : null,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.md,
                            vertical: AppSpacing.sm,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: AppRadius.xlAll,
                            borderSide: BorderSide.none,
                          ),
                          filled: true,
                          fillColor: colorScheme.surfaceContainerHigh,
                        ),
                        onChanged: (value) {
                          libraryProvider.setSearchQuery(value);
                          setState(() {});
                        },
                      ),
                    ),
                    // TabBar
                    TabBar(
                      controller: _tabController,
                      tabs: const [
                        Tab(text: '曲目'),
                        Tab(text: '专辑'),
                        Tab(text: '艺术家'),
                        Tab(text: '文件夹'),
                        Tab(text: '收藏'),
                      ],
                      // 5 个 Tab 内容较窄，关闭滚动并居中分布到整行，
                      // 缩窄每个 Tab 内部 padding 让全部标题都能完整显示。
                      isScrollable: false,
                      tabAlignment: TabAlignment.center,
                      padding: EdgeInsets.zero,
                      labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                      labelStyle: textTheme.titleSmall,
                      unselectedLabelStyle: textTheme.titleSmall,
                      dividerColor: Colors.transparent,
                    ),
                  ],
                ),
              )
            : null,
      ),
      body: isScanning && !hasMusic
          ? _buildScanningState(colorScheme)
          : !hasMusic
          ? _buildEmptyState(colorScheme)
          : TabBarView(
              controller: _tabController,
              physics: const TabSnapPhysics(),
              children: [
                SongsPage(songs: libraryProvider.songs),
                AlbumsPage(albums: libraryProvider.albums),
                ArtistsPage(artists: libraryProvider.artists),
                FoldersPage(folders: libraryProvider.folders),
                const _LocalFavoritesTab(),
              ],
            ),
      floatingActionButton: _buildScanFAB(context, colorScheme),
    );
  }

  Widget _buildScanFAB(BuildContext context, ColorScheme colorScheme) {
    // 替换为 M3E 规范的 FAB：M3EFab 默认中等尺寸的容器 56 / 图标 24 /
    // 圆角 16，配色沿用 primaryContainer + onPrimaryContainer，
    // 与本项目 floatingActionButtonTheme 原有定义一致，故无需显式传色。
    // 本页仅此一个 FAB，M3EFab 不支持 heroTag，不存在 Hero 标签冲突。
    // 宿主将浮动播放栏占位注入 MediaQuery；FAB 默认位置只参考系统 viewPadding。
    // 将这部分占位补到 FAB 上，保持在播放栏上方并保留间距。
    final mediaQuery = MediaQuery.of(context);
    final playerInset =
        (mediaQuery.padding.bottom - mediaQuery.viewPadding.bottom).clamp(
          0.0,
          double.infinity,
        );
    return Padding(
      padding: EdgeInsets.only(bottom: playerInset + 12),
      // tv: M3EFab 不带焦点节点，TV 下包成 DpadFocusable 才能被遥控选中
      // （点击仍走 FAB 自身的 onPressed —— 内层手势优先）。
      child: _tvSheetRow(
        () => _showScanMenu(context),
        debugLabel: 'library_scan_fab',
        focusNode: _tvFabNode,
        // 非 TV：M3EButton 内核会自建 FocusNode 并用 FocusRing 画 primary 色
        // 焦点描边（外观与 TV 焦点环一致），键盘方向键/Tab 遍历到就会显示，
        // 触屏点击不持焦。非 TV 没有遥控导航语义，整树禁聚焦消除该视觉；
        // 与 TV 下 DpadFocusable.excludeChildFocus 同语义，重复包裹无害。
        ExcludeFocus(
          child: M3EFab(
            onPressed: () => _showScanMenu(context),
            icon: const Icon(Icons.add),
          ),
        ),
      ),
    );
  }

  /// tv: 弹层内的行/开关包成 [DpadFocusable] 单停点。
  ///
  /// 这些行原本只有 `onTap`、不带焦点节点，遥控下弹层打开后整片没有落点
  /// （2026-10-04：本地音乐加号点开后无任何焦点）。触屏路径原样返回，零变化。
  ///
  /// [autofocus] 不可靠（2026-10-05 真机实测）：Flutter 的 `Focus.autofocus` 走
  /// `FocusScopeNode.autofocus(node)`，只在 scope **首次**执行 `_doRequestFocus`
  /// 时消费一次；m3e 弹层是复用/延迟挂载的路由，实测首项拿不到焦点，焦点反而
  /// 落到评分更高的末行开关上（用户反馈「要按两次才有焦点」）。故本方法改为
  /// 记录**弹层内是否已有节点持焦**，由 [_tvEnsureSheetFocus] 在打开后显式补一次
  /// `requestFocus`。
  Widget _tvSheetRow(
    VoidCallback? action,
    Widget child, {
    bool autofocus = false,
    String? debugLabel,
    FocusNode? focusNode,
    ValueChanged<bool>? onFocusChange,
  }) {
    if (!kTvBuild) return child;
    return DpadFocusable(
      autofocus: autofocus,
      debugLabel: debugLabel,
      focusNode: focusNode,
      onSelect: action,
      enabled: action != null,
      onFocusChange: onFocusChange,
      child: child,
    );
  }

  /// tv: 弹层挂载后显式把焦点交给 [target]（**只尝试一次**）。
  ///
  /// 挂在弹层内容根节点的 post-frame 回调里：此时所有行都已布局、各自的
  /// 渲染矩形可用，`requestFocus` 才能被 dpad 与 [TvFocusHighlight] 正常识别。
  ///
  /// 判「弹层内是否已有人持焦」必须**按子树归属**判断，不能只看
  /// `primaryFocus.hasFocus`：弹层打开瞬间，焦点从页面移交到弹层路由是
  /// **异步**的，此刻 `primaryFocus` 仍是页面里的节点（如扫描 FAB）且
  /// `hasFocus == true`，直接按 hasRun 之外的「有人持焦就放弃」会把首项焦点
  /// 整个吞掉——这正是 2026-10-05 真机看到的「焦点落在末行开关上」。
  ///
  /// [hasRun] 读、[markRun] 写，两者配对实现自锁——本方法在 build 里被调用，
  /// 每帧都会走到，但只允许真正请求一次，否则会反复 `requestFocus` 打断
  /// 用户后续的正常移动。
  void _tvEnsureSheetFocus(
    FocusNode? target,
    BuildContext sheetContext, {
    required bool Function() hasRun,
    required void Function() markRun,
  }) {
    if (!kTvBuild || target == null || hasRun()) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (hasRun()) return;
      markRun();
      if (!target.canRequestFocus) return;
      if (target.context == null || !target.context!.mounted) return;
      if (_tvFocusInsideSheet(sheetContext)) return;
      target.requestFocus();
    });
  }

  /// 焦点是否落在 [sheetContext] 这棵子树里（用于「弹层内是否已有人持焦」）。
  bool _tvFocusInsideSheet(BuildContext sheetContext) {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    final target = sheetContext as Element;
    var found = false;
    ctx.visitAncestorElements((el) {
      if (identical(el, target)) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  void _showScanMenu(BuildContext context) {
    _dismissSearchFocus();
    _tvScanMenuFocusRequested = false;
    final provider = context.read<LibraryProvider>();
    showM3EModalBottomSheet(
      context: context,
      builder: (ctx) {
        return Consumer<LibraryProvider>(
          builder: (ctx, library, _) {
            // 每个动作只写一份：触屏走 ListTile 的 onTap、TV 走
            // DpadFocusable 的 onSelect，两条路径共用同一份实现，
            // 免得改了一边忘了另一边。
            void rescan() {
              Navigator.pop(ctx);
              provider.loadLocalMusic();
            }

            // 原addScanFolder 回调已并入 [_showScanFolderManagement]（那里才有列表上下文，
            // 添加后能就地看到结果），此处不再需要。

            void manageScanFolders() {
              Navigator.pop(ctx);
              _showScanFolderManagement(context);
            }

            void manageExcluded() {
              Navigator.pop(ctx);
              _showExcludedFolderManagement(context);
            }

            return SafeArea(
              child: Builder(
                builder: (sheetCtx) {
                  // tv: 首项焦点在弹层挂载后再显式请求（autofocus 不可靠，
                  // 见 [_tvEnsureSheetFocus] 说明）。build 里每帧都调，靠
                  // _tvScanMenuFocusRequested 自锁，只真正请求一次。
                  _tvEnsureSheetFocus(
                    _tvScanMenuFirstNode,
                    sheetCtx,
                    hasRun: () => _tvScanMenuFocusRequested,
                    markRun: () => _tvScanMenuFocusRequested = true,
                  );
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                  Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: Text(
                      '扫描本地音乐',
                      style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  // tv: 首项持有显式焦点节点，由 [_tvEnsureSheetFocus] 在弹层
                  // 挂载后主动请求（`autofocus` 在 m3e 弹层里不可靠）
                  _tvSheetRow(
                    rescan,
                    debugLabel: 'scan_menu_rescan',
                    ListTile(
                      leading: const Icon(Icons.refresh),
                      title: const Text('扫描音乐'),
                      subtitle: const Text('扫描默认目录和已添加的文件夹'),
                      onTap: rescan,
                    ),
                    focusNode: _tvScanMenuFirstNode,
                  ),
                  // 打开扫描文件夹管理面板（列出已添加项 + 移除）。
                  // 此前直接调文件夹选择器，加完就看不到有哪些、也没法移除，
                  // 用户以为没持久化（实际已存盘，见 LocalMusicRepository.saveFolders）。
                  _tvSheetRow(
                    manageScanFolders,
                    debugLabel: 'scan_menu_add_folder',
                    ListTile(
                      leading: const Icon(Icons.create_new_folder_outlined),
                      title: const Text('添加扫描文件夹'),
                      subtitle: Text(
                          '选择额外的文件夹进行扫描'
                          '${provider.scanFolders.isEmpty ? '' : '（已添加 ${provider.scanFolders.length} 个）'}'),
                      onTap: manageScanFolders,
                    ),
                  ),
                  _tvSheetRow(
                    manageExcluded,
                    debugLabel: 'scan_menu_excluded',
                    ListTile(
                      leading: const Icon(Icons.folder_off_outlined),
                      title: const Text('排除文件夹'),
                      subtitle: Text(
                          '已排除 ${provider.excludedFolders.length} 个文件夹'),
                      onTap: manageExcluded,
                    ),
                  ),
                  // tv: 开关行同样要单停点；OK 键翻转取值
                  _tvSheetRow(
                    () => library
                        .setFilterShortAudio(!library.filterShortAudio),
                    debugLabel: 'scan_menu_filter_short',
                    SwitchListTile(
                      title: const Text('过滤不超过 60 秒的音频'),
                      subtitle: const Text(
                          '默认关闭，开启后本地音乐列表只显示时长大于 60 秒的音频'),
                      value: library.filterShortAudio,
                      onChanged: library.setFilterShortAudio,
                    ),
                  ),
                  const Gap(AppSpacing.sm),
                    ],
                  );
                },
              ),
            );
          },
        );
      },
    );
  }

  /// 从路径取目录名。
  ///
  /// Windows 上路径是 `C:\Users\...\Music`，只按 `/` 切分拿到的会是整条路径
  /// （弹窗里显示成一长串）。这里同时兼容两种分隔符。
  static String _folderDisplayName(String path) {
    final parts = path
        .split(RegExp(r'[/\\]'))
        .where((p) => p.isNotEmpty)
        .toList();
    return parts.isEmpty ? path : parts.last;
  }

  /// 扫描文件夹管理：列出已添加的扫描目录并支持移除。
  ///
  /// 此前「添加扫描文件夹」只有添加入口、没有列表，添加后既看不到加了哪些、
  /// 也无法移除 —— 用户以为"没持久化"（其实 `_scanFolders` 已存盘）。
  /// 这里与 [_showExcludedFolderManagement] 对称，补上可见性与可管理性。
  void _showScanFolderManagement(BuildContext context) {
    _dismissSearchFocus();
    final provider = context.read<LibraryProvider>();
    showM3EModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            final scanFolders = provider.scanFolders;

            Future<void> addFolder() async {
              _dismissSearchFocus();
              final success = await provider.addScanFolder();
              if (success && ctx.mounted) {
                setModalState(() {});
                if (context.mounted) {
                  showToast('已添加扫描文件夹，点击扫描音乐生效', long: true);
                }
              }
            }

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '扫描文件夹',
                          style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        // tv: 关闭按钮也要能被选中（否则弹层只有列表行可达）
                        _tvSheetRow(
                          () => Navigator.pop(ctx),
                          debugLabel: 'scan_folder_close',
                          IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () => Navigator.pop(ctx),
                          ),
                        ),
                      ],
                    ),
                    const Gap(AppSpacing.xs),
                    Text(
                      '已添加的文件夹会与默认目录一起扫描，重启后依然生效',
                      style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const Gap(AppSpacing.md),
                    if (scanFolders.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                        child: Center(child: Text('暂无添加的扫描文件夹')),
                      )
                    else
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.of(ctx).size.height * 0.35,
                        ),
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: scanFolders.length,
                          itemBuilder: (context, index) {
                            final folder = scanFolders[index];
                            void remove() {
                              provider.removeScanFolder(folder);
                              setModalState(() {});
                            }

                            // tv: 整行单停点，OK=移除该文件夹
                            return _tvSheetRow(
                              remove,
                              debugLabel: 'scan_folder_remove_row',
                              ListTile(
                                leading: const Icon(Icons.folder_outlined),
                                title: Text(
                                  _folderDisplayName(folder),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  folder,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: IconButton(
                                  icon: const Icon(Icons.remove_circle_outline),
                                  onPressed: remove,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    const Gap(AppSpacing.md),
                    SizedBox(
                      width: double.infinity,
                      child: _tvSheetRow(
                        addFolder,
                        debugLabel: 'scan_folder_add',
                        FilledButton.tonalIcon(
                          icon: const Icon(Icons.create_new_folder_outlined),
                          label: const Text('添加扫描文件夹'),
                          onPressed: addFolder,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showExcludedFolderManagement(BuildContext context) {
    _dismissSearchFocus();
    final provider = context.read<LibraryProvider>();
    showM3EModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            final excludedFolders = provider.excludedFolders;

            Future<void> addExcluded() async {
              _dismissSearchFocus();
              final success = await provider.addExcludedFolder();
              if (success) {
                setModalState(() {});
                if (context.mounted) {
                  showToast('已添加排除文件夹，重新扫描后生效', long: true);
                }
              }
            }

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '排除文件夹',
                          style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        // tv: 关闭按钮也要能被选中（否则弹层只有列表行可达）
                        _tvSheetRow(
                          () => Navigator.pop(ctx),
                          debugLabel: 'excluded_close',
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('关闭'),
                          ),
                        ),
                      ],
                    ),
                    const Gap(AppSpacing.xs),
                    Text(
                      '排除的文件夹及其子目录不会被扫描',
                      style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const Gap(AppSpacing.md),
                    if (excludedFolders.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                        child: Center(child: Text('暂无排除文件夹')),
                      )
                    else
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.of(ctx).size.height * 0.35,
                        ),
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: excludedFolders.length,
                          itemBuilder: (context, index) {
                            final folder = excludedFolders[index];
                            final name = _folderDisplayName(folder);
                            void remove() {
                              provider.removeExcludedFolder(folder);
                              setModalState(() {});
                            }

                            // tv: 整行单停点，OK=移除该文件夹
                            return _tvSheetRow(
                              remove,
                              debugLabel: 'excluded_remove_row',
                              ListTile(
                                leading: const Icon(Icons.folder_off_outlined),
                                title: Text(
                                  name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  folder,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: IconButton(
                                  icon: const Icon(Icons.remove_circle_outline),
                                  onPressed: remove,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    const Gap(AppSpacing.sm),
                    // 添加排除文件夹按钮
                    SizedBox(
                      width: double.infinity,
                      child: _tvSheetRow(
                        addExcluded,
                        debugLabel: 'excluded_add',
                        FilledButton.tonalIcon(
                          onPressed: addExcluded,
                          icon: const Icon(Icons.add),
                          label: const Text('添加排除文件夹'),
                        ),
                      ),
                    ),
                    const Gap(AppSpacing.sm),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildScanningState(ColorScheme colorScheme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const M3ELoadingIndicator(),
          const Gap(AppSpacing.lg),
          Text(
            '正在扫描本地音乐...',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(ColorScheme colorScheme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.library_music_outlined,
            size: 64,
            color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const Gap(AppSpacing.lg),
          Text(
            '还没有本地音乐',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const Gap(AppSpacing.sm),
          Text(
            '点击扫描按钮添加本地音乐',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
          const Gap(AppSpacing.xl),
          FilledButton.tonal(
            onPressed: () {
              _dismissSearchFocus();
              context.read<LibraryProvider>().loadLocalMusic();
            },
            child: const Text('扫描音乐'),
          ),
        ],
      ),
    );
  }
}

/// 本地音乐收藏 tab：从 `LocalFavoritesProvider` 读取 id 集合，再从
/// `LibraryProvider.allSongs` 中按 id 匹配出完整 Song，传入 `SongsPage`
/// 复用其随机播放 / 排序 / 定位当前播放等交互。
class _LocalFavoritesTab extends StatelessWidget {
  const _LocalFavoritesTab();

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryProvider>();
    final localFavorites = context.watch<LocalFavoritesProvider>();
    final favoriteIds = localFavorites.favoriteIds;

    // 收藏的歌曲列表：未过滤的本地歌曲 × 收藏 id 集合
    final allFavorites = library.allSongs
        .where((s) => favoriteIds.contains(s.id))
        .toList();

    // 跟随 LibraryProvider 搜索框过滤
    final query = library.searchQuery.trim().toLowerCase();
    final filtered = query.isEmpty
        ? allFavorites
        : allFavorites
              .where(
                (s) =>
                    s.title.toLowerCase().contains(query) ||
                    s.artist.toLowerCase().contains(query) ||
                    s.album.toLowerCase().contains(query),
              )
              .toList();

    if (allFavorites.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.favorite_border,
              size: 64,
              color: Theme.of(
                context,
              ).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const Gap(AppSpacing.lg),
            Text(
              '还没有本地收藏',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const Gap(AppSpacing.sm),
            Text(
              '在曲目列表中点击心形图标即可收藏',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(
                  context,
                ).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      );
    }

    if (filtered.isEmpty) {
      return Center(
        child: Text(
          '没有匹配的收藏',
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return SongsPage(songs: filtered);
  }
}
