/// 听歌 Wrapped 年度总结页。
///
/// 与听歌统计页（listen_stats_page.dart，滚动窗口聚合）不同，这里走
/// [ListenStatsDb] 的**自然年区间**聚合：进入页默认展示当年，当年无数据
/// 自动回落到最近有数据的一年；顶部胶囊可在有数据的年份间切换。
/// 整页为 7 张故事卡（PageView 翻页 + 底部 x/y 页码）：
/// 封面 → 年度艺人 → 年度歌曲 → 年度专辑 → 月度节奏 → 听歌习惯 → 结尾。
///
/// 依赖注入：[ListenWrappedPage.db] 可注入测试用库；缺省用进程内共享
/// 实例（只读查询、懒开库，与 LocalListenStatsProvider 同策略）。
/// 动画约定：卡片全部静态呈现（非跟手动画须限帧驱动，本页不做进度
/// 动画），翻页动画仅在用户按键时播放（320ms 一次性补间，无常驻 Ticker）。
///
/// TV 遥控 / 桌面键盘（阶段 F）：
/// - 故事区是**整页单停点**（照 artist_photo_banner 的全幅 PageView 先例，
///   用裸 [Focus] 接 onKeyEvent 而非 DpadFocusable：整卡缩放/辉光特效
///   没有意义，且 OK 语义要自定义成"下一页"）；左右键翻页、OK 下一页、
///   上下键放行给 dpad 光束遍历（上到年份胶囊、AppBar 返回）。
/// - 年份胶囊每个一颗 [DpadFocusable] 单停点（OK 即切年），横向带包
///   [TvScrollRegion]（memoryKey 记忆 + wrap 回绕，规则 §12.4-2/5）。
/// - 进入页面焦点落在故事区（一个 autofocus，规则 §12.4-1）。
library;

import 'dart:async';

import 'package:dpad/dpad.dart';
import 'package:flutter/services.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/build_flags.dart';
import '../../core/remote/tv_scroll_region.dart';
import '../../core/theme/app_dimens.dart';
import '../../data/db/listen_stats_db.dart';

/// Top 榜（艺人/歌曲/专辑）展示条数：前 5。
const int _topLimit = 5;

/// 故事卡总数（封面 → 艺人 → 歌曲 → 专辑 → 月度 → 习惯 → 结尾）。
const int _kStoryPageCount = 7;

/// 单年聚合快照（页面状态，不可变）。
class _YearData {
  const _YearData({
    required this.plays,
    required this.playedMs,
    required this.activeDays,
    required this.topArtists,
    required this.topTracks,
    required this.topAlbums,
    required this.monthlyCounts,
    required this.longestStreak,
    required this.rediscovery,
  });

  /// 播放次数（有效口径，下同）。
  final int plays;

  /// 净播放时长合计（毫秒）。
  final int playedMs;

  /// 活跃天数（有播放的自然日数）。
  final int activeDays;

  /// 艺人 Top（ListenStatsDb.topArtists 行：key/count/playedMs/isUnknown）。
  final List<Map<String, Object?>> topArtists;

  /// 歌曲 Top（行内 repArtist 为代表演唱者）。
  final List<Map<String, Object?>> topTracks;

  /// 专辑 Top（行内 repTitle 为代表曲目）。
  final List<Map<String, Object?>> topAlbums;

  /// 12 个月的播放次数（下标 0 = 1 月，无数据的月份为 0）。
  final List<int> monthlyCounts;

  /// 最长连续收听天数。
  final int longestStreak;

  /// 重逢老歌次数（同一曲时隔一周以上再听）。
  final int rediscovery;
}

/// Wrapped 年度总结页。
class ListenWrappedPage extends StatefulWidget {
  const ListenWrappedPage({super.key, ListenStatsDb? db}) : _dbOverride = db;

  /// 进程内共享的默认库（只读查询；懒开库，构造无 IO）。
  static final ListenStatsDb _defaultDb = ListenStatsDb();

  /// 测试注入的库；null 时用默认实例。
  final ListenStatsDb? _dbOverride;

