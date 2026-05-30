import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/kugou_provider.dart';
import '../../widgets/app_animation.dart';
import '../login/login_page.dart';
import '../settings/settings_page.dart';

class UserCenterPage extends StatefulWidget {
  const UserCenterPage({super.key});

  @override
  State<UserCenterPage> createState() => _UserCenterPageState();
}

class _UserCenterPageState extends State<UserCenterPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final kugou = context.read<KugouProvider>();
      if (kugou.isLoggedIn) {
        kugou.getVipDetail();
        kugou.getUserCloud();
        kugou.getUserHistory();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('我的'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsPage()),
            ),
          ),
          Consumer<KugouProvider>(
            builder: (context, kugou, _) => IconButton(
              icon: Icon(kugou.isLoggedIn ? Icons.logout : Icons.login),
              onPressed: kugou.isLoggedIn
                  ? () => showDialog(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('退出登录'),
                        content: const Text('确定要退出登录吗？'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('取消'),
                          ),
                          TextButton(
                            onPressed: () {
                              kugou.logout();
                              Navigator.pop(ctx);
                            },
                            child: const Text('确定'),
                          ),
                        ],
                      ),
                    )
                  : () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const LoginPage()),
                    ),
            ),
          ),
        ],
      ),
      body: Consumer<KugouProvider>(
        builder: (context, kugou, _) {
          if (!kugou.isLoggedIn) return _buildNotLoggedIn(cs, tt);
          return RefreshIndicator(
            onRefresh: () async {
              await kugou.getVipDetail();
              await kugou.getUserCloud();
              await kugou.getUserHistory();
            },
            child: CustomScrollView(
              slivers: [
                _buildUserHeader(cs, tt, kugou),
                _buildVipCard(cs, tt, kugou),
                _buildActionGrid(cs),
                _buildCloudSection(cs, kugou),
                _buildHistorySection(cs, kugou),
                const SliverToBoxAdapter(child: SizedBox(height: 80)),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildNotLoggedIn(ColorScheme cs, TextTheme tt) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.person_outline,
              size: 80,
              color: cs.onSurfaceVariant.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 16),
            Text(
              '登录后享受更多精彩',
              style: tt.titleMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Text(
              '同步歌单、收藏、云盘等',
              style: tt.bodyMedium?.copyWith(
                color: cs.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              icon: const Icon(Icons.person),
              label: const Text('登录'),
              onPressed: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const LoginPage())),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUserHeader(ColorScheme cs, TextTheme tt, KugouProvider kugou) {
    return SliverToBoxAdapter(
      child: FadeInUp(
        child: Container(
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: LinearGradient(
              colors: [cs.primaryContainer, cs.tertiaryContainer],
            ),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 32,
                backgroundImage: kugou.userInfo?.avatar != null
                    ? CachedNetworkImageProvider(kugou.userInfo!.avatar!)
                    : null,
                child: kugou.userInfo?.avatar == null
                    ? Icon(Icons.person, size: 32, color: cs.onPrimaryContainer)
                    : null,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      kugou.userInfo?.nickname ?? '用户',
                      style: tt.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: cs.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'ID: ${kugou.userInfo?.userid ?? ''}',
                      style: TextStyle(
                        color: cs.onPrimaryContainer.withValues(alpha: 0.7),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: cs.onPrimaryContainer),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVipCard(ColorScheme cs, TextTheme tt, KugouProvider kugou) {
    final vip = kugou.vipInfo;
    return SliverToBoxAdapter(
      child: FadeInUp(
        delayMs: 50,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: cs.outlineVariant),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: vip?.isVip == true
                      ? Colors.amber.withValues(alpha: 0.2)
                      : cs.surfaceContainerHighest,
                ),
                child: Icon(
                  vip?.isVip == true
                      ? Icons.workspace_premium
                      : Icons.workspace_premium_outlined,
                  color: vip?.isVip == true
                      ? Colors.amber
                      : cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      vip?.isVip == true ? 'VIP会员' : '开通VIP会员',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      vip?.isVip == true
                          ? '有效期至: ${vip?.expireTime ?? '永久'}'
                          : '畅享无损音质、个性皮肤等',
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              FilledButton.tonal(
                onPressed: () {},
                child: Text(vip?.isVip == true ? '续费' : '开通'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActionGrid(ColorScheme cs) {
    return SliverToBoxAdapter(
      child: FadeInUp(
        delayMs: 100,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _actionItem(
                cs,
                Icons.cloud,
                '云盘',
                () => context.read<KugouProvider>().getUserCloud(),
              ),
              _actionItem(
                cs,
                Icons.history,
                '历史',
                () => context.read<KugouProvider>().getUserHistory(),
              ),
              _actionItem(cs, Icons.favorite, '收藏', () {}),
              _actionItem(cs, Icons.download, '下载', () {}),
            ],
          ),
        ),
      ),
    );
  }

  Widget _actionItem(
    ColorScheme cs,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: cs.surfaceContainerHighest,
            ),
            child: Icon(icon, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildCloudSection(ColorScheme cs, KugouProvider kugou) {
    return SliverToBoxAdapter(
      child: FadeInUp(
        delayMs: 150,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Card(
            child: ListTile(
              leading: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: cs.primaryContainer,
                ),
                child: Icon(Icons.cloud, color: cs.onPrimaryContainer),
              ),
              title: const Text('我的云盘'),
              subtitle: Text(
                '同步你的音乐文件',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {},
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHistorySection(ColorScheme cs, KugouProvider kugou) {
    return SliverToBoxAdapter(
      child: FadeInUp(
        delayMs: 200,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Card(
            child: ListTile(
              leading: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: cs.tertiaryContainer,
                ),
                child: Icon(Icons.history, color: cs.onTertiaryContainer),
              ),
              title: const Text('播放历史'),
              subtitle: Text(
                '最近播放的歌曲',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {},
            ),
          ),
        ),
      ),
    );
  }
}
