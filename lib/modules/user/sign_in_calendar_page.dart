import 'package:material_ui/material_ui.dart';
import 'package:intl/intl.dart';
import 'package:m3e_core/m3e_core.dart';
import '../../widgets/md3_pull_to_refresh.dart';
import 'package:provider/provider.dart';
import '../../widgets/verify_captcha_dialog.dart';

import '../../core/theme/app_dimens.dart';
import '../../core/utils/app_toast.dart';
import '../../providers/kugou_provider.dart';
import 'vip_status.dart';

/// 签到日历二级页面：从「我的」页面会员卡片左侧入口进入。
///
/// 原来日历直接挂在「我的」页面底部，挤压了页面主体；这里独立成页，
/// 签到 / 听歌领取 / 广告领取 三个按钮以及 20028 二次安全验证弹窗
/// 都随日历一起迁移到本页（这些入口只在本页出现）。
class SignInCalendarPage extends StatefulWidget {
  const SignInCalendarPage({super.key});

  @override
  State<SignInCalendarPage> createState() => _SignInCalendarPageState();
}

class _SignInCalendarPageState extends State<SignInCalendarPage> {
  /// 防止验证码弹窗被多次触发（pendingVerifyCaptcha 存在期间只弹一次）
  bool _captchaDialogShowing = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('签到日历')),
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
          return Md3PullToRefresh(
            onRefresh: () async {
              await kugou.getVipMonthRecord();
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.lg,
                AppSpacing.lg,
                80,
              ),
              children: [_buildVipCalendar(cs, tt, kugou, context)],
            ),
          );
        },
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

    return Center(
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
              const Gap(AppSpacing.lg),
              _buildWeekdayHeader(cs),
              const Gap(AppSpacing.sm),
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
              const Gap(AppSpacing.md),
              _buildVipExpirySection(cs, tt, kugou),
            ],
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
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xs,
        vertical: AppSpacing.xs,
      ),
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
          const Gap(AppSpacing.sm),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                    vertical: 6,
                  ),
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
              const Gap(AppSpacing.sm),
              FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                    vertical: 6,
                  ),
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
              const Gap(AppSpacing.sm),
              FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                    vertical: 6,
                  ),
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
          const Gap(AppSpacing.xs),
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
    try {
      final code = await showVerifyCaptchaDialog(context,
        txappid: pending.txappid);
      if (code == null) {
        kugou.cancelVerifyCaptcha();
      } else {
        kugou.completeVerifyCaptcha(code);
      }
    } finally {
      _captchaDialogShowing = false;
      if (!pending.completer.isCompleted) kugou.cancelVerifyCaptcha();
    }
  }

  Widget _buildWeekdayHeader(ColorScheme cs) {
    const labels = ['一', '二', '三', '四', '五', '六', '日'];
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxs),
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
      padding: const EdgeInsets.symmetric(
        vertical: AppSpacing.lg,
        horizontal: AppSpacing.lg,
      ),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: AppRadius.lgAll,
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
          const Gap(AppSpacing.lg),
          // 文字统计
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '本月已打卡',
                  style: tt.labelMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
                const Gap(AppSpacing.xxs),
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
                    const Gap(AppSpacing.xs),
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
                  const Gap(AppSpacing.xs),
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

  /// 日历下方的会员到期区块：列出畅听/概念会员的具体到期时间。
  Widget _buildVipExpirySection(
    ColorScheme cs,
    TextTheme tt,
    KugouProvider kugou,
  ) {
    final busiList = kugou.vipInfo?.busiVipList;
    return Container(
      padding: const EdgeInsets.symmetric(
        vertical: AppSpacing.lg,
        horizontal: AppSpacing.lg,
      ),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: AppRadius.lgAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '会员到期时间',
            style: tt.labelMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
          const Gap(AppSpacing.md),
          _buildExpiryRow(
            tt,
            cs,
            '畅听会员',
            findActiveBusiVip(busiList, 'tvip'),
          ),
          const Gap(AppSpacing.sm),
          _buildExpiryRow(
            tt,
            cs,
            '概念会员',
            findActiveBusiVip(busiList, 'svip'),
          ),
        ],
      ),
    );
  }

  /// 单行会员到期信息：相对时间优先，右侧展示具体到期日期；未开通显示「未开通」。
  Widget _buildExpiryRow(
    TextTheme tt,
    ColorScheme cs,
    String title,
    Map<String, dynamic>? active,
  ) {
    final endTime = active?['vip_end_time']?.toString();
    final relText = active != null ? formatVipExpireText(endTime) : null;
    final absText = active != null ? formatVipDateTime(endTime) : null;
    final dimmed = active == null;
    final status = dimmed
        ? '未开通'
        : (relText != null ? '$relText · $absText' : '$absText');
    return Row(
      children: [
        Text(
          title,
          style: tt.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
            color: dimmed ? cs.onSurfaceVariant : null,
          ),
        ),
        const Gap(AppSpacing.sm),
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
