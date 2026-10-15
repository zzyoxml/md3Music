import 'dart:io' show Platform;

import 'package:material_ui/material_ui.dart';

/// 本地 API 服务不可用时说明在线内容受限，并允许用户原地重试。
class LocalServerDownBanner extends StatefulWidget {
  const LocalServerDownBanner({super.key, required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  State<LocalServerDownBanner> createState() => _LocalServerDownBannerState();
}

class _LocalServerDownBannerState extends State<LocalServerDownBanner> {
  bool _retrying = false;

  Future<void> _retry() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      await widget.onRetry();
    } catch (_) {
      // 服务层维护失败状态；提示条继续显示，用户可稍后再次重试。
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    // 文件名要跟本平台真实产物一致：Android 是 libkugou_server.so，.dll 只在 Windows 构建存在
    final hint = Platform.isWindows
        ? '本地数据接口未启动，在线内容不可用（可能缺少 kugou_server.dll）'
        : Platform.isAndroid
        ? '本地数据接口未启动，在线内容不可用（libkugou_server.so 没跑起来，点右边按钮再试一次）'
        : '本地数据接口未启动，在线内容不可用';

    return Material(
      color: colorScheme.errorContainer.withValues(alpha: 0.85),
      child: Padding(
        padding: const EdgeInsets.only(left: 16, right: 8, top: 4, bottom: 4),
        child: Row(
          children: [
            Icon(
              Icons.dns_outlined,
              size: 18,
              color: colorScheme.onErrorContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                hint,
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onErrorContainer,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            IconButton(
              tooltip: '重试本地接口',
              onPressed: _retrying ? null : _retry,
              icon: _retrying
                  ? SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colorScheme.onErrorContainer,
                      ),
                    )
                  : Icon(Icons.refresh, color: colorScheme.onErrorContainer),
            ),
          ],
        ),
      ),
    );
  }
}
