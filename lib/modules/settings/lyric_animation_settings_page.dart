import 'package:flutter/material.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';

/// 歌词动画调节子页面。
///
/// 集中调节 AM 歌词的逐行动画参数，全部为**无极**滑块（无档位小圆点）：
/// - 歌词非当前行缩放
/// - 歌词当前行位置（滚动锚位）
/// - 级联错峰上限 / 步长 / 衰减
///
/// 监听 [LyricPreferences] 实时刷新；拖动中只刷新标签（onChanged），
/// 松手写入偏好（onChangeEnd），避免拖动过程反复触发歌词组件重渲染。
class LyricAnimationSettingsPage extends StatelessWidget {
  const LyricAnimationSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final prefs = LyricPreferences.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('歌词动画')),
      body: AnimatedBuilder(
        animation: prefs,
        builder: (context, _) {
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              _buildSliderTile<double>(
                prefs: prefs,
                title: '歌词非当前行缩放',
                value: prefs.inactiveScale,
                min: LyricPreferences.minInactiveScale,
                max: LyricPreferences.maxInactiveScale,
                label: prefs.inactiveScale.toStringAsFixed(3),
                onChanged: (v) => prefs.setInactiveScale(v),
              ),
              _buildSliderTile<double>(
                prefs: prefs,
                title: '歌词当前行位置',
                value: prefs.alignPosition,
                min: LyricPreferences.minAlignPosition,
                max: LyricPreferences.maxAlignPosition,
                label: prefs.alignPosition.toStringAsFixed(2),
                onChanged: (v) => prefs.setAlignPosition(v),
              ),
              const Divider(height: 24),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text('切行错峰（下方行滞后跟随）',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              _buildSliderTile<double>(
                prefs: prefs,
                title: '错峰上限',
                subtitle: '越靠下的行最多"粘"这么久才回位',
                value: prefs.cascadeMaxDelayMs,
                min: LyricPreferences.minCascadeMaxDelayMs,
                max: LyricPreferences.maxCascadeMaxDelayMs,
                label:
                    '${prefs.cascadeMaxDelayMs.round()} ms',
                onChanged: (v) => prefs.setCascadeMaxDelayMs(v),
              ),
              _buildSliderTile<double>(
                prefs: prefs,
                title: '错峰步长',
                subtitle: '相邻行的错峰时间间隔',
                value: prefs.cascadeBaseStepMs,
                min: LyricPreferences.minCascadeBaseStepMs,
                max: LyricPreferences.maxCascadeBaseStepMs,
                label: '${prefs.cascadeBaseStepMs.round()} ms',
                onChanged: (v) => prefs.setCascadeBaseStepMs(v),
              ),
              _buildSliderTile<double>(
                prefs: prefs,
                title: '错峰衰减',
                subtitle: '每越过一行步长 × 1/x（越大衰减越快）',
                value: prefs.cascadeDecayX,
                min: LyricPreferences.minCascadeDecayX,
                max: LyricPreferences.maxCascadeDecayX,
                label: '1/${prefs.cascadeDecayX.toStringAsFixed(2)}',
                onChanged: (v) => prefs.setCascadeDecayX(v),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 构建一个"M3ESlider + 标题/副标题"的无极滑块 tile。
  Widget _buildSliderTile<T extends num>({
    required LyricPreferences prefs,
    required String title,
    String? subtitle,
    required double value,
    required double min,
    required double max,
    required String label,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          title: Text(title),
          subtitle: subtitle == null ? null : Text(subtitle),
          trailing: Text(label),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: M3ESlider(
            decoration: const M3ESliderDecoration(
                haptic: M3EHapticFeedback.medium),
            // 不传 divisions → 无极连续滑块（无档位小圆点）
            value: value,
            min: min,
            max: max,
            label: label,
            onChanged: onChanged,
            onChangeEnd: onChanged,
          ),
        ),
      ],
    );
  }
}