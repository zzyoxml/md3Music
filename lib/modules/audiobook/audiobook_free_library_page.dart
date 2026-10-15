import '../../core/layout/page_layout.dart';
import '../../widgets/tv_dropdown_menu.dart';
import '../../core/layout/adaptive_content_grid.dart';
import '../../core/layout/adaptive_navigator.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../providers/kugou_provider.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/md3_pull_to_refresh.dart';
import '../../widgets/playlist_cover_hero.dart';
import '../../widgets/smart_artwork_image.dart';
import 'audiobook_album_detail_page.dart';

/// 免费听书库（三级页）：分类 + 排序 + 男/女频 + 连载状态筛选，分页加载免费有声书专辑。
///
/// 上游 /longaudio/v1/album/list（free=1）：
/// - tag_id 分类：906=有声小说、1097=玄幻异界（更多分类待抓包补充）
/// - sort：0=默认 / 1=播放量 / 2=更新时间
/// - gender：0=不限 / 1=男频 / 2=女频
/// - status：0=全部 / 1=连载 / 2=完结
class AudiobookFreeLibraryPage extends StatefulWidget {
  const AudiobookFreeLibraryPage({super.key});

  @override
  State<AudiobookFreeLibraryPage> createState() =>
      _AudiobookFreeLibraryPageState();
}

class _AudiobookFreeLibraryPageState extends State<AudiobookFreeLibraryPage> {
  final ScrollController _scrollController = ScrollController();

  int _tagId = 906;
  int _sort = 0;
  int _gender = 0;
  int _status = 0;
  bool _firstLoading = true;

  static const int _pageSize = 20;

  /// 分类选项：动态来自 provider 的 longAudioTags（/longaudio/tag/list 的 24 个子分类），
  /// 首位固定追加「全部(906)」。
  List<(int, String)> _tagOptions(KugouProvider kugou) {
    return [
      (906, '全部'),
      ...kugou.longAudioTags,
    ];
  }

  /// 排序选项：值 = 上游 sort。
  static const List<(int, String)> _sortOptions = [
    (0, '默认'),
    (1, '播放量'),
    (2, '更新时间'),
  ];

  /// 性别选项：值 = 上游 gender。
  static const List<(int, String)> _genderOptions = [
    (0, '不限'),
    (1, '男频'),
    (2, '女频'),
  ];

