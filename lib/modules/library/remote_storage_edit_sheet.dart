// 必须用 material_ui（项目统一约定）：Flutter 3.47 已将 Material 库解耦为
// 独立包，m3e_core 的 M3EBottomSheet 提供的 Material 祖先只对 material_ui 的
// TextField 生效。若此处导入 flutter/material.dart，TextField 会因
// 「No Material widget found」抛异常并被兜底成「此处内容加载出错」。
import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/services/remote/remote_storage_config.dart';
import '../../core/services/remote/remote_storage_repository.dart';
import '../../core/utils/app_text_context_menu.dart';
import '../../core/utils/app_toast.dart';
import '../../providers/remote_storage_provider.dart';
import 'remote_folder_picker_page.dart';

/// 添加 / 编辑远程存储的底部弹窗表单。
///
/// 调用方须以 `isScrollControlled: true` 打开，否则表单高度被限制。
/// Provider 从 Provider 树读取（项目惯例），故无参注入。
class RemoteStorageEditSheet extends StatefulWidget {
  /// 为空表示新增；非空表示编辑该配置。
  final RemoteStorageConfig? initial;

  const RemoteStorageEditSheet({super.key, this.initial});

  @override
  State<RemoteStorageEditSheet> createState() => _RemoteStorageEditSheetState();
}

class _RemoteStorageEditSheetState extends State<RemoteStorageEditSheet> {
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _rootPath;
  late RemoteStorageType _type;
  late bool _useTls;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final c = widget.initial;
    _type = c?.type ?? RemoteStorageType.webdav;
    _useTls = c?.useTls ?? false;
    _name = TextEditingController(text: c?.name ?? '');
    _host = TextEditingController(text: c?.host ?? '');
    // port 为 0 表示「未显式指定」，输入框留空让用户看到自动推导效果
    _port = TextEditingController(
      text: (c == null || c.port == 0) ? '' : '${c.port}',
    );
    _username = TextEditingController(text: c?.username ?? '');
    _password = TextEditingController(text: c?.password ?? '');
    _rootPath = TextEditingController(text: c?.rootPath ?? '/');
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _username.dispose();
    _password.dispose();
    _rootPath.dispose();
    super.dispose();
  }

  /// 用当前输入构造一条（可能是临时、尚未保存的）配置。
  /// [forBrowse] 时 id 用占位值，仅用于目录浏览。
  RemoteStorageConfig _buildConfig({required bool forBrowse}) {
    final host = _host.text.trim();
    final name = _name.text.trim();
    return RemoteStorageConfig(
      id: widget.initial?.id ??
          (forBrowse ? '__browse__' : RemoteStorageRepository.newId()),
      name: name.isEmpty ? host : name,
      type: _type,
      host: host,
      port: int.tryParse(_port.text.trim()) ?? 0,
      useTls: _useTls,
      username: _username.text.trim(),
      password: _password.text,
      rootPath: _rootPath.text.trim().isEmpty ? '/' : _rootPath.text.trim(),
    );
  }

  Future<void> _save() async {
    if (_host.text.trim().isEmpty) {
      showToast('请填写服务器地址');
      return;
    }
    setState(() => _busy = true);
    await context.read<RemoteStorageProvider>().saveConfig(_buildConfig(forBrowse: false));
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _testConnection() async {
    if (_host.text.trim().isEmpty) {
      showToast('请填写服务器地址');
      return;
    }
    setState(() => _busy = true);
    final msg = await context
        .read<RemoteStorageProvider>()
        .testConnection(_buildConfig(forBrowse: true));
    if (!mounted) return;
    setState(() => _busy = false);
    showToast(msg, long: true);
  }

  Future<void> _browseRootPath() async {
    if (_host.text.trim().isEmpty) {
      showToast('请先填写服务器地址');
      return;
    }
    final picked = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => RemoteFolderPickerPage(
          type: _type,
          config: _buildConfig(forBrowse: true),
        ),
      ),
    );
    if (picked != null) {
      _rootPath.text = picked;
    }
  }

  @override
  Widget build(BuildContext context) {
    // 【必须返回 M3EBottomSheet】M3EBottomSheet 内部才提供 Material 祖先
    // （m3e_core 的 showM3EModalBottomSheet 不像 Flutter 原生 showModalBottomSheet
    // 那样自带 Material）。若这里返回裸 Padding/Column，下面的 TextField 会因
    // 「No Material widget found」抛异常，被全局 ErrorWidget 兜底成
    // 「此处内容加载出错」——这正是表单所有输入框显示错误占位的原因。
    return Padding(
      // 键盘弹出时整体顶起，避免输入框被键盘遮挡
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: M3EBottomSheet(
        title: Text(widget.initial == null ? '添加远程存储' : '编辑远程存储'),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 协议选择：与设置页「主题模式」同款二选一控件（含相邻按钮挤压动效）
              Center(
                child: M3EToggleButtonGroup(
                  actions: const [
                    M3EToggleButtonGroupAction(
                      label: Text('WebDAV'),
                      icon: Icon(Icons.cloud_outlined),
                    ),
                    M3EToggleButtonGroupAction(
                      label: Text('FTP'),
                      icon: Icon(Icons.dns_outlined),
                    ),
                  ],
                  selectedIndex: _type.index,
                  onSelectedIndexChanged: (index) {
                    if (index == null) return;
                    setState(() => _type = RemoteStorageType.values[index]);
                  },
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _name,
                contextMenuBuilder: buildAppTextContextMenu,
                decoration: const InputDecoration(
                  labelText: '名称',
                  hintText: '我的NAS',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _host,
                contextMenuBuilder: buildAppTextContextMenu,
                decoration: const InputDecoration(
                  labelText: '地址',
                  hintText: '192.168.1.10',
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _port,
                      contextMenuBuilder: buildAppTextContextMenu,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '端口（留空自动）',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // TLS 开关同用二选一控件：语义比 FilterChip 更明确
                  M3EToggleButtonGroup(
                    actions: const [
                      M3EToggleButtonGroupAction(label: Text('HTTP')),
                      M3EToggleButtonGroupAction(label: Text('HTTPS')),
                    ],
                    selectedIndex: _useTls ? 1 : 0,
                    onSelectedIndexChanged: (index) {
                      if (index == null) return;
                      setState(() => _useTls = index == 1);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _username,
                contextMenuBuilder: buildAppTextContextMenu,
                decoration: const InputDecoration(labelText: '用户名'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _password,
                contextMenuBuilder: buildAppTextContextMenu,
                obscureText: true,
                decoration: const InputDecoration(labelText: '密码'),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _rootPath,
                      contextMenuBuilder: buildAppTextContextMenu,
                      decoration: const InputDecoration(
                        labelText: '根路径',
                        hintText: '/music',
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.folder_open),
                    tooltip: '浏览目录',
                    onPressed: _busy ? null : _browseRootPath,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // 测试连接 + 保存
              Row(
                children: [
                  Expanded(
                    child: M3EButton.icon(
                      onPressed: _busy ? null : _testConnection,
                      icon: const Icon(Icons.wifi_tethering, size: 18),
                      label: const Text('测试连接'),
                      style: M3EButtonStyle.outlined,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: M3EButton(
                      onPressed: _busy ? null : _save,
                      style: M3EButtonStyle.filled,
                      child: Text(_busy ? '处理中...' : '保存并扫描'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}