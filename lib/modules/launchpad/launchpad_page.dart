import 'dart:async';

import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/layout/page_layout.dart';
import '../../core/layout/responsive_layout.dart' show gridColumnsForWidth;
import '../../core/theme/app_dimens.dart';
import '../../providers/tab_config_provider.dart';
import '../../widgets/scroll_aware_app_bar.dart';
import '../settings/home_tab_manager.dart';
import '_launchpad_card.dart';

/// LaunchPad 导航页：以"导航网站"的形式列出所有可用 Tab（除"我的"和自身），
/// 按「未固定 / 已固定」两个分区展示（固定 = 出现在底部导航栏，置底显示）。
///
/// 交互规则：
/// - 点击可见 tab：直接切换主 tab；
/// - 点击隐藏 tab：以二级页面路由打开对应功能页；
/// - **长按任意 tab**：按下即播封面流同款扭曲波——先一切向图标收拢一下，
///   波前再从图标边缘向外扩散（同封面流点击封面的那一道波，只取长按处一圈
///   小范围，不做整屏过场）；按下 2 秒（系统长按识别 + 1.5s）动作自动执行：
///   隐藏 tab → 启用并切换；已固定 tab → 取消固定。提前松手波回缩、动作不触发。
/// 点击/长按/滑动由 GestureDetector 手势竞技场裁决，滚动时不会误触。
class LaunchPadPage extends StatefulWidget {
  final ValueChanged<String> onTabSelected;
  final ValueChanged<String> onTabEnabled;
  final ValueChanged<String> onTabUnpinned;
  final ValueChanged<String> onTabOpened;

  const LaunchPadPage({
    super.key,
    required this.onTabSelected,
    required this.onTabEnabled,
    required this.onTabUnpinned,
    required this.onTabOpened,
  });

  @override
  State<LaunchPadPage> createState() => _LaunchPadPageState();
}

class _LaunchPadPageState extends State<LaunchPadPage> {
  String? _pressingTabId;
  Timer? _pressTimer;

  /// 长按动作延迟：波整段 2s = 系统长按识别（约 500ms）+ 本定时器（1500ms），
  /// 卡片动画按同一条时间轴起演，动作正好卡在波走完那一刻落地。
  static const Duration _pressDuration = Duration(milliseconds: 1500);

  @override
  void dispose() {
    _pressTimer?.cancel();
    super.dispose();
  }

  void _onLongPressStart(String tabId, bool hidden) {
    _pressTimer?.cancel();
    setState(() => _pressingTabId = tabId);
    _pressTimer = Timer(_pressDuration, () {
      if (!mounted || _pressingTabId != tabId) return;
      _pressTimer = null;
      setState(() => _pressingTabId = null);
      if (hidden) {
        widget.onTabEnabled(tabId);
      } else {
        widget.onTabUnpinned(tabId);
      }
    });
  }

  void _onLongPressEnd(String tabId) {
    _pressTimer?.cancel();
    _pressTimer = null;
    if (_pressingTabId == tabId) {
      setState(() => _pressingTabId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tabConfig = context.watch<TabConfigProvider>();
    final tabs = tabConfig.allTabs
        .where((t) => t.id != 'user' && t.id != 'launchpad')
        .toList();
    final pinned =
        tabs.where((t) => !tabConfig.hiddenTabs.contains(t.id)).toList();
    final unpinned =
        tabs.where((t) => tabConfig.hiddenTabs.contains(t.id)).toList();

    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final minColumns = isLandscape ? 4 : 3;
    final windowWidth = MediaQuery.sizeOf(context).width;
    final sideGutter =
        (windowWidth - ContentWidth.resolveWidth(context, windowWidth)) / 2;

    return Scaffold(
      appBar: ScrollAwareAppBar(
        title: 'LaunchPad',
        tabId: 'launchpad',
        opaque: true,
        titleSpacing: sideGutter + AppSpacing.lg,
        actions: [
          Padding(
            padding: EdgeInsets.only(right: sideGutter),
            child: IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: '编辑固定项',
              onPressed: _showEditSheet,
            ),
          ),
        ],
      ),
      body: ContentWidth(
        child: CustomScrollView(
          slivers: [
            if (unpinned.isNotEmpty) ...[
              _buildSectionHeader('未固定', unpinned.length, first: true),
              _buildGrid(tabConfig, unpinned, minColumns),
            ],
            if (pinned.isNotEmpty) ...[
              _buildSectionHeader('已固定', pinned.length, first: unpinned.isEmpty),
              _buildGrid(tabConfig, pinned, minColumns),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 88)),
          ],
        ),
      ),
    );
  }

  void _showEditSheet() {
    showM3EModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => const _LaunchPadEditPanel(),
    );
  }

  Widget _buildSectionHeader(String title, int count, {bool first = false}) {
    final cs = Theme.of(context).colorScheme;
    return SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.lg,
          first ? AppSpacing.sm : AppSpacing.xl,
          AppSpacing.lg,
          AppSpacing.md,
        ),
        child: Row(
          children: [
            Text(title,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                      color: cs.onSurface,
                    )),
            const Gap(AppSpacing.sm),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xxs),
              decoration: ShapeDecoration(
                color: cs.surfaceContainerHighest,
                shape: const StadiumBorder(),
              ),
              child: Text('$count',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: cs.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      )),
            ),
            const Gap(AppSpacing.md),
            Expanded(
              child: Divider(color: cs.outlineVariant.withValues(alpha: 0.6), height: 1),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGrid(TabConfigProvider tabConfig, List<TabItem> items, int minColumns) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) {
          // 列数仍按宽度自适应（不动壁纸模式的布局口径）；只把格子改成
          // 正方形（宽=高），外观回到一周前大色块那种高度，间距 12。
          final columns = gridColumnsForWidth(constraints.crossAxisExtent,
              targetExtent: 148, min: minColumns, max: 7);
          return SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 1.0,
            ),
            delegate: SliverChildBuilderDelegate((context, i) {
              final tab = items[i];
              final hidden = tabConfig.hiddenTabs.contains(tab.id);
              return LaunchPadCard(
            icon: homeTabIcon(tab.id),
            label: tab.label,
            hidden: hidden,
            onTap: hidden
                ? () => widget.onTabOpened(tab.id)
                : () => widget.onTabSelected(tab.id),
            onLongPressStart: () => _onLongPressStart(tab.id, hidden),
            onLongPressEnd: () => _onLongPressEnd(tab.id),
          );
        }, childCount: items.length),
      );
    },
      ),
  );
  }
}

class _LaunchPadEditPanel extends StatelessWidget {
  const _LaunchPadEditPanel();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.85,
        child: const HomeTabManagerList(title: 'LaunchPad 管理', embedded: false),
      ),
    );
  }
}