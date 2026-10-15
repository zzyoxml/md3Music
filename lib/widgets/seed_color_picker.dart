import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../core/build_flags.dart';
import '../core/remote/remote_slider.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/app_text_context_menu.dart';
import '../core/utils/hex_color.dart';

/// 字形压在用户自选色上时的前景色：按 WCAG 相对亮度判定（阈值 0.19，
/// 由全色域最劣对比度反推，最差仍有 4.4:1）。
/// 不用 HSV value——它取的是最大通道：默认色 #0061A4 的 value 0.64 却只有
/// 0.11 亮度，按 value 判会选成黑字 3.0:1，而白字是 6.5:1。
Color _glyphColorOn(Color background) =>
    background.computeLuminance() >= 0.19 ? Colors.black87 : Colors.white;

/// 预设种子色 + 自定义颜色选择面板。
///
/// 8 格圆形网格（4 列 × 2 行）：前 7 格为预设色，最后 1 格（第二排最右）为
/// 「自定义颜色」圆形调色盘，点击打开 HSV 色轮或十六进制色号取色。
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
                        ? Icon(Icons.check, color: _glyphColorOn(color), size: 20)
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
                  // 彩虹环不是用户选色，没有单一亮度可判，保持白色图标
                  child: const Icon(Icons.colorize, color: Colors.white, size: 20),
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          Text(
            '前 7 色取自 Material 3 官方 Theme Builder 的 key tone 40；'
            '最后一项为自定义取色（色轮或十六进制色号）',
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

  /// 色号输入框。文本不是状态源，只是 `_hsv` 的显示与「待提交的显式意图」。
  final TextEditingController _hexController = TextEditingController();

  /// 非 null 时输入框显示内联错误，且不覆盖用户正在编辑的文本。
  String? _hexError;

  @override
  void initState() {
    super.initState();
    _hexController.text = formatHexColor(widget.initial);
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  /// 颜色任何来源（色轮 / 滑块 / 色号）都走这一处收口：输入框与预览条始终
  /// 以规范色号反映当前颜色，避免出现「色轮是 A、框里写着 B」的双值歧义。
  void _setHsv(HSVColor next) {
    setState(() {
      _hsv = next;
      _hexController.text = formatHexColor(next.toColor());
      _hexError = null;
    });
  }

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
    _setHsv(_hsv.withHue(hue).withSaturation(r));
  }

  /// 键盘「完成」提交色号：非法时只在输入框下方提示，不动当前颜色、不吞掉文本。
  void _submitHex() {
    final parsed = parseHexColor(_hexController.text);
    if (parsed == null) {
      setState(() => _hexError = '格式不对，示例：#1E88E5');
      return;
    }
    // 由色号反推 HSV，色轮上的选中标记随之落到该色
    _setHsv(HSVColor.fromColor(parsed));
  }

  /// 确定：输入框文本合法时以它为准（用户常输入完直接点按钮，`onSubmitted` 不会触发），
  /// 非法时回退色轮当前色，不让按钮变死。
  /// 合法文本直接解析成 Color，不经 HSV 往返，避免舍入偏差。
  void _confirm() {
    Navigator.pop(context, parseHexColor(_hexController.text) ?? _hsv.toColor());
  }

  @override
  Widget build(BuildContext context) {
    final color = _hsv.toColor();
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('自定义主题色'),
      // 弹出键盘后可滚动，避免对话框内容被裁切
      content: SingleChildScrollView(
        child: Column(
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
                  // tv: TV 构建换 RemoteSlider（原生 Slider 吞四方向键、
                  // 焦点困死）；参数原样透传，触屏路径不变。
                  child: kTvBuild
                      ? RemoteSlider(
                          value: _hsv.value,
                          onChanged: (v) => _setHsv(_hsv.withValue(v)),
                        )
                      : Slider(
                          value: _hsv.value,
                          onChanged: (v) => _setHsv(_hsv.withValue(v)),
                        ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // 实时预览：底色是当前色，文字即它的色号（比「当前颜色」四个字更有用）
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
                  formatHexColor(color),
                  style: TextStyle(
                    color: _glyphColorOn(color),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            // 十六进制色号：支持 #RGB / #RRGGBB，# 前缀与大小写随意
            TextField(
              controller: _hexController,
              contextMenuBuilder: buildAppTextContextMenu,
              keyboardType: TextInputType.text,
              textCapitalization: TextCapitalization.none,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submitHex(),
              decoration: InputDecoration(
                labelText: '十六进制色号',
                hintText: '#1E88E5',
                errorText: _hexError,
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _confirm,
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
