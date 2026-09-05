import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:m3e_core/m3e_core.dart' hide M3EPullToRefreshIndicator;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/services/equalizer_service.dart';
import '../../core/utils/app_toast.dart';
import '../../services/kugou_api/kugou_api_client.dart';

/// 社区音效条目（/get/model → ocean/v6/sound/list 的 data[] 元素）。
///
/// classify=2 为官方蝰蛇音效，classify=3 为社区音效。
/// 会员专属音效不下发 .irs（[soundUrl] 为空、仅有 vpf 专有格式），
/// 本页统一过滤，只保留可应用的免费条目。
class KugouSoundItem {
  final int id;
  final String name;
  final int classify;
  final String tagName;
  final String author;
  final String? authorHeader;
  final String intro;
  final List<String> labels;
  final String? iconUrl;
  final String? soundUrl;
  final int userCount;
  final int vpfSize;

  const KugouSoundItem({
    required this.id,
    required this.name,
    required this.classify,
    required this.tagName,
    this.author = '',
    this.authorHeader,
    this.intro = '',
    this.labels = const [],
    this.iconUrl,
    this.soundUrl,
    this.userCount = 0,
    this.vpfSize = 0,
  });

  bool get isOfficial => classify == 2;

  /// 是否带音效文件（会员专属音效不下发此字段）。
  bool get available => soundUrl != null && soundUrl!.isNotEmpty;

  static KugouSoundItem? fromJson(dynamic json) {
    if (json is! Map) return null;
    String str(String key) {
      final v = json[key];
      return v == null ? '' : v.toString();
    }

    final labels = <String>[];
    final rawLabels = json['label'];
    if (rawLabels is List) {
      for (final l in rawLabels) {
        if (l != null && l.toString().isNotEmpty) labels.add(l.toString());
      }
    }
    return KugouSoundItem(
      id: int.tryParse(str('id')) ?? 0,
      name: str('name'),
      classify: int.tryParse(str('classify')) ?? 3,
      tagName: str('tag_name'),
      author: str('author'),
      authorHeader: str('author_header').isEmpty ? null : str('author_header'),
      intro: str('intro'),
      labels: labels,
      iconUrl: str('icon_url').isEmpty ? null : str('icon_url'),
      soundUrl: str('sound').isEmpty ? null : str('sound'),
      userCount: int.tryParse(str('user_count')) ?? 0,
      vpfSize: int.tryParse(str('vpfsize')) ?? 0,
    );
  }
}

/// 使用人数格式化：95439187 → "9543.9万"，120000000 → "1.2亿"。
String _formatUserCount(int n) {
  if (n >= 100000000) {
    return '${(n / 100000000).toStringAsFixed(1)}亿';
  }
  if (n >= 10000) {
    return '${(n / 10000).toStringAsFixed(1)}万';
  }
  return '$n';
}

/// 分类固定展示顺序。
const List<String> _kTagOrder = ['重低音', '设备模拟', '环绕', '人声', '趣味', '其他'];

class SoundsPage extends StatefulWidget {
  const SoundsPage({super.key});

  @override
  State<SoundsPage> createState() => _SoundsPageState();
}

class _SoundsPageState extends State<SoundsPage> {
  final KugouApiClient _api = KugouApiClient();
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  int _sort = 3; // 固定最热排序
  int? _classify; // null=全部 2=蝰蛇官方 3=社区
  String? _tag; // null=全部分类

  List<KugouSoundItem> _items = [];
  int _page = 1;
  bool _hasMore = true;
  bool _loading = false;
  bool _loadingMore = false;

  // 搜索（上游无搜索参数，客户端多页匹配热门/最新榜单）
  bool _searchMode = false;
  bool _searching = false;
  String _searchKeyword = '';
  List<KugouSoundItem> _searchResults = [];

