// 项目统一使用 material_ui（Flutter 3.47 起 Material 库已解耦为独立包）
import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/services/remote/ftp_client.dart';
import '../../core/services/remote/remote_storage_config.dart';
import '../../core/services/remote/webdav_client.dart';

/// 远程目录浏览选择器：逐级进入子目录，选中后返回路径。
///
/// 仅列出目录项（音频文件不展示）；顶部「选择当前目录」返回当前路径。
/// FTP 每次列举独立建连、用完即断开，不跨页面持有连接。
class RemoteFolderPickerPage extends StatefulWidget {
  final RemoteStorageType type;
  final RemoteStorageConfig config;

  const RemoteFolderPickerPage({
    super.key,
    required this.type,
    required this.config,
  });

  @override
  State<RemoteFolderPickerPage> createState() => _RemoteFolderPickerPageState();
}

class _RemoteFolderPickerPageState extends State<RemoteFolderPickerPage> {
  /// 当前所在目录（从根开始）。
  String _currentPath = '/';
  List<WebDavEntry> _entries = <WebDavEntry>[];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load('/');
  }

  Future<void> _load(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await _listDir(path);
      if (!mounted) return;
      setState(() {
        _entries = entries.where((e) => e.isDirectory).toList();
        _currentPath = path;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// 统一列举：[FtpEntry] 与 [WebDavEntry] 结构同构，逐字段映射。
  Future<List<WebDavEntry>> _listDir(String path) async {
    if (widget.type == RemoteStorageType.webdav) {
      return WebDavClient(widget.config).list(path);
    }
    final client = FtpClient(
      host: widget.config.host,
      port: widget.config.effectivePort,
      username: widget.config.username,
      password: widget.config.password,
    );
    await client.connect();
    try {
      final raw = await client.list(path);
      return raw
          .map((e) => WebDavEntry(
                path: e.path,
                name: e.name,
                isDirectory: e.isDirectory,
                size: e.size,
              ))
          .toList();
    } finally {
      // 用完即断开，避免连接泄漏
      await client.disconnect();
    }
  }

  /// 计算上一级目录（根目录返回 null）。
  String? get _parentPath {
    if (_currentPath == '/' || _currentPath.isEmpty) return null;
    final trimmed = _currentPath.endsWith('/')
        ? _currentPath.substring(0, _currentPath.length - 1)
        : _currentPath;
    final idx = trimmed.lastIndexOf('/');
    return idx <= 0 ? '/' : trimmed.substring(0, idx);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('选择目录')),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: M3ELoadingIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48),
              const SizedBox(height: 12),
              Text('加载失败：$_error', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              M3EButton(
                onPressed: () => _load(_currentPath),
                style: M3EButtonStyle.tonal,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    final parent = _parentPath;
    return ListView(
      children: [
        // 选择当前目录：返回并回填路径
        ListTile(
          leading: const Icon(Icons.check_circle_outline),
          title: const Text('选择当前目录'),
          subtitle: Text(
            _currentPath,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => Navigator.pop(context, _currentPath),
        ),
        if (parent != null)
          ListTile(
            leading: const Icon(Icons.arrow_upward),
            title: const Text('上一级'),
            onTap: () => _load(parent),
          ),
        const Divider(height: 1),
        if (_entries.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(child: Text('当前目录没有子目录')),
          )
        else
          for (final e in _entries)
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => _load(e.path),
            ),
      ],
    );
  }
}