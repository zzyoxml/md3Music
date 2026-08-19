import 'package:flutter/material.dart';

import '../../../core/services/custom_font_loader.dart';
import '../../../core/utils/app_toast.dart';
import 'lyric_preferences.dart';

/// 歌词字号/行间距/字体调节面板。
///
/// 可嵌入设置页或作为 BottomSheet 弹出。
/// 用 AnimatedBuilder 监听 [LyricPreferences]，滑动滑块或切换字体时实时刷新歌词。
///
/// 字号范围 12~30px，行间距系数范围 1.0~2.0。
/// 行高公式：`actualLineHeight = (fontSize / defaultFontSize) * lineSpacing`。
///
/// 字体来源（system / bundled / custom）独立于全局 ThemeProvider，
/// 仅作用于歌词渲染路径。custom 模式通过 SAF 选择 TTF/OTF 文件，
/// 用 FontLoader 注册为 [LyricPreferences.lyricCustomFontFamily]。
class LyricPreferencesPanel extends StatelessWidget {
  const LyricPreferencesPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final prefs = LyricPreferences.instance;
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
                    '歌词显示',
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
                min: LyricPreferences.minFontSize,
                max: LyricPreferences.maxFontSize,
                divisions:
                    (LyricPreferences.maxFontSize -
                            LyricPreferences.minFontSize)
                        .round(),
                value: prefs.fontSize,
                onChanged: prefs.setFontSize,
              ),
              const SizedBox(height: 8),
              // 字重滑块
              Text('字重：${_fontWeightLabel(prefs.fontWeightValue)}'),
              Slider(
                min: LyricPreferences.minFontWeight.toDouble(),
                max: LyricPreferences.maxFontWeight.toDouble(),
                divisions: ((LyricPreferences.maxFontWeight -
                        LyricPreferences.minFontWeight) ~/
                    100),
                value: prefs.fontWeightValue.toDouble(),
                onChanged: (v) => prefs.setFontWeight(v.round()),
              ),
              const SizedBox(height: 8),
              // 行间距滑块
              Text('行间距：${prefs.lineSpacing.toStringAsFixed(1)} ×'),
              Slider(
                min: LyricPreferences.minLineSpacing,
                max: LyricPreferences.maxLineSpacing,
                divisions: ((LyricPreferences.maxLineSpacing -
                            LyricPreferences.minLineSpacing) *
                        10)
                    .round(),
                value: prefs.lineSpacing,
                onChanged: prefs.setLineSpacing,
              ),
              const SizedBox(height: 8),
              // 实际行高预览
              Text(
                '实际行高倍数：${prefs.lineHeightMultiplier.toStringAsFixed(2)} ×',
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
  String _getFontSourceLabel(LyricFontSource source) {
    switch (source) {
      case LyricFontSource.system:
        return '系统默认（手机字体优先）';
      case LyricFontSource.bundled:
        return '内置 SimHei';
      case LyricFontSource.custom:
        return '自定义字体';
    }
  }

  /// 弹出歌词字体来源选择面板（与全局字体选择解耦）。
  void _showFontSourceSheet(BuildContext context, LyricPreferences prefs) {
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
                    '歌词字体来源',
                    style: Theme.of(ctx).textTheme.titleMedium,
                  ),
                ),
              ),
              ListTile(
                leading: Icon(
                  current == LyricFontSource.system
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: Theme.of(ctx).colorScheme.primary,
                ),
                title: const Text('系统默认'),
                subtitle: const Text('使用手机系统字体（推荐）'),
                onTap: () async {
                  await prefs.setFontSource(LyricFontSource.system);
                  if (ctx.mounted) Navigator.pop(ctx);
                },
              ),
              ListTile(
                leading: Icon(
                  current == LyricFontSource.bundled
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: Theme.of(ctx).colorScheme.primary,
                ),
                title: const Text('内置 SimHei'),
                subtitle: const Text('使用打包的黑体字体'),
                onTap: () async {
                  await prefs.setFontSource(LyricFontSource.bundled);
                  if (ctx.mounted) Navigator.pop(ctx);
                },
              ),
              ListTile(
                leading: Icon(
                  current == LyricFontSource.custom
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

  /// 调用原生 SAF 文件选择器让用户选择字体文件，成功后保存并应用到歌词。
  Future<void> _pickAndApplyCustomFont(
    BuildContext context,
    LyricPreferences prefs,
  ) async {
    final path = await CustomFontLoader.pickFontFile();
    if (path == null) {
      // 用户取消
      if (!context.mounted) return;
      showToast('未选择字体文件', long: true);
      return;
    }
    // 先保存路径并加载字体（_tryLoadCustomFont 内部会注册 FontLoader）
    await prefs.setCustomFontPath(path);
    // 再切换来源为 custom（即使加载失败也切换，UI 自然降级为系统字体）
    await prefs.setFontSource(LyricFontSource.custom);
    if (!context.mounted) return;
    final loaded = prefs.effectiveFontFamily != null;
    showToast(loaded ? '已应用自定义字体到歌词' : '字体加载失败，已降级为系统字体', long: true);
  }
}
