import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:m3e_core/m3e_core.dart';
import '../../widgets/md3_pull_to_refresh.dart';

import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/pinchable_grid_view.dart';
import '../../widgets/scroll_aware_app_bar.dart';
import '../login/login_page.dart';
import 'channel_detail_page.dart';

/// 主页「频道」Tab 根页。
///
/// 展示用户订阅的频道列表（/youth/channel/all），未登录时提示去登录。
/// 点击频道进入 [ChannelDetailPage]，返回后刷新（订阅状态可能变化）。
class ChannelPage extends StatefulWidget {
  const ChannelPage({super.key});

  @override
  State<ChannelPage> createState() => _ChannelPageState();
}

class _ChannelPageState extends State<ChannelPage> {
  final ScrollController _scrollController = ScrollController();
  bool _isLoading = true;
  bool _needsLogin = false;
  List<KugouYouthChannel> _channels = [];

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkLoginAndLoad();
    });
  }

  Future<void> _checkLoginAndLoad() async {
    // /youth/channel/all 需登录：未登录直接提示去登录
    if (!KugouApiClient().isLoggedIn) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _needsLogin = true;
        });
      }
      _showLoginRequiredDialog();
      return;
    }
    await _load();
  }

  Future<void> _load({bool showLoading = true}) async {
    if (showLoading && mounted) setState(() => _isLoading = true);
    Map<String, dynamic>? r;
    try {
      r = await KugouApiClient().getYouthChannels();
    } catch (_) {
      r = null;
    }
    final channels = <KugouYouthChannel>[];
    for (final e in _listOf(r)) {
      if (e is! Map<String, dynamic>) continue;
      final c = KugouYouthChannel.fromJson(e);
      if (c.id.isNotEmpty) channels.add(c);
    }
    if (!mounted) return;
    setState(() {
      _channels = channels;
      // 上游返回错误（status=0 且 error_code 非 0）时区分：
      // 20002 = 未登录 → 引导登录；其他错误 → 显示空态文案
      final err = r?['error_code'];
      _needsLogin = err is num && err != 0 && err == 20002;
      _isLoading = false;
    });
  }

  /// 从响应中提取列表（防御：data 可能是 Map 或 List，list 字段名多变）
  List<dynamic> _listOf(Map<String, dynamic>? json) {
    if (json == null) return const [];
    final d = json['data'];
    if (d is Map<String, dynamic>) {
      final l = d['list'] ??
          d['info'] ??
          d['channels'] ??
          d['channel_list'] ??
          d['items'] ??
          d['data'];
      if (l is List) return l;
      // info 可能是 Map（如 {list: [...]}）时继续下钻
      final inner = l is Map<String, dynamic>
          ? (l['list'] ?? l['items'] ?? l['data'])
          : null;
      if (inner is List) return inner;
    }
    if (d is List) return d;
    final l = json['list'] ?? json['info'];
    if (l is List) return l;
    return const [];
  }

  void _showLoginRequiredDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('请先登录'),
        content: const Text('频道功能需要登录账号，是否前往登录？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const LoginPage()),
              );
              // 登录返回后重新加载
              if (mounted) _load();
            },
            child: const Text('去登录'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: ScrollAwareAppBar(
        title: '频道',
        // 有壁纸时顶栏完全透明（与发现页一致），无壁纸时恒不透明 surface
        opaque: true,
        scrollController: _scrollController,
      ),
      body: _isLoading
          ? const Center(child: M3ELoadingIndicator())
          : _channels.isEmpty
              ? _buildEmpty(cs)
              : Md3PullToRefresh(
                  onRefresh: () => _load(showLoading: false),
                  child: PinchableGridView(
                    controller: _scrollController,
                    itemCount: _channels.length,
                    childAspectRatio: 0.72,
                    padding: const EdgeInsets.all(16),
                    itemBuilder: (context, i) => _ChannelCard(
                      channel: _channels[i],
                      onTap: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) =>
                                ChannelDetailPage(channel: _channels[i]),
                          ),
                        );
                        // 返回后刷新（订阅状态可能变化）
                        if (mounted) _load();
                      },
                    ),
                  ),
                ),
    );
  }

  Widget _buildEmpty(ColorScheme cs) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.dynamic_feed_outlined,
            size: 48,
            color: cs.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 12),
          Text(
            _needsLogin ? '登录后可查看订阅的频道' : '暂无频道数据',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
          if (_needsLogin) ...[
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const LoginPage()),
                );
                if (mounted) _load();
              },
              icon: const Icon(Icons.login),
              label: const Text('去登录'),
            ),
          ],
        ],
      ),
    );
  }
}

/// 单个频道卡片：封面 + 名称（样式对齐 scene_page 的 _SceneCard）
class _ChannelCard extends StatelessWidget {
  final KugouYouthChannel channel;
  final VoidCallback? onTap;

  const _ChannelCard({required this.channel, this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: cs.surfaceContainerLow,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: channel.coverUrl != null
                    ? CachedNetworkImage(
                        imageUrl: channel.coverUrl!,
                        memCacheWidth: 540,
                        memCacheHeight: 540,
                        fit: BoxFit.cover,
                        errorWidget: (_, _, _) => ColoredBox(
                          color: Colors.transparent,
                          child: Center(
                            child: Icon(
                              Icons.dynamic_feed_outlined,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                      )
                    : ColoredBox(
                        color: Colors.transparent,
                        child: Center(
                          child: Icon(
                            Icons.dynamic_feed_outlined,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                child: Text(
                  channel.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: tt.labelMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: cs.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
