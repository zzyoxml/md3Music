import 'package:cached_network_image/cached_network_image.dart';
import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/build_flags.dart';
import '../../data/models/song.dart';
import '../../providers/kugou_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';

/// 歌曲成绩单（榜单成就）面板入口。
///
/// 与「看评论」同模式的统一入口（歌曲信息页 / 歌曲行菜单 / 无法播放对话框共用）：
/// 数据来自 /song/ranking（平台成就卡，匿名可用）与 /song/ranking/filter
/// （子榜单历史明细，需登录，首次展开时懒加载一次）。
void showSongRankingSheet(BuildContext context, Song song) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (sheetCtx) => DraggableScrollableSheet(
      initialChildSize: 0.65,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      expand: false,
      builder: (innerCtx, scrollController) => Column(
        children: [
          Container(
            width: 32,
            height: 4,
            margin: const EdgeInsets.only(top: 12, bottom: 8),
            decoration: BoxDecoration(
              color: Theme.of(innerCtx).colorScheme.outline,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '成绩单: ${song.displayName}',
                    style: Theme.of(innerCtx).textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: '关闭',
                  onPressed: () => Navigator.of(innerCtx).pop(),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: SongRankingView(
              song: song,
              scrollController: scrollController,
            ),
          ),
        ],
      ),
    ),
  );
}

/// 成绩单内容视图：平台成就卡列表，卡片可展开查看子榜单历史明细。
class SongRankingView extends StatefulWidget {
  final Song song;

  /// 绑定 DraggableScrollableSheet 的滚动控制器（列表滚到顶后继续拖可缩放面板）。
  final ScrollController? scrollController;

  const SongRankingView({
    super.key,
    required this.song,
    this.scrollController,
  });

  @override
  State<SongRankingView> createState() => _SongRankingViewState();
}

class _SongRankingViewState extends State<SongRankingView> {
  KugouSongRanking? _summary;
  bool _summaryLoading = true;
  String? _summaryError;

  /// filter 明细：null=尚未拉取。
  List<KugouSongRankingFilterItem>? _filterItems;
  bool _filterLoading = false;
  bool _filterFailed = false;

  /// 当前展开的平台卡（按 info 下标），单开互斥；null=全部收起。
  int? _expandedIndex;

  String? get _albumAudioId {
    final id = widget.song.albumAudioId;
    if (id == null || id.isEmpty) return null;
    return id;
  }

  @override
  void initState() {
    super.initState();
    if (_albumAudioId != null) _loadSummary();
  }

  Future<void> _loadSummary() async {
    setState(() {
      _summaryLoading = true;
      _summaryError = null;
    });
    final ranking =
        await KugouApiClient().getSongRanking(_albumAudioId!);
    if (!mounted) return;
    setState(() {
      _summaryLoading = false;
      if (ranking == null) {
        _summaryError = '成绩单加载失败';
      } else {
        _summary = ranking;
      }
    });
  }

  /// 首次展开任意平台卡时懒加载明细，整个会话只拉一次。
  Future<void> _loadFilter() async {
    setState(() => _filterLoading = true);
    final items = await KugouApiClient().getSongRankingFilter(_albumAudioId!);
    if (!mounted) return;
    setState(() {
      _filterLoading = false;
      _filterFailed = items == null;
      _filterItems = items ?? const [];
    });
  }

  void _toggleCard(int index) {
    setState(() {
      _expandedIndex = _expandedIndex == index ? null : index;
    });
    if (_expandedIndex != null && _filterItems == null && !_filterLoading) {
      _loadFilter();
    }
  }

