import 'dart:convert';

import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/build_flags.dart';
import '../../core/layout/page_layout.dart';
import '../../core/remote/tv_card_focus.dart';
import '../../core/remote/tv_reorder.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/utils/app_toast.dart';

enum DiscoverSection { personalFm, daily, homeDiscover, newSongs, newAlbums }

double discoverSectionManagerSheetHeight(double viewportHeight) =>
    (viewportHeight * 0.85).clamp(0.0, 440.0).toDouble();

extension DiscoverSectionInfo on DiscoverSection {
  String get label => switch (this) {
        DiscoverSection.personalFm => '私人 FM',
        DiscoverSection.daily => '每日推荐',
        DiscoverSection.homeDiscover => '刷歌推荐',
        DiscoverSection.newSongs => '新歌速递',
        DiscoverSection.newAlbums => '新碟上架',
      };

  IconData get icon => switch (this) {
        DiscoverSection.personalFm => Icons.radio_outlined,
        DiscoverSection.daily => Icons.today_outlined,
        DiscoverSection.homeDiscover => Icons.refresh,
        DiscoverSection.newSongs => Icons.music_note_outlined,
        DiscoverSection.newAlbums => Icons.album_outlined,
      };
}

/// 与导航栏的 Tab 配置独立；一个快照保存顺序和开关，避免两份设置互相覆盖。
class DiscoverSectionConfig {
  const DiscoverSectionConfig({
    this.order = DiscoverSection.values,
    this.hidden = const {
      DiscoverSection.newSongs,
      DiscoverSection.newAlbums,
    },
  });

  // settings_ 前缀确保「还原所有设置」会清除布局，但不涉及账号数据。
  static const preferenceKey = 'settings_discover_sections';
  final List<DiscoverSection> order;
  final Set<DiscoverSection> hidden;

  List<DiscoverSection> get visible =>
      order.where((section) => !hidden.contains(section)).toList();

  static Future<DiscoverSectionConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(preferenceKey);
    if (saved == null) return const DiscoverSectionConfig();
    try {
      final data = jsonDecode(saved);
      if (data is! Map<String, dynamic>) return const DiscoverSectionConfig();
      final byId = {for (final section in DiscoverSection.values) section.name: section};
      final order = <DiscoverSection>[];
      for (final id in (data['order'] is List ? data['order'] as List : const [])) {
        final section = byId[id];
        if (section != null && !order.contains(section)) order.add(section);
      }
      // 去重、忽略旧 ID；将将来新增的区块补到末尾，不重置用户已有顺序。
      order.addAll(DiscoverSection.values.where((section) => !order.contains(section)));
      final hidden = <DiscoverSection>{
        for (final id in (data['hidden'] is List ? data['hidden'] as List : const []))
          if (byId[id] != null) byId[id]!,
      };
      return DiscoverSectionConfig(
        order: List.unmodifiable(order), hidden: Set.unmodifiable(hidden));
    } catch (_) {
      return const DiscoverSectionConfig();
    }
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = await prefs.setString(preferenceKey, jsonEncode({
      'order': order.map((section) => section.name).toList(),
      'hidden': hidden.map((section) => section.name).toList(),
    }));
    if (!saved) throw StateError('保存发现页布局失败');
  }

  DiscoverSectionConfig toggle(DiscoverSection section) {
    final next = {...hidden};
    if (!next.remove(section)) next.add(section);
    return DiscoverSectionConfig(order: order, hidden: Set.unmodifiable(next));
  }

  /// 与现成的 M3E / TV 排序组件使用相同下标语义，向下拖动时 newIndex 含 +1。
  DiscoverSectionConfig reorder(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= order.length || newIndex < 0 || newIndex > order.length) return this;
    final next = [...order];
    final section = next.removeAt(oldIndex);
    next.insert(newIndex > oldIndex ? newIndex - 1 : newIndex, section);
    return DiscoverSectionConfig(order: List.unmodifiable(next), hidden: hidden);
  }
}

/// 宽屏按可见顺序两两等宽排列；FM 始终占整行，排序不会改变其卡片比例。
/// 编辑按钮是最后一个普通 sliver，不吸底、不悬浮，滚动到底才可见。
class DiscoverSectionsSliver extends StatelessWidget {
  const DiscoverSectionsSliver({
    super.key, required this.config, required this.sectionBuilder,
    required this.onEdit, this.status,
  });

  final DiscoverSectionConfig config;
  final Widget Function(DiscoverSection) sectionBuilder;
  final VoidCallback onEdit;
  final Widget? status;

