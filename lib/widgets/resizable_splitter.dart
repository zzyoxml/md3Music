import 'package:material_ui/material_ui.dart';

/// 可拖拽的竖直分隔条（桌面化布局用，见横屏平板重设计计划 4.5）。
///
/// 用于「侧栏 ↔ 内容」「列表 ↔ 详情」之间：手指沿水平方向拖动即调整两侧宽度。
///
/// - 命中区宽度 [hitWidth]（≥16dp，触控友好），视觉分隔线仅 1dp，居中绘制；
/// - 拖动时通过 [onDelta] 回传水平位移增量（dx，向右为正），由父级夹取宽度；
/// - 接外接键鼠时显示 `resizeColumn` 光标（属键鼠增强，不影响触控主体）。
class ResizableSplitter extends StatelessWidget {
  const ResizableSplitter({
    super.key,
    required this.onDelta,
    this.onDragEnd,
    this.hitWidth = 16.0,
    this.color,
  });

  /// 水平拖动增量回调（dx，向右为正）。
  final ValueChanged<double> onDelta;

  /// 拖动结束回调（用于持久化最终宽度）。
  final VoidCallback? onDragEnd;

  /// 命中区宽度（dp）。默认 16，保证触控可命中。
  final double hitWidth;

  /// 分隔线颜色。默认 [ColorScheme.outlineVariant]。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final lineColor = color ?? Theme.of(context).colorScheme.outlineVariant;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) => onDelta(d.delta.dx),
        onHorizontalDragEnd: (_) => onDragEnd?.call(),
        child: SizedBox(
          width: hitWidth,
          height: double.infinity,
          child: Center(
            child: Container(width: 1, color: lineColor),
          ),
        ),
      ),
    );
  }
}