  /// 成就卡 → 子榜单条目匹配：先按 platform 数字，再按平台名；
  /// ranking 只返回一个平台且匹配不到时展示整个 filter 列表兜底。
  List<KugouSongRankingFilterItem> _filterItemsFor(KugouSongRankingInfo card) {
    final items = _filterItems;
    if (items == null || items.isEmpty) return const [];
    bool matches(KugouSongRankingFilterItem e) {
      if (card.platform != null && e.platform != null) {
        return e.platform == card.platform;
      }
      if (card.platformName != null && e.platformName != null) {
        return e.platformName == card.platformName;
      }
      return false;
    }

    final matched = items.where(matches).toList();
    if (matched.isEmpty && _summary != null && _summary!.info.length == 1) {
      return items;
    }
    return matched;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    // 成绩单依赖 album_audio_id（即 MixSongID），缺失时无可查询
    if (_albumAudioId == null) {
      return _buildEmpty(context, '该歌曲暂无成绩单数据', colorScheme, textTheme);
    }
    if (_summaryLoading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text('成绩单加载中…',
                style: textTheme.bodySmall
                    ?.copyWith(color: colorScheme.onSurfaceVariant)),
          ],
        ),
      );
    }
    if (_summaryError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_summaryError!,
                style: textTheme.bodyMedium
                    ?.copyWith(color: colorScheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            TextButton(onPressed: _loadSummary, child: const Text('重试')),
          ],
        ),
      );
    }
    final summary = _summary;
    final cards = summary?.info ?? const <KugouSongRankingInfo>[];
    final summaryText = (summary?.title2?.isNotEmpty ?? false)
        ? summary!.title2
        : (summary?.title?.isNotEmpty ?? false) ? summary!.title : null;
    if (cards.isEmpty && (summaryText == null || summaryText.isEmpty)) {
      return _buildEmpty(context, '暂无成绩单数据', colorScheme, textTheme);
    }

    return ListView(
      controller: widget.scrollController,
      padding: const EdgeInsets.only(top: 4, bottom: 24),
      children: [
        if (summaryText != null && summaryText.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(summaryText,
                style: textTheme.bodyMedium
                    ?.copyWith(color: colorScheme.onSurfaceVariant)),
          ),
        if (cards.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Text('暂无平台榜单数据',
                  style: textTheme.bodySmall
                      ?.copyWith(color: colorScheme.onSurfaceVariant)),
            ),
          ),
        for (var i = 0; i < cards.length; i++) _buildRankingCard(i, cards[i]),
      ],
    );
  }

  Widget _buildEmpty(
    BuildContext context,
    String message,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.leaderboard_outlined,
              size: 40, color: colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(message,
              style: textTheme.bodySmall
                  ?.copyWith(color: colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  /// 平台成就卡：头部为停点（TV 下 DpadFocusable 单停点），展开面板独立于停点
  /// （参照评论楼中楼的拆分教训：整卡当停点会让焦点矩形随展开高度失控）。
  Widget _buildRankingCard(int index, KugouSongRankingInfo card) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final expanded = _expandedIndex == index;

    final platformName =
        (card.platformName?.isNotEmpty ?? false) ? card.platformName! : '未知平台';
    final times = card.rankingTimes;
    final lastTime = card.lastTime;
    final rank = card.rankingNum ?? 0;

    final head = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: [
          _buildLogo(card.logoPic ?? card.sharePic, colorScheme),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(platformName,
                    style: textTheme.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(
                  '累计上榜：${times != null && times > 0 ? '$times 次' : '未知'}'
                  ' · 最近上榜：${lastTime != null && lastTime.isNotEmpty ? lastTime : '未知'}',
                  style: textTheme.bodySmall
                      ?.copyWith(color: colorScheme.onSurfaceVariant),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (rank > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '第 $rank 名',
                style: textTheme.labelMedium
                    ?.copyWith(color: colorScheme.onPrimaryContainer),
              ),
            )
          else
            Text('暂无排名',
                style: textTheme.bodySmall
                    ?.copyWith(color: colorScheme.onSurfaceVariant)),
          const SizedBox(width: 4),
          AnimatedRotation(
            turns: expanded ? 0.5 : 0,
            duration: const Duration(milliseconds: 200),
            child: Icon(Icons.expand_more, color: colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );

    final Widget headStop = kTvBuild
        ? DpadFocusable(
            debugLabel: 'tv/song-ranking-card-$index',
            onSelect: () => _toggleCard(index),
            // 宽度钉回外层列宽，避免 TV 焦点矩形收缩到内容宽
            child: SizedBox(width: double.infinity, child: head),
          )
        : InkWell(onTap: () => _toggleCard(index), child: head);

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          headStop,
          if (expanded) ...[
            const Divider(height: 1, indent: 16, endIndent: 16),
            _buildFilterPanel(card),
          ],
        ],
      ),
    );
  }

  /// 展开面板：子榜单历史明细（榜单名 + 累计次数 + 历史最高名次）。
  Widget _buildFilterPanel(KugouSongRankingInfo card) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    Widget body;
    if (_filterLoading) {
      body = Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Text('榜单明细加载中…',
                style: textTheme.bodySmall
                    ?.copyWith(color: colorScheme.onSurfaceVariant)),
          ],
        ),
      );
    } else {
      final items = _filterItemsFor(card);
      if (items.isEmpty) {
        // 未登录时 filter 拉不到明细：温和提示，不强制跳登录页
        final loggedIn = context.read<KugouProvider>().isLoggedIn;
        final hint = _filterFailed && !loggedIn
            ? '登录后可查看完整榜单明细'
            : '暂无更多榜单详情';
        body = Padding(
          padding: const EdgeInsets.all(16),
          child: Text(hint,
              style: textTheme.bodySmall
                  ?.copyWith(color: colorScheme.onSurfaceVariant)),
        );
      } else {
        body = Column(
          children: [
            for (final item in items)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(item.name ?? '未知榜单',
                              style: textTheme.bodyMedium,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 2),
                          Text(
                            '累计上榜：${item.count != null && item.count! > 0 ? '${item.count} 次' : '未知'}',
                            style: textTheme.bodySmall
                                ?.copyWith(color: colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      item.topRanking != null && item.topRanking! > 0
                          ? '最高第 ${item.topRanking} 名'
                          : '暂无排名',
                      style: textTheme.bodySmall?.copyWith(
                        color: item.topRanking != null && item.topRanking! > 0
                            ? colorScheme.primary
                            : colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      }
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: body,
    );
  }

  Widget _buildLogo(String? url, ColorScheme colorScheme) {
    Widget fallback() => Container(
          color: colorScheme.surfaceContainerHighest,
          alignment: Alignment.center,
          child: Icon(Icons.leaderboard_outlined,
              size: 22, color: colorScheme.onSurfaceVariant),
        );
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: 42,
        height: 42,
        child: (url != null && url.isNotEmpty)
            ? CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.cover,
                placeholder: (_, _) => fallback(),
                errorWidget: (_, _, _) => fallback(),
              )
            : fallback(),
      ),
    );
  }
}
