import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/kugou_provider.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/md3_pull_to_refresh.dart';
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

  Future<void> _pickOption(
    String title,
    List<(int, String)> options,
    int current,
    ValueChanged<int> onChanged,
  ) async {
    final sel = await showModalBottomSheet<int>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Text(title, style: Theme.of(sheetContext).textTheme.titleMedium),
            ),
            for (final (value, label) in options)
              ListTile(
                title: Text(label),
                trailing: value == current ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(sheetContext).pop(value),
              ),
          ],
        ),
      ),
    );
    if (sel != null && sel != current) {
      setState(() => onChanged(sel));
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final kugou = context.watch<KugouProvider>();
    final albums = kugou.longAudioFreeAlbums;
    final loadingMore = kugou.longAudioFreeLoading;

    return Scaffold(
      appBar: AppBar(title: const Text('免费听书库')),
      body: Column(
        children: [
          // 分类横向 chips（动态来自分类接口 + 首位「全部」）
          SizedBox(
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
          // 排序 / 性别 / 状态
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                _FilterButton(
                  label: '排序 · ${_labelOf(_sortOptions, _sort)}',
                  onTap: () =>
                      _pickOption('排序', _sortOptions, _sort, (v) => _sort = v),
                ),
                const SizedBox(width: 8),
                _FilterButton(
                  label: _labelOf(_genderOptions, _gender),
                  onTap: () => _pickOption(
                    '性别',
                    _genderOptions,
                    _gender,
                    (v) => _gender = v,
                  ),
                ),
                const SizedBox(width: 8),
                _FilterButton(
                  label: '状态 · ${_labelOf(_statusOptions, _status)}',
                  onTap: () => _pickOption(
                    '状态',
                    _statusOptions,
                    _status,
                    (v) => _status = v,
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
                        child: ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.symmetric(vertical: 8),
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
                              onTap: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => AudiobookAlbumDetailPage(
                                      album: album,
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  String _labelOf(List<(int, String)> options, int value) {
    for (final (v, label) in options) {
      if (v == value) return label;
    }
    return '';
  }
}

/// 排序/性别/状态筛选按钮。
class _FilterButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _FilterButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Material(
      color: cs.surfaceContainerLow,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: tt.labelMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(width: 2),
              Icon(Icons.arrow_drop_down, size: 18, color: cs.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

/// 免费听书库专辑条目：封面 + 名称 + 集数 / 简介。
class _FreeAlbumTile extends StatelessWidget {
  final KugouLongAudioAlbum album;
  final VoidCallback onTap;

  const _FreeAlbumTile({required this.album, required this.onTap});

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
          child: SmartArtworkImage(
            artworkUri: album.coverUrl,
            size: double.infinity,
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
