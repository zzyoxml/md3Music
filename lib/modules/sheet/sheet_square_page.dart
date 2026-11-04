import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:m3e_core/m3e_core.dart';

import '../../core/build_flags.dart';
import '../../core/remote/tv_scroll_region.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/md3_pull_to_refresh.dart';
import '../../widgets/md3e_loading_indicator.dart';
import '../../widgets/tv_dropdown_menu.dart';
import 'song_sheet_sheet.dart';

/// 乐器选项（接口契约：1 吉他 / 2 尤克里里 / 3 钢琴 / 4 简谱）。
const List<M3EDropdownItem<int>> _kInstrumentItems = [
  M3EDropdownItem(label: '吉他', value: 1),
  M3EDropdownItem(label: '尤克里里', value: 2),
  M3EDropdownItem(label: '钢琴', value: 3),
  M3EDropdownItem(label: '简谱', value: 4),
];

/// 主页「曲谱」可选 Tab 根页：曲谱广场（/sheet/explore）+ 排行榜（/sheet/rank）。
///
/// 全部匿名可用。乐器/难度筛选 + 广场标签筛选（/sheet/tags），
/// 列表触底翻页。点击谱目进酷狗官方 H5 渲染页（[SheetRenderPage]）。
class SheetSquarePage extends StatefulWidget {
  const SheetSquarePage({super.key});

  @override
  State<SheetSquarePage> createState() => _SheetSquarePageState();
}

