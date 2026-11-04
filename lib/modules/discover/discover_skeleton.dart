import 'package:material_ui/material_ui.dart';

import '../../core/theme/app_dimens.dart';
import '../../widgets/app_animation.dart';

/// 发现页冷启动骨架积木：几何尺寸对齐真实内容，替换时布局抖动最小。
///
/// - [DiscoverSongRowsSkeleton] 对齐 [SongListItem]（封面 52、内边距 h10/v6、
///   图文间距 12、标题 + 副标题两行），行高 ≈ 52 + 6*2 = 64。
/// - [DiscoverAlbumGridSkeleton] 对齐 [CompactAlbumGrid] 的
///   「方块封面 + 两行标题」单元格与 16dp 页边距、格间 12dp 缝。
///
/// 骨架只放占位块，不放按钮 / TvCardFocus：冷启动期间无可聚焦对象，
/// TV 焦点链路不受影响（真实内容到达淡入后焦点自然落在新版式上）。
///
/// 文字条：标题撑满行宽、副标题给固定宽度（比标题短一截）——骨架行高由
/// 52dp 封面唯一决定，文字条宽度只影响观感不影响布局。

/// 区块「骨架 → 真实内容」的淡入替换容器（发现页冷启动用）。
///
/// [loading] 为 true 且 [skeleton] 给了占位时，渲染「真实标题 + 骨架内容」；
/// 翻回 false 后整块 320ms 淡入换成 [content]。
///
/// 骨架版**只带标题、不带调用方内容里的 trailing「›」等 GlobalKey 节点**：
/// AnimatedSwitcher 交叉淡入期间新旧两棵子树同时挂载，若两边都持有同一个
/// GlobalKey 会当场撞 key（重复 GlobalKey 直接抛异常）。标题文本走参数，
/// 因为它不依赖网络、冷启动就能定稿。
class DiscoverSectionFadeSwap extends StatelessWidget {
  const DiscoverSectionFadeSwap({
    super.key,
    required this.title,
    required this.loading,
    required this.skeleton,
    required this.content,
  });

  final String title;
  final bool loading;
  final Widget skeleton;
  final Widget content;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 320),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      // 交叉淡入期间新旧两棵树同时在布局里，默认 layoutBuilder 居中堆叠
      // 会让区块在淡入过程中上下跳；钉住顶边才只有透明度在动。
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: AlignmentDirectional.topStart,
        children: [...previousChildren, ?currentChild],
      ),
      child: loading
          ? KeyedSubtree(
              key: ValueKey('discover-skeleton-$title'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 与 _SectionBlock 的标题行同规格：同 padding、同字号，且
                  // 用 48dp 空位顶住 trailing「›」（真实内容里是 IconButton）
                  // ——否则骨架标题行比内容矮一截，淡入时整块上下跳。
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.sm,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                vertical: AppSpacing.xs),
                            child: Text(
                              title,
                              style: tt.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        const SizedBox(width: 48, height: 48),
                      ],
                    ),
                  ),
                  skeleton,
                ],
              ),
            )
          : KeyedSubtree(key: ValueKey('discover-content-$title'), child: content),
    );
  }
}

/// 竖排 N 行「歌曲行」骨架（每日推荐 / 刷歌推荐 / 新歌速递区块用）。
class DiscoverSongRowsSkeleton extends StatelessWidget {
  const DiscoverSongRowsSkeleton({super.key, this.rows = 4});

  final int rows;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Column(
        children: [
          for (var i = 0; i < rows; i++)
            // 与内容版一致地给每行稳定 key（AnimatedSwitcher 交叉淡入期间
            // 新旧两棵树会同时挂载）。
            KeyedSubtree(
              key: ValueKey('discover-skeleton-row-$i'),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 6),
                child: Row(
                  children: [
                    const ShimmerLoading(
                        width: 52, height: 52, radius: 8, diagonal: true),
                    const Gap(AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: const [
                          ShimmerLoading(
                              width: double.infinity, height: 14, radius: 6,
                              diagonal: true),
                          Gap(4),
                          ShimmerLoading(
                              width: 150, height: 12, radius: 6,
                              diagonal: true),
                        ],
                      ),
                    ),
                    const Gap(AppSpacing.md),
                    const ShimmerLoading(
                        width: 24, height: 24, radius: 12, diagonal: true),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 2 列「专辑格」骨架（新碟上架区块用）。
class DiscoverAlbumGridSkeleton extends StatelessWidget {
  const DiscoverAlbumGridSkeleton({super.key, this.cells = 4});

  final int cells;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < cells; i += 2) {
      rows.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.sm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _cell(i)),
              const Gap(AppSpacing.md),
              Expanded(child: i + 1 < cells ? _cell(i + 1) : const SizedBox.shrink()),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }

  Widget _cell(int index) {
    return KeyedSubtree(
      key: ValueKey('discover-skeleton-album-$index'),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xs),
        child: Row(
          children: [
            const ShimmerLoading(
                width: 52, height: 52, radius: 8, diagonal: true),
            const Gap(10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  ShimmerLoading(
                      width: double.infinity, height: 13, radius: 6,
                      diagonal: true),
                  Gap(4),
                  ShimmerLoading(
                      width: 110, height: 13, radius: 6, diagonal: true),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
