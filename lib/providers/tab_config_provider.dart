import 'package:flutter/foundation.dart';

import '../data/repositories/settings_repository.dart';

/// 主页 Tab 配置项。
///
/// [id] 唯一标识，[label] 显示名称，[isRemovable] 是否允许隐藏。
/// "我的"页面（user）不允许隐藏，保证用户始终有入口进入设置/登录。
class TabItem {
  final String id;
  final String label;
  final bool isRemovable;

  const TabItem({
    required this.id,
    required this.label,
    this.isRemovable = true,
  });

  TabItem copyWith({String? id, String? label, bool? isRemovable}) {
    return TabItem(
      id: id ?? this.id,
      label: label ?? this.label,
      isRemovable: isRemovable ?? this.isRemovable,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is TabItem && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// 默认 Tab 定义（与 app.dart _MainLayout._pages 顺序对应）。
const List<TabItem> kDefaultTabs = [
  TabItem(id: 'discover', label: '发现'),
  TabItem(id: 'launchpad', label: 'LaunchPad'),
  TabItem(id: 'user', label: '我的', isRemovable: false),
];

/// 可选 Tab（默认隐藏，需在设置页手动开启）。
const List<TabItem> kOptionalTabs = [
  TabItem(id: 'favorites', label: '收藏'),
  TabItem(id: 'library', label: '本地音乐'), // 原默认（本地音乐），现改为可选
  TabItem(id: 'fm', label: '私人FM'), // 原默认（私人FM），现改为可选
  TabItem(id: 'coverflow', label: '封面流'),
  TabItem(id: 'search', label: '搜索'),
  TabItem(id: 'charts', label: '排行榜'),
  TabItem(id: 'ip', label: '编辑精选'),
  TabItem(id: 'recognition', label: '听歌识曲'),
  TabItem(id: 'audiobook', label: '听书'),
  TabItem(id: 'scene', label: '场景音乐'),
  TabItem(id: 'channel', label: '频道'),
  TabItem(id: 'brush', label: '刷刷'),
  TabItem(id: 'settings', label: '设置'),
];

/// 所有可用 Tab（默认显示 + 可选）。
final List<TabItem> kAllAvailableTabs = [...kDefaultTabs, ...kOptionalTabs];

/// 管理主页底部导航 Tab 的显示/隐藏和排序。
///
/// 持久化到 SharedPreferences，通过 [SettingsRepository] 读写。
class TabConfigProvider extends ChangeNotifier {
  final SettingsRepository _repo = SettingsRepository();

  /// 当前生效的 tab 列表（已排序、已过滤隐藏项）。
  List<TabItem> _visibleTabs = List.from(kDefaultTabs);

  /// 所有 tab 的完整排序（含隐藏项），用于设置页展示。
  List<TabItem> _allTabs = List.from(kAllAvailableTabs);

  /// 隐藏的 tab id 集合。可选 Tab 默认隐藏（本地音乐 library 默认显示）。
  Set<String> _hiddenTabs = {
    for (final t in kOptionalTabs)
      if (t.id != 'library') t.id,
  };

  List<TabItem> get visibleTabs => _visibleTabs;
  List<TabItem> get allTabs => _allTabs;
  Set<String> get hiddenTabs => _hiddenTabs;

  TabConfigProvider() {
    _load();
  }

  Future<void> _load() async {
    try {
      final order = await _repo.getTabOrder();
      final hidden = await _repo.getHiddenTabs();
      _hiddenTabs = hidden;

      if (order != null && order.isNotEmpty) {
        // 按持久化顺序重排
        final ordered = <TabItem>[];
        for (final id in order) {
          final tab = kAllAvailableTabs.where((t) => t.id == id).firstOrNull;
          if (tab != null) ordered.add(tab);
        }
        // 补充新增的 tab（版本更新可能新增 tab）。
        // 新增 tab 一律默认隐藏，避免老用户升级后突然多出 Tab；
        // 例外：launchpad 作为默认导航首页，升级后也保持默认显示。
        // 若用户此前主动打开过（toggleTabVisibility 会写 order 使其
        // 包含该 tab，从而不会走到这个分支），则保持可见。
        for (final tab in kAllAvailableTabs) {
          if (!ordered.any((t) => t.id == tab.id)) {
            ordered.add(tab);
            if (tab.id != 'launchpad') {
              _hiddenTabs.add(tab.id);
            }
          }
        }
        _allTabs = ordered;
      } else {
        // 新用户：使用全部可用 Tab，可选 Tab 默认隐藏（本地音乐默认显示）
        _allTabs = List.from(kAllAvailableTabs);
        for (final tab in kOptionalTabs) {
          if (tab.id != 'library') {
            _hiddenTabs.add(tab.id);
          }
        }
      }

      _rebuildVisible();
      notifyListeners();
      // 持久化更新后的 hidden，确保新 Tab 的默认隐藏状态被保存
      await _repo.setHiddenTabs(_hiddenTabs);
    } catch (_) {}
  }

  void _rebuildVisible() {
    _visibleTabs = _allTabs.where((t) => !_hiddenTabs.contains(t.id)).toList();
    // 安全检查：至少保留一个 tab
    if (_visibleTabs.isEmpty) {
      _visibleTabs = [_allTabs.last];
    }
  }

  /// 切换某个 tab 的显示/隐藏。
  /// [isRemovable] 为 false 的 tab 不允许隐藏。
  Future<void> toggleTabVisibility(String tabId) async {
    final tab = _allTabs.where((t) => t.id == tabId).firstOrNull;
    if (tab == null || !tab.isRemovable) return;

    if (_hiddenTabs.contains(tabId)) {
      _hiddenTabs.remove(tabId);
      // 显示 tab 时同步持久化顺序：_load() 会把持久化 order 中缺失的
      // tab 当作"新增 tab"重新加回隐藏列表，因此必须让 order 包含该 tab，
      // 否则重启后开关状态被重置（如新增的 audiobook tab）。
      await _repo.setTabOrder(_allTabs.map((t) => t.id).toList());
    } else {
      // 不允许隐藏所有可移除 tab（至少保留一个可见）
      final visibleCount =
          _allTabs.where((t) => !_hiddenTabs.contains(t.id)).length;
      if (visibleCount <= 1) return;
      _hiddenTabs.add(tabId);
    }

    _rebuildVisible();
    notifyListeners();
    await _repo.setHiddenTabs(_hiddenTabs);
  }

  /// 拖拽排序：将 [oldIndex] 位置的 tab 移动到 [newIndex]。
  Future<void> reorderTabs(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= _allTabs.length) return;
    if (newIndex < 0 || newIndex > _allTabs.length) return;

    final item = _allTabs.removeAt(oldIndex);
    // ReorderableListView 的 newIndex 在向下拖动时需要 -1
    final adjustedIndex = newIndex > oldIndex ? newIndex - 1 : newIndex;
    _allTabs.insert(adjustedIndex.clamp(0, _allTabs.length), item);

    _rebuildVisible();
    notifyListeners();
    await _repo.setTabOrder(_allTabs.map((t) => t.id).toList());
  }

  /// 重置为默认配置。
  Future<void> resetToDefault() async {
    _allTabs = List.from(kAllAvailableTabs);
    _hiddenTabs = {
      for (final t in kOptionalTabs)
        if (t.id != 'library') t.id,
    };
    _rebuildVisible();
    notifyListeners();
    await _repo.setTabOrder(kAllAvailableTabs.map((t) => t.id).toList());
    await _repo.setHiddenTabs(_hiddenTabs);
  }

  /// 根据 tab id 获取其在 visibleTabs 中的索引。
  int visibleIndexOf(String tabId) {
    return _visibleTabs.indexWhere((t) => t.id == tabId);
  }
}
