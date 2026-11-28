import 'dart:io';

import 'package:dio/dio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';

import 'release_info.dart';
import 'update_web_links.dart';
import 'windows_update_service.dart';

Future<void> showWindowsUpdateDialog(
  BuildContext context,
  ReleaseInfo release, {
  required Future<void> Function() onExitForUpdate,
  WindowsUpdateService? service,
}) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _WindowsUpdateDialog(
        release: release,
        onExitForUpdate: onExitForUpdate,
        service: service ?? WindowsUpdateService.instance,
      ),
    );

class _WindowsUpdateDialog extends StatefulWidget {
  const _WindowsUpdateDialog({
    required this.release,
    required this.onExitForUpdate,
    required this.service,
  });

  final ReleaseInfo release;
  final Future<void> Function() onExitForUpdate;
  final WindowsUpdateService service;

  @override
  State<_WindowsUpdateDialog> createState() => _WindowsUpdateDialogState();
}

class _WindowsUpdateDialogState extends State<_WindowsUpdateDialog> {
  final CancelToken _cancelToken = CancelToken();
  bool _downloading = false;
  bool _installing = false;
  int _received = 0;
  int _total = 0;
  File? _archive;
  String? _error;

  @override
  void dispose() {
    if (_downloading) _cancelToken.cancel('dialog closed');
    super.dispose();
  }

  Future<void> _download() async {
    setState(() {
      _downloading = true;
      _error = null;
    });
    try {
      final archive = await widget.service.download(
        widget.release,
        cancelToken: _cancelToken,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _received = received;
            _total = total > 0 ? total : (widget.release.windowsZipSize ?? 0);
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _archive = archive;
        _downloading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _error = _cancelToken.isCancelled ? '下载已取消' : '下载失败：$error';
      });
    }
  }

  Future<void> _install() async {
    final archive = _archive;
    if (archive == null) return;
    setState(() {
      _installing = true;
      _error = null;
    });
    try {
      await widget.service.installAndExit(
        archive,
        expectedVersion: widget.release.version,
      );
      await widget.onExitForUpdate();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _installing = false;
        _error = '$error';
      });
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final progress = _total > 0 ? (_received / _total).clamp(0.0, 1.0) : null;
    final notes = widget.release.body.trim();

    return AlertDialog(
      actionsAlignment: MainAxisAlignment.center,
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
      title: Row(
        children: [
          Expanded(
            child: Text(
              _downloading ? '正在下载更新' : '发现新版本',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          IconButton(
            tooltip: '关闭',
            onPressed: _installing ? null : () => Navigator.pop(context),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      titlePadding: const EdgeInsets.fromLTRB(24, 12, 12, 8),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('MD3Music v${widget.release.version}'),
            const SizedBox(height: 8),
            Container(
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(color: scheme.outlineVariant),
                borderRadius: BorderRadius.circular(12),
                color: scheme.surfaceContainerLow,
              ),
              child: Scrollbar(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(14),
                  child: SelectableText(
                    notes.isEmpty ? '此版本没有提供更新说明。' : notes,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ),
            ),
            if (_downloading) ...[
              const SizedBox(height: 10),
              M3ELinearProgressIndicator(value: progress),
              const SizedBox(height: 6),
              Text(
                '下载进度：${progress == null ? '准备中' : '${(progress * 100).round()}%'}'
                '${_total > 0 ? '（${_formatBytes(_received)} / ${_formatBytes(_total)}）' : ''}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ] else if (_archive != null) ...[
              const SizedBox(height: 10),
              Text(_installing
                  ? '正在解压并校验更新包，请勿关闭。准备完成后将自动退出、安装并重新打开；成功或失败均会通知。'
                  : '更新包已下载完成。点击立即更新，校验通过后自动重启并覆盖便携版；失败时保留原版本。'),
            ] else ...[
              const SizedBox(height: 10),
              const Text('发现新版本，可先下载，稍后再重启安装。'),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: scheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        M3ETextButton(
          onPressed: _installing ? null : () => openUpdateWebPage(updateProjectUrl),
          child: const Text('项目地址'),
        ),
        M3ETextButton(
          onPressed: _installing ? null : () => openUpdateWebPage(updateMirrorWebsiteUrl),
          child: const Text('镜像下载网站'),
        ),
        if (_downloading)
          M3ETextButton(
            onPressed: () {
              _cancelToken.cancel('user cancelled');
              Navigator.pop(context);
            },
            child: const Text('取消下载'),
          )
        else if (_archive != null) ...[
          M3ETextButton(
            onPressed: _installing ? null : () => Navigator.pop(context),
            child: const Text('稍后'),
          ),
          M3EFilledButton(
            onPressed: _installing ? null : _install,
            child: Text(_installing ? '正在启动更新' : '立即更新'),
          ),
        ] else ...[
          M3ETextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('稍后'),
          ),
          M3EFilledButton(
            onPressed: _downloading ? null : _download,
            child: const Text('下载更新'),
          ),
        ],
      ],
    );
  }
}
