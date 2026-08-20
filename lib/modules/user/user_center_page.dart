import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/utils/app_toast.dart';
import '../../data/models/kugou_account.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/kugou_provider.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/scroll_aware_app_bar.dart';
import '../login/login_page.dart';
import '../settings/settings_page.dart';
import 'cloud_music_page.dart';
import 'downloads_page.dart';
import 'listen_ranking_page.dart';
import 'play_history_page.dart';
import 'purchased_page.dart';
import 'vip_status.dart';

class UserCenterPage extends StatefulWidget {
  const UserCenterPage({super.key});

  @override
  State<UserCenterPage> createState() => _UserCenterPageState();
}

class _UserCenterPageState extends State<UserCenterPage> {
  /// 顶栏渐变 ScrollController：与 ScrollAwareAppBar 共享
  final ScrollController _scrollController = ScrollController();

  /// 防止验证码弹窗被多次触发（pendingVerifyCaptcha 存在期间只弹一次）
  bool _captchaDialogShowing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final kugou = context.read<KugouProvider>();
      if (kugou.isLoggedIn) {
        kugou.getVipDetail();
        kugou.getVipMonthRecord();
        kugou.getGradeInfo();
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Scaffold(
      appBar: ScrollAwareAppBar(
        title: '我的',
        scrollController: _scrollController,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SettingsPage())),
          ),
          Consumer<KugouProvider>(
            builder: (context, kugou, _) => IconButton(
              icon: Icon(kugou.isLoggedIn ? Icons.logout : Icons.login),
              onPressed: kugou.isLoggedIn
                  ? () => _confirmLogout(context, kugou)
                  : () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const LoginPage()),
                    ),
            ),
          ),
        ],
      ),
      body: Consumer<KugouProvider>(
        builder: (context, kugou, _) {
          // 监听 20028 二次安全验证请求，弹出腾讯滑块验证码
          final pending = kugou.pendingVerifyCaptcha;
          if (pending != null && !_captchaDialogShowing) {
            _captchaDialogShowing = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _showVerifyCaptchaDialog(context, kugou, pending);
            });
          }
          if (!kugou.isLoggedIn) return _buildNotLoggedIn(cs, tt);
          return M3EPullToRefreshIndicator(
            onRefresh: () async {
              await kugou.getVipDetail();
              await kugou.getVipMonthRecord();
              await kugou.getGradeInfo();
            },
            child: CustomScrollView(
              controller: _scrollController,
              slivers: [
                _buildUserHeader(cs, tt, kugou),
                const SliverToBoxAdapter(child: SizedBox(height: 16)),
                _buildActionGrid(cs),
                const SliverToBoxAdapter(child: SizedBox(height: 16)),
                _buildVipCard(cs, tt, kugou),
                const SliverToBoxAdapter(child: SizedBox(height: 16)),
                _buildVipCalendar(cs, tt, kugou, context),
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

  Widget _buildUserAvatar(KugouProvider kugou, ColorScheme cs) {
    final avatarUrl = kugou.userInfo?.avatar;
    final userId = kugou.userid ?? 'default';

    if (avatarUrl == null || avatarUrl.isEmpty) {
      return CircleAvatar(
        radius: 32,
        backgroundColor: cs.primary.withValues(alpha: 0.2),
        child: Icon(Icons.person, size: 32, color: cs.onPrimaryContainer),
      );
    }

    // 修复：使用更安全的缓存键，避免 userId 为 null 导致的问题
    final safeUserId = userId.toString().replaceAll(
      RegExp(r'[^a-zA-Z0-9]'),
      '_',
    );
    final cacheKey = 'avatar_$safeUserId';

    return CircleAvatar(
      radius: 32,
      backgroundColor: cs.primary.withValues(alpha: 0.2),
      child: ClipOval(
        child: CachedNetworkImage(
          imageUrl: avatarUrl,
          memCacheWidth: 192,
          memCacheHeight: 192,
          cacheKey: cacheKey,
          width: 64,
          height: 64,
          fit: BoxFit.cover,
          placeholder: (context, url) =>
              Icon(Icons.person, size: 32, color: cs.onPrimaryContainer),
          errorWidget: (context, url, error) =>
              Icon(Icons.person, size: 32, color: cs.onPrimaryContainer),
        ),
      ),
    );
  }

  Widget _buildUserHeader(ColorScheme cs, TextTheme tt, KugouProvider kugou) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Material(
          color: cs.primaryContainer,
          borderRadius: BorderRadius.circular(20),
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => _showAccountManager(context, kugou),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  _buildUserAvatar(kugou, cs),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          kugou.userInfo?.nickname ?? '用户',
                          style: tt.titleLarge?.copyWith(
                            color: cs.onPrimaryContainer,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'ID: ${kugou.userid ?? ''}',
                          style: tt.labelSmall?.copyWith(
                            color: cs.onPrimaryContainer.withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (kugou.gradeInfo != null) ...[
                    const SizedBox(width: 12),
                    _buildGradePill(cs, tt, kugou.gradeInfo!, kugou.unreportedSeconds),
                  ],
                  Icon(Icons.chevron_right, color: cs.onPrimaryContainer),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 听歌等级胶囊：LV + 累计时长 + 未上报时长（≥5分钟显示）+ 升级进度
  Widget _buildGradePill(
    ColorScheme cs,
    TextTheme tt,
    KugouGradeInfo grade,
    int unreportedSec,
  ) {
    final sec = grade.dSec ?? grade.duration ?? 0;
    final gradeNum = grade.pGrade ?? 0;
    final cur = (grade.pCurrentPoint ?? 0).toDouble();
    final next = (grade.pNextGradePoint ?? 1).toDouble();
    final progress = next > 0 ? (cur / next).clamp(0.0, 1.0) : 0.0;
    final showUnreported = unreportedSec >= 300; // 5 分钟
    return Container(
      width: 116,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: cs.surface.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.graphic_eq, size: 13, color: cs.onPrimaryContainer),
              const SizedBox(width: 3),
              Text(
                'LV.$gradeNum',
                style: tt.labelMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: cs.onPrimaryContainer,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            _formatGradeSeconds(sec),
            style: tt.labelSmall?.copyWith(
              color: cs.onPrimaryContainer.withValues(alpha: 0.75),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (showUnreported) ...[
            const SizedBox(height: 2),
            Text(
              '未上报 ${_formatGradeSeconds(unreportedSec)}',
              style: tt.labelSmall?.copyWith(
                fontSize: 10,
                color: cs.error,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: M3ELinearProgressIndicator(
              value: progress,
              minHeight: 3,
              backgroundColor: cs.onPrimaryContainer.withValues(alpha: 0.15),
              valueColor: AlwaysStoppedAnimation<Color>(cs.primary),
            ),
          ),
        ],
      ),
    );
  }

  /// 秒数 → 可读时长，精确到分钟：X天Y小时Z分 / X小时Y分 / X分钟。
  String _formatGradeSeconds(int sec) {
    if (sec <= 0) return '0分钟';
    final d = sec ~/ 86400;
    final h = (sec % 86400) ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    if (d > 0) return '$d天$h小时$m分';
    if (h > 0) return '$h小时$m分';
    return '$m分钟';
  }

  // ==================== 多账号管理 ====================

  /// 登出确认（多账号感知：有其他账号时提示会自动切换）
  Future<void> _confirmLogout(BuildContext context, KugouProvider kugou) async {
    final hasOthers = kugou.savedAccounts.length > 1;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出当前账号'),
        content: Text(
          hasOthers ? '将退出当前账号，并自动切换到其他账号。确定？' : '确定要退出登录吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await kugou.logout();
    if (!context.mounted) return;
    // 退出/切换后重新同步「我喜欢的」
    context.read<FavoritesProvider>().loadFavorites();
  }

  /// 打开「账号管理」底部面板：展示已保存账号、支持切换/删除/登录新账号
  void _showAccountManager(BuildContext context, KugouProvider kugou) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
      builder: (sheetCtx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Consumer<KugouProvider>(
              builder: (context, provider, _) {
                final cs = Theme.of(context).colorScheme;
                final tt = Theme.of(context).textTheme;
                final accounts = provider.savedAccounts;
                return ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.7,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Text(
                            '账号管理',
                            style: tt.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const Spacer(),
                          if (accounts.length > 1)
                            Text(
                              '${accounts.length} 个账号',
                              style: tt.bodySmall?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (accounts.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 32),
                          child: Column(
                            children: [
                              Icon(
                                Icons.person_outline,
                                size: 48,
                                color: cs.onSurfaceVariant.withValues(
                                  alpha: 0.4,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '暂无已保存的账号',
                                style: tt.bodyMedium?.copyWith(
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        )
                      else
                        Flexible(
                          child: ListView.separated(
                            shrinkWrap: true,
                            itemCount: accounts.length,
                            separatorBuilder: (_, index) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) => _buildAccountTile(
                              context,
                              accounts[index],
                              provider,
                            ),
                          ),
                        ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const LoginPage()),
                        ),
                        icon: const Icon(Icons.add),
                        label: const Text('登录新账号'),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  /// 单个已保存账号的行
  Widget _buildAccountTile(
    BuildContext context,
    KugouAccount account,
    KugouProvider kugou,
  ) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final isCurrent = account.userid == kugou.userid;
    final displayName = (account.nickname != null && account.nickname!.isNotEmpty)
        ? account.nickname!
        : '用户 ${account.userid}';
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: _accountAvatar(account, cs),
      title: Row(
        children: [
          Flexible(
            child: Text(
              displayName,
              style: tt.bodyLarge?.copyWith(
                fontWeight: FontWeight.w600,
                // 过期账号的昵称置灰
                color: account.expired ? cs.onSurfaceVariant : null,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (account.expired) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: cs.errorContainer,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '登录已过期',
                style: tt.labelSmall?.copyWith(
                  color: cs.onErrorContainer,
                  fontSize: 10,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: Text('ID: ${account.userid}', style: tt.bodySmall),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isCurrent)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Icon(Icons.check_circle, color: cs.primary, size: 20),
            ),
          IconButton(
            tooltip: '删除账号',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _confirmRemoveAccount(context, account, kugou),
          ),
        ],
      ),
      // 过期账号点击直接引导重新登录/删除，不再走切换（凭证已失效）
      onTap: account.expired
          ? () => _handleExpiredAccount(context, account, kugou)
          : (isCurrent ? null : () => _switchToAccount(context, account, kugou)),
    );
  }

  /// 账号头像：有头像用缓存图，无则显示昵称首字
  Widget _accountAvatar(KugouAccount account, ColorScheme cs) {
    final avatarUrl = account.avatar;
    final nickname = account.nickname;
    final fallback = Text(
      (nickname != null && nickname.isNotEmpty)
          ? nickname.characters.first
          : '?',
      style: TextStyle(color: cs.onPrimaryContainer, fontSize: 16),
    );
    if (avatarUrl == null || avatarUrl.isEmpty) {
      return CircleAvatar(
        backgroundColor: cs.primary.withValues(alpha: 0.15),
        child: fallback,
      );
    }
    final safeUserId = account.userid.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
    return CircleAvatar(
      backgroundColor: cs.primary.withValues(alpha: 0.15),
      child: ClipOval(
        child: CachedNetworkImage(
          imageUrl: avatarUrl,
          memCacheWidth: 96,
          memCacheHeight: 96,
          cacheKey: 'avatar_$safeUserId',
          width: 40,
          height: 40,
          fit: BoxFit.cover,
          errorWidget: (c, u, e) => fallback,
        ),
      ),
    );
  }

  /// 切换账号（确认 → 切换 + 过期检测 → 重载收藏 → 关闭面板）
  Future<void> _switchToAccount(
    BuildContext context,
    KugouAccount account,
    KugouProvider kugou,
  ) async {
    final navigator = Navigator.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('切换账号'),
        content: Text('切换到「${account.nickname ?? account.userid}」？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('切换'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final result = await kugou.switchAccount(account.userid);
    if (!context.mounted) return;
    switch (result) {
      case SwitchAccountResult.success:
        navigator.pop(); // 关闭账号管理面板
        context.read<FavoritesProvider>().loadFavorites();
        showToast('已切换到 ${account.nickname ?? account.userid}', long: true);
      case SwitchAccountResult.tokenExpired:
        // 凭证已切换但登录态过期：引导重新登录或删除该账号
        navigator.pop();
        await _handleExpiredAccount(context, account, kugou);
      case SwitchAccountResult.noCredentials:
        showToast('切换失败，该账号凭证已失效', long: true);
    }
  }

  /// 账号登录态已过期：提示并引导重新登录 / 删除该账号。
  Future<void> _handleExpiredAccount(
    BuildContext context,
    KugouAccount account,
    KugouProvider kugou,
  ) async {
    if (!context.mounted) return;
    final navigator = Navigator.of(context);
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('登录已过期'),
        content: Text(
          '「${account.nickname ?? account.userid}」的登录状态已过期，'
          '需重新登录后才能使用该账号。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'remove'),
            child: const Text('删除该账号'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'relogin'),
            child: const Text('重新登录'),
          ),
        ],
      ),
    );
    if (!context.mounted) return;

    switch (action) {
      case 'relogin':
        // 重新登录：登录成功后 setLoginCookies 会清除该账号的过期标记
        await navigator.push(
          MaterialPageRoute(builder: (_) => const LoginPage()),
        );
      case 'remove':
        await kugou.removeAccount(account.userid);
        if (!context.mounted) return;
        context.read<FavoritesProvider>().loadFavorites();
        showToast('已删除过期账号', long: true);
    }
  }

  /// 删除账号（确认 → 删除 → 若为当前账号则重载收藏 → 关闭面板）
  Future<void> _confirmRemoveAccount(
    BuildContext context,
    KugouAccount account,
    KugouProvider kugou,
  ) async {
    final isCurrent = account.userid == kugou.userid;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除账号'),
        content: Text(
          isCurrent
              ? '将删除当前账号并退出登录（若有其他账号会自动切换）。确定？'
              : '确定删除该账号？其登录态将被清除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    await kugou.removeAccount(account.userid);
    if (!context.mounted) return;
    if (isCurrent) {
      context.read<FavoritesProvider>().loadFavorites();
    }
    Navigator.of(context).pop(); // 关闭账号管理面板
    showToast('已删除账号 ${account.nickname ?? account.userid}', long: true);
  }

  Widget _buildVipCard(ColorScheme cs, TextTheme tt, KugouProvider kugou) {
    final vip = kugou.vipInfo;
    final busiList = vip?.busiVipList;
    final tvip = findActiveBusiVip(busiList, 'tvip');
    final svip = findActiveBusiVip(busiList, 'svip');
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          // 实心矩形包裹：填充主题容器色，而非仅单一描边
          color: cs.surfaceContainer,
          border: Border.all(color: cs.outlineVariant),
        ),
        child: Column(
          children: [
            _buildVipRow(
              cs: cs,
              tt: tt,
              active: tvip,
              title: '畅听会员',
              icon: Icons.headphones,
              iconBg: cs.secondaryContainer,
              iconFg: cs.onSecondaryContainer,
            ),
            const SizedBox(height: 12),
            _buildVipRow(
              cs: cs,
              tt: tt,
              active: svip,
              title: '概念会员',
              icon: Icons.workspace_premium,
              iconBg: cs.primaryContainer,
              iconFg: cs.onPrimaryContainer,
            ),
          ],
        ),
      ),
    );
  }

  /// 单行会员状态（移植自 EchoMusic Profile.vue「会员状态」卡片）：
  /// 已开通显示相对到期时间 + 具体到期时间，未开通显示「未开通」。
  Widget _buildVipRow({
    required ColorScheme cs,
    required TextTheme tt,
    required Map<String, dynamic>? active,
    required String title,
    required IconData icon,
    required Color iconBg,
    required Color iconFg,
  }) {
    final endTime = active?['vip_end_time']?.toString();
    // 相对到期时间（如"5天后到期"），解析失败时为 null
    final relText = active != null ? formatVipExpireText(endTime) : null;
    // 具体到期时间（yyyy-MM-dd HH:mm）
    final absText = active != null ? formatVipDateTime(endTime) : null;
    final dimmed = active == null;
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: dimmed ? cs.surfaceContainerHighest : iconBg,
          ),
          child: Icon(icon, color: dimmed ? cs.onSurfaceVariant : iconFg),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: tt.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: dimmed ? cs.onSurfaceVariant : null,
                ),
              ),
              if (active != null) ...[
                if (relText != null)
                  Text(
                    relText,
                    style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                Text(
                  '$absText',
                  style: tt.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
              ] else
                Text(
                  '未开通',
                  style: tt.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
            ],
          ),
        ),
        Icon(
          dimmed ? Icons.radio_button_unchecked : Icons.check_circle,
          size: 18,
          color: dimmed
              ? cs.onSurfaceVariant.withValues(alpha: 0.5)
              : iconFg,
        ),
      ],
    );
  }

  Widget _buildActionGrid(ColorScheme cs) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _actionItem(cs, Icons.history, '历史', () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PlayHistoryPage()),
              );
            }),
            _actionItem(cs, Icons.bar_chart, '排行', () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ListenRankingPage()),
              );
            }),
            _actionItem(cs, Icons.cloud, '云盘', () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CloudMusicPage()),
              );
            }),
            _actionItem(cs, Icons.download, '下载', () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const DownloadsPage()),
              );
            }),
            _actionItem(cs, Icons.shopping_bag_outlined, '已购', () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PurchasedPage()),
              );
            }),
          ],
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
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildVipCalendar(
    ColorScheme cs,
    TextTheme tt,
    KugouProvider kugou,
    BuildContext context,
  ) {
    final record = kugou.vipMonthRecord;
    final now = DateTime.now();
    final curYear = now.year;
    final curMonth = now.month;
    final receivedDays = <int>{};
    if (record != null) {
      final data = record['data'] as Map<String, dynamic>?;
      final list = data?['list'] ?? data?['record_list'] ?? record['list'];
      if (list is List) {
        for (final item in list) {
          if (item is Map<String, dynamic>) {
            // 只显示概念版(svip)签到记录，过滤畅听(tvip)
            final vipType = item['vip_type']?.toString() ?? '';
            if (vipType != 'svip') continue;
            final dm = _parseReceivedYearMonthDay(item);
            if (dm != null && dm.year == curYear && dm.month == curMonth) {
              receivedDays.add(dm.day);
            }
          }
        }
      }
    }
    // 本地兜底：服务端记录不及时时，合并本地已签日期，保证今天立即打勾
    for (final key in kugou.localSignedDays) {
      final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(key);
      if (m != null &&
          int.parse(m.group(1)!) == curYear &&
          int.parse(m.group(2)!) == curMonth) {
        receivedDays.add(int.parse(m.group(3)!));
      }
    }
    final monthLabel = DateFormat('yyyy 年 M 月', 'zh_CN').format(now);
    final daysInMonth = DateTime(curYear, curMonth + 1, 0).day;
    // weekday: Mon=1..Sun=7 → 周一开头 0 个前导
    final leading = DateTime(curYear, curMonth, 1).weekday - 1;

    return SliverToBoxAdapter(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Container(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
            decoration: BoxDecoration(
              color: cs.surfaceContainerLow,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: cs.shadow.withValues(alpha: 0.06),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildCalendarHeader(cs, tt, monthLabel, kugou, context),
                const SizedBox(height: 16),
                _buildWeekdayHeader(cs),
                const SizedBox(height: 8),
                _buildCalendarGrid(
                  cs,
                  curYear,
                  curMonth,
                  leading,
                  daysInMonth,
                  receivedDays,
                  now,
                ),
                const SizedBox(height: 20),
                _buildStatFooter(cs, tt, receivedDays.length),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCalendarHeader(
    ColorScheme cs,
    TextTheme tt,
    String monthLabel,
    KugouProvider kugou,
    BuildContext context,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  monthLabel,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  minimumSize: const Size(0, 32),
                  textStyle: tt.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                onPressed: kugou.manualSignInRunning
                    ? null
                    : () => _handleManualSignIn(context, kugou),
                icon: kugou.manualSignInRunning
                    ? M3ELoadingIndicator(
                        constraints: BoxConstraints.tightFor(
                          width: 16,
                          height: 16,
                        ),
                        color: cs.onSecondaryContainer,
                      )
                    : const Icon(Icons.check_circle_outline, size: 16),
                label: Text(kugou.manualSignInRunning ? '签到中' : '签到'),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  minimumSize: const Size(0, 32),
                  textStyle: tt.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                onPressed: kugou.listenClaimRunning
                    ? null
                    : () => _handleListenClaim(context, kugou),
                icon: kugou.listenClaimRunning
                    ? M3ELoadingIndicator(
                        constraints: BoxConstraints.tightFor(
                          width: 16,
                          height: 16,
                        ),
                        color: cs.onSecondaryContainer,
                      )
                    : const Icon(Icons.headphones, size: 16),
                label: Text(kugou.listenClaimRunning ? '领取中' : '听歌领取'),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  minimumSize: const Size(0, 32),
                  textStyle: tt.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                onPressed: kugou.adClaimRunning
                    ? null
                    : () => _handleAdClaim(context, kugou),
                icon: kugou.adClaimRunning
                    ? M3ELoadingIndicator(
                        constraints: BoxConstraints.tightFor(
                          width: 16,
                          height: 16,
                        ),
                        color: cs.onSecondaryContainer,
                      )
                    : const Icon(Icons.monetization_on_outlined, size: 16),
                label: Text(kugou.adClaimRunning ? '领取中' : '广告领取'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // 仅签到异常时点击 —— 提示语
          Text(
            '仅签到异常时点击',
            style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Future<void> _handleManualSignIn(
    BuildContext context,
    KugouProvider kugou,
  ) async {
    final (_, msg) = await kugou.manualSignIn();
    showToast(msg, long: true);
  }

  Future<void> _handleListenClaim(
    BuildContext context,
    KugouProvider kugou,
  ) async {
    final (_, msg) = await kugou.listenSongClaim();
    showToast(msg, long: true);
  }

  Future<void> _handleAdClaim(
    BuildContext context,
    KugouProvider kugou,
  ) async {
    final (_, msg) = await kugou.claimAdVip();
    showToast(msg, long: true);
  }

  /// 20028 二次安全验证弹窗：WebView 加载本地滑块验证码页面（腾讯 TCaptcha），
  /// 验证通过后把 verifycode 回传给 provider，由 provider 调 /verify/user/info 并重试签到。
  Future<void> _showVerifyCaptchaDialog(
    BuildContext context,
    KugouProvider kugou,
    VerifyCaptchaRequest pending,
  ) async {
    final controller = WebViewController();
    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'CaptchaChannel',
        onMessageReceived: (message) {
          final data = message.message;
          print('[CAPTCHA] channel: $data');
          if (data == '__READY__') {
            // 页面 JS 就绪信号：注入 txappid 拉起验证码（比 onPageFinished 更可靠）
            controller.runJavaScript(
              'window.initCaptcha && initCaptcha(${pending.txappid})',
            );
            return;
          }
          if (data == '__CANCEL__' || data == '__ERROR__') {
            kugou.cancelVerifyCaptcha();
          } else {
            kugou.completeVerifyCaptcha(data);
          }
          if (context.mounted) Navigator.of(context).pop();
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            // 页面加载完成后注入 txappid 并拉起腾讯验证码
            controller.runJavaScript(
              'window.initCaptcha && initCaptcha(${pending.txappid})',
            );
          },
          onWebResourceError: (_) {
            // 页面/资源加载失败：取消验证，避免白框卡死
            kugou.cancelVerifyCaptcha();
            if (context.mounted) Navigator.of(context).pop();
          },
        ),
      )
      ..loadFlutterAsset('assets/web/verify_captcha.html');

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 标题栏 + 关闭按钮（验证码弹不出时用户可退出，避免白框卡死）
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '安全验证',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: '取消验证',
                    onPressed: () {
                      kugou.cancelVerifyCaptcha();
                      Navigator.of(dialogContext).pop();
                    },
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            SizedBox(
              width: 360,
              height: 400,
              child: WebViewWidget(controller: controller),
            ),
          ],
        ),
      ),
    );

    _captchaDialogShowing = false;
    // 弹窗关闭但验证仍未完成（流程中断/超时）→ 取消，避免 completer 悬挂
    if (kugou.pendingVerifyCaptcha != null) {
      kugou.cancelVerifyCaptcha();
    }
  }

  Widget _buildWeekdayHeader(ColorScheme cs) {
    const labels = ['一', '二', '三', '四', '五', '六', '日'];
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Row(
        children: [
          for (final l in labels)
            Expanded(
              child: Center(
                child: Text(
                  l,
                  style: tt.labelSmall?.copyWith(
                    color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStatFooter(ColorScheme cs, TextTheme tt, int receivedCount) {
    final now = DateTime.now();
    final daysInMonth = DateTime(now.year, now.month + 1, 0).day;
    final progress = receivedCount / daysInMonth;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          // 进度环
          SizedBox(
            width: 56,
            height: 56,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 56,
                  height: 56,
                  child: M3ECircularProgressIndicator(
                    size: 56,
                    value: progress,
                    strokeWidth: 4,
                    backgroundColor: cs.surfaceContainerLow,
                    color: cs.primary,
                  ),
                ),
                Text(
                  '${(progress * 100).round()}%',
                  style: tt.labelSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: cs.primary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          // 文字统计
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '本月已打卡',
                  style: tt.labelMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 2),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      '$receivedCount',
                      style: tt.headlineMedium?.copyWith(
                        color: cs.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '/ $daysInMonth 天',
                      style: tt.labelMedium?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // 连续打卡激励
          if (receivedCount > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                color: cs.secondaryContainer,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.local_fire_department,
                    size: 14,
                    color: cs.onSecondaryContainer,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '坚持中',
                    style: tt.labelSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: cs.onSecondaryContainer,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCalendarGrid(
    ColorScheme cs,
    int year,
    int month,
    int leading,
    int daysInMonth,
    Set<int> receivedDays,
    DateTime now,
  ) {
    final tt = Theme.of(context).textTheme;
    final rows = <Widget>[];
    var cells = <Widget>[];

    void addCell(Widget w) {
      cells.add(w);
      if (cells.length == 7) {
        rows.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: cells),
          ),
        );
        cells = [];
      }
    }

    Widget buildEmptyCell() {
      return Expanded(
        child: AspectRatio(aspectRatio: 1, child: const SizedBox()),
      );
    }

    for (var i = 0; i < leading; i++) {
      addCell(buildEmptyCell());
    }
    for (var day = 1; day <= daysInMonth; day++) {
      final isReceived = receivedDays.contains(day);
      final isToday = day == now.day;
      final isFuture = day > now.day;
      addCell(
        Expanded(
          child: AspectRatio(
            aspectRatio: 1,
            child: Center(
              child: SizedBox(
                width: 32,
                height: 32,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // 背景圆
                    Container(
                      width: double.infinity,
                      height: double.infinity,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isReceived
                            ? cs.primary
                            : (isToday
                                  ? cs.primary.withValues(alpha: 0.1)
                                  : Colors.transparent),
                        border: isToday && !isReceived
                            ? Border.all(color: cs.primary, width: 2)
                            : null,
                      ),
                    ),
                    // 签到勾选图标覆盖层
                    if (isReceived)
                      Positioned(
                        bottom: -2,
                        right: -2,
                        child: Container(
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: cs.secondary,
                            border: Border.all(color: cs.surface, width: 1.5),
                          ),
                          child: Icon(
                            Icons.check,
                            size: 9,
                            color: cs.onSecondary,
                          ),
                        ),
                      ),
                    // 日期文字
                    Text(
                      '$day',
                      style: tt.bodySmall?.copyWith(
                        fontWeight: isToday || isReceived
                            ? FontWeight.w700
                            : null,
                        color: isReceived
                            ? cs.onPrimary
                            : (isToday
                                  ? cs.primary
                                  : (isFuture
                                        ? cs.onSurfaceVariant.withValues(
                                            alpha: 0.35,
                                          )
                                        : cs.onSurface)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    while (cells.isNotEmpty && cells.length < 7) {
      addCell(buildEmptyCell());
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }

  DateTime? _parseReceivedYearMonthDay(Map<String, dynamic> item) {
    // 实际返回结构: {"day":"2026-06-07","receive_vip":1,"vip_type":"tvip",...}
    final day = item['day'];
    if (day is String) {
      final m = RegExp(r'^(\d{4})[-/](\d{1,2})[-/](\d{1,2})').firstMatch(day);
      if (m != null) {
        return DateTime(
          int.parse(m.group(1)!),
          int.parse(m.group(2)!),
          int.parse(m.group(3)!),
        );
      }
    }
    if (day is int && day > 1000000000) {
      final ms = day > 1e12 ? day : day * 1000;
      return DateTime.fromMillisecondsSinceEpoch(ms);
    }
    return null;
  }
}
