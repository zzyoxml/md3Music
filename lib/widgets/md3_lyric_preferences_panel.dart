import 'package:flutter/material.dart';

import '../core/services/custom_font_loader.dart';
import '../core/utils/app_toast.dart';
import 'md3_lyric_preferences.dart';

/// MD3 风格播放页的歌词显示调节面板。
///
/// 与 Apple Music 风格的 `LyricPreferencesPanel` 结构类似，但内部使用
/// [Md3LyricPreferences] 独立配置（与 Apple Music 风格的设置互不干扰）。
///
/// 包含：
/// - 字号滑块
/// - 行间距系数滑块
/// - 字体来源（系统/内置/自定义）
/// - 实际行高预览
/// - 重置按钮
class Md3LyricPreferencesPanel extends StatelessWidget {
  const Md3LyricPreferencesPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final prefs = Md3LyricPreferences.instance;
    return AnimatedBuilder(
      animation: prefs,
      builder: (context, _) {
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 标题栏
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '歌词显示（MD3 风格）',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  TextButton(
                    onPressed: () => prefs.reset(),
                    child: const Text('重置'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // 字号滑块
              Text('字号：${prefs.fontSize.round()} px'),
              Slider(
                min: Md3LyricPreferences.minFontSize,
                max: Md3LyricPreferences.maxFontSize,
                divisions:
                    (Md3LyricPreferences.maxFontSize -
                            Md3LyricPreferences.minFontSize)
                        .round(),
                value: prefs.fontSize,
                onChanged: prefs.setFontSize,
              ),
              const SizedBox(height: 8),
              // 字重滑块
              Text('字重：${_fontWeightLabel(prefs.fontWeightValue)}'),
              Slider(
                min: Md3LyricPreferences.minFontWeight.toDouble(),
                max: Md3LyricPreferences.maxFontWeight.toDouble(),
                divisions: ((Md3LyricPreferences.maxFontWeight -
                        Md3LyricPreferences.minFontWeight) ~/
                    100),
                value: prefs.fontWeightValue.toDouble(),
                onChanged: (v) => prefs.setFontWeight(v.round()),
              ),
              const SizedBox(height: 8),
              // 行间距滑块
              Text('行间距：${prefs.lineSpacing.toStringAsFixed(1)} ×'),
              Slider(
                min: Md3LyricPreferences.minLineSpacing,
                max: Md3LyricPreferences.maxLineSpacing,
                divisions: ((Md3LyricPreferences.maxLineSpacing -
                            Md3LyricPreferences.minLineSpacing) *
                        10)
                    .round(),
                value: prefs.lineSpacing,
                onChanged: prefs.setLineSpacing,
              ),
              const SizedBox(height: 8),
              // 实际行高预览
              Text(
                '实际行高：${prefs.lineHeightMultiplier.toStringAsFixed(1)} × 字号',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const Divider(height: 24),
              // 字体选择入口
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.text_fields),
                title: const Text('歌词字体'),
                subtitle: Text(_getFontSourceLabel(prefs.fontSource)),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () => _showFontSourceSheet(context, prefs),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 字重数值 → 中文标签。
  String _fontWeightLabel(int value) {
    switch (value) {
      case 300:
        return '细体';
      case 400:
        return '常规';
      case 500:
        return '中等';
      case 600:
        return '半粗';
      case 700:
        return '粗体';
      case 800:
        return '特粗';
      case 900:
        return '黑体';
      default:
        return '$value';
    }
  }

  /// 字体来源中文标签。
  String _getFontSourceLabel(Md3LyricFontSource source) {
    switch (source) {
      case Md3LyricFontSource.system:
        return '系统默认（手机字体优先）';
      case Md3LyricFontSource.bundled:
        return '内置 SimHei';
      case Md3LyricFontSource.custom:
        return '自定义字体';
    }
  }

  /// 弹出字体来源选择面板。
  void _showFontSourceSheet(BuildContext context, Md3LyricPreferences prefs) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final current = prefs.fontSource;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'MD3 歌词字体来源',
                    style: Theme.of(ctx).textTheme.titleMedium,
                  ),
                ),
              ),
              ListTile(
                leading: Icon(
                  current == Md3LyricFontSource.system
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: Theme.of(ctx).colorScheme.primary,
                ),
                title: const Text('系统默认'),
                subtitle: const Text('使用手机系统字体（推荐）'),
                onTap: () async {
                  await prefs.setFontSource(Md3LyricFontSource.system);
                  if (ctx.mounted) Navigator.pop(ctx);
                },
              ),
              ListTile(
                leading: Icon(
                  current == Md3LyricFontSource.bundled
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: Theme.of(ctx).colorScheme.primary,
                ),
                title: const Text('内置 SimHei'),
                subtitle: const Text('使用打包的黑体字体'),
                onTap: () async {
                  await prefs.setFontSource(Md3LyricFontSource.bundled);
                  if (ctx.mounted) Navigator.pop(ctx);
                },
              ),
              ListTile(
                leading: Icon(
                  current == Md3LyricFontSource.custom
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: Theme.of(ctx).colorScheme.primary,
                ),
                title: const Text('自定义字体'),
                subtitle: Text(
                  prefs.customFontPath == null
                      ? '点击从设备选择 .ttf / .otf 文件'
                      : '已加载：${prefs.customFontPath}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () async {
                  // 立即关闭面板，避免文件选择器与 BottomSheet 重叠
                  if (ctx.mounted) Navigator.pop(ctx);
                  await _pickAndApplyCustomFont(context, prefs);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  /// 通过 SAF 选择字体文件并应用到 MD3 歌词偏好。
  Future<void> _pickAndApplyCustomFont(
    BuildContext context,
    Md3LyricPreferences prefs,
  ) async {
    final path = await CustomFontLoader.pickFontFile();
    if (path == null) {
      if (!context.mounted) return;
      showToast('未选择字体文件', long: true);
      return;
    }
    await prefs.setCustomFontPath(path);
    await prefs.setFontSource(Md3LyricFontSource.custom);
    if (!context.mounted) return;
    final loaded = prefs.effectiveFontFamily != null;
    showToast(loaded ? '已应用自定义字体到 MD3 歌词' : '字体加载失败，已降级为系统字体', long: true);
  }
}