class _SheetSquarePageState extends State<SheetSquarePage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final ScrollController _scrollController = ScrollController();

  int _instruments = 1;
  int _level = 0;
  int _tagid = 0;
  List<KugouSheetTag> _tags = [];

  final Map<int, List<KugouSheetInfo>> _lists = {0: [], 1: []};
  final Map<int, int> _pages = {0: 1, 1: 1};
  final Map<int, bool> _loading = {0: false, 1: false};
  final Map<int, bool> _hasMore = {0: true, 1: true};
  final Map<int, String?> _errors = {0: null, 1: null};

  static const _pagesize = 30;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      // 切页签立即重建（筛选栏按 index 决定是否显示标签行），并懒加载空页签
      if (mounted) setState(() {});
      if (!_tabController.indexIsChanging) {
        final i = _tabController.index;
        if ((_lists[i] ?? const []).isEmpty &&
            !(_loading[i] ?? false) &&
            (_errors[i] == null)) {
          _load(i);
        }
      }
    });
    _scrollController.addListener(_onScroll);
    _loadTags();
    _load(0);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.extentAfter < 400) {
      final i = _tabController.index;
      if (!(_loading[i] ?? false) &&
          (_hasMore[i] ?? false) &&
          (_errors[i] == null)) {
        _load(i, append: true);
      }
    }
  }

  /// 难度选项随乐器变化：吉他（1 进阶/2 基础/0 中级），尤克里里/钢琴
  /// （0 基础/1 进阶），简谱（0 基础）。
  Map<int, String> get _levelOptions {
    switch (_instruments) {
      case 1:
        return const {1: '进阶', 2: '基础', 0: '中级'};
      case 2:
      case 3:
        return const {0: '基础', 1: '进阶'};
      default:
        return const {0: '基础'};
    }
  }

  Future<void> _loadTags() async {
    try {
      final r = await KugouApiClient().getSheetTags();
      if (!mounted) return;
      final data = r?['data'] as Map<String, dynamic>? ?? r ?? const {};
      final raw = data['list'];
      final tags = <KugouSheetTag>[];
      if (raw is List) {
        for (final e in raw) {
          if (e is Map<String, dynamic>) tags.add(KugouSheetTag.fromJson(e));
        }
      }
      setState(() => _tags = tags);
    } catch (_) {
      // 标签失败不阻塞广场：仅少筛选能力
    }
  }

  Future<void> _load(int tab, {bool append = false}) async {
    if (_loading[tab] == true) return;
    setState(() {
      _loading[tab] = true;
      _errors[tab] = null;
      if (!append) {
        _pages[tab] = 1;
        _hasMore[tab] = true;
      }
    });
    final page = append ? (_pages[tab] ?? 1) : 1;
    Map<String, dynamic>? r;
    try {
      r = tab == 0
          ? await KugouApiClient().getSheetExplore(
              page: page,
              pagesize: _pagesize,
              instruments: _instruments,
              level: _level,
              tagid: _tagid,
            )
          : await KugouApiClient().getSheetRank(
              page: page,
              pagesize: _pagesize,
              instruments: _instruments,
              level: _level,
            );
    } catch (_) {
      r = null;
    }
    if (!mounted) return;
    final list = <KugouSheetInfo>[];
    if (r != null) {
      final data = r['data'] as Map<String, dynamic>? ?? r;
      final raw = data['list'];
      if (raw is List) {
        for (final e in raw) {
          if (e is! Map<String, dynamic>) continue;
          final song = KugouSheetInfo.fromJson(e);
          // 外层是歌曲壳（含内嵌 list 谱目数组）：展开内层；无内层时当作单谱目
          final inner = e['list'];
          if (inner is List && inner.isNotEmpty) {
            for (final s in inner) {
              if (s is Map<String, dynamic>) {
                final item = KugouSheetInfo.fromJson({
                  ...s,
                  // 谱名缺省用歌曲名；歌名/歌手/封面沿用外层歌曲壳
                  'name': _sheetName(s, song),
                  'song_name': song.songName,
                  'singer_name': song.singerName,
                  'cover': song.coverUrl ?? '',
                });
                if (item.opernId.isNotEmpty) list.add(item);
              }
            }
          } else if (song.opernId.isNotEmpty) {
            list.add(song);
          }
        }
      }
    }
    setState(() {
      _loading[tab] = false;
      _lists[tab] = append ? [...(_lists[tab] ?? const []), ...list] : list;
      _pages[tab] = page + 1;
      // 返回少于页大小视为没有更多；失败时保留已有数据提示重试
      _hasMore[tab] = r != null && list.length >= _pagesize;
      _errors[tab] = r == null ? '加载失败' : null;
    });
  }

  String _sheetName(Map<String, dynamic> s, KugouSheetInfo song) {
    final t = s['opern_type_name'] ?? s['opern_name'];
    return (t is String && t.isNotEmpty) ? t : song.name;
  }

  void _switchInstruments(int v) {
    if (v == _instruments) return;
    setState(() {
      _instruments = v;
      _level = _levelOptions.keys.first; // 切乐器后重置为该乐器的首个难度
      _tagid = 0;
    });
    _load(0);
    if ((_lists[1] ?? const []).isNotEmpty) _load(1);
  }

  void _switchLevel(int v) {
    if (v == _level) return;
    setState(() => _level = v);
    _load(0);
    if ((_lists[1] ?? const []).isNotEmpty) _load(1);
  }

  void _switchTag(int v) {
    if (v == _tagid) return;
    setState(() => _tagid = v);
    _load(0);
  }

  Future<void> _refresh() async {
    _load(0);
    if ((_lists[1] ?? const []).isNotEmpty) await _load(1);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('曲谱'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [Tab(text: '广场'), Tab(text: '排行榜')],
        ),
      ),
      body: Column(
        children: [
          _buildFilterBar(context),
          const Divider(height: 1),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildListTab(0),
                _buildListTab(1),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar(BuildContext context) {
    // 触屏紧凑字段：每项固定宽度横排；面板宽=字段宽（m3e_core 硬绑定），
    // 窄字段会让长标签（"尤克里里"）截断，故取 112dp。
    // showChipAnimation 必须为 false：默认 true 时选中项渲染成 chip（优先级
    // 高于 singleSelect 的文字分支），chip 的色块+清除钮会把 label 挤没——
    // 实机（2026-10-24 截图）表现为字段里只剩一个空色块。false 走
    // singleSelect 的 Text 分支直接显示 label。
    const fieldStyle = M3EDropdownFieldStyle(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      borderRadius: BorderRadius.all(Radius.circular(18)),
      showArrow: true,
    );
    const fieldWidth = 112.0;
    final showTags = _tabController.index == 0 && _tags.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildDropdown<int>(
                  items: _withSelected(_kInstrumentItems, _instruments),
                  fieldStyle: fieldStyle,
                  width: fieldWidth,
                  onChanged: (sel) {
                    if (sel.isEmpty) return; // 单选不允许取消
                    _switchInstruments(sel.first.value);
                  },
                ),
                const SizedBox(width: 8),
                _buildDropdown<int>(
                  items: _withSelected(_levelItems, _level),
                  fieldStyle: fieldStyle,
                  width: fieldWidth,
                  onChanged: (sel) {
                    if (sel.isEmpty) return;
                    _switchLevel(sel.first.value);
                  },
                ),
                if (showTags) ...[
                  const SizedBox(width: 8),
                  _buildDropdown<int>(
                    items: _tagItems,
                    fieldStyle: fieldStyle,
                    width: fieldWidth,
                    onChanged: (sel) {
                      if (sel.isEmpty) return;
                      _switchTag(sel.first.value);
                    },
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 构建单个下拉筛选（触屏 = M3EDropdownMenu，TV = D-pad 弹层，同一回调契约）。
  ///
  /// items 必须按当前值重建（`selected` 即实时选中态）——与
  /// `tv_dropdown_menu.dart` 头注的本仓既定手法一致。
  Widget _buildDropdown<T>({
    required List<M3EDropdownItem<T>> items,
    required M3EDropdownFieldStyle fieldStyle,
    required double width,
    required ValueChanged<List<M3EDropdownItem<T>>> onChanged,
  }) {
    return SizedBox(
      width: width,
      child: TvDropdownMenu<T>(
        items: items,
        singleSelect: true,
        // 单选场景必须关 chip 动画（见 _buildFilterBar 注释）
        showChipAnimation: false,
        fieldStyle: fieldStyle,
        onSelectionChanged: onChanged,
      ),
    );
  }

  /// 按 [selected] 值标记 items 的选中态（每次 build 重建实例）。
  List<M3EDropdownItem<int>> _withSelected(
    List<M3EDropdownItem<int>> items,
    int selected,
  ) {
    return [
      for (final item in items)
        item.copyWith(selected: item.value == selected),
    ];
  }

  /// 难度选项（随乐器变化，每次 build 从 `_levelOptions` 生成稳定顺序）。
  List<M3EDropdownItem<int>> get _levelItems => [
        for (final e in _levelOptions.entries)
          M3EDropdownItem(label: e.value, value: e.key),
      ];

  /// 标签选项（"全部" + /sheet/tags 返回）。
  List<M3EDropdownItem<int>> get _tagItems => [
        const M3EDropdownItem(label: '全部', value: 0),
        for (final t in _tags)
          M3EDropdownItem(label: t.name, value: int.tryParse(t.id) ?? 0),
      ];

  Widget _buildListTab(int tab) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final items = _lists[tab] ?? const [];
    final loading = _loading[tab] == true;

    Widget body;
    if (items.isEmpty && loading) {
      body = const Center(child: MD3ELoadingIndicator());
    } else if (items.isEmpty && _errors[tab] != null) {
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_errors[tab]!,
                style: textTheme.bodyMedium
                    ?.copyWith(color: colorScheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () {
                setState(() => _errors[tab] = null);
                _load(tab);
              },
              child: const Text('重试'),
            ),
          ],
        ),
      );
    } else if (items.isEmpty) {
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.library_music_outlined,
                size: 40, color: colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text('暂无曲谱',
                style: textTheme.bodySmall
                    ?.copyWith(color: colorScheme.onSurfaceVariant)),
          ],
        ),
      );
    } else {
      body = Md3PullToRefresh(
        onRefresh: _refresh,
        child: TvScrollRegion(
          memoryKey: 'tv/sheet-square-$tab',
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.only(top: 4, bottom: 24),
            itemCount: items.length + (loading || (_hasMore[tab] ?? false) ? 1 : 0),
            itemBuilder: (ctx, i) {
              if (i >= items.length) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: MD3ELoadingIndicator(size: 20),
                    ),
                  ),
                );
              }
              return _SheetCard(item: items[i]);
            },
          ),
        ),
      );
    }
    return body;
  }
}

