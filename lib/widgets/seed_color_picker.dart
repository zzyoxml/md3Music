import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';

/// 预设种子色 + 自定义颜色选择面板。
///
/// 8 格圆形网格（4 列 × 2 行）：前 7 格为预设色，最后 1 格（第二排最右）为
/// 「自定义颜色」圆形调色盘，点击打开 HSV 色轮自定义取色。
class SeedColorPicker extends StatelessWidget {
  /// 当前选中的颜色（用于高亮显示）。
  final Color currentColor;

  /// 选中颜色后的回调。
  final ValueChanged<Color> onSelected;

  const SeedColorPicker({
    super.key,
    required this.currentColor,
    required this.onSelected,
  });

  /// 当前颜色是否属于预设色之外的"自定义"色（决定自定义槽的高亮）。
  bool _isCustomSelected(List<Color> presets) {
    return !presets.any((c) => c.toARGB32() == currentColor.toARGB32());
  }

  Future<void> _openCustomPicker(BuildContext ctx) async {
    final picked = await showDialog<Color>(
      context: ctx,
      builder: (_) => _CustomColorPickerDialog(initial: currentColor),
    );
    if (picked != null) onSelected(picked);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // 前 7 个预设色 + 最后 1 个自定义槽
    final presets = AppTheme.presetSeedColors.take(7).toList();
    const total = 8;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '选择主题色',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 16),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 1,
            ),
            itemCount: total,
            itemBuilder: (ctx, i) {
              if (i < presets.length) {
                final color = presets[i];
                final isSelected = color.toARGB32() == currentColor.toARGB32();
                return GestureDetector(
                  onTap: () => onSelected(color),
                  child: Container(
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isSelected
                            ? colorScheme.onSurface
                            : colorScheme.outlineVariant,
                        width: isSelected ? 3 : 1,
                      ),
                    ),
                    child: isSelected
                        ? const Icon(Icons.check, color: Colors.white, size: 20)
                        : null,
                  ),
                );
              }
              // 自定义颜色槽：彩虹圆环 + 调色盘图标，点击打开 HSV 色轮
              final isCustomSelected = _isCustomSelected(presets);
              return GestureDetector(
                onTap: () => _openCustomPicker(ctx),
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const SweepGradient(
                      colors: [
                        Color(0xFFE53935),
                        Color(0xFFFDD835),
                        Color(0xFF43A047),
                        Color(0xFF1E88E5),
                        Color(0xFF8E24AA),
                        Color(0xFFE53935),
                      ],
                    ),
                    border: Border.all(
                      color: isCustomSelected
                          ? colorScheme.onSurface
                          : colorScheme.outlineVariant,
                      width: isCustomSelected ? 3 : 1,
                    ),
                  ),
                  child: const Icon(Icons.colorize, color: Colors.white, size: 20),
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          Text(
            '前 7 色取自 Material 3 官方 Theme Builder 的 key tone 40；最后一项为自定义取色',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }
}

/// 自定义颜色选择对话框：HSV 色轮（圆环选色相 + 半径选饱和度）+ 亮度滑块。
class _CustomColorPickerDialog extends StatefulWidget {
  final Color initial;

  const _CustomColorPickerDialog({required this.initial});

  @override
  State<_CustomColorPickerDialog> createState() =>
      _CustomColorPickerDialogState();
}

class _CustomColorPickerDialogState extends State<_CustomColorPickerDialog> {
  static const double _wheelSize = 200;
  late HSVColor _hsv = HSVColor.fromColor(widget.initial);

  /// 由色轮上的触点位置换算色相（角度）与饱和度（半径）。
  void _pickFromLocal(Offset local) {
    final size = _wheelSize;
    final center = Offset(size / 2, size / 2);
    final dx = local.dx - center.dx;
    final dy = local.dy - center.dy;
    final radius = size / 2;
    final dist = math.sqrt(dx * dx + dy * dy);
    final r = (dist / radius).clamp(0.0, 1.0);
    var angle = math.atan2(dy, dx) * 180 / math.pi;
    final hue = angle < 0 ? angle + 360 : angle;
    setState(() => _hsv = _hsv.withHue(hue).withSaturation(r));
  }

  @override
  Widget build(BuildContext context) {
    final color = _hsv.toColor();
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('自定义主题色'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // HSV 色轮
          GestureDetector(
            onTapDown: (d) => _pickFromLocal(d.localPosition),
            onPanDown: (d) => _pickFromLocal(d.localPosition),
            onPanUpdate: (d) => _pickFromLocal(d.localPosition),
            child: SizedBox(
              width: _wheelSize,
              height: _wheelSize,
              child: CustomPaint(
                painter: _HueWheelPainter(selection: _hsv),
              ),
            ),
          ),
          const SizedBox(height: 12),
          // 亮度滑块
          Row(
            children: [
              Icon(Icons.brightness_6, size: 20, color: scheme.onSurfaceVariant),
              Expanded(
                child: Slider(
                  value: _hsv.value,
                  onChanged: (v) => setState(() => _hsv = _hsv.withValue(v)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 实时预览
          Container(
            width: double.infinity,
            height: 44,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Center(
              child: Text(
                '当前颜色',
                style: TextStyle(
                  color: _hsv.value > 0.5 ? Colors.black87 : Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, color),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

/// 绘制 HSV 色轮：色相环绕 + 中心白（饱和度 0）→ 边缘纯色，并画出选中标记。
class _HueWheelPainter extends CustomPainter {
  final HSVColor selection;

  _HueWheelPainter({required this.selection});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2;
    final rect = Offset.zero & size;

    // 色相环
    final sweep = Paint()
      ..shader = SweepGradient(
        colors: const [
          Color(0xFFFF0000),
          Color(0xFFFFFF00),
          Color(0xFF00FF00),
          Color(0xFF00FFFF),
          Color(0xFF0000FF),
          Color(0xFFFF00FF),
          Color(0xFFFF0000),
        ],
      ).createShader(rect);
    canvas.drawCircle(center, radius, sweep);

    // 饱和度：中心白 → 边缘透明（圆盘越靠外颜色越纯）
    final radial = Paint()
      ..shader = RadialGradient(
        colors: [Colors.white, Colors.white.withValues(alpha: 0)],
        stops: const [0.0, 1.0],
      ).createShader(rect);
    canvas.drawCircle(center, radius, radial);

    // 外圈描边
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0x33000000),
    );

    // 选中标记（白点 + 描边）
    final angle = selection.hue * math.pi / 180;
    final r = selection.saturation * radius;
    final marker = center + Offset(math.cos(angle) * r, math.sin(angle) * r);
    canvas.drawCircle(marker, 6, Paint()..color = Colors.white);
    canvas.drawCircle(
      marker,
      6,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.black87,
    );
  }

  @override
  bool shouldRepaint(covariant _HueWheelPainter old) =>
      old.selection != selection;
}
