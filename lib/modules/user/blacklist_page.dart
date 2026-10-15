import 'dart:async';

import 'package:dpad/dpad.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/build_flags.dart';
import '../../core/layout/page_layout.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/utils/app_toast.dart';
import '../../providers/blacklist_provider.dart';
import '../../providers/kugou_provider.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/md3_pull_to_refresh.dart';

/// 内容黑名单管理：双 Tab（歌曲「不感兴趣」/ 歌手「已屏蔽歌手」），
/// 展示/移除黑名单条目。黑名单内容不会出现在猜你喜欢、每日推荐等推荐场景中
/// （由酷狗服务端在本账号的推荐链路上排除，客户端无需自行过滤）。
/// 数据来自 /blacklist/list（Rust `blacklist.rs`），作用域为当前登录账号。
class BlacklistPage extends StatefulWidget {
  const BlacklistPage({super.key});

  @override
  State<BlacklistPage> createState() => _BlacklistPageState();
}

class _BlacklistPageState extends State<BlacklistPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  static const List<String> _labels = ['song', 'singer'];
  static const List<String> _tabTitles = ['不感兴趣', '已屏蔽歌手'];
  static const List<String> _emptyTexts = [
    '还没有标记不感兴趣的歌曲',
    '还没有屏蔽任何歌手',
  ];
  static const List<String> _unnamedFallbacks = ['未命名歌曲', '未命名歌手'];

  /// 正在移除中的条目 key（行内 loading 并禁点，防重复提交）。
  final Set<String> _removingKeys = {};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _labels.length, vsync: this);
    _tabController.addListener(_ensureCurrentTabLoaded);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureCurrentTabLoaded();
    });
  }

  @override
  void dispose() {
    _tabController.removeListener(_ensureCurrentTabLoaded);
    _tabController.dispose();
    super.dispose();
  }

  void _ensureCurrentTabLoaded() {
    if (!mounted) return;
    if (!context.read<KugouProvider>().isLoggedIn) return;
    final label = _labels[_tabController.index.clamp(0, _labels.length - 1)];
    // 已加载过则复用缓存；进行中的拉取由 Provider 去重。
    unawaited(context.read<BlacklistProvider>().load(label));
  }

  Future<void> _refresh(String label) {
    return context.read<BlacklistProvider>().load(label, force: true);
  }

  Future<void> _confirmRemove(KugouBlacklistEntry entry) async {
    final isSong = entry.label != 'singer';
    final name = entry.displayName(isSong ? _unnamedFallbacks[0] : _unnamedFallbacks[1]);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isSong ? '撤销不感兴趣' : '取消屏蔽歌手'),
        content: Text(
          isSong
              ? '确定撤销对「$name」的不感兴趣吗？这首歌可能会再次出现在推荐中。'
              : '确定取消屏蔽歌手「$name」吗？该歌手可能会再次出现在推荐中。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: Text(isSong ? '确认撤销' : '取消屏蔽'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _remove(entry);
  }

  Future<void> _remove(KugouBlacklistEntry entry) async {
    final isSong = entry.label != 'singer';
    setState(() => _removingKeys.add(entry.key));
    try {
      final ok = await context.read<BlacklistProvider>().remove(entry);
      if (!mounted) return;
      if (ok) {
        final name =
            entry.displayName(isSong ? _unnamedFallbacks[0] : _unnamedFallbacks[1]);
        showToast(isSong ? '已撤销对「$name」的不感兴趣' : '已取消屏蔽歌手「$name」');
      } else {
        showToast('移除失败，请稍后重试');
      }
    } finally {
      if (mounted) {
        setState(() => _removingKeys.remove(entry.key));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<BlacklistProvider>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('黑名单管理'),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            for (var i = 0; i < _labels.length; i++)
              Tab(text: _tabTitle(i, provider)),
          ],
        ),
      ),
      body: ContentWidth(
        child: TabBarView(
          controller: _tabController,
          children: [
            for (final label in _labels) _buildTab(context, label, provider),
          ],
        ),
      ),
    );
  }

  /// Tab 标题：加载过后带计数（EchoMusic 同款）。
  String _tabTitle(int index, BlacklistProvider provider) {
    final label = _labels[index];
    final title = _tabTitles[index];
    if (!provider.isLoaded(label)) return title;
    return '$title ${provider.totalOf(label)}';
  }

  Widget _buildTab(
    BuildContext context,
    String label,
    BlacklistProvider provider,
  ) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    if (!context.watch<KugouProvider>().isLoggedIn) {
      return _buildHint(
        cs,
        tt,
        icon: Icons.lock_outline,
        text: '当前未登录，登录后可管理黑名单',
      );
    }
    if (provider.isLoading(label) && !provider.isLoaded(label)) {
      return const Center(child: M3ELoadingIndicator());
    }
    final error = provider.errorOf(label);
    final entries = provider.entries(label);
    if (error != null && entries.isEmpty) {
      return _buildErrorState(context, cs, tt, label);
    }
    if (provider.isLoaded(label) && entries.isEmpty) {
      return _buildHint(
        cs,
        tt,
        icon: label == 'singer'
            ? Icons.visibility_off_outlined
            : Icons.thumb_down_off_alt,
        text: _emptyTexts[label == 'singer' ? 1 : 0],
        hint: '标记后不会出现在猜你喜欢、每日推荐等推荐场景中',
      );
    }
    return Md3PullToRefresh(
      onRefresh: () => _refresh(label),
      child: ListView.builder(
        padding: const EdgeInsets.all(AppSpacing.lg),
        itemCount: entries.length + (provider.hasMore(label) ? 1 : 0) + 1,
        itemBuilder: (context, i) {
          // 首行：拉取失败但已有内容时的错误横幅（含重试）
          if (i == 0) {
            if (error != null) {
              return _buildErrorBanner(context, cs, tt, label);
            }
            return const SizedBox.shrink();
          }
          final entryIndex = i - 1;
          if (entryIndex < entries.length) {
            return _entryCard(context, cs, tt, entries[entryIndex]);
          }
          return _buildLoadMore(context, label, provider);
        },
      ),
    );
  }

  Widget _buildErrorState(
    BuildContext context,
    ColorScheme cs,
    TextTheme tt,
    String label,
  ) {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.xxl),
      children: [
        const Gap(AppSpacing.xxl),
        Icon(
          Icons.error_outline,
          size: 48,
          color: cs.onSurfaceVariant.withValues(alpha: 0.4),
        ),
        const Gap(AppSpacing.md),
        Text(
          '获取黑名单失败，请检查网络后重试',
          textAlign: TextAlign.center,
          style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
        ),
        const Gap(AppSpacing.lg),
        Center(
          child: OutlinedButton.icon(
            onPressed: () => _refresh(label),
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ),
      ],
    );
  }

  Widget _buildErrorBanner(
    BuildContext context,
    ColorScheme cs,
    TextTheme tt,
    String label,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: cs.errorContainer,
          borderRadius: AppRadius.mdAll,
        ),
        child: Row(
          children: [
            Icon(Icons.error_outline, size: 18, color: cs.onErrorContainer),
            const Gap(AppSpacing.sm),
            Expanded(
              child: Text(
                '刷新失败，当前展示的是缓存内容',
                style: tt.bodySmall?.copyWith(color: cs.onErrorContainer),
              ),
            ),
            TextButton(
              onPressed: () => _refresh(label),
              style: TextButton.styleFrom(
                foregroundColor: cs.onErrorContainer,
                visualDensity: VisualDensity.compact,
              ),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadMore(
    BuildContext context,
    String label,
    BlacklistProvider provider,
  ) {
    final cs = Theme.of(context).colorScheme;
    if (provider.isLoading(label)) {
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.lg),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Center(
        child: OutlinedButton(
          onPressed: () =>
              context.read<BlacklistProvider>().loadMore(label),
          child: Text(
            '加载更多',
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ),
      ),
    );
  }

  Widget _buildHint(
    ColorScheme cs,
    TextTheme tt, {
    required IconData icon,
    required String text,
    String? hint,
  }) {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.xxl),
      children: [
        const Gap(AppSpacing.xxl),
        Icon(icon, size: 48, color: cs.onSurfaceVariant.withValues(alpha: 0.4)),
        const Gap(AppSpacing.sm),
        Text(
          text,
          textAlign: TextAlign.center,
          style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
        ),
        if (hint != null) ...[
          const Gap(AppSpacing.xs),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: tt.bodySmall?.copyWith(
              color: cs.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ],
    );
  }

  Widget _entryCard(
    BuildContext context,
    ColorScheme cs,
    TextTheme tt,
    KugouBlacklistEntry entry,
  ) {
    final isSong = entry.label != 'singer';
    final name =
        entry.displayName(isSong ? _unnamedFallbacks[0] : _unnamedFallbacks[1]);
    final removing = _removingKeys.contains(entry.key);

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: AppRadius.lgAll,
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: AppRadius.mdAll,
            ),
            child: Icon(
              isSong
                  ? Icons.thumb_down_off_alt
                  : Icons.visibility_off_outlined,
              size: 20,
              color: cs.onSurfaceVariant,
            ),
          ),
          const Gap(AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tt.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                  ),
                ),
                if (entry.createdAtText.isNotEmpty) ...[
                  const Gap(2),
                  Text(
                    isSong
                        ? '标记于 ${entry.createdAtText}'
                        : '屏蔽于 ${entry.createdAtText}',
                    style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
          const Gap(AppSpacing.sm),
          _removeButton(context, cs, entry, removing),
        ],
      ),
    );
  }

  /// 「移除」按钮：TV 下按项目约定包 DpadFocusable 单停点（OK 走同一确认流程）。
  Widget _removeButton(
    BuildContext context,
    ColorScheme cs,
    KugouBlacklistEntry entry,
    bool removing,
  ) {
    void onRequest() {
      if (!removing) _confirmRemove(entry);
    }

    final visual = removing
        ? const Padding(
            padding: EdgeInsets.symmetric(horizontal: AppSpacing.sm),
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        : TextButton(
            onPressed: onRequest,
            style: TextButton.styleFrom(
              foregroundColor: cs.error,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
            ),
            child: const Text('移除'),
          );
    if (removing) return visual;

    if (kTvBuild) {
      return DpadFocusable(
        debugLabel: 'blacklist/remove-${entry.label}-${entry.key}',
        onSelect: onRequest,
        child: visual,
      );
    }
    return visual;
  }
}
