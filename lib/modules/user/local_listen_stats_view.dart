import 'package:dpad/dpad.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/build_flags.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/utils/app_toast.dart';
import '../../providers/local_listen_stats_provider.dart';

/// 本地听歌统计视图（听歌统计页「本地」数据源 Tab 的内容）。
///
/// 数据全部来自本地库（[LocalListenStatsProvider] 聚合 play_records），
/// 不依赖登录态/网络，本地歌与未知艺人/专辑同样计入；与云端 Tab
/// （ListenStatsPage 内联的云端布局）互斥展示，由页面顶部的数据源
/// 切换控件控制。
///
/// 布局：时间范围切换 → 概览 2x2 卡 → Top 歌曲/艺人/专辑 → 月度趋势条形图。
/// 趋势图为静态等高 Container 列（零图表库、无常驻动画，功耗友好）；
/// TV 构建下榜单行与趋势柱用 [DpadFocusable] 包裹保证遥控器焦点可达。
class LocalListenStatsView extends StatefulWidget {
  const LocalListenStatsView({super.key});

  @override
  State<LocalListenStatsView> createState() => _LocalListenStatsViewState();
}

class _LocalListenStatsViewState extends State<LocalListenStatsView> {
  /// 首次聚合尚未完成：overview 全 0 只是因为还没查到数据，
  /// 此期间显示加载态而非空态，避免空态闪烁。
  bool _initializing = true;

  /// 切换时间范围进行中：目标范围可能无数据（overview 为 0），
  /// 加载完成前同样不显示空态。
  bool _switching = false;

