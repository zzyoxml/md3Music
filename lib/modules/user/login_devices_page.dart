import 'package:dpad/dpad.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../core/build_flags.dart';
import '../../core/layout/page_layout.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/utils/app_toast.dart';
import '../../providers/kugou_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/md3_pull_to_refresh.dart';

/// 登录设备管理：展示当前登录账号的全部登录设备，支持把非本机设备踢下线。
/// 数据来自 /login/device（酷狗 get_dev），作用域天然是当前 token/userid ——
/// 只能管理当前登录账号的设备，与其他已保存账号无关。
class LoginDevicesPage extends StatefulWidget {
  const LoginDevicesPage({super.key});

  @override
  State<LoginDevicesPage> createState() => _LoginDevicesPageState();
}

class _LoginDevicesPageState extends State<LoginDevicesPage> {
  KugouLoginDeviceSnapshot? _snapshot;
  bool _loading = true;
  bool _refreshing = false;
  String? _error;

  /// 正在被踢下线的设备 mid（展示行内 loading 并禁点，防重复提交）。
  String? _kickingMid;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    final kugou = context.read<KugouProvider>();
    if (!kugou.isLoggedIn) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '当前未登录，请先登录后再管理设备';
      });
      return;
    }
    final snap = await kugou.apiClient.getLoginDevices();
    if (!mounted) return;
    setState(() {
      _refreshing = false;
      _snapshot = snap;
      _loading = false;
      _error = snap == null
          ? '获取登录设备失败，请检查网络后重试'
          : (snap.ok ? null : '获取登录设备失败，登录状态可能已失效');
    });
  }

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    await _fetch();
  }

  Future<void> _confirmKick(KugouLoginDevice device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移除登录设备'),
        content: Text('移除「${device.title}」后，该设备需要重新登录。'),
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
            child: const Text('确认移除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _kick(device);
  }

  Future<void> _kick(KugouLoginDevice device) async {
    setState(() => _kickingMid = device.mid);
    try {
      final resp = await context.read<KugouProvider>().apiClient.kickLoginDevice(
            tMid: device.mid,
            t: device.t,
            tAppid: device.appid,
            tClientver: device.ver,
          );
      final ok = resp != null && KugouApiClient.isBizOk(resp);
      if (!mounted) return;
      if (ok) {
        showToast('已移除「${device.title}」');
        await _fetch();
      } else {
        showToast('移除失败，请稍后重试');
      }
    } finally {
      if (mounted) setState(() => _kickingMid = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('登录设备管理')),
      body: ContentWidth(
        child: _loading
            ? const Center(child: M3ELoadingIndicator())
            : Md3PullToRefresh(
                onRefresh: _fetch,
                child: _buildList(context, cs),
              ),
      ),
    );
  }

  Widget _buildList(BuildContext context, ColorScheme cs) {
    final tt = Theme.of(context).textTheme;
    final snap = _snapshot;
    if (_error != null || snap == null) {
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
            _error ?? '获取登录设备失败',
            textAlign: TextAlign.center,
            style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
          const Gap(AppSpacing.lg),
          Center(
            child: OutlinedButton.icon(
              onPressed: _refresh,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ),
        ],
      );
    }
    if (snap.devices.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        children: [
          const Gap(AppSpacing.xxl),
          Icon(
            Icons.devices_other,
            size: 48,
            color: cs.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const Gap(AppSpacing.sm),
          Text(
            '暂无登录设备记录',
            textAlign: TextAlign.center,
            style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(AppSpacing.lg),
      itemCount: snap.devices.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) return _summaryHeader(context, cs, tt, snap.devices.length);
        return _deviceCard(context, cs, tt, snap.devices[i - 1]);
      },
    );
  }

  Widget _summaryHeader(
    BuildContext context,
    ColorScheme cs,
    TextTheme tt,
    int count,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '当前账号已登录 $count 台设备',
              style: tt.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: cs.onSurface,
              ),
            ),
          ),
          if (_refreshing)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            IconButton(
              tooltip: '刷新',
              onPressed: _refresh,
              icon: Icon(Icons.refresh, color: cs.onSurfaceVariant),
            ),
        ],
      ),
    );
  }

  Widget _deviceCard(
    BuildContext context,
    ColorScheme cs,
    TextTheme tt,
    KugouLoginDevice device,
  ) {
    final isKicking = _kickingMid != null && _kickingMid == device.mid;
    final detailParts = <String>[
      if (device.loginTypeLabel.isNotEmpty) device.loginTypeLabel,
      if (device.platform.isNotEmpty) device.platform,
    ];
    final activityParts = <String>[
      if (device.activeTimeText.isNotEmpty) '活跃于 ${device.activeTimeText}',
      if (device.locationLabel.isNotEmpty) device.locationLabel,
    ];

    final card = Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: AppRadius.lgAll,
        border: device.isCurrent
            ? Border.all(color: cs.primary.withValues(alpha: 0.35))
            : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: device.isCurrent
                  ? cs.primaryContainer
                  : cs.surfaceContainerHighest,
              borderRadius: AppRadius.mdAll,
            ),
            child: Icon(
              Icons.smartphone,
              size: 20,
              color: device.isCurrent
                  ? cs.onPrimaryContainer
                  : cs.onSurfaceVariant,
            ),
          ),
          const Gap(AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        device.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: tt.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: cs.onSurface,
                        ),
                      ),
                    ),
                    if (device.isCurrent) ...[
                      const Gap(AppSpacing.xs),
                      _deviceTag(
                        '本机',
                        cs.primaryContainer,
                        cs.onPrimaryContainer,
                      ),
                    ] else if (device.isNew) ...[
                      const Gap(AppSpacing.xs),
                      _deviceTag('新设备', cs.tertiaryContainer,
                          cs.onTertiaryContainer),
                    ],
                  ],
                ),
                if (detailParts.isNotEmpty) ...[
                  const Gap(2),
                  Text(
                    detailParts.join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
                if (activityParts.isNotEmpty) ...[
                  const Gap(2),
                  Text(
                    activityParts.join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
          if (device.canKick) ...[
            const Gap(AppSpacing.sm),
            _kickButton(context, cs, tt, device, isKicking),
          ],
        ],
      ),
    );
    return card;
  }

  /// 「移除」按钮：TV 下按项目约定包 DpadFocusable 单停点（OK 走同一确认流程）。
  Widget _kickButton(
    BuildContext context,
    ColorScheme cs,
    TextTheme tt,
    KugouLoginDevice device,
    bool isKicking,
  ) {
    void onRequest() {
      if (!isKicking) _confirmKick(device);
    }

    final visual = isKicking
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
    if (isKicking) return visual;

    if (kTvBuild) {
      return DpadFocusable(
        debugLabel: 'login-devices/kick-${device.mid}',
        onSelect: onRequest,
        child: visual,
      );
    }
    return visual;
  }

  Widget _deviceTag(String label, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xs,
        vertical: 1,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: AppRadius.smAll,
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: fg,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}
