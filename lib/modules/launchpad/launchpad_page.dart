import 'dart:async';

import 'package:dpad/dpad.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/build_flags.dart';
import '../../providers/tab_config_provider.dart';
import '../../widgets/scroll_aware_app_bar.dart';
import '../settings/home_tab_manager.dart';

/// LaunchPad 导航页：以"导航网站"的形式列出所有可用 Tab（除"我的"和自身），
/// 按「未固定 / 已固定」两个分区展示（固定 = 出现在底部导航栏，置底显示）。
///
/// 交互规则：
/// - 点击可见 tab：直接切换主 tab；
/// - 点击隐藏 tab：**不启用**，以二级页面路由打开对应功能页；
/// - 长按隐藏 tab：系统长按（500ms）触发时提示层淡入，持续按住满 2 秒
///   启用并切换主 tab（交互参考 Zen 模式长按退出，松开即取消）。
/// 点击/长按/滑动由 GestureDetector 手势竞技场裁决，滚动时不会误触。
///
/// 右上角「编辑」弹出底部托盘（与设置页「主页管理」一致）：开关控制固定与否
/// （增删固定项）、拖拽把手调整顺序（即底部导航栏顺序）。
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
    // "我的"与自身不参与列表；已固定（底栏可见）与未固定分成两个分区
    final tabs = tabConfig.allTabs
        .where((t) => t.id != 'user' && t.id != 'launchpad')
        .toList();
    final pinned = tabs
        .where((t) => !tabConfig.hiddenTabs.contains(t.id))
        .toList();
    final unpinned = tabs
        .where((t) => tabConfig.hiddenTabs.contains(t.id))
        .toList();
    // 手机竖屏 3 列，横屏（及宽屏）4 列
    final columns =
        MediaQuery.orientationOf(context) == Orientation.landscape ? 4 : 3;

    return Scaffold(
      appBar: ScrollAwareAppBar(
        title: 'LaunchPad',
        tabId: 'launchpad',
        opaque: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: '编辑固定项',
            onPressed: _showEditSheet,
          ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          // 未固定在前，已固定分区置底
          if (unpinned.isNotEmpty) ...[
            _buildSectionHeader('未固定', unpinned.length),
            _buildGrid(tabConfig, unpinned, columns),
          ],
          if (pinned.isNotEmpty) ...[
            _buildSectionHeader('已固定', pinned.length),
            _buildGrid(tabConfig, pinned, columns),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 88)),
        ],
      ),
    );
  }

  /// 右上角「编辑」：弹出底部托盘管理固定项（交互与设置页「主页管理」一致：
  /// 拖拽排序 + 开关固定状态，点外部或下滑关闭）。
  void _showEditSheet() {
    showM3EModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => const _LaunchPadEditPanel(),
    );
  }

  /// 分区标题（已固定 / 未固定）。
  Widget _buildSectionHeader(String title, int count) {
    final cs = Theme.of(context).colorScheme;
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Row(
          children: [
            Text(
              title,
              // 非顶栏标题：比顶栏字号小一档
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '$count',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: Divider(color: cs.outlineVariant, height: 1)),
          ],
        ),
      ),
    );
  }

  /// 单个分区的图标网格。
  Widget _buildGrid(
    TabConfigProvider tabConfig,
    List<TabItem> items,
    int columns,
  ) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 1.0,
        ),
        delegate: SliverChildBuilderDelegate((context, i) {
          final tab = items[i];
          final hidden = tabConfig.hiddenTabs.contains(tab.id);
          return _LaunchPadCard(
            icon: homeTabIcon(tab.id),
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
        }, childCount: items.length),
      ),
    );
  }
}

/// LaunchPad 编辑托盘（右上角「编辑」弹出）：可拖拽排序 + 固定/取消固定开关。
///
/// 与设置页「主页管理」共用 [HomeTabManagerList]：展示完整 Tab 列表、
/// 下标与 [TabConfigProvider.allTabs] 1:1（不再过滤 user/launchpad、不再做下标换算），
/// 拖拽/开关/重置行为两处完全一致，任一处修改后另一处经 Provider 立即刷新。
class _LaunchPadEditPanel extends StatelessWidget {
  const _LaunchPadEditPanel();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.85,
        child: const HomeTabManagerList(
          title: 'LaunchPad 管理',
          embedded: false,
        ),
      ),
    );
  }
}

/// LaunchPad 网格卡片：图标 + 名称（固定/未固定同样不透明显示）。
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
    final content = ClipRRect(
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
    );
    if (!hidden) return content;
    // tv: TV 构建下隐藏 tab 卡单停点（GestureDetector 不可聚焦；OK=跳二级页）。
    // 长按启用不接入 D-pad（按住进度提示层由指针事件驱动，OK 长按无法等价
    // 复现），TV 上经设置页「主页管理」启用隐藏 tab。
    if (kTvBuild) {
      return DpadFocusable(
        onSelect: onTap,
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