  @override
  State<ListenWrappedPage> createState() => _ListenWrappedPageState();
}

class _ListenWrappedPageState extends State<ListenWrappedPage> {
  ListenStatsDb get _db => widget._dbOverride ?? ListenWrappedPage._defaultDb;

  final PageController _pageController = PageController();

  /// 首帧后触发加载（加载首个 setState 均在 await 之后，但与
  /// listen_stats_page 同用 postFrameCallback 模式，避免 build 期间 mark）。
  bool _loading = true;

  /// 有数据的年份（降序，来自全库按月聚合的 yyyyMM）。
  List<int> _years = const <int>[];

  /// 当前展示的年份；null 表示尚无数据。
  int? _selectedYear;

  _YearData? _data;

  int _pageIndex = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_load());
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  // ---- 数据加载 ----

  /// 首次加载：先查全库月份得出有数据的年份，再进入默认年份。
  Future<void> _load() async {
    try {
      final all = await _db.monthlyTrends();
      if (!mounted) return;
      final years = <int>{
        for (final m in all) m.month ~/ 100,
      }.toList()
        ..sort((a, b) => b.compareTo(a));
      if (years.isEmpty) {
        setState(() => _loading = false);
        return;
      }
      setState(() => _years = years);
      // 默认当年；当年无数据则回落到最近有数据的年份
      final current = DateTime.now().year;
      await _selectYear(years.contains(current) ? current : years.first);
    } catch (_) {
      // 年度总结属锦上添花：加载失败退回空态，不让页面挂着 loading
      if (mounted) {
        setState(() {
          _loading = false;
          _years = const <int>[];
          _data = null;
        });
      }
    }
  }

  /// 切换年份并聚合该年全部数据（选择器点击时先转 loading）。
  Future<void> _selectYear(int year) async {
    final startMs = DateTime(year).millisecondsSinceEpoch;
    final endMs = DateTime(year + 1).millisecondsSinceEpoch;
    final ov = await _db.overview(startMs: startMs, endMs: endMs);
    final artists =
        await _db.topArtists(startMs: startMs, endMs: endMs, limit: _topLimit);
    final tracks =
        await _db.topTracks(startMs: startMs, endMs: endMs, limit: _topLimit);
    final albums =
        await _db.topAlbums(startMs: startMs, endMs: endMs, limit: _topLimit);
    final monthly = await _db.monthlyTrends(startMs: startMs, endMs: endMs);
    final streak = await _db.longestStreak(startMs: startMs, endMs: endMs);
    final rediscovery =
        await _db.rediscovery(startMs: startMs, endMs: endMs);
    // 按月摊到 12 格（库只返回有数据的月份）
    final counts = List<int>.filled(12, 0);
    for (final m in monthly) {
      final idx = m.month % 100 - 1;
      if (idx >= 0 && idx < 12) counts[idx] = m.count;
    }
    if (!mounted) return;
    setState(() {
      _selectedYear = year;
      _data = _YearData(
        plays: ov.plays,
        playedMs: ov.playedMs,
        activeDays: ov.activeDays,
        topArtists: artists,
        topTracks: tracks,
        topAlbums: albums,
        monthlyCounts: counts,
        longestStreak: streak,
        rediscovery: rediscovery,
      );
      _loading = false;
      _pageIndex = 0;
    });
    // 换年回到封面页（无动画，PageView 未挂载时跳过）
    if (_pageController.hasClients) {
      _pageController.jumpToPage(0);
    }
  }

  /// 年份胶囊点击（Selector 回调里丢弃 Future，忽略未等待告警）。
  Future<void> _onYearTap(int year) async {
    if (year == _selectedYear || _loading) return;
    setState(() => _loading = true);
    try {
      await _selectYear(year);
    } catch (_) {
      // 切换失败退回空数据态，保持页面可用
      if (mounted) {
        setState(() {
          _loading = false;
          _data = null;
        });
      }
    }
  }

  // ---- TV 遥控 / 桌面键盘翻页（阶段 F） ----

  /// 故事区按键：左右键翻页、OK/Enter 下一页，其余放行（上下键交给
  /// dpad 光束遍历移出到年份胶囊 / AppBar）。
  ///
  /// 照 artist_photo_banner 的全幅 PageView 先例用裸 Focus 而非
  /// DpadFocusable：① 整页单停点套整卡缩放/辉光特效没有视觉意义；
  /// ② OK 语义要自定义（卡片纯展示，无可选对象）。不 skipTraversal：
  /// 本页故事区是胶囊带之下唯一的停点，上下光束不会误吸、必须可达，
  /// 与写真 banner"下方还有歌曲行会被大矩形吸焦"的场景不同。
  KeyEventResult _handleStoryKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight) {
      _flipStoryPage(key == LogicalKeyboardKey.arrowLeft ? -1 : 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter) {
      // OK：与触屏"点右半屏翻下一页"同义；末页时不动但消费按键，
      // 避免漏给根 Shortcuts 触发无关 ActivateIntent。
      _flipStoryPage(1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 翻一页（[delta] ±1）。边界夹取不回绕：故事线是线性叙事，
  /// 封面/结尾页到边即停（非轮播，不合 §12.4-5 的 wrap 口径）。
  /// 320ms 一次性补间与 artist_photo_banner.flipBy 同参。
  void _flipStoryPage(int delta) {
    if (!_pageController.hasClients) return;
    final current = _pageController.page?.round() ?? _pageIndex;
    final target = (current + delta).clamp(0, _kStoryPageCount - 1);
    if (target == current) return;
    _pageController.animateToPage(
      target,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  // ---- 页面骨架 ----

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('年度总结')),
      body: _loading
          ? const Center(child: M3ELoadingIndicator())
          : _years.isEmpty || _data == null
              ? _buildEmpty(context)
              : _buildContent(context, _data!),
    );
  }

  /// 全库无数据：整页空态。
  Widget _buildEmpty(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.music_off_outlined,
            size: 64,
            color: cs.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(
            '今年还没有播放记录',
            style: Theme.of(context)
                .textTheme
                .bodyLarge
                ?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          Text(
            '听一会儿歌，年底再来看你的年度总结吧',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                ),
          ),
        ],
      ),
    );
  }

  /// 故事卡流：年份选择胶囊 + PageView + 页码指示。
  Widget _buildContent(BuildContext context, _YearData data) {
    final pages = _buildPages(context, data);
    return Column(
      children: [
        _buildYearSelector(context),
        Expanded(
          // TV/桌面键盘：整页单停点 + autofocus（§12.4-1，主动作 = 故事区）。
          // 触屏构建下该 Focus 无视觉、不抢手势，无副作用。
          // 换年时 body 短暂换成 loading 再挂回：autofocus 让焦点确定性地
          // 回落故事区（此时旧停点已随子树销毁，不存在"抢焦点"）。
          child: Focus(
            autofocus: true,
            onKeyEvent: _handleStoryKey,
            child: PageView(
              controller: _pageController,
              onPageChanged: (i) => setState(() => _pageIndex = i),
              children: pages,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          child: Text(
            '${_pageIndex + 1} / ${pages.length}',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ),
      ],
    );
  }

  /// 有数据年份的切换胶囊（横向滚动；选中态即时换色，无隐式动画）。
  ///
  /// TV：横向带包 [TvScrollRegion]（memoryKey 记忆 + wrap 回绕），
  /// 每颗胶囊包 [DpadFocusable] 单停点（§12.4-3），OK 即切年；
  /// 触屏构建下两者都树摇剔除，与改造前完全一致。
  Widget _buildYearSelector(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final selector = SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.xs,
        ),
        children: [
          for (final year in _years)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
              child: _buildYearPill(context, year, cs),
            ),
        ],
      ),
    );
    return TvScrollRegion(memoryKey: 'wrapped/year-selector', child: selector);
  }

  /// 单颗年份胶囊。TV 构建下 DpadFocusable 默认 excludeChildFocus 剔除
  /// 内层 InkWell 的焦点节点，一张胶囊只有一个停点。
  Widget _buildYearPill(BuildContext context, int year, ColorScheme cs) {
    Widget pill = InkWell(
      borderRadius: BorderRadius.circular(AppRadius.full),
      onTap: () {
        // ignore: discarded_futures
        _onYearTap(year);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: year == _selectedYear ? cs.primary : cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(AppRadius.full),
        ),
        child: Text(
          '$year',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: year == _selectedYear ? cs.onPrimary : cs.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
        ),
      ),
    );
    if (kTvBuild) {
      pill = DpadFocusable(
        debugLabel: 'wrapped/year-$year',
        onSelect: () {
          // ignore: discarded_futures
          _onYearTap(year);
        },
        child: pill,
      );
    }
    return pill;
  }

  // ---- 7 张故事卡（顺序即叙事线） ----

  List<Widget> _buildPages(BuildContext context, _YearData data) {
    return [
      _coverCard(context, data),
      _artistsCard(context, data),
      _tracksCard(context, data),
      _albumsCard(context, data),
      _monthlyCard(context, data),
      _habitsCard(context, data),
      _endingCard(context, data),
    ];
  }

  /// 1. 封面卡：年份标题 + 总播放次数 + 净听时长。
  Widget _coverCard(BuildContext context, _YearData data) {
    final cs = Theme.of(context).colorScheme;
    return _pageShell(
      key: const ValueKey<String>('wrapped_page_cover'),
      background: cs.primaryContainer,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '我的 $_selectedYear 听歌年度总结',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: cs.onPrimaryContainer,
                ),
          ),
          const Gap(AppSpacing.lg),
          Text(
            '共播放 ${_formatCount(data.plays)} 次',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: cs.onPrimaryContainer,
                ),
          ),
          const Gap(AppSpacing.xs),
          Text(
            '净听 ${_formatListenMs(data.playedMs)}',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: cs.onPrimaryContainer,
                ),
          ),
        ],
      ),
    );
  }

  /// 2. 年度艺人卡：第一名大字 + 2~5 名列表。
  Widget _artistsCard(BuildContext context, _YearData data) {
    final cs = Theme.of(context).colorScheme;
    final artists = data.topArtists;
    final first = artists.isEmpty ? null : artists.first;
    return _pageShell(
      key: const ValueKey<String>('wrapped_page_artists'),
      background: cs.secondaryContainer,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardTitle(context, Icons.mic_none, '年度最爱艺人',
              cs.onSecondaryContainer),
          const Gap(AppSpacing.md),
          if (first != null) ...[
            Text(
              '#1',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: cs.onSecondaryContainer.withValues(alpha: 0.7),
                  ),
            ),
            Text(
              first['key']! as String,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: cs.onSecondaryContainer,
                  ),
            ),
            const Gap(AppSpacing.xs),
            Text(
              '${_formatCount(first['count']! as int)} 次',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: cs.onSecondaryContainer.withValues(alpha: 0.7),
                  ),
            ),
          ],
          const Gap(AppSpacing.lg),
          for (var i = 1; i < artists.length; i++)
            _rankRow(
              context,
              rank: i + 1,
              title: artists[i]['key']! as String,
              count: artists[i]['count']! as int,
              fg: cs.onSecondaryContainer,
              muted: cs.onSecondaryContainer.withValues(alpha: 0.7),
            ),
        ],
      ),
    );
  }

  /// 3. 年度歌曲卡：前 5，副行为代表演唱者。
  Widget _tracksCard(BuildContext context, _YearData data) {
    final cs = Theme.of(context).colorScheme;
    return _pageShell(
      key: const ValueKey<String>('wrapped_page_tracks'),
      background: cs.tertiaryContainer,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardTitle(
              context, Icons.queue_music, '年度最常播放', cs.onTertiaryContainer),
          const Gap(AppSpacing.md),
          for (var i = 0; i < data.topTracks.length; i++)
            _rankRow(
              context,
              rank: i + 1,
              title: data.topTracks[i]['key']! as String,
              subtitle: data.topTracks[i]['repArtist'] as String?,
              count: data.topTracks[i]['count']! as int,
              fg: cs.onTertiaryContainer,
              muted: cs.onTertiaryContainer.withValues(alpha: 0.7),
            ),
        ],
      ),
    );
  }

  /// 4. 年度专辑卡：前 5，副行为代表曲目。
  Widget _albumsCard(BuildContext context, _YearData data) {
    final cs = Theme.of(context).colorScheme;
    return _pageShell(
      key: const ValueKey<String>('wrapped_page_albums'),
      background: cs.surfaceContainerHigh,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardTitle(context, Icons.album_outlined, '年度专辑', cs.onSurface),
          const Gap(AppSpacing.md),
          for (var i = 0; i < data.topAlbums.length; i++)
            _rankRow(
              context,
              rank: i + 1,
              title: data.topAlbums[i]['key']! as String,
              subtitle: data.topAlbums[i]['repTitle'] as String?,
              count: data.topAlbums[i]['count']! as int,
              fg: cs.onSurface,
              muted: cs.onSurfaceVariant,
            ),
        ],
      ),
    );
  }

  /// 5. 月度趋势卡：12 个月播放次数自绘条形（静态，无数值动画）。
  Widget _monthlyCard(BuildContext context, _YearData data) {
    final cs = Theme.of(context).colorScheme;
    final counts = data.monthlyCounts;
    final maxCount = counts.fold<int>(0, (m, v) => v > m ? v : m);
    return _pageShell(
      key: const ValueKey<String>('wrapped_page_monthly'),
      background: cs.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardTitle(context, Icons.calendar_month, '月度节奏', cs.onSurface),
          const Gap(AppSpacing.md),
          Expanded(
            // 柱区必须吃到有界高度：Row(stretch) 包在 Expanded 里，
            // 柱体用 Align+FractionallySizedBox 自底向上按比例撑高
            // （同 listen_stats_page 柱状图的约束套路）。
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < 12; i++)
                  Expanded(
                    child: Column(
                      children: [
                        Text(
                          counts[i] > 0 ? '${counts[i]}' : '',
                          maxLines: 1,
                          overflow: TextOverflow.clip,
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(
                                color:
                                    cs.onSurfaceVariant.withValues(alpha: 0.6),
                              ),
                        ),
                        const Gap(AppSpacing.xxs),
                        Expanded(
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: FractionallySizedBox(
                              heightFactor: counts[i] <= 0 || maxCount <= 0
                                  ? 0.0
                                  : counts[i] / maxCount,
                              widthFactor: 0.6,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: counts[i] <= 0
                                      ? Colors.transparent
                                      : cs.primary,
                                  borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(4),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const Gap(AppSpacing.xxs),
                        Text(
                          '${i + 1}月',
                          maxLines: 1,
                          overflow: TextOverflow.clip,
                          style:
                              Theme.of(context).textTheme.labelSmall?.copyWith(
                                    fontSize: 9,
                                    color: cs.onSurfaceVariant
                                        .withValues(alpha: 0.6),
                                  ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const Gap(AppSpacing.xs),
          Text(
            '每月播放次数',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                ),
          ),
        ],
      ),
    );
  }

  /// 6. 听歌习惯卡：活跃天数 / 最长连续 / 重逢老歌。
  Widget _habitsCard(BuildContext context, _YearData data) {
    final cs = Theme.of(context).colorScheme;
    return _pageShell(
      key: const ValueKey<String>('wrapped_page_habits'),
      background: cs.surfaceContainerHigh,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardTitle(
              context, Icons.local_fire_department_outlined, '听歌习惯',
              cs.onSurface),
          const Gap(AppSpacing.lg),
          _habitStat(context, '${data.activeDays}', '天', '今年有播放记录的日子'),
          const Gap(AppSpacing.lg),
          _habitStat(context, '${data.longestStreak}', '天', '最长连续收听天数'),
          const Gap(AppSpacing.lg),
          _habitStat(context, '${data.rediscovery}', '次', '重逢老歌（时隔一周以上再听）'),
        ],
      ),
    );
  }

  /// 7. 结尾卡：按数据生成的一句总结。
  Widget _endingCard(BuildContext context, _YearData data) {
    final cs = Theme.of(context).colorScheme;
    return _pageShell(
      key: const ValueKey<String>('wrapped_page_ending'),
      background: cs.primaryContainer,
      child: Center(
        child: Text(
          _buildSummary(data),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
                color: cs.onPrimaryContainer,
                height: 1.6,
              ),
        ),
      ),
    );
  }

  /// 结尾文案：第一名艺人是"未知艺人"归桶时退化为天数叙事。
  String _buildSummary(_YearData data) {
    final first =
        data.topArtists.isEmpty ? null : data.topArtists.first;
    final unknown = (first?['isUnknown'] as bool?) ?? false;
    final artist = first?['key'] as String?;
    final hook = (artist == null || artist.isEmpty || unknown)
        ? '你用音乐标记了 ${data.activeDays} 个日子'
        : '你把最多的时间给了「$artist」';
    return '$_selectedYear 年，$hook。\n'
        '共收听 ${_formatCount(data.plays)} 次 · 净听 ${_formatListenMs(data.playedMs)}。\n'
        '新的一年，继续与音乐同行。';
  }

  // ---- 通用部件与格式化 ----

  /// 故事卡外壳：整页内边距 + 大圆角容器（surface 系色调补浅描边）。
  Widget _pageShell({
    Key? key,
    required Color background,
    required Widget child,
  }) {
    final cs = Theme.of(context).colorScheme;
    final needsBorder = background == cs.surfaceContainerLow ||
        background == cs.surfaceContainerHigh;
    return Container(
      key: key,
      margin: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: needsBorder
            ? Border.all(color: cs.outlineVariant.withValues(alpha: 0.4))
            : null,
      ),
      child: child,
    );
  }

  /// 卡片标题行（图标 + 文字）。
  Widget _cardTitle(BuildContext context, IconData icon, String text,
      Color fg) {
    return Row(
      children: [
        Icon(icon, size: 16, color: fg.withValues(alpha: 0.7)),
        const Gap(AppSpacing.xs),
        Text(
          text,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: fg,
              ),
        ),
      ],
    );
  }

  /// Top 榜行：名次 + 标题（可带副行）+ 次数。
  Widget _rankRow(
    BuildContext context, {
    required int rank,
    required String title,
    String? subtitle,
    required int count,
    required Color fg,
    required Color muted,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        children: [
          SizedBox(
            width: 24,
            child: Text(
              '$rank',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: muted,
                  ),
            ),
          ),
          const Gap(AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: fg,
                      ),
                ),
                if (subtitle != null && subtitle.isNotEmpty)
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: muted,
                        ),
                  ),
              ],
            ),
          ),
          const Gap(AppSpacing.sm),
          Text(
            '${_formatCount(count)}次',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: muted,
                ),
          ),
        ],
      ),
    );
  }

  /// 习惯卡单条数值行（大数字 + 单位 + 说明）。
  Widget _habitStat(
      BuildContext context, String value, String unit, String label) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          value,
          style: Theme.of(context).textTheme.displaySmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: cs.onSurface,
              ),
        ),
        const Gap(AppSpacing.xs),
        Text(
          unit,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: cs.onSurfaceVariant,
              ),
        ),
        const Gap(AppSpacing.md),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
          ),
        ),
      ],
    );
  }

  /// 次数格式化：≥1亿 → "x.x亿"，≥1万 → "x.x万"，其余原值
  /// （与 mv_models / sounds_page 的友好显示口径一致）。
  static String _formatCount(int n) {
    if (n >= 100000000) {
      return '${(n / 100000000).toStringAsFixed(1)}亿';
    }
    if (n >= 10000) {
      return '${(n / 10000).toStringAsFixed(1)}万';
    }
    return '$n';
  }

  /// 净听时长：毫秒 → "x小时y分"；不足 1 小时只显示分钟。
  static String _formatListenMs(int ms) {
    final totalMin = ms ~/ 60000;
    final h = totalMin ~/ 60;
    final m = totalMin % 60;
    if (h > 0) return '$h小时$m分';
    return '$m分钟';
  }
}
