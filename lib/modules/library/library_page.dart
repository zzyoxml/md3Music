import 'package:flutter/material.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../core/utils/app_toast.dart';
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

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    _searchFocusNode = FocusNode();
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

  @override
  void dispose() {
    playerExpansion.removeListener(_onPlayerExpansionChanged);
    _tabController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
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
        centerTitle: true,
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
                        horizontal: 16,
                        vertical: 4,
                      ),
                      child: TextField(
                        controller: _searchController,
                        focusNode: _searchFocusNode,
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
                            horizontal: 12,
                            vertical: 8,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(28),
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
                      // 缩窄每个 Tab 内部 padding 让"收藏"也能完整显示。
                      isScrollable: false,
                      tabAlignment: TabAlignment.center,
                      padding: EdgeInsets.zero,
                      labelPadding: const EdgeInsets.symmetric(horizontal: 6),
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
    return FloatingActionButton(
      onPressed: () => _showScanMenu(context),
      child: const Icon(Icons.add),
    );
  }

  void _showScanMenu(BuildContext context) {
    final provider = context.read<LibraryProvider>();
    showModalBottomSheet(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '扫描本地音乐',
                  style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('扫描音乐'),
                subtitle: const Text('扫描默认目录和已添加的文件夹'),
                onTap: () {
                  Navigator.pop(ctx);
                  provider.loadLocalMusic();
                },
              ),
              ListTile(
                leading: const Icon(Icons.create_new_folder_outlined),
                title: const Text('添加扫描文件夹'),
                subtitle: const Text('选择额外的文件夹进行扫描'),
                onTap: () async {
                  Navigator.pop(ctx);
                  final success = await provider.addScanFolder();
                  if (success && context.mounted) {
                    showToast('已添加文件夹，点击扫描音乐', long: true);
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.folder_off_outlined),
                title: const Text('排除文件夹'),
                subtitle: Text('已排除 ${provider.excludedFolders.length} 个文件夹'),
                onTap: () {
                  Navigator.pop(ctx);
                  _showExcludedFolderManagement(context);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  void _showExcludedFolderManagement(BuildContext context) {
    final provider = context.read<LibraryProvider>();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            final excludedFolders = provider.excludedFolders;
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
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
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('关闭'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '排除的文件夹及其子目录不会被扫描',
                      style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (excludedFolders.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
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
                            final name = folder
                                .split('/')
                                .where((p) => p.isNotEmpty)
                                .last;
                            return ListTile(
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
                                onPressed: () {
                                  provider.removeExcludedFolder(folder);
                                  setModalState(() {});
                                },
                              ),
                            );
                          },
                        ),
                      ),
                    const SizedBox(height: 8),
                    // 添加排除文件夹按钮
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.tonalIcon(
                        onPressed: () async {
                          final success = await provider.addExcludedFolder();
                          if (success) {
                            setModalState(() {});
                            if (context.mounted) {
                              showToast('已添加排除文件夹，重新扫描后生效', long: true);
                            }
                          }
                        },
                        icon: const Icon(Icons.add),
                        label: const Text('添加排除文件夹'),
                      ),
                    ),
                    const SizedBox(height: 8),
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
          const SizedBox(height: 16),
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
          const SizedBox(height: 16),
          Text(
            '还没有本地音乐',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '点击扫描按钮添加本地音乐',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.tonal(
            onPressed: () {
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
            const SizedBox(height: 16),
            Text(
              '还没有本地收藏',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
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
