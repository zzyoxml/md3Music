import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:m3e_core/m3e_core.dart';
import '../../widgets/md3_pull_to_refresh.dart';
import 'package:provider/provider.dart';

import '../../core/utils/app_toast.dart';
import '../../data/models/kugou_account.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/kugou_provider.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/scroll_aware_app_bar.dart';
import '../login/login_page.dart';
import '../settings/settings_page.dart';
import 'cloud_music_page.dart';
import 'listen_ranking_page.dart';
import 'play_history_page.dart';
import 'purchased_page.dart';
import 'sign_in_calendar_page.dart';
import 'vip_status.dart';

class UserCenterPage extends StatefulWidget {
  /// 可选扩展：用户中心快捷操作网格的额外条目（默认关闭，由私有构建注入）。
  /// 返回的 Widget 追加在操作网格 Row 末尾。
  static List<Widget> Function(BuildContext context, ColorScheme cs)?
      extraActionItemsBuilder;

  const UserCenterPage({super.key});

  @override
  State<UserCenterPage> createState() => _UserCenterPageState();
}

class _UserCenterPageState extends State<UserCenterPage> {
  /// 顶栏渐变 ScrollController：与 ScrollAwareAppBar 共享
  final ScrollController _scrollController = ScrollController();

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
        // 有壁纸时顶栏完全透明（与发现页一致），无壁纸时恒不透明 surface
        opaque: true,
        tabId: 'user',
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
          if (!kugou.isLoggedIn) return _buildNotLoggedIn(cs, tt);
          return Md3PullToRefresh(
            onRefresh: () async {
              await kugou.getVipDetail();
              await kugou.getVipMonthRecord();
              await kugou.getGradeInfo();
            },
            child: CustomScrollView(
              controller: _scrollController,
              // 内容不满屏时也允许下拉触发刷新
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                _buildUserHeader(cs, tt, kugou),
                const SliverToBoxAdapter(child: SizedBox(height: 16)),
                _buildActionGrid(cs),
                const SliverToBoxAdapter(child: SizedBox(height: 16)),
                _buildVipCard(cs, tt, kugou),
                // 80 之上叠加系统手势条（小横条）高度，避免末项被压住
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 80 + MediaQuery.paddingOf(context).bottom,
                  ),
                ),
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
    const double radius = 32;

