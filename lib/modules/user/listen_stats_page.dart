import 'package:dpad/dpad.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../core/build_flags.dart';
import '../../core/layout/adaptive_navigator.dart';
import '../../core/layout/page_layout.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/motion_constants.dart';
import '../../core/widgets/staggered_animations.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/listen_stats_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/song_list_item.dart';
import '../artist/artist_detail_page.dart';
import '../player/secondary_mini_player.dart';

/// 听歌统计页（可视化）。
///
/// EchoMusic「统计」Tab 同款布局：4 张总览卡 → 最近 7 天柱状图 → 时段偏好 →
/// 常听歌手 TOP6 → 高频歌曲 TOP6 → 最常回访专辑。**数据全部来自云端**
/// （/user/listen 排行 + /user/history 最近历史 + /user/grade/info 等级），
/// 本地计数不参与统计（听歌记录已统一云端，一条计算路径）。
class ListenStatsPage extends StatefulWidget {
  const ListenStatsPage({super.key});

  @override
  State<ListenStatsPage> createState() => _ListenStatsPageState();
}

class _ListenStatsPageState extends State<ListenStatsPage> {
  @override
  void initState() {
    super.initState();
    // postFrame 延迟（同 PlayHistoryPage）：加载方法首个 notifyListeners
    // 同步发生，直接在 initState 调会在首帧 build 期间 markNeedsBuild 抛异常。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadAll();
    });
  }

  void _loadAll() {
    final stats = context.read<ListenStatsProvider>();
    // 排行与统计同源（由 /user/history 聚合派生）：一次 force 拉齐两份排行
    // （provider 内部会翻取历史页到排名所需深度）。
    // ignore: discarded_futures
    stats.loadRanking(0, force: true);
    final kugou = context.read<KugouProvider>();
    if (kugou.isLoggedIn && kugou.gradeInfo == null) {
      // ignore: discarded_futures
      kugou.getGradeInfo();
    }
  }

  Future<void> _refreshAll() async {
    final stats = context.read<ListenStatsProvider>();
    await Future.wait([
      stats.loadRanking(0, force: true),
      context.read<KugouProvider>().getGradeInfo(),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('听歌统计')),
      body: ContentWidth(
        child: SecondaryMiniPlayerHost(
          child: _buildBody(),
        ),
      ),
    );
  }

  Widget _buildBody() {
    final loggedIn = context.watch<KugouProvider>().isLoggedIn;
    final stats = context.watch<ListenStatsProvider>();
    final grade = context.watch<KugouProvider>().gradeInfo;
    if (!loggedIn) return _buildNotLoggedIn();
    final anyLoading = stats.isLoadingRanking(0) || stats.isLoadingRanking(1);
    final weekSongs = stats.rankingSongs(0);
    final allSongs = stats.rankingSongs(1);
    if (!stats.isRankingLoaded(0) && !stats.isRankingLoaded(1) && anyLoading) {
      return const Center(child: M3ELoadingIndicator());
    }
    if (weekSongs.isEmpty && allSongs.isEmpty && !stats.historyLoaded) {
      // 两份排行都空且历史也没拉到：整体失败态（有 error 才提示重试）
      if (stats.rankingError(0) != null || stats.rankingError(1) != null) {
        return _buildErrorRetry();
      }
    }
    final agg = stats.aggregate();
    return RefreshIndicator(
      onRefresh: _refreshAll,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildOverviewCards(agg, grade),
            const Gap(AppSpacing.md),
            _buildOverviewCardsRow2(agg),
            if (agg.historyTimeAvailable) ...[
              const Gap(AppSpacing.lg),
              _buildWeekChart(agg),
              const Gap(AppSpacing.lg),
              _buildTimeBuckets(agg),
            ],
            if (agg.topArtists.isNotEmpty) ...[
              const Gap(AppSpacing.lg),
              _buildArtists(agg.topArtists),
            ],
            if (agg.topSongs.isNotEmpty) ...[
              const Gap(AppSpacing.lg),
              _buildTopSongs(agg.topSongs),
            ],
            if (agg.topAlbum != null) ...[
              const Gap(AppSpacing.lg),
              _buildAlbumBanner(agg.topAlbum!),
            ],
            if (agg.historyTimeAvailable &&
                agg.historySampleCount > 0) ...[
              const Gap(AppSpacing.md),
              Text(
                '时间维度基于最近 ${agg.historySampleCount} 条云端记录聚合',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurfaceVariant
                      .withValues(alpha: 0.6),
                ),
              ),
            ],
            const Gap(AppSpacing.xl),
          ],
        ),
      ),
    );
  }

  // ---- 总览 4 卡（EchoMusic 同款网格；色调取 ColorScheme 容器色） ----

  /// 总览卡行。IntrinsicHeight 提供有界高度：Row(stretch) 直接放进
  /// 滚动视图会吃到无限高约束（layout 崩溃），两卡还需等高对齐。
  Widget _buildOverviewCards(ListenStatsAggregate agg, KugouGradeInfo? grade) {
    final sec = grade?.dSec ?? grade?.duration ?? 0;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _overviewCard(
              tone: _CardTone.primary,
              icon: Icons.schedule_outlined,
              label: '累计听歌',
              value: _formatTotalDuration(sec),
              hint: '来自云端账号累计',
            ),
          ),
          const Gap(AppSpacing.md),
          Expanded(
            child: _overviewCard(
              tone: _CardTone.secondary,
              icon: Icons.military_tech_outlined,
              label: '听歌等级',
              value: grade == null ? '—' : 'LV.${grade.pGrade ?? 0}',
              hint: grade == null
                  ? null
                  : '成长值 ${grade.pCurrentPoint ?? 0}/${grade.pNextGradePoint ?? 0}',
              progress: grade == null
                  ? null
                  : _gradeProgress(grade),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOverviewCardsRow2(ListenStatsAggregate agg) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _overviewCard(
              tone: _CardTone.tertiary,
              icon: Icons.local_fire_department_outlined,
              label: '本周播放',
              value: '${agg.weekTotalPlays} 次',
              hint: 'TOP${agg.weekSongCount} 首合计',
            ),
          ),
          const Gap(AppSpacing.md),
          Expanded(
            child: _overviewCard(
              tone: _CardTone.surface,
              icon: Icons.bar_chart,
              label: '累计播放',
              value: '${agg.totalPlays} 次',
              hint: 'TOP${agg.totalSongCount} 首合计',
            ),
          ),
        ],
      ),
    );
  }

  /// 总览卡的数值文本：数字从 0 计数到目标值，前后缀（"LV." / " 次"）保留。
  ///
  /// 无数字或目标值为 0 时直接原样显示，不套动画（避免 0→0 空转）。
  Widget _animatedValueText(String value, Color fg) {
    final style = Theme.of(context).textTheme.titleLarge?.copyWith(
      fontWeight: FontWeight.w800,
      color: fg,
    );
    // 分组：前缀 / 数字 / 后缀（"LV.5" → "LV." / 5 / ""，"123 次" → "" / 123 / " 次"）
    final match = RegExp(r'^(\D*)(\d+)(.*)$').firstMatch(value);
    final numericValue = match == null ? 0 : int.parse(match.group(2)!);
    if (match == null || numericValue == 0) {
      return Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }
    // 必须用 IntTween：Tween<int> 的默认 lerp 会算出 double 而抛
    // "Cannot lerp between" 异常（IntTween 内部会 round）。
    // 时长取 M3 standard 400ms：进场动画需在既有测试 harness 的
    // 400ms pump 窗口内收敛到终值（assert 断言的是终值文本）。
    return TweenAnimationBuilder<int>(
      tween: IntTween(begin: 0, end: numericValue),
      duration: M3ExpressiveMotion.defaultDuration,
      curve: Curves.easeOutCubic,
      builder: (context, current, _) {
        return Text(
          '${match.group(1)}$current${match.group(3)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: style,
        );
      },
    );
  }

  Widget _overviewCard({
    required _CardTone tone,
    required IconData icon,
    required String label,
    required String value,
    String? hint,
    double? progress,
  }) {
    final cs = Theme.of(context).colorScheme;
    final (Color bg, Color fg) = switch (tone) {
      _CardTone.primary => (cs.primaryContainer, cs.onPrimaryContainer),
      _CardTone.secondary => (cs.secondaryContainer, cs.onSecondaryContainer),
      _CardTone.tertiary => (cs.tertiaryContainer, cs.onTertiaryContainer),
      _CardTone.surface => (cs.surfaceContainerHigh, cs.onSurface),
    };

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: fg.withValues(alpha: 0.7)),
              const Gap(AppSpacing.xs),
              Text(
                label,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: fg.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
          const Gap(AppSpacing.xs),
          _animatedValueText(value, fg),
          if (progress != null) ...[
            const Gap(AppSpacing.xs),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 4,
                backgroundColor: fg.withValues(alpha: 0.15),
                valueColor: AlwaysStoppedAnimation<Color>(fg),
              ),
            ),
          ],
          if (hint != null) ...[
            const Gap(AppSpacing.xs),
            Text(
              hint,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: fg.withValues(alpha: 0.55),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ---- 最近 7 天柱状图（纯 Container 渐变柱，零图表库） ----

  Widget _buildWeekChart(ListenStatsAggregate agg) {
    final cs = Theme.of(context).colorScheme;
    final days = agg.last7Days;
    final maxPlays = days.fold<int>(1, (m, d) => d.plays > m ? d.plays : m);
    const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    
    return _sectionCard(
      title: '最近 7 天',
      icon: Icons.calendar_view_week,
      child: SizedBox(
        height: 168,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < days.length; i++)
              Expanded(
                child: Column(
                  children: [
                    Text(
                      '${days[i].plays}',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    const Gap(AppSpacing.xs),
                    // 柱子区必须 Expanded 包住：StaggeredBar 内部的
                    // FractionallySizedBox(heightFactor) 需要「有界高度」约束，
                    // 直接放在无界 Column 里会算出 NaN 约束而 layout 崩溃。
                    Expanded(
                      child: StaggeredBar(
                        index: i,
                        totalItems: 7,
                        heightFactor: days[i].plays <= 0
                            ? 0.0
                            : (days[i].plays / maxPlays),
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 6),
                          decoration: BoxDecoration(
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(6),
                            ),
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [cs.primary, cs.tertiary],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const Gap(AppSpacing.xs),
                    Text(
                      weekdays[days[i].day.weekday - 1],
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      '${days[i].day.month}/${days[i].day.day}',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        fontSize: 10,
                        color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ---- 时段偏好（4 桶横条） ----

  Widget _buildTimeBuckets(ListenStatsAggregate agg) {
    final cs = Theme.of(context).colorScheme;
    const labels = [
      ('凌晨', '00-06'),
      ('上午', '06-12'),
      ('下午', '12-18'),
      ('夜晚', '18-24'),
    ];
    final maxBucket =
        agg.timeBuckets.fold<int>(1, (m, v) => v > m ? v : m);
    
    return _sectionCard(
      title: '时段偏好',
      icon: Icons.schedule,
      child: Column(
        children: [
          for (var i = 0; i < labels.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  SizedBox(
                    width: 72,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          labels[i].$1,
                          style: Theme.of(context)
                              .textTheme
                              .labelMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          labels[i].$2,
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(
                                fontSize: 10,
                                color: cs.onSurfaceVariant.withValues(
                                  alpha: 0.6,
                                ),
                              ),
                        ),
                      ],
                    ),
                  ),
                  const Gap(AppSpacing.sm),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(99),
                      child: SizedBox(
                        height: 8,
                        child: Stack(
                          children: [
                            Container(
                              color: cs.onSurface.withValues(alpha: 0.06),
                            ),
                            StaggeredProgressBar(
                              index: i,
                              totalItems: 4,
                              targetValue: agg.timeBuckets[i] <= 0
                                  ? 0.0
                                  : (agg.timeBuckets[i] / maxBucket),
                              minWidthFactor: 0.04,
                              gradient: LinearGradient(
                                colors: [cs.tertiary, cs.primary],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const Gap(AppSpacing.sm),
                  SizedBox(
                    width: 40,
                    child: Text(
                      '${agg.timeBuckets[i]} 条',
                      textAlign: TextAlign.right,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ---- 常听歌手 TOP6（序号徽章 + 横条） ----

  Widget _buildArtists(List<ListenStatsArtist> artists) {
    final cs = Theme.of(context).colorScheme;
    final maxPlays =
        artists.fold<int>(1, (m, a) => a.plays > m ? a.plays : m);
    
    return _sectionCard(
      title: '常听歌手',
      icon: Icons.mic_none,
      child: Column(
        children: [
          for (var i = 0; i < artists.length; i++)
            // 行级交错上浮：与行内进度条延伸动画同拍启动，形成连贯入场
            StaggeredSlideFade(
              index: i,
              totalItems: artists.length,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: _artistRow(artists[i], i, artists.length, maxPlays, cs),
              ),
            ),
        ],
      ),
    );
  }

  Widget _artistRow(
    ListenStatsArtist artist,
    int index,
    int totalItems,
    int maxPlays,
    ColorScheme cs,
  ) {
    final row = InkWell(
      onTap: artist.artistId == null
          ? null
          : () {
              AdaptiveNav.openDetail(
                context,
                (_) => ArtistDetailPage(
                  artistId: artist.artistId!,
                  artistName: artist.name,
                ),
              );
            },
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Container(
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: cs.onSurface.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Text(
                '${index + 1}',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
            const Gap(AppSpacing.sm),
            SizedBox(
              width: 104,
              child: Text(
                artist.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            const Gap(AppSpacing.sm),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: SizedBox(
                  height: 7,
                  child: Stack(
                    children: [
                      Container(
                        color: cs.onSurface.withValues(alpha: 0.06),
                      ),
                      StaggeredProgressBar(
                        index: index,
                        totalItems: totalItems,
                        targetValue: (artist.plays / maxPlays),
                        minWidthFactor: 0.08,
                        gradient: LinearGradient(
                          colors: [cs.primary, cs.secondary],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const Gap(AppSpacing.sm),
            Text(
              '${artist.plays}次',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
    if (kTvBuild && artist.artistId != null) {
      return DpadFocusable(
        debugLabel: 'listen-stats/artist-${artist.name}',
        onSelect: () {
          AdaptiveNav.openDetail(
            context,
            (_) => ArtistDetailPage(
              artistId: artist.artistId!,
              artistName: artist.name,
            ),
          );
        },
        child: row,
      );
    }
    return row;
  }

  // ---- 高频歌曲 TOP6（可播放行） ----

  Widget _buildTopSongs(List<KugouRankedSong> songs) {
    final cs = Theme.of(context).colorScheme;
    return _sectionCard(
      title: '高频歌曲',
      icon: Icons.queue_music,
      child: Column(
        children: [
          for (var i = 0; i < songs.length; i++)
            // 行级交错上浮：SongListItem 内部无数据动画，行本身补上入场
            StaggeredSlideFade(
              index: i,
              totalItems: songs.length,
              child: Row(
                children: [
                  SizedBox(
                    width: 28,
                    child: Text(
                      '${i + 1}',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: i < 3 ? FontWeight.w800 : FontWeight.w500,
                        color: i < 3
                            ? cs.primary
                            : cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Expanded(
                    child: SongListItem(
                      song: songs[i].song,
                      onTap: () {
                        final list = songs.map((r) => r.song).toList();
                        context
                            .read<PlayerProvider>()
                            .playOnlinePlaylist(list, i);
                      },
                      onMoreTap: () {},
                    ),
                  ),
                  if (songs[i].playCount != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text(
                        '${songs[i].playCount}次',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ---- 最常回访专辑 banner ----

  Widget _buildAlbumBanner(ListenStatsAlbum album) {
    final cs = Theme.of(context).colorScheme;
    return StaggeredSlideFade(
      index: 0,
      totalItems: 1,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: cs.primaryContainer,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Icon(
                Icons.album_outlined,
                color: cs.onPrimaryContainer,
              ),
            ),
            const Gap(AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '最常回访专辑',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  const Gap(AppSpacing.xs),
                  Text(
                    album.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
            const Gap(AppSpacing.sm),
            Text(
              '${album.plays}次 · ${album.songCount}首',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- 通用部件 ----

  Widget _sectionCard({
    required String title,
    required IconData icon,
    required Widget child,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: cs.onSurfaceVariant),
              const Gap(AppSpacing.xs),
              Text(
                title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const Gap(AppSpacing.md),
          child,
        ],
      ),
    );
  }

  Widget _buildNotLoggedIn() {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.cloud_off_outlined,
            size: 64,
            color: cs.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(
            '登录后可查看听歌统计',
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          Text(
            '统计数据来自云端账号的听歌记录',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorRetry() {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.error_outline,
            size: 64,
            color: cs.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(
            '统计数据加载失败',
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(
            onPressed: () {
              setState(_loadAll);
            },
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }

  String _formatTotalDuration(int seconds) {
    if (seconds <= 0) return '0 分钟';
    final d = seconds ~/ 86400;
    final h = (seconds % 86400) ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (d > 0) return '$d天$h小时';
    if (h > 0) return '$h小时$m分';
    return '$m 分钟';
  }

  double _gradeProgress(KugouGradeInfo grade) {
    final cur = (grade.pCurrentPoint ?? 0).toDouble();
    final next = (grade.pNextGradePoint ?? 1).toDouble();
    return next > 0 ? (cur / next).clamp(0.0, 1.0) : 0.0;
  }
}

enum _CardTone { primary, secondary, tertiary, surface }
