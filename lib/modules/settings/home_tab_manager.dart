import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/build_flags.dart';
import '../../core/remote/tv_reorder.dart';
import '../../core/utils/app_haptics.dart';
import '../../core/utils/app_toast.dart';
import '../../providers/tab_config_provider.dart';

/// 统一的主页 Tab 图标映射。
///
/// 设置页「主页管理」与 LaunchPad 编辑、LaunchPad 网格共用同一份映射，
/// 与 app.dart 各 tab 的图标保持一致，避免两处各维护一份而漂移。
IconData homeTabIcon(String tabId) {
  switch (tabId) {
    case 'launchpad':
      return Icons.grid_view;
    case 'discover':
      return Icons.explore;
    case 'coverflow':
      return Icons.album;
    case 'library':
      return Icons.library_music;
    case 'favorites':
      return Icons.favorite;
    case 'fm':
      return Icons.radio;
    case 'search':
      return Icons.search;
    case 'charts':
      return Icons.leaderboard;
    case 'ip':
      return Icons.edit_note;
    case 'recognition':
      return Icons.mic;
    case 'audiobook':
      return Icons.auto_stories;
    case 'scene':
      return Icons.landscape;
    case 'channel':
      return Icons.podcasts;
    case 'sheet':
      return Icons.queue_music;
    case 'brush':
      return Icons.swipe;
    case 'listen_together':
      return Icons.groups;
    case 'settings':
      return Icons.settings;
    case 'user':
      return Icons.person;
    default:
      return Icons.circle;
  }
}

/// 统一的主页 Tab 管理列表：拖拽排序 + 显示/隐藏（固定到底部导航栏）开关 + 重置。
///
/// 设置页「主页管理」与 LaunchPad 编辑托盘共用这同一套界面与配置逻辑，
/// 均直接读写 [TabConfigProvider.allTabs]（下标与列表 1:1，无过滤、无下标换算）。
/// 因两者都 `watch` 同一个 Provider，任一入口修改后另一入口立即刷新；
/// 拖拽排序、显示开关、「必显示」规则与重置行为完全一致。
class HomeTabManagerList extends StatefulWidget {
  /// 面板标题（设置页 / LaunchPad 各自的措辞）。
  final String title;

  /// 内嵌于已可滚动的父级（设置页 ListView 内）时为 true：
  /// 列表 shrinkWrap 且自身不滚动；LaunchPad 底部托盘为 false，列表 Expanded 自行滚动。
  final bool embedded;

  const HomeTabManagerList({
    super.key,
    this.title = '主页 Tab 管理',
    this.embedded = false,
  });

  @override
  State<HomeTabManagerList> createState() => _HomeTabManagerListState();
}

class _HomeTabManagerListState extends State<HomeTabManagerList> {
  /// tv: 遥控拖拽排序状态机（同播放队列口径）。非 TV 构建不接线。
  late final TvReorderController _reorder = TvReorderController(
    itemCount: () =>
        context.read<TabConfigProvider>().allTabs.length,
    onReorder: (oldIndex, newIndex) =>
        context.read<TabConfigProvider>().reorderTabs(oldIndex, newIndex),
    labelOf: (index) =>
        context.read<TabConfigProvider>().allTabs[index].label,
    onToast: (msg, {long = false}) => showToast(msg, long: long),
  );

  @override
  void dispose() {
    _reorder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final tabConfig = context.watch<TabConfigProvider>();
    final allTabs = tabConfig.allTabs;
    final hiddenTabs = tabConfig.hiddenTabs;

    final list = M3EReorderableDismissibleList(
      shrinkWrap: widget.embedded,
      physics: widget.embedded ? const NeverScrollableScrollPhysics() : null,
      listPadding: const EdgeInsets.symmetric(horizontal: 8),
      itemCount: allTabs.length,
      // key 由 M3E 内部套用（KeyedSubtree），保证重排后行状态稳定
      keyBuilder: (index) => ValueKey(allTabs[index].id),
      // 索引语义与 ReorderableListView 一致（M3E 内部已在 to > from 时补 +1），
      // 因此 provider 侧不需要任何换算
      onReorder: (oldIndex, newIndex) =>
          tabConfig.reorderTabs(oldIndex, newIndex),
      // 置零 M3E 卡片自身的背景/圆角/间距/内边距：行内是自带样式的 ListTile
      // 同时用 direction: none 关掉滑动（本列表只有显示/隐藏，没有删除）
      style: M3EDismissibleCardStyle(
        outerRadius: 0,
        innerRadius: 0,
        gap: 0,
        padding: EdgeInsets.zero,
        color: Colors.transparent,
        // tv: 同播放队列——TV 构建关掉 M3E 卡片自绘的焦点环，只留全局
        // TvFocusHighlight 一层（详见 player_playlist_view.dart 的说明）。
        focusRingColor: kTvBuild ? Colors.transparent : null,
        direction: DismissDirection.none,
      ),
      itemBuilder: (context, index) {
        final tab = allTabs[index];
        final isHidden = hiddenTabs.contains(tab.id);
        // search: -
        final row = ListTile(
          leading: Icon(
            homeTabIcon(tab.id),
            color: isHidden ? cs.onSurfaceVariant : cs.primary,
          ),
          title: Text(
            tab.label,
            style: TextStyle(color: isHidden ? cs.onSurfaceVariant : null),
          ),
          subtitle: !tab.isRemovable
              ? Text(
                  '必显示',
                  style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                )
              : Text(
                  isHidden ? '未显示' : '显示在底部导航栏',
                  style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (tab.isRemovable)
                Switch(
                  value: !isHidden,
                  onChanged: (_) {
                    AppHaptics.lightImpact(HapticCategory.control);
                    tabConfig.toggleTabVisibility(tab.id);
                  },
                ),
              Icon(Icons.drag_handle, size: 20, color: cs.onSurfaceVariant),
            ],
          ),
        );
        // tv: 整行单停点 + 排序方向键。OK = 切换显示开关（与触屏点 Switch 同效）；
        // 不可移除的行 onSelect 传 null（DpadFocusable 允许 onSelect 为空）。
        if (!kTvBuild) return row;
        return TvReorderItem(
          index: index,
          controller: _reorder,
          onSelect: tab.isRemovable
              ? () {
                  AppHaptics.lightImpact(HapticCategory.control);
                  tabConfig.toggleTabVisibility(tab.id);
                }
              : null,
          child: row,
        );
      },
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: [
              Expanded(child: Text(widget.title, style: tt.titleMedium)),
              TextButton(
                onPressed: () => tabConfig.resetToDefault(),
                child: const Text('重置'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '拖拽排序，开关控制是否显示在底部导航栏（“我的”不可隐藏）',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
        ),
        const SizedBox(height: 8),
        widget.embedded ? list : Expanded(child: list),
      ],
    );
  }
}