/// 广场/排行榜谱目卡：谱名 + 歌名封面（内层展开时）+ 类型/记法 + 难度徽章。
class _SheetCard extends StatelessWidget {
  final KugouSheetInfo item;

  const _SheetCard({required this.item});

  void _open(BuildContext context) {
    openSheetRender(
      context,
      SheetRenderTarget(
        title: item.opernTypeName ?? item.name,
        opernId: item.opernId,
        jumpUrl: item.jumpUrl,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    // 主标题：歌名 — 歌手（songName 为空回退谱名/类型名，保证非空）
    final song = item.songName;
    final singer = item.singerName;
    final title = (song != null && song.isNotEmpty)
        ? (singer != null && singer.isNotEmpty ? '$song — $singer' : song)
        : (item.opernTypeName ?? item.name);
    // 副标题：谱名 · 记法 · 原调 · 谱作者（各段为空自动跳过）
    final meta = <String>[
      if (item.opernTypeName?.isNotEmpty ?? false) item.opernTypeName!,
      if (item.opernDrawTypeName?.isNotEmpty ?? false) item.opernDrawTypeName!,
      if (item.originalTune?.isNotEmpty ?? false) '原调 ${item.originalTune!}',
      if (item.opernAuthor?.isNotEmpty ?? false) '谱：${item.opernAuthor!}',
    ].join(' · ');

    final head = Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: [
          // 广场项内层谱目无独立封面：沿用歌曲封面（展开时已注入 cover 键）
          if (item.coverUrl != null && item.coverUrl!.isNotEmpty) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 48,
                height: 48,
                child: Image.network(
                  item.coverUrl!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Container(
                    color: colorScheme.surfaceContainerHighest,
                    child: const Icon(Icons.library_music_outlined, size: 22),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: textTheme.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (meta.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    meta,
                    style: textTheme.bodySmall
                        ?.copyWith(color: colorScheme.onSurfaceVariant),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              _levelBadge(item.instruments, item.opernLevel),
              style: textTheme.labelMedium
                  ?.copyWith(color: colorScheme.onPrimaryContainer),
            ),
          ),
        ],
      ),
    );

    final card = kTvBuild
        ? DpadFocusable(
            debugLabel: 'tv/sheet-card-${item.opernId}',
            onSelect: () => _open(context),
            child: SizedBox(width: double.infinity, child: head),
          )
        : InkWell(onTap: () => _open(context), child: head);

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: card,
    );
  }

  /// 难度徽章文案（与 song_sheet_sheet 同语义，此处内联避免 UI 依赖环）。
  String _levelBadge(int instruments, int level) {
    switch (instruments) {
      case 1:
        return switch (level) { 1 => '进阶', 2 => '基础', _ => '中级' };
      case 2:
      case 3:
        return level == 1 ? '进阶' : '基础';
      default:
        return '基础';
    }
  }
}
