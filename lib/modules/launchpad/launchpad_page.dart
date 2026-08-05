import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/tab_config_provider.dart';

/// LaunchPad 导航页：以"导航网站"的形式列出所有可用 Tab（除"我的"和自身）。
///
/// 交互规则：
/// - 点击可见 tab：直接切换主 tab；
/// - 点击隐藏 tab：**不启用**，以二级页面路由打开对应功能页；
/// - 长按隐藏 tab：系统长按（500ms）触发时提示层淡入，持续按住满 2 秒
///   启用并切换主 tab（交互参考 Zen 模式长按退出，松开即取消）。
/// 点击/长按/滑动由 GestureDetector 手势竞技场裁决，滚动时不会误触。
class LaunchPadPage extends StatefulWidget {
  /// 点击可见 tab 时回调其 id（_MainLayout 负责切换主 tab）。
  final ValueChanged<String> onTabSelected;

  /// 长按隐藏 tab 完成时回调其 id（_MainLayout 负责启用并切换主 tab）。
  final ValueChanged<String> onTabEnabled;

  /// 点击隐藏 tab 时回调其 id（_MainLayout 负责以二级页面路由打开）。
  final ValueChanged<String> onTabOpened;

  const LaunchPadPage({
    super.key,
    required this.onTabSelected,
    required this.onTabEnabled,
    required this.onTabOpened,
  });

  @override
  State<LaunchPadPage> createState() => _LaunchPadPageState();
}

class _LaunchPadPageState extends State<LaunchPadPage> {
  /// 长按启用总时长（与 Zen 模式长按退出保持一致）。
  static const Duration _enableDuration = Duration(milliseconds: 2000);
  /// 系统长按识别耗时（GestureDetector onLongPressStart 触发点），
  /// 与"0.5s 后淡入提示"一致；剩余 [_enableDuration] 减去该时长。
  static const Duration _longPressDelay = Duration(milliseconds: 500);
  /// 提示层淡入动画时长。
  static const Duration _hintFade = Duration(milliseconds: 200);

  /// 正在长按启用的 tab id；null 表示无长按进行中。
  String? _enablingTabId;
  /// 长按已识别（提示层淡入中/已显示）。
  bool _showHint = false;
  /// 长按识别后到启用前的剩余计时。
  Timer? _enableTimer;

  @override
  void dispose() {
    _enableTimer?.cancel();
    super.dispose();
  }

  /// 长按被系统识别（按住满 500ms 且无滑动）：淡入提示并计时启用。
  void _onLongPressStart(String tabId) {
    _enableTimer?.cancel();
    setState(() {
      _enablingTabId = tabId;
      _showHint = true;
    });
    _enableTimer = Timer(_enableDuration - _longPressDelay, () {
      if (!mounted || _enablingTabId != tabId) return;
      _enableTimer = null;
      setState(() {
        _enablingTabId = null;
        _showHint = false;
      });
      widget.onTabEnabled(tabId);
    });
  }

  /// 长按结束（松开/手势被取消）：取消剩余计时并隐藏提示层。
  /// 长按完成启用后松手（[_enablingTabId] 已置 null）：直接忽略。
  void _onLongPressEnd() {
    _enableTimer?.cancel();
    _enableTimer = null;
    if (_enablingTabId == null) return;
    setState(() {
      _enablingTabId = null;
      _showHint = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tabConfig = context.watch<TabConfigProvider>();
    final tabs = tabConfig.allTabs
        .where((t) => t.id != 'user' && t.id != 'launchpad')
        .toList();
    // 宽屏（平板/横屏）4 列，手机 2 列
    final columns = MediaQuery.sizeOf(context).width >= 600 ? 4 : 2;

    return Scaffold(
      appBar: AppBar(title: const Text('LaunchPad')),
      body: GridView.builder(
        padding: const EdgeInsets.all(16),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 1.0,
        ),
        itemCount: tabs.length,
        itemBuilder: (context, i) {
          final tab = tabs[i];
          final hidden = tabConfig.hiddenTabs.contains(tab.id);
          return _LaunchPadCard(
            icon: _tabIcon(tab.id),
            label: tab.label,
            hidden: hidden,
            enabling: _enablingTabId == tab.id,
            showHint: _showHint,
            // 可见 tab 点击切主 tab；隐藏 tab 点击跳二级页面（长按启用）
            onTap: hidden
                ? () => widget.onTabOpened(tab.id)
                : () => widget.onTabSelected(tab.id),
            onLongPressStart: hidden
                ? () => _onLongPressStart(tab.id)
                : null,
            onLongPressEnd: hidden ? _onLongPressEnd : null,
          );
        },
      ),
    );
  }

  /// Tab 图标映射，与 app.dart / 设置页的映射保持一致。
  IconData _tabIcon(String tabId) {
    switch (tabId) {
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
        return Icons.dynamic_feed;
      case 'settings':
        return Icons.settings;
      default:
        return Icons.circle;
    }
  }
}

/// LaunchPad 网格卡片：图标 + 名称；隐藏的 tab 半透明显示。
///
/// 可见 tab 用 [InkWell] 点击切换；隐藏 tab 用 [GestureDetector] 注册
/// onTap（跳二级页）+ onLongPress（启用），手势竞技场裁决点击/长按/滑动，
/// 网格滚动时 tap 与 longPress 都会被取消，避免误触。
class _LaunchPadCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool hidden;
  /// 是否正在长按启用（用于构建提示层）。
  final bool enabling;
  /// 长按已识别，提示层淡入。
  final bool showHint;
  final VoidCallback onTap;
  final VoidCallback? onLongPressStart;
  final VoidCallback? onLongPressEnd;

  const _LaunchPadCard({
    required this.icon,
    required this.label,
    required this.hidden,
    required this.enabling,
    required this.showHint,
    required this.onTap,
    this.onLongPressStart,
    this.onLongPressEnd,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final content = Opacity(
      opacity: hidden ? 0.45 : 1.0,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Material(
          color: cs.surfaceContainerLow,
          child: InkWell(
            onTap: hidden ? null : onTap,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 36, color: cs.primary),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!hidden) return content;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPressStart: (_) => onLongPressStart?.call(),
      onLongPressEnd: (_) => onLongPressEnd?.call(),
      onLongPressCancel: () => onLongPressEnd?.call(),
      child: Stack(
        // expand：内容铺满网格格子，与可见 tab 卡片同尺寸同位置
        // （loose 会缩成内容大小并靠左上角对齐）
        fit: StackFit.expand,
        children: [
          content,
          if (enabling) Positioned.fill(child: _buildEnableHint()),
        ],
      ),
    );
  }

  /// 长按启用提示层（参考 Zen 模式长按退出）：半透明黑色背景 + 图标 + 文字。
  /// 长按被系统识别（500ms）后通过 [AnimatedOpacity] 淡入，
  /// IgnorePointer 不拦截指针事件。
  Widget _buildEnableHint() {
    return IgnorePointer(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: AnimatedOpacity(
          opacity: showHint ? 1.0 : 0.0,
          duration: _LaunchPadPageState._hintFade,
          child: Container(
            color: Colors.black.withValues(alpha: 0.6),
            alignment: Alignment.center,
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.power_settings_new, color: Colors.white, size: 28),
                const SizedBox(height: 8),
                Text(
                  '继续长按启用「$label」',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
