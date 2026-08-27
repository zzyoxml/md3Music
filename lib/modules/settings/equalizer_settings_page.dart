import 'dart:io' show Platform;
import 'dart:ui';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:m3e_core/m3e_core.dart';

import '../../core/services/equalizer_service.dart';
import '../../core/utils/app_haptics.dart';
import '../../core/utils/app_toast.dart';

/// 均衡器设置页：Material Design 3 风格，包含频率响应曲线、预设芯片、垂直频段滑块。
///
/// 视觉层级（从上到下）：
/// 1. 顶部状态卡：图标徽章 + 标题 + 预设药丸 + 段数标签 + Switch 开关
/// 2. 频率响应曲线：CustomPainter 绘制平滑贝塞尔曲线 + 渐变填充
/// 3. 预设芯片栏：横向滚动，自定义预设 + 系统预设
/// 4. 频段垂直滑块面板：dB 标尺 + 垂直 Slider + 频率标签
/// 5. 底部提示文字
class EqualizerSettingsPage extends StatefulWidget {
  const EqualizerSettingsPage({super.key});

  @override
  State<EqualizerSettingsPage> createState() => _EqualizerSettingsPageState();
}

class _EqualizerSettingsPageState extends State<EqualizerSettingsPage> {
  final _eq = EqualizerService.instance;

