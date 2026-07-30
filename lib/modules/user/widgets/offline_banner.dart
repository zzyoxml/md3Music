import 'package:flutter/material.dart';

/// 「我的收藏」页顶部离线模式提示横幅。
///
/// 仅在网络异常且本地有上次同步的数据时显示。点击可手动触发刷新（由父级 onTap 注入）。
class OfflineBanner extends StatelessWidget {
  final DateTime? lastSyncTime;
  final VoidCallback? onRetry;

  const OfflineBanner({
    super.key,
    required this.lastSyncTime,
    this.onRetry,
  });

  String _formatTime(DateTime? t) {
    if (t == null) return '未知';
    final local = t.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final lastSync = lastSyncTime;
    final label = lastSync == null
        ? '离线模式'
        : '离线模式 · 上次同步于 ${_formatTime(lastSync)}';

    return Material(
      color: colorScheme.errorContainer.withValues(alpha: 0.85),
      child: InkWell(
        onTap: onRetry,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(
                Icons.cloud_off_outlined,
                size: 18,
                color: colorScheme.onErrorContainer,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onErrorContainer,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (onRetry != null)
                Text(
                  '点击重试',
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onErrorContainer,
                    decoration: TextDecoration.underline,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
