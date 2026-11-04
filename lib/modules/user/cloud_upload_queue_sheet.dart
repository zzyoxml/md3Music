import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../core/build_flags.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/utils/app_toast.dart';
import '../../providers/cloud_upload_provider.dart';

/// 打开云盘上传队列面板（底部弹窗，DraggableScrollableSheet 可拖拽高度）。
Future<void> showCloudUploadQueueSheet(BuildContext context) {
  context.read<CloudUploadProvider>().ensureMatchLoaded();
  return showM3EModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) {
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.92,
        builder: (context, scrollController) {
          // 本文件 import 的是 flutter/material.dart；m3e 弹窗链路（material_ui）
          // 插入的是其同名 Material，flutter 版 ListTile/SwitchListTile 找不到
          // flutter Material 祖先会整块报「此处内容加载出错」（AGENTS 4.13），
          // 故内容必须自带一层 flutter Material。
          return Material(
            type: MaterialType.transparency,
            child: Consumer<CloudUploadProvider>(
              builder: (context, up, _) {
                return Column(
                  children: [
                    _buildHeader(context, up),
                    const Divider(height: 1),
                    Expanded(
                      child: up.tasks.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.cloud_upload_outlined,
                                    size: 48,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant
                                        .withValues(alpha: 0.5),
                                  ),
                                  const Gap(AppSpacing.md),
                                  Text(
                                    '暂无上传任务',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant,
                                        ),
                                  ),
                                ],
                              ),
                            )
                          : _TaskList(tasks: up.tasks, controller: scrollController),
                    ),
                    const Divider(height: 1),
                    _buildFooterActions(context, up),
                  ],
                );
              },
            ),
          );
        },
      );
    },
  );
}

/// 队列头部：标题 + 汇总 + 总进度条 + 「匹配官方曲库」开关。
Widget _buildHeader(BuildContext context, CloudUploadProvider up) {
  final theme = Theme.of(context);
  final onVariant = theme.colorScheme.onSurfaceVariant;
  final current = up.currentTask;
  return Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.lg,
      AppSpacing.none,
      AppSpacing.lg,
      AppSpacing.sm,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('上传队列', style: theme.textTheme.titleMedium),
            const Spacer(),
            Text(
              '成功 ${up.successCount} · 失败 ${up.failedCount} · 等待 ${up.waitingCount}',
              style: theme.textTheme.bodySmall?.copyWith(color: onVariant),
            ),
          ],
        ),
        const Gap(AppSpacing.sm),
        M3ELinearProgressIndicator(
          value: up.hasTasks ? up.overallProgress : 0,
          backgroundColor: theme.colorScheme.surfaceContainerHighest,
        ),
        const Gap(AppSpacing.xs),
        Text(
          up.isRunning
              ? (current == null
                    ? '准备上传…'
                    : current.matching
                          ? '匹配中「${current.title}」'
                          : '上传中「${current.title}」')
              : '队列空闲',
          style: theme.textTheme.bodySmall?.copyWith(color: onVariant),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: up.matchEnabled,
          onChanged: (v) => up.setMatchEnabled(v),
          title: Text('匹配官方曲库', style: theme.textTheme.bodyMedium),
          subtitle: Text(
            '上传前按文件哈希匹配，命中后显示官方歌名、歌手与歌词（对未开始的任务生效）',
            style: theme.textTheme.bodySmall?.copyWith(color: onVariant),
          ),
        ),
      ],
    ),
  );
}

/// 队列任务列表（tv: 整列表收进 DpadRegion，行内单停点）。
class _TaskList extends StatelessWidget {
  const _TaskList({required this.tasks, required this.controller});