  @override
  void initState() {
    super.initState();
    // 页面打开时尝试绑定
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _eq.tryBind();
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        title: const Text('均衡器'),
        centerTitle: true,
        actions: [
          ListenableBuilder(
            listenable: _eq,
            builder: (context, _) {
              final hasNonZero =
                  _eq.bandLevels.any((l) => l != 0) && _eq.enabled;
              return IconButton(
                icon: const Icon(Icons.restart_alt),
                tooltip: '重置',
                onPressed: hasNonZero
                    ? () {
                        HapticFeedback.lightImpact();
                        _eq.reset();
                        showToast('已重置所有频段');
                      }
                    : null,
              );
            },
          ),
        ],
      ),
      body: (kIsWeb || !Platform.isAndroid)
          ? _buildUnsupportedPlatform(colorScheme)
          : ListenableBuilder(
              listenable: _eq,
              builder: (context, _) {
                if (_eq.isBinding) {
                  return _buildLoading(colorScheme);
                }
                if (!_eq.isBound) {
                  return _buildNotBound(colorScheme);
                }
                return _buildEqualizerContent(colorScheme);
              },
            ),
    );
  }

  // ─── 状态页面 ───

  Widget _buildLoading(ColorScheme colorScheme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 32,
            height: 32,
            child: M3ECircularProgressIndicator(
              size: 32,
              strokeWidth: 3,
              color: colorScheme.primary,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '正在初始化均衡器...',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildNotBound(ColorScheme colorScheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.graphic_eq_rounded,
              size: 64,
              color: colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              '请先播放一首歌曲以激活音频引擎',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: colorScheme.onSurface,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              '均衡器需要活跃的音频会话才能工作',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.tonal(
              onPressed: () => _eq.tryBind(),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUnsupportedPlatform(ColorScheme colorScheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.phone_android_rounded,
              size: 64,
              color: colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              '该平台暂不支持均衡器（仅 Android）',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: colorScheme.onSurface,
                  ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  // ─── 主内容 ───

  Widget _buildEqualizerContent(ColorScheme colorScheme) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        _buildStatusCard(colorScheme),
        const SizedBox(height: 16),
        _buildFrequencyResponseCurve(colorScheme),
        const SizedBox(height: 16),
        _buildPresetChips(colorScheme),
        const SizedBox(height: 16),
        _buildBandsPanel(colorScheme),
        const SizedBox(height: 12),
        _buildBottomHint(colorScheme),
      ],
    );
  }

  // ─── 1. 顶部状态卡 ───

  Widget _buildStatusCard(ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        children: [
          // 图标徽章
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              Icons.graphic_eq_rounded,
              color: colorScheme.onPrimaryContainer,
              size: 24,
            ),
          ),
          const SizedBox(width: 12),
          // 标题 + 预设药丸
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '均衡器',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: _eq.enabled
                            ? colorScheme.secondaryContainer
                            : colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _eq.currentPreset,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: _eq.enabled
                                  ? colorScheme.onSecondaryContainer
                                  : colorScheme.onSurfaceVariant,
                            ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${_eq.bandCount} 段',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Switch 开关
          Switch(
            value: _eq.enabled,
            onChanged: (value) {
              AppHaptics.tick();
              _eq.setEnabled(value);
            },
          ),
        ],
      ),
    );
  }

  // ─── 2. 频率响应曲线 ───

  Widget _buildFrequencyResponseCurve(ColorScheme colorScheme) {
    return SizedBox(
      height: 120,
      child: CustomPaint(
        painter: _FrequencyResponsePainter(
          bandLevels: _eq.bandLevels,
          minLevel: _eq.minLevel,
          maxLevel: _eq.maxLevel,
          enabled: _eq.enabled,
          primaryColor: colorScheme.primary,
          outlineColor: colorScheme.outline,
          surfaceColor: colorScheme.surface,
        ),
        size: Size.infinite,
      ),
    );
  }

  // ─── 3. 预设芯片栏 ───

  Widget _buildPresetChips(ColorScheme colorScheme) {
    final presets = _eq.allPresetNames;
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: presets.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final preset = presets[index];
          final isSelected = preset == _eq.currentPreset;
          return GestureDetector(
            onTap: _eq.enabled
                ? () {
                    AppHaptics.tick();
                    _eq.applyPreset(preset);
                  }
                : null,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: isSelected
                    ? colorScheme.secondaryContainer
                    : colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(20),
                border: !isSelected
                    ? Border.all(
                        color: colorScheme.outlineVariant,
                        width: 1,
                      )
                    : null,
              ),
              alignment: Alignment.center,
              child: Text(
                preset,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: isSelected
                          ? colorScheme.onSecondaryContainer
                          : colorScheme.onSurfaceVariant,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                    ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ─── 4. 频段垂直滑块面板 ───

  Widget _buildBandsPanel(ColorScheme colorScheme) {
    final disabled = !_eq.enabled;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        children: [
          // dB 标尺
          _buildDbScale(colorScheme),
          const SizedBox(height: 8),
          // 滑块行
          SizedBox(
            height: 220,
            child: Row(
              children: List.generate(_eq.bandCount, (i) {
                return Expanded(
                  child: _BandSlider(
                    bandIndex: i,
                    disabled: disabled,
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDbScale(ColorScheme colorScheme) {
    return SizedBox(
      height: 20,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _dbLabel('+${_eq.maxDb}', colorScheme.primary, colorScheme),
          _dbLabel('0', colorScheme.onSurfaceVariant, colorScheme),
          _dbLabel('${_eq.minDb}', colorScheme.tertiary, colorScheme),
        ],
      ),
    );
  }

  Widget _dbLabel(
      String text, Color color, ColorScheme colorScheme) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 11,
        color: color,
        fontWeight: FontWeight.w500,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }

  // ─── 5. 底部提示 ───

  Widget _buildBottomHint(ColorScheme colorScheme) {
    return Text(
      _eq.enabled
          ? '拖动滑块调节频段，或选择预设快速应用'
          : '启用均衡器后即可调节频段',
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
      textAlign: TextAlign.center,
    );
  }
}

// ─── 单个频段滑块组件 ───

class _BandSlider extends StatelessWidget {
  final int bandIndex;
  final bool disabled;

  const _BandSlider({
    required this.bandIndex,
    required this.disabled,
  });

  @override
  Widget build(BuildContext context) {
    final eq = EqualizerService.instance;
    final colorScheme = Theme.of(context).colorScheme;

    return ListenableBuilder(
      listenable: eq,
      builder: (context, _) {
        final level = eq.bandLevels[bandIndex];
        final dbValue = EqualizerService.mbToDb(level);
        final freqLabel = EqualizerService.formatFreq(eq.centerFreqs[bandIndex]);

        // dB 值颜色编码
        Color dbColor;
        if (level > 0) {
          dbColor = colorScheme.primary;
        } else if (level < 0) {
          dbColor = colorScheme.tertiary;
        } else {
          dbColor = colorScheme.onSurfaceVariant;
        }

        return Column(
          children: [
            // dB 值显示
            Text(
              '${dbValue >= 0 ? '+' : ''}${dbValue.toStringAsFixed(1)}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: disabled ? colorScheme.onSurfaceVariant.withValues(alpha: 0.4) : dbColor,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 4),
            // 垂直滑块：M3ESlider 原生支持垂直方向，min 在底部 max 在顶部
            Expanded(
              child: M3ESlider(
                orientation: Axis.vertical,
                enabled: !disabled,
                value: level.toDouble().clamp(
                      eq.minLevel.toDouble(),
                      eq.maxLevel.toDouble(),
                    ),
                min: eq.minLevel.toDouble(),
                max: eq.maxLevel.toDouble(),
                // 不设 divisions：无密集刻度节点，观感更清爽
                onChanged: (value) {
                  eq.setBandLevel(bandIndex, value.round());
                },
              ),
            ),
            const SizedBox(height: 4),
            // 频率标签
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: level != 0 && !disabled
                    ? colorScheme.secondaryContainer
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                freqLabel,
                style: TextStyle(
                  fontSize: 10,
                  color: disabled
                      ? colorScheme.onSurfaceVariant.withValues(alpha: 0.4)
                      : colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ─── 频率响应曲线画笔 ───

class _FrequencyResponsePainter extends CustomPainter {
  final List<int> bandLevels;
  final int minLevel;
  final int maxLevel;
  final bool enabled;
  final Color primaryColor;
  final Color outlineColor;
  final Color surfaceColor;

  _FrequencyResponsePainter({
    required this.bandLevels,
    required this.minLevel,
    required this.maxLevel,
    required this.enabled,
    required this.primaryColor,
    required this.outlineColor,
    required this.surfaceColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (bandLevels.isEmpty || maxLevel == minLevel) return;

    final paint = Paint()
      ..color = enabled ? primaryColor : primaryColor.withValues(alpha: 0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // 0 dB 基准线
    final zeroY = size.height / 2;
    final dashPaint = Paint()
      ..color = outlineColor.withValues(alpha: 0.4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    const dashWidth = 4.0;
    const dashSpace = 4.0;
    double x = 0;
    while (x < size.width) {
      canvas.drawLine(
        Offset(x, zeroY),
        Offset(x + dashWidth, zeroY),
        dashPaint,
      );
      x += dashWidth + dashSpace;
    }

    // 计算频段点位置
    final points = <Offset>[];
    final n = bandLevels.length;
    for (int i = 0; i < n; i++) {
      final px = n == 1 ? size.width / 2 : (i / (n - 1)) * size.width;
      // 将 mB 值映射到 Y 坐标：maxLevel → 0, 0 → center, minLevel → bottom
      final normalized = (bandLevels[i] - minLevel) / (maxLevel - minLevel);
      final py = size.height - (normalized * size.height);
      points.add(Offset(px, py));
    }

    // 构建平滑路径
    final path = _buildSmoothPath(points);

    // 绘制填充区域
    final fillPath = Path.from(path)
      ..lineTo(points.last.dx, size.height)
      ..lineTo(points.first.dx, size.height)
      ..close();

    final gradient = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        primaryColor.withValues(alpha: enabled ? 0.15 : 0.05),
        primaryColor.withValues(alpha: 0),
      ],
    );

    final fillPaint = Paint()
      ..shader = gradient.createShader(
        Rect.fromLTWH(0, 0, size.width, size.height),
      )
      ..style = PaintingStyle.fill;

    canvas.drawPath(fillPath, fillPaint);

    // 绘制曲线
    canvas.drawPath(path, paint);

    // 绘制频段点
    final pointPaint = Paint()
      ..color = enabled ? primaryColor : primaryColor.withValues(alpha: 0.3)
      ..style = PaintingStyle.fill;

    for (final point in points) {
      canvas.drawCircle(point, 4, pointPaint);
    }
  }

  /// 构建平滑贝塞尔曲线路径
  Path _buildSmoothPath(List<Offset> points) {
    if (points.isEmpty) return Path();
    final path = Path()..moveTo(points.first.dx, points.first.dy);

    if (points.length == 1) return path;

    for (int i = 0; i < points.length - 1; i++) {
      final p0 = points[i];
      final p1 = points[i + 1];
      final midX = (p0.dx + p1.dx) / 2;
      // S 型曲线：控制点在水平中点，保持各自的 Y 值
      path.cubicTo(midX, p0.dy, midX, p1.dy, p1.dx, p1.dy);
    }

    return path;
  }

  @override
  bool shouldRepaint(covariant _FrequencyResponsePainter oldDelegate) {
    return oldDelegate.bandLevels != bandLevels ||
        oldDelegate.enabled != enabled ||
        oldDelegate.minLevel != minLevel ||
        oldDelegate.maxLevel != maxLevel ||
        oldDelegate.primaryColor != primaryColor;
  }
}
