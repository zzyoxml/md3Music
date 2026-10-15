import 'package:flutter/foundation.dart';

import '../data/repositories/settings_repository.dart';

/// 桌面快捷方式配置项（Android 长按应用图标弹出的快捷入口）。
///
/// [id] 对应主页 tab id（与 TabConfigProvider 一致，用于路由到对应功能页），
/// [label] 显示名称，[iconResource] 为 Android drawable 资源名
/// （QuickActions 的 ShortcutItem.icon 按资源名查找，如 ic_shortcut_favorite）。
class DesktopShortcutItem {
  final String id;
  final String label;
  final String iconResource;

  const DesktopShortcutItem({
    required this.id,
    required this.label,
    required this.iconResource,
  });
}

/// 候选桌面快捷方式：复用主页 Tab 功能页。
/// 排除 launchpad（导航中枢，非功能页）、user（个人中心）、
/// settings（配置页，已可从「我的」进入）。
/// 默认启用项（favorites/recognition/search）排在前面，保持旧行为。
const List<DesktopShortcutItem> kDesktopShortcutCandidates = [
  DesktopShortcutItem(
    id: 'favorites',
    label: '我的收藏',
    iconResource: 'ic_shortcut_favorite',
  ),
  DesktopShortcutItem(
    id: 'recognition',
    label: '听歌识曲',
    iconResource: 'ic_shortcut_mic',
  ),
  DesktopShortcutItem(
    id: 'search',
    label: '搜索',
    iconResource: 'ic_shortcut_search',
  ),
  DesktopShortcutItem(
    id: 'discover',
    label: '发现',
    iconResource: 'ic_shortcut_discover',
  ),
  DesktopShortcutItem(
    id: 'library',
    label: '本地音乐',
    iconResource: 'ic_shortcut_library',
  ),
  DesktopShortcutItem(
    id: 'fm',
    label: '私人FM',
    iconResource: 'ic_shortcut_fm',
  ),
  DesktopShortcutItem(
    id: 'coverflow',
    label: '封面流',
    iconResource: 'ic_shortcut_coverflow',
  ),
  DesktopShortcutItem(
    id: 'charts',
    label: '排行榜',
    iconResource: 'ic_shortcut_charts',
  ),
  DesktopShortcutItem(
    id: 'ip',
    label: '编辑精选',
    iconResource: 'ic_shortcut_ip',
  ),
  DesktopShortcutItem(
    id: 'audiobook',
    label: '听书',
    iconResource: 'ic_shortcut_audiobook',
  ),
  DesktopShortcutItem(
    id: 'scene',
    label: '场景音乐',
    iconResource: 'ic_shortcut_scene',
  ),
  DesktopShortcutItem(
    id: 'channel',
    label: '频道',
    iconResource: 'ic_shortcut_channel',
  ),
  DesktopShortcutItem(
    id: 'brush',
    label: '刷刷',
    iconResource: 'ic_shortcut_brush',
  ),
];

/// 默认启用的快捷方式 id（与旧版写死的 3 个一致）。
const Set<String> _kDefaultVisibleIds = {'favorites', 'recognition', 'search'};

/// 管理桌面快捷方式的显示/隐藏和排序。
///
/// 持久化到 SharedPreferences，通过 [SettingsRepository] 读写。
/// 每次变更后由 _AppView 重新调用 quickActions.setShortcutItems 生效。
class ShortcutConfigProvider extends ChangeNotifier {
  final SettingsRepository _repo = SettingsRepository();

  /// 所有候选的完整排序（含关闭项），用于设置页展示。
  List<DesktopShortcutItem> _allShortcuts = List.from(kDesktopShortcutCandidates);

  /// 关闭（隐藏）的快捷方式 id 集合。默认只启用 favorites/recognition/search。
  Set<String> _hiddenIds = _defaultHiddenIds();

  /// 当前生效（启用且有序）的快捷方式列表。
  List<DesktopShortcutItem> get visibleShortcuts =>
      _allShortcuts.where((s) => !_hiddenIds.contains(s.id)).toList();