  final List<CloudUploadTask> tasks;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    final list = ListView.builder(
      controller: controller,
      itemCount: tasks.length,
      itemBuilder: (context, index) => _TaskRow(task: tasks[index]),
    );
    // tv: 分区容器保焦点（memoryKey 记住回到面板时的位置）
    if (kTvBuild) {
      return DpadRegion(
        memoryKey: 'tv/cloud_upload_queue',
        child: list,
      );
    }
    return list;
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.task});

  final CloudUploadTask task;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final subtitleStyle = theme.textTheme.bodySmall?.copyWith(
      color: cs.onSurfaceVariant,
    );

    final Widget leading;
    switch (task.status) {
      case CloudUploadStatus.waiting:
        leading = Icon(
          Icons.schedule,
          size: 24,
          color: cs.onSurfaceVariant.withValues(alpha: 0.6),
        );
      case CloudUploadStatus.uploading:
        leading = SizedBox(
          width: 24,
          height: 24,
          child: M3ELoadingIndicator(),
        );
      case CloudUploadStatus.success:
        leading = Icon(Icons.check_circle, size: 24, color: cs.primary);
      case CloudUploadStatus.failed:
        leading = Icon(Icons.error_outline, size: 24, color: cs.error);
    }

    final subtitleParts = <String>[
      if (task.artist.isNotEmpty) task.artist,
      if (task.total > 0) _formatSize(task.total),
    ];

    final Widget row = ListTile(
      dense: true,
      leading: leading,
      title: Text(
        task.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: task.status == CloudUploadStatus.failed
            ? theme.textTheme.bodyMedium?.copyWith(color: cs.error)
            : null,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (subtitleParts.isNotEmpty)
            Text(
              subtitleParts.join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: subtitleStyle,
            ),
          if (task.status == CloudUploadStatus.uploading &&
              task.progress != null) ...[
            const Gap(AppSpacing.xxs),
            M3ELinearProgressIndicator(
              value: task.progress,
              backgroundColor: cs.surfaceContainerHighest,
            ),
          ],
          if (task.status == CloudUploadStatus.success &&
              (task.matched || task.instant))
            Text(
              task.instant ? '秒传' : '已匹配官方曲库',
              style: subtitleStyle,
            ),
          if (task.status == CloudUploadStatus.failed &&
              (task.error ?? '').isNotEmpty)
            Text(
              task.error!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: cs.error),
            ),
        ],
      ),
      trailing: task.status == CloudUploadStatus.failed
          ? IconButton(
              tooltip: '重试',
              icon: const Icon(Icons.refresh),
              onPressed: () {
                context.read<CloudUploadProvider>().retryTask(task.id);
              },
            )
          : null,
    );

    // tv: 行单停点，OK = 重试（仅失败行有动作）
    if (kTvBuild && task.status == CloudUploadStatus.failed) {
      return DpadFocusable(
        onSelect: () {
          context.read<CloudUploadProvider>().retryTask(task.id);
        },
        child: row,
      );
    }
    return row;
  }
}

/// 底部操作行：重试失败 / 清除已完成 / 取消全部。
Widget _buildFooterActions(BuildContext context, CloudUploadProvider up) {
  Widget action(String label, VoidCallback? onPressed) {
    final button = TextButton(onPressed: onPressed, child: Text(label));
    // tv: 文本按钮单停点
    if (kTvBuild) {
      return DpadFocusable(
        onSelect: onPressed,
        child: button,
      );
    }
    return button;
  }

  return Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.lg,
      AppSpacing.xs,
      AppSpacing.lg,
      AppSpacing.sm,
    ),
    child: Row(
      children: [
        action(
          up.failedCount > 0 ? '重试失败 (${up.failedCount})' : '重试失败',
          up.failedCount > 0
              ? () {
                  final n = context.read<CloudUploadProvider>().retryFailed();
                  showToast('已重新加入 $n 首失败任务');
                }
              : null,
        ),
        action(
          '清除已完成',
          up.successCount > 0 || up.failedCount > 0
              ? () {
                  context.read<CloudUploadProvider>().clearFinished();
                }
              : null,
        ),
        const Spacer(),
        action(
          '取消全部待上传',
          up.waitingCount > 0
              ? () {
                  final n = context
                      .read<CloudUploadProvider>()
                      .cancelWaiting();
                  showToast('已移除 $n 首待上传任务');
                }
              : null,
        ),
      ],
    ),
  );
}

/// 云盘页顶部上传横幅：队列非空时显示，点击展开队列面板。
class CloudUploadBanner extends StatelessWidget {
  const CloudUploadBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<CloudUploadProvider>(
      builder: (context, up, _) {
        if (!up.hasTasks) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final cs = theme.colorScheme;
        final current = up.currentTask;
        final label = up.isRunning
            ? (current == null
                  ? '准备上传…'
                  : current.matching
                        ? '匹配中「${current.title}」'
                        : '上传中「${current.title}」')
            : '上传完成：成功 ${up.successCount}'
                '${up.failedCount > 0 ? '，失败 ${up.failedCount}' : ''}';

        final content = Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    up.isRunning ? Icons.cloud_upload_outlined : Icons.done_all,
                    size: 18,
                    color: cs.onSurfaceVariant,
                  ),
                  const Gap(AppSpacing.sm),
                  Expanded(
                    child: Text(
                      '上传队列 ${up.successCount + up.failedCount}/${up.tasks.length} · $label',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.expand_less,
                    size: 18,
                    color: cs.onSurfaceVariant,
                  ),
                ],
              ),
              const Gap(AppSpacing.xs),
              M3ELinearProgressIndicator(
                value: up.overallProgress,
                backgroundColor: cs.surfaceContainerHighest,
              ),
            ],
          ),
        );

        // 本文件 import 的是 flutter/material.dart，此 Material 即 flutter 的
        // Material（AGENTS 4.13：ink 效果组件必须自带 flutter Material）。
        final banner = Material(
          color: cs.surfaceContainerLow,
          borderRadius: AppRadius.mdAll,
          clipBehavior: Clip.antiAlias,
          child: kTvBuild
              ? DpadFocusable(
                  onSelect: () => showCloudUploadQueueSheet(context),
                  child: content,
                )
              : InkWell(
                  onTap: () => showCloudUploadQueueSheet(context),
                  child: content,
                ),
        );
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.sm,
            AppSpacing.lg,
            0,
          ),
          child: banner,
        );
      },
    );
  }
}

String _formatSize(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)}GB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }
  return '${(bytes / 1024).toStringAsFixed(0)}KB';
}
