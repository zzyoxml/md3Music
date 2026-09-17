import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:m3e_core/m3e_core.dart';
import '../../widgets/md3_pull_to_refresh.dart';

import '../../core/utils/app_toast.dart';
import '../../data/models/playlist.dart';
import '../../providers/kugou_provider.dart';
import '../../widgets/pinchable_grid_view.dart';
import '../../widgets/scroll_aware_app_bar.dart';
import '../playlist/playlist_page.dart';
import 'ip_detail_page.dart';

/// 主页「编辑精选」Tab 页。
///
/// 展示两块内容：
/// 1. 编辑精选（/top/ip → musicadservice 每日推荐）：两列网格卡片；
/// 2. 编辑精选专区（/ip/zone）：纵向网格卡片（Pad 可捏合调整列数）。
/// 点击任意卡片进入 [IpDetailPage]。
class IpPage extends StatefulWidget {
  const IpPage({super.key});

  @override
  State<IpPage> createState() => _IpPageState();
}

class _IpPageState extends State<IpPage> {
  /// 顶栏渐变 ScrollController：与 ScrollAwareAppBar 共享
  final ScrollController _scrollController = ScrollController();
  bool _isLoading = true;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _load();
      if (mounted) setState(() => _isLoading = false);
    });
  }

  /// 并行加载编辑精选列表 + 专区（进入页面即强制刷新）
  Future<void> _load() async {
    final kugou = context.read<KugouProvider>();
    await Future.wait([
      kugou.getIpHome(forceRefresh: true),
      kugou.getIpZone(forceRefresh: true),
    ]);
  }

  /// 从响应中提取列表（防御：data 可能是 Map 或 List，list 字段名多变）
  List<dynamic> _listOf(Map<String, dynamic>? data) {
    if (data == null) return const [];
    final d = data['data'];
    if (d is Map<String, dynamic>) {
      final list = d['list'] ?? d['info'] ?? d['items'];
      if (list is List) return list;
    }
    if (d is List) return d;
    return const [];
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      appBar: ScrollAwareAppBar(
        title: '编辑精选',
        // 有壁纸时顶栏完全透明（与发现页一致），无壁纸时恒不透明 surface
        opaque: true,
        scrollController: _scrollController,
      ),
      body: _isLoading
          ? const Center(child: M3ELoadingIndicator())
          : Selector<KugouProvider, (List<dynamic>, List<dynamic>)>(
              selector: (_, kugou) =>
                  (_listOf(kugou.ipHomeData), _listOf(kugou.ipZoneData)),
              builder: (context, lists, _) {
                final picks = lists.$1;
                final zones = lists.$2;
                if (picks.isEmpty && zones.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.edit_note,
                          size: 48,
                          color: cs.onSurfaceVariant.withValues(alpha: 0.5),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '暂无编辑精选数据',
                          style: tt.titleMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 16),
                        FilledButton.tonal(
                          onPressed: () async {
                            setState(() => _isLoading = true);
                            await _load();
                            if (mounted) setState(() => _isLoading = false);
                          },
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  );
                }
                return Md3PullToRefresh(
                  onRefresh: _load,
                  child: ListView(
                    controller: _scrollController,
                    padding: const EdgeInsets.only(bottom: 24),
                    children: [
                      if (picks.isNotEmpty)
                        _buildPicksSection(context, cs, tt, picks),
                      if (zones.isNotEmpty)
                        _buildZoneSection(context, cs, tt, zones),
                    ],
                  ),
                );
              },
            ),
    );
  }

  /// 区块 1：编辑精选（/top/ip）两列网格
  Widget _buildPicksSection(
    BuildContext context,
    ColorScheme cs,
    TextTheme tt,
    List<dynamic> items,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            '编辑精选',
            style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        PinchableGridView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          spacing: 12.0,
          childAspectRatio: 0.78,
          itemCount: items.length,
          itemBuilder: (context, i) {
            final item = items[i];
            if (item is! Map<String, dynamic>) {
              return const SizedBox.shrink();
            }
            return _PicksCard(
              title: _stringOf(item, 'title', fallback: 'name'),
              coverUrl: _pickCover(item),
              onTap: () => _openPickItem(item),
            );
          },
        ),
      ],
    );
  }

  /// 区块 2：编辑精选专区（/ip/zone）纵向网格。
  /// 与区块 1 同为可捏合网格（Pad 默认 4 列、双指调整列数），
  /// 不再单行横滑，随页面整体上下滚动。
  Widget _buildZoneSection(
    BuildContext context,
    ColorScheme cs,
    TextTheme tt,
    List<dynamic> items,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            '编辑精选专区',
            style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        PinchableGridView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          spacing: 12.0,
          childAspectRatio: 0.78,
          itemCount: items.length,
          itemBuilder: (context, i) {
            final item = items[i];
            if (item is! Map<String, dynamic>) {
              return const SizedBox.shrink();
            }
            return _PicksCard(
              title: _stringOf(item, 'title', fallback: 'name'),
              coverUrl: _pickCover(item),
              onTap: () => _openZoneItem(item),
            );
          },
        ),
      ],
    );
  }

  /// 编辑精选卡片点击：ip 专题进详情页，歌单（type=1）进歌单页
  void _openPickItem(Map<String, dynamic> item) {
    final title = _stringOf(item, 'title', fallback: 'name');
    final ipId = _pickIpId(item);
    if (ipId != null) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => IpDetailPage(ipId: ipId, title: title),
        ),
      );
      return;
    }
    // 歌单项（/top/ip 中 type=1，extra 含 global_collection_id / specialid）
    final gid = _pickGlobalCollectionId(item);
    if (gid != null) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PlaylistPage(
            playlist: Playlist(
              id: gid,
              name: title,
              artworkUri: _pickCover(item),
              songCount: 0,
              songs: const [],
            ),
          ),
        ),
      );
      return;
    }
    _showUnavailable(title);
  }

  /// 专区卡片点击：无 ip_id 时先调 /ip/zone/home 尝试提取
  Future<void> _openZoneItem(Map<String, dynamic> item) async {
    final title = _stringOf(item, 'title', fallback: 'name');
    final pickedId = _pickIpId(item);
    final ipId = pickedId ?? await _resolveZoneIpId(item);
    if (ipId == null) {
      _showUnavailable(title);
      return;
    }
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => IpDetailPage(ipId: ipId, title: title),
      ),
    );
  }

  /// 专区项无 ip_id 时，用 /ip/zone/home 尝试提取（可能为空）
  Future<String?> _resolveZoneIpId(Map<String, dynamic> item) async {
    final rawId = item['id']?.toString();
    if (rawId == null || rawId.isEmpty) return null;
    try {
      final r = await context.read<KugouProvider>().apiClient.getIpZoneHome(
        rawId,
      );
      final data = r?['data'];
      if (data is Map<String, dynamic>) {
        final v = data['ip_id'] ?? data['ipId'];
        if (v != null && v.toString().isNotEmpty && v.toString() != '0') {
          return v.toString();
        }
      }
    } catch (_) {}
    return null;
  }

  void _showUnavailable(String title) {
    showToast('「$title」暂无可浏览内容', long: true);
  }

  // ---------- 防御性字段解析 ----------

  String _stringOf(Map<String, dynamic> item, String key,
      {String? fallback}) {
    final v = item[key];
    if (v != null && v.toString().isNotEmpty) return v.toString();
    if (fallback != null) {
      final f = item[fallback];
      if (f != null && f.toString().isNotEmpty) return f.toString();
    }
    return '';
  }

  /// 封面地址：extra 优先（/top/ip 的封面在顶层 image_url/sizable_image_url，
  /// 专区的在顶层 icon），统一把 {size} 占位替换为 400。
  String? _pickCover(Map<String, dynamic> item) {
    const keys = [
      'img_url',
      'cover',
      'cover_url',
      'img',
      'image_url',
      'sizable_image_url',
      'icon',
    ];
    String? raw;
    final extra = item['extra'];
    if (extra is Map<String, dynamic>) {
      for (final key in keys) {
        final v = extra[key];
        if (v is String && v.isNotEmpty) {
          raw = v;
          break;
        }
      }
    }
    if (raw == null) {
      for (final key in keys) {
        final v = item[key];
        if (v is String && v.isNotEmpty) {
          raw = v;
          break;
        }
      }
    }
    return raw?.replaceAll('{size}', '400');
  }

  /// ip_id：extra/顶层优先（Rust 端 /ip/zone 会写入顶层 ip_id）；
  /// /top/ip 的 extra.ip_id 因 Rust 提取 bug 常为 0，回退解析 inner_url。
  String? _pickIpId(Map<String, dynamic> item) {
    final extra = item['extra'];
    if (extra is Map<String, dynamic>) {
      final v = extra['ip_id'];
      if (_validIpId(v)) return v.toString();
      // inner_url 形如 https://m.kugou.com/ssr/musicip/ip?...&ip_id=113997&hreffrom=...
      final inner = extra['inner_url'];
      if (inner is String && inner.isNotEmpty) {
        try {
          final ip = Uri.parse(inner).queryParameters['ip_id'];
          if (ip != null && ip.isNotEmpty && ip != '0') return ip;
        } catch (_) {}
      }
    }
    final v = item['ip_id'];
    if (_validIpId(v)) return v.toString();
    return null;
  }

  /// 歌单全局 ID：/top/ip 歌单项（type=1）extra 里的 global_collection_id / specialid
  String? _pickGlobalCollectionId(Map<String, dynamic> item) {
    final extra = item['extra'];
    if (extra is Map<String, dynamic>) {
      final v = extra['global_collection_id'] ?? extra['specialid'];
      if (v != null && v.toString().isNotEmpty) return v.toString();
    }
    final v = item['global_collection_id'];
    if (v != null && v.toString().isNotEmpty) return v.toString();
    return null;
  }

  bool _validIpId(dynamic v) {
    if (v == null) return false;
    final s = v.toString();
    return s.isNotEmpty && s != '0';
  }
}

/// 编辑精选网格卡片：方形封面 + 标题
class _PicksCard extends StatelessWidget {
  final String title;
  final String? coverUrl;
  final VoidCallback? onTap;

  const _PicksCard({required this.title, this.coverUrl, this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: cs.surfaceContainerLow,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: coverUrl != null
                    ? CachedNetworkImage(
                        imageUrl: coverUrl!,
                        memCacheWidth: 540,
                        memCacheHeight: 540,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        placeholder: (_, _) => _coverPlaceholder(cs),
                        errorWidget: (_, _, _) => _coverPlaceholder(cs),
                      )
                    : _coverPlaceholder(cs),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _coverPlaceholder(ColorScheme cs) {
    return Container(
      color: cs.surfaceContainerHighest,
      child: Center(
        child: Icon(Icons.edit_note, color: cs.onSurfaceVariant, size: 32),
      ),
    );
  }
}