  int? _appliedId;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadLocalState();
    _refresh();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  /// 恢复已应用音效标记（均衡器侧的预设/开关由 EqualizerService 自行持久化，
  /// 杀后台重启后播放时自动重新生效）。
  Future<void> _loadLocalState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final appliedId = prefs.getInt('sound_applied_id');
      if (!mounted) return;
      setState(() => _appliedId = appliedId);
    } catch (e) {
      debugPrint('[Sounds] loadLocalState error: $e');
    }
  }

  void _onScroll() {
    if (_searchMode || !_hasMore || _loadingMore || _loading) return;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  List<KugouSoundItem> _parseItems(Map<String, dynamic>? resp) {
    if (resp == null || resp['status'] != 1) return [];
    final data = resp['data'];
    if (data is! List) return [];
    final out = <KugouSoundItem>[];
    for (final e in data) {
      final item = KugouSoundItem.fromJson(e);
      // 过滤会员专属（无音效文件）与无效条目
      if (item != null && item.id > 0 && item.available) out.add(item);
    }
    return out;
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _page = 1;
      _hasMore = true;
    });
    final resp = await _api.getSoundModel(sort: _sort, page: 1, pagesize: 30);
    final list = _parseItems(resp);
    if (!mounted) return;
    setState(() {
      _items = list;
      _loading = false;
      _hasMore = list.length >= 30;
    });
  }

  Future<void> _loadMore() async {
    setState(() => _loadingMore = true);
    final next = _page + 1;
    final resp = await _api.getSoundModel(sort: _sort, page: next, pagesize: 30);
    final list = _parseItems(resp);
    if (!mounted) return;
    setState(() {
      _loadingMore = false;
      if (list.isEmpty) {
        _hasMore = false;
      } else {
        _page = next;
        final known = _items.map((e) => e.id).toSet();
        _items = [..._items, ...list.where((e) => !known.contains(e.id))];
        _hasMore = list.length >= 30;
      }
    });
  }

  List<KugouSoundItem> get _filteredItems {
    var list = _items;
    if (_classify != null) {
      list = list.where((e) => e.classify == _classify).toList();
    }
    if (_tag != null) {
      list = list.where((e) => e.tagName == _tag).toList();
    }
    return list;
  }

  bool _matches(KugouSoundItem it, String kw) {
    final k = kw.toLowerCase();
    final hay = '${it.name} ${it.author} ${it.tagName} '
            '${it.labels.join(' ')} ${it.intro}'
        .toLowerCase();
    return hay.contains(k);
  }

  Future<void> _doSearch(String kw) async {
    final keyword = kw.trim();
    if (keyword.isEmpty) {
      showToast('请输入搜索关键词');
      return;
    }
    setState(() {
      _searching = true;
      _searchKeyword = keyword;
      _searchResults = [];
    });
    final results = <int, KugouSoundItem>{};
    for (int p = 1; p <= 6; p++) {
      final resp =
          await _api.getSoundModel(sort: _sort, page: p, pagesize: 50);
      final list = _parseItems(resp);
      if (list.isEmpty) break;
      for (final it in list) {
        if (_matches(it, keyword)) results.putIfAbsent(it.id, () => it);
      }
    }
    if (!mounted) return;
    setState(() {
      _searching = false;
      _searchResults = results.values.toList();
    });
  }

  // ==================== 应用 ====================

  /// 依据音效名称/标签/简介关键词映射到原生均衡器预设。
  static String mapPreset(KugouSoundItem it) {
    final text = '${it.name} ${it.labels.join(' ')} ${it.intro}';
    bool has(List<String> kws) => kws.any((k) => text.contains(k));
    if (has(['重低音', '低音炮', 'bass', 'Bass', 'BASS'])) return '重低音';
    if (has(['人声', '女声', '男声', 'vocal'])) return '人声';
    if (has(['电音', '电子', 'DJ'])) return '电子';
    if (has(['摇滚', 'rock', 'Rock'])) return '摇滚';
    if (has(['高音', '解析', 'HiFi', 'HIFI', 'hifi', '清晰', '人耳'])) {
      return '高音增强';
    }
    if (has(['环绕', '3D', '现场', '影院', '声场'])) return '电子';
    switch (it.tagName) {
      case '重低音':
        return '重低音';
      case '人声':
        return '人声';
      case '环绕':
        return '电子';
      case '设备模拟':
        return '流行';
      case '趣味':
        return '电子';
      default:
        return '流行';
    }
  }

  Future<void> _apply(KugouSoundItem item) async {
    final eq = EqualizerService.instance;
    final preset = mapPreset(item);
    await eq.setEnabled(true);
    await eq.applyPreset(preset);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('sound_applied_id', item.id);
    await prefs.setString('sound_applied_name', item.name);
    if (!mounted) return;
    setState(() => _appliedId = item.id);
    showToast('已应用「${item.name}」· 均衡器预设：$preset');
  }

  Future<void> _unapply() async {
    final eq = EqualizerService.instance;
    await eq.applyPreset('正常');
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('sound_applied_id');
    await prefs.remove('sound_applied_name');
    if (!mounted) return;
    setState(() => _appliedId = null);
    showToast('已取消应用音效');
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: _searchMode ? _buildSearchField(cs) : const Text('音效'),
        actions: [
          IconButton(
            icon: Icon(_searchMode ? Icons.close : Icons.search),
            tooltip: _searchMode ? '退出搜索' : '搜索音效',
            onPressed: () {
              setState(() {
                _searchMode = !_searchMode;
                if (!_searchMode) {
                  _searchController.clear();
                  _searchResults = [];
                  _searchKeyword = '';
                }
              });
            },
          ),
        ],
      ),
      body: _searchMode ? _buildSearchBody(cs) : _buildBrowseBody(cs),
    );
  }

  Widget _buildSearchField(ColorScheme cs) {
    return TextField(
      controller: _searchController,
      autofocus: true,
      textInputAction: TextInputAction.search,
      onSubmitted: _doSearch,
      decoration: InputDecoration(
        hintText: '搜索音效名称 / 作者 / 分类',
        hintStyle: TextStyle(color: cs.onSurfaceVariant),
        border: InputBorder.none,
        suffixIcon: IconButton(
          icon: const Icon(Icons.search),
          onPressed: () => _doSearch(_searchController.text),
        ),
      ),
    );
  }

  Widget _buildSearchBody(ColorScheme cs) {
    if (_searching) {
      return const Center(child: M3ELoadingIndicator());
    }
    if (_searchKeyword.isEmpty) {
      return Center(
        child: Text(
          '在热门/最新榜单中搜索音效',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: cs.onSurfaceVariant,
              ),
        ),
      );
    }
    if (_searchResults.isEmpty) {
      return Center(
        child: Text(
          '未找到与「$_searchKeyword」相关的音效',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: cs.onSurfaceVariant,
              ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text(
            '匹配到 ${_searchResults.length} 个音效',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
          ),
        ),
        for (final it in _searchResults) _SoundTile(
          item: it,
          applied: _appliedId == it.id,
          onApply: () => _apply(it),
          onUnapply: _unapply,
          onTap: () => _showDetail(it),
        ),
      ],
    );
  }

  Widget _buildBrowseBody(ColorScheme cs) {
    if (_loading) {
      return const Center(child: M3ELoadingIndicator());
    }
    final list = _filteredItems;
    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        SliverToBoxAdapter(child: _buildFilterPanel(cs)),
        if (_tag == null && _classify == null)
          ..._buildGroupedSlivers(list)
        else
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) => _tileFor(list[i]),
              childCount: list.length,
            ),
          ),
        SliverToBoxAdapter(
          child: _loadingMore
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: M3ELoadingIndicator()),
                )
              : (_hasMore
                  ? const SizedBox(height: 24)
                  : Padding(
                      padding: const EdgeInsets.all(16),
                      child: Center(
                        child: Text(
                          list.isEmpty ? '暂无音效' : '没有更多了',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: cs.onSurfaceVariant),
                        ),
                      ),
                    )),
        ),
      ],
    );
  }

  Widget _tileFor(KugouSoundItem it) => _SoundTile(
        item: it,
        applied: _appliedId == it.id,
        onApply: () => _apply(it),
        onUnapply: _unapply,
        onTap: () => _showDetail(it),
      );

  /// 全部分类时按分类分组展示，归类清晰。
  List<Widget> _buildGroupedSlivers(List<KugouSoundItem> list) {
    final groups = <String, List<KugouSoundItem>>{};
    for (final it in list) {
      final key = it.tagName.isEmpty ? '其他' : it.tagName;
      groups.putIfAbsent(key, () => []).add(it);
    }
    final orderedTags = [
      ..._kTagOrder.where(groups.containsKey),
      ...groups.keys.where((k) => !_kTagOrder.contains(k)),
    ];
    final widgets = <Widget>[];
    for (final tag in orderedTags) {
      final items = groups[tag]!;
      widgets.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Row(
              children: [
                Text(
                  tag,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(width: 8),
                Text(
                  '${items.length}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
        ),
      );
      widgets.add(
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, i) => _tileFor(items[i]),
            childCount: items.length,
          ),
        ),
      );
    }
    return widgets;
  }

  Widget _buildFilterPanel(ColorScheme cs) {
    return Container(
      color: cs.surfaceContainer.withValues(alpha: 0.5),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<int?>(
            segments: const [
              ButtonSegment(value: null, label: Text('全部')),
              ButtonSegment(value: 2, label: Text('蝰蛇官方')),
              ButtonSegment(value: 3, label: Text('社区')),
            ],
            selected: {_classify},
            onSelectionChanged: (v) => setState(() => _classify = v.first),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: const Text('全部分类'),
                    selected: _tag == null,
                    onSelected: (_) => setState(() => _tag = null),
                  ),
                ),
                for (final t in _kTagOrder)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(t),
                      selected: _tag == t,
                      onSelected: (_) => setState(() => _tag = t),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '已过滤需会员的音效；应用即时生效并持久化，重启后自动恢复。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }

  void _showDetail(KugouSoundItem item) {
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  _SoundIcon(item: item, size: 56),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.name,
                            style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 4),
                        Text(
                          '${item.isOfficial ? '蝰蛇官方' : '社区'} · ${item.tagName} · ${item.author}',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: cs.onSurfaceVariant),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${_formatUserCount(item.userCount)}人使用',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: cs.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (item.labels.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final l in item.labels)
                      Chip(
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        label: Text(l),
                      ),
                  ],
                ),
              ],
              if (item.intro.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  item.intro,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: _appliedId == item.id
                    ? OutlinedButton(
                        onPressed: () {
                          Navigator.pop(ctx);
                          _unapply();
                        },
                        child: const Text('取消应用'),
                      )
                    : FilledButton(
                        onPressed: () {
                          Navigator.pop(ctx);
                          _apply(item);
                        },
                        child: const Text('应用'),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 音效图标：网络图 + 占位回退。
class _SoundIcon extends StatelessWidget {
  const _SoundIcon({required this.item, this.size = 48});

  final KugouSoundItem item;
  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final iconUrl = item.iconUrl;
    if (iconUrl == null) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(Icons.spatial_audio_off, size: size * 0.5, color: cs.primary),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: CachedNetworkImage(
        imageUrl: iconUrl,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorWidget: (_, _, _) => Container(
          color: cs.surfaceContainerHighest,
          child:
              Icon(Icons.spatial_audio_off, size: size * 0.5, color: cs.primary),
        ),
      ),
    );
  }
}

/// 音效列表项：图标 + 名称/归属 + 应用按钮。
class _SoundTile extends StatelessWidget {
  const _SoundTile({
    required this.item,
    required this.applied,
    required this.onApply,
    required this.onUnapply,
    required this.onTap,
  });

  final KugouSoundItem item;
  final bool applied;
  final VoidCallback onApply;
  final VoidCallback onUnapply;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            _SoundIcon(item: item),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                      ),
                      if (applied)
                        Container(
                          margin: const EdgeInsets.only(left: 6),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: cs.primaryContainer,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '已应用',
                            style: TextStyle(
                              fontSize: 10,
                              color: cs.onPrimaryContainer,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${item.tagName} · ${item.author} · ${_formatUserCount(item.userCount)}人使用',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: Icon(
                applied ? Icons.check_circle : Icons.spatial_audio_off,
                size: 22,
              ),
              color: applied ? cs.primary : null,
              tooltip: applied ? '取消应用' : '应用',
              onPressed: applied ? onUnapply : onApply,
            ),
          ],
        ),
      ),
    );
  }
}