  @override
  void initState() {
    super.initState();
    // postFrame 延迟（同云端 Tab 的 loadAll）：load 内首个 notifyListeners
    // 同步发生，initState 期间直接调会在首帧 build 中 markNeedsBuild 抛异常。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _initialLoad();
    });
  }

  /// 强制重聚合（进页/下拉刷新）。provider 内部已吞掉聚合异常（只记日志），
  /// 这里对 load 本身兜底：意外抛出（如库打开失败）时原生 toast 提示。
  Future<void> _runLoad() async {
    try {
      await context.read<LocalListenStatsProvider>().load(force: true);
    } catch (_) {
      if (mounted) showToast('本地统计加载失败');
    }
  }

  Future<void> _initialLoad() async {
    await _runLoad();
    if (mounted) setState(() => _initializing = false);
  }

  /// 下拉刷新（RefreshIndicator 自带完成动画，无需本地加载状态）。
  Future<void> _reload() => _runLoad();

  /// 切换时间范围：setRange 会异步触发重载，这里再 await 一次 load
  /// （请求在 provider 内串行排队，第二次版本命中缓存、开销可忽略），
  /// 以感知"新范围聚合完成"的时点，期间遮住空态闪烁。
  Future<void> _selectRange(LocalListenStatsRange range) async {
    final provider = context.read<LocalListenStatsProvider>();
    setState(() => _switching = true);
    provider.setRange(range);
    try {
      await provider.load();
    } catch (_) {
      if (mounted) showToast('本地统计加载失败');
    }
    if (mounted) setState(() => _switching = false);
  }

  @override
  Widget build(BuildContext context) {
    final stats = context.watch<LocalListenStatsProvider>();
    final plays = stats.overview.plays;
    // 首次加载转圈；切到无数据范围的过渡期也转圈，避免空态一闪而过。
    if (_initializing || (_switching && plays == 0)) {
      return const Center(child: M3ELoadingIndicator());
    }
    if (plays == 0) {
      // 本地无任何播放记录：引导空态
      return _buildEmptyGuide();
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildRangeSwitch(stats.selectedRange),
            const Gap(AppSpacing.md),
            // 已有内容后再加载（切范围/刷新）：顶部细进度条提示，不整页转圈
            if (stats.isLoading || _switching) ...[
              const LinearProgressIndicator(minHeight: 2),
              const Gap(AppSpacing.md),
            ],
            _buildOverview(stats.overview),
            const Gap(AppSpacing.lg),
            _buildTopSection(
              title: 'Top 歌曲',
              icon: Icons.queue_music,
              entries: stats.topTracks,
              subtitleOf: (e) => e.repArtist ?? '',
            ),
            const Gap(AppSpacing.lg),
            _buildTopSection(
              title: 'Top 艺人',
              icon: Icons.mic_none,
              entries: stats.topArtists,
              subtitleOf: (e) =>
                  e.repTitle == null ? '' : '代表作 ${e.repTitle}',
            ),
            const Gap(AppSpacing.lg),
            _buildTopSection(
              title: 'Top 专辑',
              icon: Icons.album_outlined,
              entries: stats.topAlbums,
              subtitleOf: (e) =>
                  e.repTitle == null ? '' : '代表曲目 ${e.repTitle}',
            ),
            const Gap(AppSpacing.lg),
            _buildTrend(stats.monthlyTrends),
            const Gap(AppSpacing.xl),
          ],
        ),
      ),
    );
  }

  // ---- 时间范围切换 ----

  /// 时间范围切换（本周/本月/今年/全部）。
  ///
  /// tv 核对（2026-10-24）：[SegmentedButton] 的段是 TextButton（InkWell
  /// 焦点停点 + ActivateIntent 动作，WidgetsApp 默认 Shortcuts 含
  /// select→ActivateIntent），dpad 光束遍历天然可达、OK 可激活，
  /// 无需再包 DpadFocusable（同 sounds_page 等既有用法）。
  /// 切范围期间整视图换成 loading、焦点节点随之销毁：dpad 会在
  /// 焦点空缺时按记忆矩形自愈落焦（dpad _restoreFocus），无需额外接线。
  Widget _buildRangeSwitch(LocalListenStatsRange current) {
    return SegmentedButton<LocalListenStatsRange>(
      segments: const [
        ButtonSegment(value: LocalListenStatsRange.week, label: Text('本周')),
        ButtonSegment(value: LocalListenStatsRange.month, label: Text('本月')),
        ButtonSegment(value: LocalListenStatsRange.year, label: Text('今年')),
        ButtonSegment(value: LocalListenStatsRange.all, label: Text('全部')),
      ],
      selected: {current},
      onSelectionChanged: (selection) => _selectRange(selection.first),
    );
  }

  // ---- 概览 2x2 卡（色调取 ColorScheme 容器色，同云端总览卡风格） ----

  Widget _buildOverview(LocalOverview ov) {
    return Column(
      children: [
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _overviewCard(
                  tone: _CardTone.primary,
                  icon: Icons.play_circle_outline,
                  label: '播放次数',
                  value: '${ov.plays} 次',
                ),
              ),
              const Gap(AppSpacing.md),
              Expanded(
                child: _overviewCard(
                  tone: _CardTone.secondary,
                  icon: Icons.schedule_outlined,
                  label: '净听时长',
                  value: _formatPlayedMs(ov.playedMs),
                ),
              ),
            ],
          ),
        ),
        const Gap(AppSpacing.md),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _overviewCard(
                  tone: _CardTone.tertiary,
                  icon: Icons.local_fire_department_outlined,
                  label: '活跃天数',
                  value: '${ov.activeDays} 天',
                ),
              ),
              const Gap(AppSpacing.md),
              Expanded(
                child: _overviewCard(
                  tone: _CardTone.surface,
                  icon: Icons.person_outline,
                  label: '曲目 / 艺人',
                  value: '${ov.distinctTracks} / ${ov.distinctArtists}',
                  hint: '去重曲目数 / 艺人数',
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _overviewCard({
    required _CardTone tone,
    required IconData icon,
    required String label,
    required String value,
    String? hint,
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
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
              color: fg,
            ),
          ),
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

  // ---- Top 榜单（歌曲/艺人/专辑共用行结构） ----

  Widget _buildTopSection({
    required String title,
    required IconData icon,
    required List<LocalTopEntry> entries,
    required String Function(LocalTopEntry) subtitleOf,
  }) {
    return _sectionCard(
      title: title,
      icon: icon,
      child: entries.isEmpty
          // 防御分支：正常口径下 plays>0 时三个维度都有归桶结果
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
              child: Text(
                '暂无播放记录，听完一首歌再来吧',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            )
          : Column(
              children: [
                for (var i = 0; i < entries.length; i++)
                  _rankRow(i, entries[i], subtitleOf(entries[i])),
              ],
            ),
    );
  }

  Widget _rankRow(int index, LocalTopEntry entry, String subtitle) {
    final cs = Theme.of(context).colorScheme;
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Text(
              '${index + 1}',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: index < 3 ? FontWeight.w800 : FontWeight.w500,
                color: index < 3 ? cs.primary : cs.onSurfaceVariant,
              ),
            ),
          ),
          const Gap(AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.key,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                if (subtitle.isNotEmpty)
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          const Gap(AppSpacing.sm),
          Text(
            '${entry.count}次 · ${_formatPlayedMs(entry.playedMs)}',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
    // TV：榜单行用 DpadFocusable 包裹保证焦点可达（照 listen_stats_page
    // 云端榜单行的写法）。本地榜单暂无跳转目标，onSelect 为空操作。
    if (kTvBuild) {
      return DpadFocusable(
        debugLabel: 'local-listen-stats/rank-${entry.key}',
        onSelect: () {},
        child: row,
      );
    }
    return row;
  }

  // ---- 月度趋势（静态等高 Container 列，零图表库零动画） ----

  Widget _buildTrend(List<LocalMonthPoint> points) {
    // 趋势依赖月聚合结果：无数据（理论上仅异常场景）时整段隐藏
    if (points.isEmpty) return const SizedBox.shrink();
    final maxCount = points.fold<int>(1, (m, p) => p.count > m ? p.count : m);
    return _sectionCard(
      title: '月度趋势',
      icon: Icons.insert_chart_outlined,
      child: SizedBox(
        height: 140,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final p in points)
              Expanded(child: _trendColumn(p, p.count / maxCount)),
          ],
        ),
      ),
    );
  }

  Widget _trendColumn(LocalMonthPoint point, double factor) {
    final cs = Theme.of(context).colorScheme;
    final column = Column(
      children: [
        Text(
          '${point.count}',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: cs.onSurfaceVariant,
          ),
        ),
        const Gap(AppSpacing.xs),
        // 柱体区必须 Expanded 包住：FractionallySizedBox(heightFactor) 需要
        // 「有界高度」约束，且底对齐（Alignment.bottomCenter）才是柱状图。
        Expanded(
          child: FractionallySizedBox(
            alignment: Alignment.bottomCenter,
            heightFactor: factor.clamp(0.0, 1.0),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: 0.85),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(6),
                ),
              ),
            ),
          ),
        ),
        const Gap(AppSpacing.xs),
        Text(
          '${point.month % 100}月',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: cs.onSurfaceVariant,
          ),
        ),
      ],
    );
    // TV：每根柱可聚焦（无跳转目标，onSelect 空操作）
    if (kTvBuild) {
      return DpadFocusable(
        debugLabel: 'local-listen-stats/month-${point.month}',
        onSelect: () {},
        child: column,
      );
    }
    return column;
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

  Widget _buildEmptyGuide() {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.graphic_eq_outlined,
            size: 64,
            color: cs.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(
            '本地听歌统计',
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          Text(
            '暂无播放记录，听完一首歌再来吧',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  /// 净时长格式化：x小时y分（不足 1 小时退化为 y分钟 / z秒）。
  String _formatPlayedMs(int ms) {
    if (ms <= 0) return '0 分钟';
    final h = ms ~/ 3600000;
    final m = (ms % 3600000) ~/ 60000;
    if (h > 0) return '$h小时$m分';
    if (m > 0) return '$m分钟';
    return '${ms ~/ 1000} 秒';
  }
}

enum _CardTone { primary, secondary, tertiary, surface }
