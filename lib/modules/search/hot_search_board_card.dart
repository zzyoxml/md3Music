import 'package:flutter/material.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../core/remote/tv_card_focus.dart';
import '../../core/remote/tv_scroll_region.dart';
import '../../core/theme/app_dimens.dart';
import '../../providers/kugou_provider.dart';
import '../../services/kugou_api/kugou_models.dart';
import 'search_section_header.dart';

/// 榜单词行与榜名 chip 的统一行高:两列排布下保证左右列、词行与 chip 节奏一致。
const double _hotRowExtent = 36;

/// 搜索页空状态的「热门搜索」榜单卡。
///
/// 数据来自本地 Rust 服务的 `/search/hot`（上游 `hot_tab`）：9 个榜单 × 每榜 30 词。
/// 上游**不提供热度值**，故排名用序号体现（前三位强调色）。
/// 加载/失败状态收敛在 [KugouProvider.hotSearchState] 这一个 ValueNotifier 上，
/// 卡片只订阅自己那一份，不触发整页重建。
class HotSearchBoardCard extends StatefulWidget {
  const HotSearchBoardCard({super.key, required this.onKeywordTap});

  /// 点击某个热搜词。
  final ValueChanged<String> onKeywordTap;

  /// 每页词数与每榜页数（上游每榜固定 30 条）。
  static const int pageSize = 10;

  @override
  State<HotSearchBoardCard> createState() => _HotSearchBoardCardState();
}

class _HotSearchBoardCardState extends State<HotSearchBoardCard> {
  /// 单列词数:pageSize 拆成两列(左列前半、右列后半)。
  static const int _wordsPerColumn = HotSearchBoardCard.pageSize ~/ 2;

  int _boardIndex = 0;
  int _page = 0;

  /// 把当前榜序号夹紧到有效范围：刷新后榜单数量可能变少。
  int _clampBoard(int count) =>
      count == 0 ? 0 : (_boardIndex.clamp(0, count - 1));