  @override
  Widget build(BuildContext context) => SliverLayoutBuilder(
        builder: (context, constraints) {
          // 每块至少 360dp，新碟才能保持两列四行；不能沿用导航栏的 600dp
          // 断点，否则缩放或双栏后每块仅 300dp，新碟会变成一列八行。
          // crossAxisExtent 已是缩放后的局部逻辑宽度，不再按整屏或物理像素判断。
          final canPair = constraints.crossAxisExtent >=
              (usesLargeScreenContentLayout(context) ? 720 : 600);
          final rows = <Widget>[];
          Widget? pending;
          void flush() {
            if (pending != null) rows.add(pending!);
            pending = null;
          }
          if (status != null && config.visible.isNotEmpty) {
            rows.add(SliverToBoxAdapter(child: status));
          } else {
            for (final section in config.visible) {
              final child = KeyedSubtree(
                key: ValueKey('discover-section-${section.name}'),
                child: sectionBuilder(section),
              );
              if (!canPair ||
                  section == DiscoverSection.personalFm) {
                flush();
                rows.add(child);
              } else if (pending == null) {
                pending = child;
              } else {
                rows.add(SliverCrossAxisGroup(slivers: [
                  SliverCrossAxisExpanded(flex: 1, sliver: pending!),
                  SliverCrossAxisExpanded(flex: 1, sliver: child),
                ]));
                pending = null;
              }
            }
            flush();
          }
          rows.add(SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 80),
              child: Center(
                child: TvCardFocus(
                  onSelect: onEdit, debugLabel: 'discover-edit',
                  child: M3ETextButton(
                    key: const ValueKey('discover-edit'), onPressed: onEdit,
                    child: const Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.edit_outlined), Gap(AppSpacing.sm), Text('编辑'),
                    ]),
                  ),
                ),
              ),
            ),
          ));
          return SliverMainAxisGroup(slivers: rows);
        },
      );
}

/// 沿用 LaunchPad 管理的 M3E 排序列表 + 开关 + 重置交互，不修改导航栏配置。
class DiscoverSectionManager extends StatefulWidget {
  const DiscoverSectionManager({super.key, required this.config, required this.onChanged});
  final DiscoverSectionConfig config;
  final ValueChanged<DiscoverSectionConfig> onChanged;

  @override
  State<DiscoverSectionManager> createState() => _DiscoverSectionManagerState();
}

class _DiscoverSectionManagerState extends State<DiscoverSectionManager> {
  late DiscoverSectionConfig _config = widget.config;
  late final TvReorderController _reorder = TvReorderController(
    itemCount: () => _config.order.length,
    onReorder: (from, to) => _apply(_config.reorder(from, to)),
    labelOf: (index) => _config.order[index].label,
    onToast: (message, {long = false}) => showToast(message, long: long),
  );

  void _apply(DiscoverSectionConfig next) {
    setState(() => _config = next);
    widget.onChanged(next);
  }

  @override
  void dispose() {
    _reorder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Row(children: [
          Expanded(child: Text('发现页管理', style: Theme.of(context).textTheme.titleMedium)),
          TvCardFocus(
            onSelect: () => _apply(const DiscoverSectionConfig()),
            debugLabel: 'discover-reset',
            child: M3ETextButton(onPressed: () => _apply(const DiscoverSectionConfig()), child: const Text('重置')),
          ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text('拖拽排序，开关控制发现页区块是否显示；私人 FM 始终占整行',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
      ),
      Expanded(child: M3EReorderableDismissibleList(
        listPadding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: _config.order.length,
        keyBuilder: (index) => ValueKey(_config.order[index].name),
        onReorder: (from, to) => _apply(_config.reorder(from, to)),
        style: M3EDismissibleCardStyle(
          outerRadius: 0, innerRadius: 0, gap: 0, padding: EdgeInsets.zero,
          color: Colors.transparent, direction: DismissDirection.none,
          focusRingColor: kTvBuild ? Colors.transparent : null,
        ),
        itemBuilder: (context, index) {
          final section = _config.order[index];
          final visible = !_config.hidden.contains(section);
          void toggle() => _apply(_config.toggle(section));
          final row = ListTile(
            key: ValueKey('discover-manager-${section.name}'),
            leading: Icon(section.icon, color: visible ? cs.primary : cs.onSurfaceVariant),
            title: Text(section.label),
            subtitle: Text(visible ? '显示在发现页' : '未显示'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              Switch(value: visible, onChanged: (_) => toggle()),
              Icon(Icons.drag_handle, size: 20, color: cs.onSurfaceVariant),
            ]),
          );
          return kTvBuild
              ? TvReorderItem(index: index, controller: _reorder, onSelect: toggle, child: row)
              : row;
        },
      )),
    ]);
  }
}