    if (avatarUrl == null || avatarUrl.isEmpty) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: cs.primary.withValues(alpha: 0.2),
        child: Icon(
          Icons.person,
          size: 32,
          color: cs.onPrimaryContainer,
        ),
      );
    }

    // 修复：使用更安全的缓存键，避免 userId 为 null 导致的问题
    final safeUserId = userId.toString().replaceAll(
      RegExp(r'[^a-zA-Z0-9]'),
      '_',
    );
    final cacheKey = 'avatar_$safeUserId';

    return CircleAvatar(
      radius: radius,
      backgroundColor: cs.primary.withValues(alpha: 0.2),
      child: ClipOval(
        child: CachedNetworkImage(
          imageUrl: avatarUrl,
          memCacheWidth: 192,
          memCacheHeight: 192,
          cacheKey: cacheKey,
          width: radius * 2,
          height: radius * 2,
          fit: BoxFit.cover,
          placeholder: (context, url) =>
              Icon(Icons.person, size: 32, color: cs.onPrimaryContainer),
          errorWidget: (context, url, error) =>
              Icon(Icons.person, size: 32, color: cs.onPrimaryContainer),
        ),
      ),
    );
  }

  // ── 用户卡片版式基准值 ──
  // 头像：直径 64 + 3 描边 = 70，左上角外移 (-8, -18)，圆心落在卡片内 (27, 17)。
  static const double _kAvatarRadius = 32;
  static const double _kAvatarOverhangX = 8;
  static const double _kAvatarOverhangY = 18;
  static const double _kAvatarRing = 3;
  /// 头像让位宽度：内容左缘 = 20 + 52 = 72，与头像右缘（62）留 10 呼吸位。
  /// 这条线同时是 LV 文字与进度条的左对齐基准。
  static const double _kAvatarGutter = 52;
  static const double _kCardPadH = 20;

  Widget _buildUserHeader(ColorScheme cs, TextTheme tt, KugouProvider kugou) {
    final grade = kugou.gradeInfo;
    final ring = _kAvatarRing;
    final overhangX = _kAvatarOverhangX;
    final overhangY = _kAvatarOverhangY;
    final gutter = _kAvatarGutter;
    // 头像圆心（相对卡片左上角），供光环定位
    final haloCx = _kAvatarRadius + ring - overhangX;
    final haloCy = _kAvatarRadius + ring - overhangY;

    return SliverToBoxAdapter(
      child: Padding(
        // 顶部留出空间容纳超出卡片的头像
        padding: EdgeInsets.fromLTRB(16, 28, 16, 16),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Material(
              color: cs.primaryContainer,
              clipBehavior: Clip.antiAlias,
              // 对角加大圆角：左上让位圆形头像，右下承接昵称块，四角不等而对角自洽
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(32),
                topRight: Radius.circular(20),
                bottomLeft: Radius.circular(20),
                bottomRight: Radius.circular(32),
              ),
              child: Stack(
                children: [
                  // 与头像同心的两道弧，被卡片裁去大半，只在左上留下扩散感
                  _buildAvatarHalo(
                    cs,
                    cx: haloCx,
                    cy: haloCy,
                    radius: 98,
                    alpha: 0.11,
                  ),
                  _buildAvatarHalo(
                    cs,
                    cx: haloCx,
                    cy: haloCy,
                    radius: 146,
                    alpha: 0.06,
                  ),
                  InkWell(
                    onTap: () => _showAccountManager(context, kugou),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        _kCardPadH,
                        18,
                        _kCardPadH,
                        12,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(width: gutter),
                              Expanded(
                                // 无等级数据时占住等级行的高度，避免卡片塌到头像里
                                child: grade == null
                                    ? SizedBox(height: 38)
                                    : _buildGradeInfo(
                                        cs,
                                        tt,
                                        grade,
                                        kugou.unreportedSeconds,
                                      ),
                              ),
                              Padding(
                                // 下移至与等级数字视觉中心齐平
                                padding: const EdgeInsets.only(top: 7),
                                child: Icon(
                                  Icons.chevron_right,
                                  size: 20,
                                  color: cs.onPrimaryContainer.withValues(
                                    alpha: 0.5,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (grade != null) ...[
                            const SizedBox(height: 14),
                            // 进度条故意不满宽：左缘咬住等级文字，右缘咬住昵称，
                            // 成为左上与右下两块之间的一道横向连接
                            Padding(
                              padding: EdgeInsets.only(left: gutter),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(99),
                                child: M3ELinearProgressIndicator(
                                  value: _gradeProgress(grade),
                                  minHeight: 6,
                                  backgroundColor: cs.onPrimaryContainer
                                      .withValues(alpha: 0.15),
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    cs.primary,
                                  ),
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(height: 12),
                          Text(
                            kugou.userInfo?.nickname ?? '用户',
                            textAlign: TextAlign.right,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: tt.titleLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                              height: 1.15,
                              color: cs.onPrimaryContainer,
                            ),
                          ),
                          Text(
                            'ID: ${kugou.userid ?? ''}',
                            textAlign: TextAlign.right,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: tt.labelSmall?.copyWith(
                              letterSpacing: 0.4,
                              color: cs.onPrimaryContainer.withValues(
                                alpha: 0.6,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // 头像：左上角，略微超出卡片
            Positioned(
              left: -overhangX,
              top: -overhangY,
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: cs.surface, width: ring),
                  boxShadow: [
                    BoxShadow(
                      color: cs.shadow.withValues(alpha: 0.16),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: _buildUserAvatar(kugou, cs),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 与头像同心的装饰圆环，超出卡片的部分由卡片裁掉
  Widget _buildAvatarHalo(
    ColorScheme cs, {
    required double cx,
    required double cy,
    required double radius,
    required double alpha,
  }) {
    return Positioned(
      left: cx - radius,
      top: cy - radius,
      width: radius * 2,
      height: radius * 2,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: cs.onPrimaryContainer.withValues(alpha: alpha),
            width: 1.5,
          ),
        ),
      ),
    );
  }

  /// 升级进度：当前经验 / 下一等级经验
  double _gradeProgress(KugouGradeInfo grade) {
    final cur = (grade.pCurrentPoint ?? 0).toDouble();
    final next = (grade.pNextGradePoint ?? 1).toDouble();
    return next > 0 ? (cur / next).clamp(0.0, 1.0) : 0.0;
  }

  /// 听歌等级信息：LV + 累计时长 + 未上报时长（≥5分钟显示）。
  /// 三种字号共用同一条基线：层级刻意拉开，落点仍然统一。
  Widget _buildGradeInfo(
    ColorScheme cs,
    TextTheme tt,
    KugouGradeInfo grade,
    int unreportedSec,
  ) {
    final sec = grade.dSec ?? grade.duration ?? 0;
    final gradeNum = grade.pGrade ?? 0;
    final showUnreported = unreportedSec >= 300; // 5 分钟
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              'LV',
              style: tt.labelSmall?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: 1.6,
                color: cs.onPrimaryContainer.withValues(alpha: 0.55),
              ),
            ),
            const SizedBox(width: 3),
            Text(
              '$gradeNum',
              style: tt.headlineMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: cs.onPrimaryContainer,
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                _formatGradeSeconds(sec),
                style: tt.labelMedium?.copyWith(
                  color: cs.onPrimaryContainer.withValues(alpha: 0.75),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        if (showUnreported)
          Text(
            '未上报 ${_formatGradeSeconds(unreportedSec)}',
            style: tt.labelSmall?.copyWith(color: cs.error),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
      ],
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
        radius: 20,
        backgroundColor: cs.primary.withValues(alpha: 0.15),
        child: fallback,
      );
    }
    final safeUserId = account.userid.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
    return CircleAvatar(
      radius: 20,
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

  /// 会员卡片：左侧签到日历入口 + 右侧两种会员紧凑排布。
  ///
  /// 日历本体已移到 [SignInCalendarPage]（原来直接挂在本页底部）。
  Widget _buildVipCard(ColorScheme cs, TextTheme tt, KugouProvider kugou) {
    final vip = kugou.vipInfo;
    final busiList = vip?.busiVipList;
    final tvip = findActiveBusiVip(busiList, 'tvip');
    final svip = findActiveBusiVip(busiList, 'svip');
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          // 实心纯色圆角矩形：不描边
          color: cs.surfaceContainer,
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(
          color: Colors.transparent,
          // 整卡可点击进入签到日历页
          child: InkWell(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SignInCalendarPage()),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              // IntrinsicHeight：让左侧入口与右侧两行会员等高
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildCalendarEntry(cs, tt),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
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
                          const SizedBox(height: 8),
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
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 签到日历展示位：仅做视觉提示，点击由整张会员卡片统一处理。
  Widget _buildCalendarEntry(ColorScheme cs, TextTheme tt) {
    return Container(
      width: 76,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.event_available, color: cs.primary),
          const SizedBox(height: 4),
          Text(
            '签到日历',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: tt.labelMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  /// 单行会员状态（移植自 EchoMusic Profile.vue「会员状态」卡片）：
  /// 紧凑排布——图标 + 名称在左，到期信息在右侧一行内（相对时间优先，
  /// 解析不出相对时间时退回具体到期时间），未开通显示「未开通」。
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
    final status = dimmed ? '未开通' : (relText ?? '$absText');
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: dimmed ? cs.surfaceContainerHighest : iconBg,
          ),
          child: Icon(
            icon,
            size: 16,
            color: dimmed ? cs.onSurfaceVariant : iconFg,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          title,
          style: tt.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
            color: dimmed ? cs.onSurfaceVariant : null,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            status,
            textAlign: TextAlign.right,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: tt.bodySmall?.copyWith(
              color: dimmed
                  ? cs.onSurfaceVariant.withValues(alpha: 0.7)
                  : cs.onSurfaceVariant,
            ),
          ),
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
            _actionItem(cs, Icons.shopping_bag_outlined, '已购', () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PurchasedPage()),
              );
            }),
            // 可选扩展：私有构建注入的额外操作项（默认无）
            ...?UserCenterPage.extraActionItemsBuilder?.call(context, cs),
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
}
