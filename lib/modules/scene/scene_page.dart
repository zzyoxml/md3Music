import '../../core/layout/adaptive_navigator.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dpad/dpad.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import '../../widgets/md3_pull_to_refresh.dart';

import '../../core/remote/tv_card_focus.dart';
import '../../core/remote/tv_scroll_region.dart';

import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/pinchable_grid_view.dart';
import '../../widgets/playlist_cover_hero.dart';
import '../../widgets/scroll_aware_app_bar.dart';
import 'scene_detail_page.dart';

/// 主页「场景音乐」Tab 根页。
///
/// 展示场景列表（/scene/lists），点击场景进入 [SceneDetailPage]。
class ScenePage extends StatefulWidget {
  const ScenePage({super.key});

  @override
  State<ScenePage> createState() => _ScenePageState();
}

class _ScenePageState extends State<ScenePage> {
  /// 顶栏渐变 ScrollController：与 ScrollAwareAppBar 共享
  final ScrollController _scrollController = ScrollController();
  bool _isLoading = true;
  List<KugouSceneInfo> _scenes = [];

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _load();
    });
  }

  Future<void> _load({bool showLoading = true}) async {
    if (showLoading && mounted) setState(() => _isLoading = true);
    final r = await KugouApiClient().getSceneLists();
    final scenes = <KugouSceneInfo>[];
    for (final e in _listOf(r)) {
      if (e is! Map<String, dynamic>) continue;
      final s = KugouSceneInfo.fromJson(e);
      if (s.id.isNotEmpty) scenes.add(s);
    }
    if (!mounted) return;
    setState(() {
      _scenes = scenes;
      _isLoading = false;
    });
  }

  /// 从响应中提取列表（防御：data 可能是 Map 或 List，list 字段名多变）
  List<dynamic> _listOf(Map<String, dynamic>? json) {
    if (json == null) return const [];
    final d = json['data'];
    if (d is Map<String, dynamic>) {
      final l = d['list'] ?? d['info'] ?? d['items'];
      if (l is List) return l;
    }
    if (d is List) return d;
    final l = json['list'] ?? json['info'];
    if (l is List) return l;
    return const [];
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final heroFirstIndex = firstIndexById(_scenes.map((s) => s.id));
    return Scaffold(
      appBar: ScrollAwareAppBar(
        title: '场景音乐',
        opaque: true,
        scrollController: _scrollController,
      ),
      body: _isLoading
          ? const Center(child: M3ELoadingIndicator())
          : _scenes.isEmpty
              ? _buildEmpty(cs)
              : Md3PullToRefresh(
                  onRefresh: () => _load(showLoading: false),
                  // tv: 专区网格补区域语义（memoryKey + 横向 leave）。
                  child: TvScrollRegion(
                    memoryKey: 'tv/scene-grid',
                    horizontalEdge: DpadEdgeBehavior.leave,
                    child: PinchableGridView(
                    controller: _scrollController,
                    itemCount: _scenes.length,
                    childAspectRatio: 0.72,
                    padding: const EdgeInsets.all(16),
                    itemBuilder: (context, i) => _SceneCard(
                      scene: _scenes[i],
                      // 该 id 首次出现的卡才参与飞行（避免同子树重复 tag）。
                      heroTag: heroFirstIndex[_scenes[i].id] == i
                          ? sceneCoverHeroTag(_scenes[i].id)
                          : null,
                      onTap: () {
                        AdaptiveNav.openDetail(context,
                      (_) =>
                                SceneDetailPage(scene: _scenes[i]),
                        );
                      },
                    ),
                  ),
                  ),
                ),
    );
  }

  Widget _buildEmpty(ColorScheme cs) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.landscape_outlined,
            size: 48,
            color: cs.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 12),
          Text(
            '暂无场景音乐数据',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// 单个场景卡片：封面 + 名称
class _SceneCard extends StatelessWidget {
  final KugouSceneInfo scene;
  final VoidCallback? onTap;

  /// 非空时封面参与封面连贯过渡（sceneCoverHeroTag 命名空间）。
  final String? heroTag;

  const _SceneCard({required this.scene, this.onTap, this.heroTag});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final cover = scene.coverUrl != null
        ? CachedNetworkImage(
            imageUrl: scene.coverUrl!,
            memCacheWidth: 540,
            memCacheHeight: 540,
            fit: BoxFit.cover,
            errorWidget: (_, _, _) => ColoredBox(
              color: Colors.transparent,
              child: Center(
                child: Icon(
                  Icons.landscape_outlined,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
          )
        : ColoredBox(
            color: Colors.transparent,
            child: Center(
              child: Icon(
                Icons.landscape_outlined,
                color: cs.onSurfaceVariant,
              ),
            ),
          );
    final card = ClipRRect(
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: cs.surfaceContainerLow,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                // 卡外层 ClipRRect 全圆 16，封面只占上部 → 可见圆角仅上两角。
                child: heroTag == null
                    ? cover
                    : PlaylistCoverHero(
                        tag: heroTag!,
                        radius: const BorderRadius.vertical(
                          top: Radius.circular(16),
                        ),
                        child: cover,
                      ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Text(
                  scene.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: tt.labelMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: cs.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // tv: 专区卡片单停点（OK = 进入该场景详情页）。裸 InkWell 卡遥控选不中。
    return TvCardFocus(
      onSelect: onTap,
      debugLabel: 'scene-card',
      child: card,
    );
  }
}
