import 'dart:io';

import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:m3e_core/m3e_core.dart';

import '../core/remote/tv_sheet_focus.dart';
import '../core/services/folder_picker_service.dart';
import '../core/theme/app_dimens.dart';

/// 目录选择：先试系统 SAF 选择器，打不开才兜底内置目录选择弹层。
///
/// TV 上系统 SAF 选择器可用时优先走系统（用户熟悉的界面）；原生
/// `ActivityNotFoundException` 回传 PICKER_UNAVAILABLE 标记
/// [FolderPickerService.safUnavailable] 后，改弹内置目录浏览器（遥控器
/// 可操作）。返回所选路径，取消返回 null。
///
/// 非 TV 构建同样适用：系统选择器正常时行为与 [FolderPickerService.pickFolder]
/// 完全一致，兜底弹层实际不会打开。
Future<String?> pickFolderTv(
  BuildContext context, {
  required String title,
}) async {
  final path = await FolderPickerService.pickFolder();
  if (path != null || !FolderPickerService.safUnavailable) return path;
  if (!context.mounted) return null;
  return showTvFolderPickerSheet(context, title: title);
}

/// tv: 内置目录选择弹层（遥控器可操作），返回所选目录绝对路径，取消返回 null。
///
/// TV 系统普遍没有 SAF DocumentsUI：原生 `ACTION_OPEN_DOCUMENT_TREE` 打不开时
/// 直接闪退（原生侧已修），打开后遥控器也可能无法操作。该弹层是**兜底**：
/// 系统选择器打不开（PICKER_UNAVAILABLE）时由 [pickFolderTv] 调起。项目已持有
/// 存储权限，直接用 dart:io 列文件系统目录，遥控器上下移动 / OK 进入子目录，
/// 顶栏按钮确认或返回上级。
///
/// 非 TV 构建也可用（ListTile onTap / 按钮直点），兜底入口由 [pickFolderTv] 统一。
Future<String?> showTvFolderPickerSheet(
  BuildContext context, {
  required String title,
}) {
  return showM3EModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) {
      // m3e 弹层（material_ui）插入的是其同名 Material，flutter 版控件找不到
      // flutter Material 祖先会整块报错，故内容自带一层 flutter Material
      // （同 cloud_upload_queue_sheet.dart 的处理，AGENTS 4.13）。
      return Material(
        type: MaterialType.transparency,
        child: _TvFolderPickerSheet(title: title),
      );
    },
  );
}

class _TvFolderPickerSheet extends StatefulWidget {
  const _TvFolderPickerSheet({required this.title});

  final String title;

  @override
  State<_TvFolderPickerSheet> createState() => _TvFolderPickerSheetState();
}

class _TvFolderPickerSheetState extends State<_TvFolderPickerSheet> {
  /// 当前所在目录；空串表示处于根层（列出存储卷）。
  String _currentPath = '';

  /// tv: 首焦点（「选择当前文件夹」主动作）。弹层延迟挂载 autofocus 不可靠，
  /// 由 [TvSheetFocus] 显式 requestFocus。
  final FocusNode _confirmNode = FocusNode();

  @override
  void dispose() {
    _confirmNode.dispose();
    super.dispose();
  }

  /// 列出可选存储卷：内部存储 + U 盘（/storage 下非系统自引用目录）。
  List<Directory> _listVolumes() {
    final volumes = <Directory>[];
    final internal = Directory('/storage/emulated/0');
    if (internal.existsSync()) volumes.add(internal);
    try {
      for (final entity
          in Directory('/storage').listSync(followLinks: false)) {
        final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
        // emulated/0 已单独加入；self/adb 等是系统自引用，跳过
        if (name == 'emulated' || name == 'self' || name == 'adb') continue;
        if (entity is Directory) volumes.add(entity);
      }
    } catch (_) {
      // /storage 不可枚举时至少保底内部存储
    }
    return volumes;
  }

  /// 列出当前目录的子目录（隐藏目录过滤，按名排序）。
  List<Directory> _listSubDirs(Directory dir) {
    try {
      return dir
          .listSync(followLinks: false)
          .whereType<Directory>()
          .where((d) {
            final name =
                d.uri.pathSegments.where((s) => s.isNotEmpty).last;
            return !name.startsWith('.');
          })
          .toList()
        ..sort((a, b) => a.path
            .toLowerCase()
            .compareTo(b.path.toLowerCase()));
    } catch (_) {
      // 无权限 / 已拔出：视为空目录
      return [];
    }
  }

  static String _baseName(String path) {
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    return segments.isEmpty ? path : segments.last;
  }

  /// 进入子目录 / 返回上级后把焦点收回主动作，避免焦点悬在已销毁的列表行上。
  void _navigate(String path) {
    setState(() => _currentPath = path);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _confirmNode.context != null) {
        _confirmNode.requestFocus();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final atRoot = _currentPath.isEmpty;

    final List<Directory> entries;
    if (atRoot) {
      entries = _listVolumes();
    } else {
      entries = _listSubDirs(Directory(_currentPath));
    }

    return TvSheetFocus(
      targetNode: _confirmNode,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const Gap(AppSpacing.xs),
              Text(
                atRoot ? '请选择存储位置' : _currentPath,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const Gap(AppSpacing.md),
              // 主动作：确认当前目录（根层未选卷时禁用）
              SizedBox(
                width: double.infinity,
                child: DpadFocusable(
                  focusNode: _confirmNode,
                  debugLabel: 'tv_folder_picker_confirm',
                  onSelect: atRoot
                      ? null
                      : () => Navigator.pop(context, _currentPath),
                  enabled: !atRoot,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.check),
                    label: const Text('选择当前文件夹'),
                    onPressed:
                        atRoot ? null : () => Navigator.pop(context, _currentPath),
                  ),
                ),
              ),
              const Gap(AppSpacing.sm),
              SizedBox(
                width: double.infinity,
                child: DpadFocusable(
                  debugLabel: 'tv_folder_picker_up',
                  // 根层已是顶层，无法再上
                  onSelect: atRoot ? null : _goUp,
                  enabled: !atRoot,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.arrow_upward),
                    label: const Text('上一级'),
                    onPressed: atRoot ? null : _goUp,
                  ),
                ),
              ),
              const Gap(AppSpacing.md),
              if (entries.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
                  child: Center(
                    child: Text(
                      atRoot ? '未找到可用存储' : '没有子文件夹',
                      style: TextStyle(color: colorScheme.onSurfaceVariant),
                    ),
                  ),
                )
              else
                Flexible(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(context).size.height * 0.45,
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: entries.length,
                      itemBuilder: (context, index) {
                        final dir = entries[index];
                        void enter() => _navigate(dir.path);
                        return DpadFocusable(
                          debugLabel: 'tv_folder_entry_$index',
                          onSelect: enter,
                          enabled: true,
                          child: ListTile(
                            leading: Icon(
                              atRoot
                                  ? Icons.usb_outlined
                                  : Icons.folder_outlined,
                            ),
                            title: Text(
                              _baseName(dir.path),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              dir.path,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: enter,
                          ),
                        );
                      },
                    ),
                  ),
                ),
              const Gap(AppSpacing.sm),
            ],
          ),
        ),
      ),
    );
  }

  /// 返回上级：根层禁用；卷层（/storage/xxxx）返回后回到根列表。
  void _goUp() {
    final parent = Directory(_currentPath).parent.path;
    // 卷根（如 /storage/XXXX-XXXX）的 parent 是 /storage，视为回到根层
    _navigate(parent == '/storage' ? '' : parent);
  }
}