  /// 状态选项：值 = 上游 status。
  static const List<(int, String)> _statusOptions = [
    (0, '全部'),
    (1, '连载'),
    (2, '完结'),
  ];

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<KugouProvider>().getLongaudioTags();
      _reload();
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      final kugou = context.read<KugouProvider>();
      if (kugou.longAudioFreeHasMore) {
        _loadMore();
      }
    }
  }

  /// 筛选变化 / 下拉刷新：重置回第一页。
  Future<void> _reload() async {
    setState(() => _firstLoading = true);
    final kugou = context.read<KugouProvider>();
    await kugou.getLongaudioFreeList(
      tagId: _tagId,
      sort: _sort,
      gender: _gender,
      status: _status,
      page: 1,
      pageSize: _pageSize,
    );
    if (mounted) setState(() => _firstLoading = false);
  }

  Future<void> _loadMore() async {
    final kugou = context.read<KugouProvider>();
    await kugou.getLongaudioFreeList(
      tagId: _tagId,
      sort: _sort,
      gender: _gender,
      status: _status,
      page: kugou.longAudioFreePage + 1,
      pageSize: _pageSize,
      append: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final kugou = context.watch<KugouProvider>();
    final albums = kugou.longAudioFreeAlbums;
    final loadingMore = kugou.longAudioFreeLoading;
    // 同一 id 只有首次出现的条目参与飞行（避免同子树重复 tag）。
    final heroFirstIndex = firstIndexById(albums.map((a) => a.id));

    return Scaffold(
      appBar: AppBar(title: const Text('免费听书库')),
      body: ContentWidth(
        child: Column(
        children: [
          // 分类横向 chips（动态来自分类接口 + 首位「全部」）
          SizedBox(
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6,
                ),
              itemCount: _tagOptions(kugou).length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final (value, label) = _tagOptions(kugou)[i];
                return ChoiceChip(
                  label: Text(label),
                  selected: _tagId == value,
                  onSelected: (_) {
                    if (_tagId == value) return;
                    setState(() => _tagId = value);
                    _reload();
                  },
                );
              },
            ),
          ),
          // 排序 / 性别 / 状态（M3E 下拉字段，选中即重新拉取）
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _LabeledDropdown(
                    label: '排序',
                    options: _sortOptions,
                    current: _sort,
                    onPicked: (v) {
                      setState(() => _sort = v);
                      _reload();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _LabeledDropdown(
                    label: '性别',
                    options: _genderOptions,
                    current: _gender,
                    onPicked: (v) {
                      setState(() => _gender = v);
                      _reload();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _LabeledDropdown(
                    label: '状态',
                    options: _statusOptions,
                    current: _status,
                    onPicked: (v) {
                      setState(() => _status = v);
                      _reload();
                    },
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _firstLoading
                ? const Center(child: CircularProgressIndicator())
                : albums.isEmpty
                    ? _EmptyHint(hint: '该筛选条件下暂无免费听书')
                    : Md3PullToRefresh(
                        onRefresh: _reload,
                        child: CustomScrollView(
                          controller: _scrollController,
                          slivers: [
                          SliverPadding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            sliver: SliverAdaptiveContentGrid(
                              targetExtent: 360,
                              childAspectRatio: 3,
                          itemCount: albums.length + (loadingMore ? 1 : 0),
                          itemBuilder: (context, i) {
                            if (i >= albums.length) {
                              return const Padding(
                                padding: EdgeInsets.symmetric(vertical: 16),
                                child: Center(
                                  child: SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                ),
                              );
                            }
                            final album = albums[i];
                            return _FreeAlbumTile(
                              album: album,
                              // 与听书专辑详情页头（audiobookCoverHeroTag）配对。
                              heroTag: heroFirstIndex[album.id] == i
                                  ? audiobookCoverHeroTag(album.id)
                                  : null,
                              onTap: () {
                                AdaptiveNav.openDetail(context,
                                      (_) => AudiobookAlbumDetailPage(
                                      album: album,
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      ),
          ],
                      ),
                    ),
            ),
        ],
        ),
      ),
    );
  }
}

/// 第二行筛选：小标签 + M3E 下拉字段。
///
/// 选项由上级传入（值 + 文本），单选即当前筛选值；选中后由调用方重新拉取。
/// 做成 StatefulWidget 是为了在「再次点当前项导致上游取消选中」时就地重建，
/// 让字段继续显示当前值（不回调上级，避免重复拉取）。
class _LabeledDropdown extends StatefulWidget {
  final String label;
  final List<(int, String)> options;
  final int current;
  final ValueChanged<int> onPicked;

  const _LabeledDropdown({
    required this.label,
    required this.options,
    required this.current,
    required this.onPicked,
  });

  @override
  State<_LabeledDropdown> createState() => _LabeledDropdownState();
}

class _LabeledDropdownState extends State<_LabeledDropdown> {
  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.label, style: textTheme.bodySmall),
        const SizedBox(height: 2),
        TvDropdownMenu<int>(
          items: [
            for (final (value, text) in widget.options)
              M3EDropdownItem<int>(
                label: text,
                value: value,
                selected: value == widget.current,
              ),
          ],
          singleSelect: true,
          showChipAnimation: false,
          fieldStyle: const M3EDropdownFieldStyle(
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          ),
          // 回调只在上游挂载时登记一次，因此这里读 widget.current / widget.onPicked
          // 取实时值，不要捕获按值传入的局部变量
          onSelectionChanged: (selected) {
            // 单选下再次点当前项会被取消选中：强制重建以恢复显示当前值
            if (selected.isEmpty) {
              setState(() {});
              return;
            }
            final value = selected.first.value;
            if (value == widget.current) return;
            widget.onPicked(value);
          },
        ),
      ],
    );
  }
}

/// 免费听书库专辑条目：封面 + 名称 + 集数 / 简介。
class _FreeAlbumTile extends StatelessWidget {
  final KugouLongAudioAlbum album;
  final VoidCallback onTap;

  /// 非空时行封面参与封面连贯过渡（audiobookCoverHeroTag 命名空间）。
  final String? heroTag;

  const _FreeAlbumTile({
    required this.album,
    required this.onTap,
    this.heroTag,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      onTap: onTap,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 64,
          height: 64,
          child: heroTag == null
              ? SmartArtworkImage(
                  artworkUri: album.coverUrl,
                  size: double.infinity,
                )
              : PlaylistCoverHero(
                  // 圆角移交 hero（与静止态 10 一致），图片自身不再裁剪。
                  tag: heroTag!,
                  radius: BorderRadius.circular(10),
                  child: SmartArtworkImage(
                    artworkUri: album.coverUrl,
                    size: double.infinity,
                    borderRadius: 0,
                  ),
                ),
        ),
      ),
      title: Text(
        album.name,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: tt.bodyMedium?.copyWith(
          color: cs.onSurface,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (album.audioCount > 0)
              Text(
                '共 ${album.audioCount} 集',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            if (album.intro != null && album.intro!.isNotEmpty)
              Text(
                album.intro!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
          ],
        ),
      ),
      trailing: const Icon(Icons.chevron_right),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  final String hint;

  const _EmptyHint({required this.hint});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.menu_book_outlined,
            size: 48,
            color: cs.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 12),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