  @override
  Widget build(BuildContext context) {
    final provider = context.read<KugouProvider>();
    return ValueListenableBuilder<HotSearchState>(
      valueListenable: provider.hotSearchState,
      builder: (context, state, _) {
        if (state.status == HotSearchStatus.loading) {
          return _Shell(
            title: '热门搜索',
            child: SizedBox(
              height: 96,
              child: Center(
                  child: M3ELoadingIndicator(
                      color: Theme.of(context).colorScheme.primary)),
            ),
          );
        }
        if (state.status == HotSearchStatus.failed) {
          return _Shell(
            title: '热门搜索',
            // tv: 与「清空」「探索入口」同规格的动作单停点。
            trailing: TvCardFocus(
              onSelect: () => provider.loadHotSearch(forceRefresh: true),
              debugLabel: 'hot-retry',
              child: SearchSectionAction(
                label: '重试',
                onTap: () => provider.loadHotSearch(forceRefresh: true),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
              child: Text(
                state.error ?? '加载失败，请稍后重试',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
          );
        }
        if (state.boards.isEmpty) return const SizedBox.shrink();

        final boardIndex = _clampBoard(state.boards.length);
        final board = state.boards[boardIndex];
        final pages =
            (board.keywords.length / HotSearchBoardCard.pageSize).ceil();
        final page = pages == 0 ? 0 : _page % pages;
        final start = page * HotSearchBoardCard.pageSize;
        final visible = board.keywords
            .skip(start)
            .take(HotSearchBoardCard.pageSize)
            .toList();

        return _Shell(
          title: '热门搜索',
          trailing: pages > 1
              ? TvCardFocus(
                  onSelect: () => setState(() => _page = page + 1),
                  debugLabel: 'hot-next-page',
                  child: SearchSectionAction(
                    label: '换一批',
                    onTap: () => setState(() => _page = page + 1),
                  ),
                )
              : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _BoardChips(
                boards: state.boards,
                selected: boardIndex,
                onSelect: (i) => setState(() {
                  _boardIndex = i;
                  _page = 0;
                }),
              ),
              const Gap(AppSpacing.sm),
              // 两列 2×5:左列第 1-5 名、右列第 6-10 名,列距 md。
              // 相比单列 10 行,卡高约从 460dp 压到 260dp;
              // 每页词数(pageSize)与「换一批」分页行为保持不变。
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      children: [
                        for (var i = 0; i < _wordsPerColumn; i++)
                          if (i < visible.length)
                            _WordRow(
                              rank: start + i + 1,
                              keyword: visible[i],
                              onTap: () => widget.onKeywordTap(visible[i]),
                            ),
                      ],
                    ),
                  ),
                  const Gap(AppSpacing.md),
                  Expanded(
                    child: Column(
                      children: [
                        for (var i = _wordsPerColumn;
                            i < HotSearchBoardCard.pageSize;
                            i++)
                          if (i < visible.length)
                            _WordRow(
                              rank: start + i + 1,
                              keyword: visible[i],
                              onTap: () => widget.onKeywordTap(visible[i]),
                            ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 卡壳：标题行 + 可选右侧动作 + 内容。
///
/// 改版去壳裸排：与搜索历史 / 探索段同构(统一 [SearchSectionHeader] +
/// lg 水平基准)，不再用 surfaceContainerLow 圆角卡单独成盒。
/// 树上仍必须有 Material 祖先(内部 InkWell 依赖)，包一层透明 Material：
/// 搜索页把本卡挂在没有 Material 祖先的树上时会抛
/// 「No Material widget found」并被全局 _FallbackErrorWidget 顶成
/// 「此处内容加载出错」（2026-10-04 真机堆栈）。
class _Shell extends StatelessWidget {
  const _Shell({required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SearchSectionHeader(
          title: title,
          // null-aware:trailing 为空时动作区不产生任何元素。
          actions: [?trailing],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.md),
          child: Material(
            color: Colors.transparent,
            child: child,
          ),
        ),
      ],
    );
  }
}

/// 榜名横向 chip 行。选中态用 primaryContainer，未选中用 surfaceContainerHigh。
class _BoardChips extends StatelessWidget {
  const _BoardChips({
    required this.boards,
    required this.selected,
    required this.onSelect,
  });

  final List<HotSearchBoard> boards;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return SizedBox(
      height: _hotRowExtent,
      child: TvScrollRegion(
        memoryKey: 'tv/hot-boards',
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: boards.length,
          separatorBuilder: (_, _) => const Gap(AppSpacing.sm),
          itemBuilder: (context, i) {
            final active = i == selected;
            final chip = Material(
              color: active ? cs.primaryContainer : cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(AppRadius.full),
              child: InkWell(
                borderRadius: BorderRadius.circular(AppRadius.full),
                onTap: () => onSelect(i),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                  child: Align(
                    child: Text(
                      boards[i].name,
                      // 未选中态弱化用 onSurfaceVariant 颜色表达,不改字重。
                      style: tt.labelLarge?.copyWith(
                        color:
                            active ? cs.onPrimaryContainer : cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
            );
            // tv: 榜单切换 chip 单停点（OK = 切到该榜单）。
            return TvCardFocus(
              onSelect: () => onSelect(i),
              debugLabel: 'hot-board-chip',
              child: chip,
            );
          },
        ),
      ),
    );
  }
}

/// 一行热搜词：序号（前三位强调色）+ 词，整行可点。
class _WordRow extends StatelessWidget {
  const _WordRow({
    required this.rank,
    required this.keyword,
    required this.onTap,
  });

  final int rank;
  final String keyword;
  final VoidCallback onTap;

  /// 序号列宽:留足两位数序号的呼吸,不与词文贴死。
  static const double _rankWidth = 32;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final isTop3 = rank <= 3;
    final row = InkWell(
      onTap: onTap,
      borderRadius: AppRadius.mdAll,
      // 行高固定,两列排布下左右列行节奏严格对齐。
      child: SizedBox(
        height: _hotRowExtent,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
          child: Row(
            children: [
              SizedBox(
                width: _rankWidth,
                child: Text(
                  '$rank',
                  style: tt.labelLarge?.copyWith(
                    // 前三位用 primary 强调,字重交给主题原生样式。
                    color: isTop3 ? cs.primary : cs.onSurfaceVariant,
                  ),
                ),
              ),
              const Gap(AppSpacing.sm),
              Expanded(
                child: Text(
                  keyword,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tt.bodyMedium?.copyWith(color: cs.onSurface),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // tv: 热搜词行单停点（OK = 搜索该词）。
    return TvCardFocus(
      onSelect: onTap,
      debugLabel: 'hot-word-row',
      child: row,
    );
  }
}
