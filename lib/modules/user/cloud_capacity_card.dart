import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_dimens.dart';
import '../../core/theme/motion_constants.dart';
import '../../core/widgets/staggered_animations.dart';

/// 云盘容量卡片：左侧环形百分比图（已用/总额度），右侧具体大小。
///
/// 环形用 [TweenAnimationBuilder] 做一次性入场动画（收敛即停，非常驻 tick，
/// 符合 AGENTS 第 10 节限帧约定）。总额度未知（get_list 响应无配额字段，
/// 见 [_quotaBytes] 的候选键说明）时环形只画轨道、中心显示「已用」。
class CloudCapacityCard extends StatelessWidget {
  const CloudCapacityCard({
    super.key,
    required this.usedBytes,
    this.quotaBytes,
    this.songCount,
  });

  final int usedBytes;

  /// 总额度（字节）；响应未返回时为 null，环形退化为纯轨道。
  final int? quotaBytes;

  /// 歌曲数（额度未知时作为辅助信息展示）。
  final int? songCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final hasQuota = quotaBytes != null && quotaBytes! > 0;
    final percent = hasQuota ? (usedBytes / quotaBytes!).clamp(0.0, 1.0) : null;

    return EntranceScaleFade(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOutBack,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.sm,
          AppSpacing.lg,
          0,
        ),
        child: Material(
          color: cs.surfaceContainerLow,
          borderRadius: AppRadius.lgAll,
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Row(
              children: [
                _CapacityRing(percent: percent),
                const Gap(AppSpacing.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      fadeIn(
                        Text('云盘容量', style: theme.textTheme.titleSmall),
                        delay: const Duration(milliseconds: 300),
                      ),
                      const Gap(AppSpacing.xs),
                      fadeIn(
                        Text(
                          hasQuota
                              ? '${_formatSize(usedBytes)} / ${_formatSize(quotaBytes!)}'
                              : _formatSize(usedBytes),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyLarge
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        delay: const Duration(milliseconds: 350),
                      ),
                      if (hasQuota)
                        fadeIn(
                          Text(
                            '剩余 ${_formatSize((quotaBytes! - usedBytes).clamp(0, quotaBytes!))}',
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: cs.onSurfaceVariant),
                          ),
                          delay: const Duration(milliseconds: 400),
                        )
                      else if (songCount != null && songCount! > 0)
                        fadeIn(
                          Text(
                            '共 $songCount 首歌曲',
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: cs.onSurfaceVariant),
                          ),
                          delay: const Duration(milliseconds: 400),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CapacityRing extends StatelessWidget {
  const _CapacityRing({required this.percent});

  /// 0~1；null 表示额度未知（不画进度弧）。
  final double? percent;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    const size = 68.0;
    const stroke = 7.5;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: percent ?? 0),
      duration: const Duration(milliseconds: 600),
      curve: M3ExpressiveMotion.expressiveEasing,
      builder: (context, sweep, _) {
        final label = percent == null
            ? '已用'
            : '% ${(sweep * 100).round()}';
        return SizedBox(
          width: size,
          height: size,
          child: CustomPaint(
            painter: _RingPainter(
              sweep: sweep,
              trackColor: cs.surfaceContainerHighest,
              progressColor: cs.primary,
              stroke: stroke,
            ),
            child: Center(
              child: Text(
                label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface,
                    ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.sweep,
    required this.trackColor,
    required this.progressColor,
    required this.stroke,
  });

  /// 已绘制的比例（0~1，自顶部顺时针）。
  final double sweep;
  final Color trackColor;
  final Color progressColor;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final inset = stroke / 2;
    final arcRect = Rect.fromLTWH(
      inset,
      inset,
      size.width - stroke,
      size.height - stroke,
    );
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = trackColor;
    canvas.drawArc(arcRect, 0, 2 * math.pi, false, track);
    if (sweep > 0) {
      final progress = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = progressColor
        ..strokeCap = StrokeCap.round;
      // 顶部起点顺时针；极小值也保留一点可见弧长
      canvas.drawArc(
        arcRect,
        -math.pi / 2,
        2 * math.pi * sweep.clamp(0.015, 1.0),
        false,
        progress,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) =>
      oldDelegate.sweep != sweep ||
      oldDelegate.trackColor != trackColor ||
      oldDelegate.progressColor != progressColor;
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