  /// 所有候选（含关闭项）的完整排序。
  List<DesktopShortcutItem> get allShortcuts => _allShortcuts;

  /// 关闭的快捷方式 id 集合。
  Set<String> get hiddenIds => _hiddenIds;

  ShortcutConfigProvider() {
    _load();
  }

  static Set<String> _defaultHiddenIds() => {
        for (final s in kDesktopShortcutCandidates)
          if (!_kDefaultVisibleIds.contains(s.id)) s.id,
      };

  Future<void> _load() async {
    try {
      final order = await _repo.getDesktopShortcutOrder();
      final hidden = await _repo.getHiddenDesktopShortcuts();
      _hiddenIds = hidden;

      if (order != null && order.isNotEmpty) {
        // 按持久化顺序重排
        final ordered = <DesktopShortcutItem>[];
        for (final id in order) {
          final item =
              kDesktopShortcutCandidates.where((s) => s.id == id).firstOrNull;
          if (item != null) ordered.add(item);
        }
        // 补充新增候选（版本更新新增功能时默认隐藏，避免老用户桌面突然多出入口）
        for (final item in kDesktopShortcutCandidates) {
          if (!ordered.any((s) => s.id == item.id)) {
            ordered.add(item);
            _hiddenIds.add(item.id);
          }
        }
        _allShortcuts = ordered;
      } else {
        // 新用户：使用全部候选，默认只启用 3 个
        _allShortcuts = List.from(kDesktopShortcutCandidates);
        _hiddenIds = _defaultHiddenIds();
      }

      _ensureAtLeastOne();
      notifyListeners();
      // 持久化更新后的 hidden，确保新增候选的默认关闭状态被保存
      await _repo.setHiddenDesktopShortcuts(_hiddenIds);
    } catch (_) {}
  }

  /// 安全检查：至少保留一个启用项。
  void _ensureAtLeastOne() {
    if (_allShortcuts.isEmpty) return;
    if (visibleShortcuts.isEmpty) {
      _hiddenIds.remove(_allShortcuts.first.id);
    }
  }

  /// 切换某个快捷方式的显示/隐藏。
  Future<void> toggleShortcutVisibility(String id) async {
    if (!_allShortcuts.any((s) => s.id == id)) return;

    if (_hiddenIds.contains(id)) {
      _hiddenIds.remove(id);
      // 显示时同步持久化顺序：_load() 会把持久化 order 中缺失的候选
      // 当作"新增候选"重新加回隐藏列表，因此必须让 order 包含该 id，
      // 否则重启后开关状态被重置。
      await _repo.setDesktopShortcutOrder(_allShortcuts.map((s) => s.id).toList());
    } else {
      // 不允许关闭全部（至少保留一个启用）
      final visibleCount =
          _allShortcuts.where((s) => !_hiddenIds.contains(s.id)).length;
      if (visibleCount <= 1) return;
      _hiddenIds.add(id);
    }

    notifyListeners();
    await _repo.setHiddenDesktopShortcuts(_hiddenIds);
  }

  /// 拖拽排序：将 [oldIndex] 位置的快捷方式移动到 [newIndex]。
  Future<void> reorderShortcuts(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= _allShortcuts.length) return;
    if (newIndex < 0 || newIndex > _allShortcuts.length) return;

    final item = _allShortcuts.removeAt(oldIndex);
    // ReorderableListView 的 newIndex 在向下拖动时需要 -1
    final adjustedIndex = newIndex > oldIndex ? newIndex - 1 : newIndex;
    _allShortcuts.insert(adjustedIndex.clamp(0, _allShortcuts.length), item);

    notifyListeners();
    await _repo.setDesktopShortcutOrder(_allShortcuts.map((s) => s.id).toList());
  }

  /// 重置为默认配置。
  Future<void> resetToDefault() async {
    _allShortcuts = List.from(kDesktopShortcutCandidates);
    _hiddenIds = _defaultHiddenIds();
    notifyListeners();
    await _repo.setDesktopShortcutOrder(
      kDesktopShortcutCandidates.map((s) => s.id).toList(),
    );
    await _repo.setHiddenDesktopShortcuts(_hiddenIds);
  }
}
