import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../providers/kugou_provider.dart';
import '../../widgets/app_animation.dart';
import '../login/login_page.dart';
import '../settings/settings_page.dart';
import 'downloads_page.dart';
import 'favorites_page.dart';
import 'play_history_page.dart';

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
        kugou.getVipMonthRecord();
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
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SettingsPage())),
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
              await kugou.getVipMonthRecord();
            },
            child: CustomScrollView(
              slivers: [
                _buildUserHeader(cs, tt, kugou),
                _buildVipCard(cs, tt, kugou),
                const SliverToBoxAdapter(child: SizedBox(height: 16)),
                _buildActionGrid(cs),
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
    final userId = kugou.userInfo?.userid ?? 'default';
    
    if (avatarUrl == null || avatarUrl.isEmpty) {
      return CircleAvatar(
        radius: 32,
        backgroundColor: cs.primary.withValues(alpha: 0.2),
        child: Icon(Icons.person, size: 32, color: cs.onPrimaryContainer),
      );
    }
    
    return CircleAvatar(
      radius: 32,
      backgroundColor: cs.primary.withValues(alpha: 0.2),
      child: ClipOval(
        child: CachedNetworkImage(
          imageUrl: avatarUrl,
          cacheKey: 'avatar_$userId',
          width: 64,
          height: 64,
          fit: BoxFit.cover,
          placeholder: (context, url) => Icon(
            Icons.person,
            size: 32,
            color: cs.onPrimaryContainer,
          ),
          errorWidget: (context, url, error) => Icon(
            Icons.person,
            size: 32,
            color: cs.onPrimaryContainer,
          ),
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
              _buildUserAvatar(kugou, cs),
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
              _actionItem(cs, Icons.history, '历史', () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const PlayHistoryPage()),
                );
              }),
              _actionItem(cs, Icons.favorite, '收藏', () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const FavoritesPage()),
                );
              }),
              _actionItem(cs, Icons.download, '下载', () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const DownloadsPage()),
                );
              }),
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
            final dm = _parseReceivedYearMonthDay(item);
            if (dm != null && dm.year == curYear && dm.month == curMonth) {
              receivedDays.add(dm.day);
            }
          }
        }
      }
    }
    final monthLabel = DateFormat('yyyy 年 M 月', 'zh_CN').format(now);
    final daysInMonth = DateTime(curYear, curMonth + 1, 0).day;
    // weekday: Mon=1..Sun=7 → 周一开头 0 个前导
    final leading = DateTime(curYear, curMonth, 1).weekday - 1;

    return SliverToBoxAdapter(
      child: FadeInUp(
        delayMs: 80,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              decoration: BoxDecoration(
                color: cs.surfaceContainerLow,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildCalendarHeader(cs, tt, monthLabel, kugou, context),
                  const SizedBox(height: 8),
                  _buildWeekdayHeader(cs),
                  const SizedBox(height: 4),
                  _buildCalendarGrid(
                    cs,
                    curYear,
                    curMonth,
                    leading,
                    daysInMonth,
                    receivedDays,
                    now,
                  ),
                  const SizedBox(height: 12),
                  _buildStatFooter(cs, tt, receivedDays.length),
                ],
              ),
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
      child: Row(
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            icon: const Icon(Icons.chevron_left),
            color: cs.onSurfaceVariant,
            onPressed: () {},
          ),
          Expanded(
            child: Text(
              monthLabel,
              textAlign: TextAlign.center,
              style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            icon: const Icon(Icons.chevron_right),
            color: cs.onSurfaceVariant,
            onPressed: () {},
          ),
          const SizedBox(width: 4),
          FilledButton.tonalIcon(
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              minimumSize: const Size(0, 32),
              textStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            onPressed: kugou.manualSignInRunning
                ? null
                : () => _handleManualSignIn(context, kugou),
            icon: kugou.manualSignInRunning
                ? SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: cs.onPrimaryContainer,
                    ),
                  )
                : const Icon(Icons.check_circle_outline, size: 16),
            label: Text(kugou.manualSignInRunning ? '签到中' : '签到'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleManualSignIn(
    BuildContext context,
    KugouProvider kugou,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final (ok, msg) = await kugou.manualSignIn();
    messenger.showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        backgroundColor: ok
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.errorContainer,
      ),
    );
  }

  Widget _buildWeekdayHeader(ColorScheme cs) {
    const labels = ['一', '二', '三', '四', '五', '六', '日'];
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: labels.map((l) {
          return Expanded(
            child: Center(
              child: Text(
                l,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildStatFooter(ColorScheme cs, TextTheme tt, int receivedCount) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Text(
            '截至目前，你已坚持打卡',
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '$receivedCount',
                style: tt.displaySmall?.copyWith(
                  color: cs.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                '天',
                style: tt.titleMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '请再接再厉，继续努力',
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
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
    const cellSize = 40.0;
    final rows = <Widget>[];
    var cells = <Widget>[];

    void addCell(Widget w) {
      cells.add(w);
      if (cells.length == 7) {
        rows.add(Row(children: cells));
        cells = [];
      }
    }

    for (var i = 0; i < leading; i++) {
      addCell(const SizedBox(width: cellSize, height: cellSize));
    }
    for (var day = 1; day <= daysInMonth; day++) {
      final isReceived = receivedDays.contains(day);
      final isToday = day == now.day;
      addCell(
        SizedBox(
          width: cellSize,
          height: cellSize,
          child: Center(
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isReceived ? cs.primary : Colors.transparent,
                border: isToday && !isReceived
                    ? Border.all(color: cs.primary, width: 1.5)
                    : null,
              ),
              alignment: Alignment.center,
              child: Text(
                '$day',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isToday || isReceived
                      ? FontWeight.w600
                      : FontWeight.normal,
                  color: isReceived ? cs.onPrimary : cs.onSurface,
                ),
              ),
            ),
          ),
        ),
      );
    }
    while (cells.isNotEmpty && cells.length < 7) {
      addCell(const SizedBox(width: cellSize, height: cellSize));
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
