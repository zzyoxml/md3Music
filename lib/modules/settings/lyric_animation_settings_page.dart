import '../../core/build_flags.dart';
import '../../core/layout/page_layout.dart';
import '../../core/remote/remote_slider.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:md3music/core/utils/app_toast.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import '../../core/utils/app_haptics.dart';

/// 歌词动画调节子页面。
///
/// 集中调节 AM 歌词的逐行动画参数与歌词效果强度，全部为**无极**滑块（无档位小圆点）：
/// - 当前行细节：已播字上浮高度
/// - 间奏点（节奏点）：水平位置 / 圆点大小 / 点间距（均为 × 字号系数）
/// - 歌词非当前行缩放
/// - 歌词当前行位置（滚动锚位）
/// - 级联错峰上限 / 步长 / 衰减
/// - 级联错峰起点开关（从当前行开始 / 从视口顶部开始）
/// - 歌词效果：歌词模糊强度（需开启歌词高斯模糊）、动态颜色混色比例
///   （需开启歌词动态颜色）、辉光强度（需开启歌词辉光效果）、
///   辉光触发阈值、辉光判定方式（自适应 / 固定时长二选一）与固定时长阈值、
///   字内渐变样式（经典 / 扫光二选一）
///
/// AppBar 的重置按钮可**二次确认后**把本页全部参数恢复默认——
/// 注意只重置本页 17 个参数，绝不调用 [LyricPreferences.reset]
/// （那会把字号/行距/动态颜色开关等不在本页的设置一并清掉）。
///
/// 监听 [LyricPreferences] 实时刷新；拖动中只刷新标签（onChanged），
/// 松手写入偏好（onChangeEnd），避免拖动过程反复触发歌词组件重渲染。
class LyricAnimationSettingsPage extends StatelessWidget {
  const LyricAnimationSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final prefs = LyricPreferences.instance;
    return Scaffold(
      appBar: AppBar(
        title: const Text('歌词动画'),
        actions: [
          IconButton(
            icon: const Icon(Icons.restart_alt),
            tooltip: '恢复本页默认',
            onPressed: () => _confirmResetAll(context, prefs),
          ),
        ],
      ),
      body: ContentWidth(
        child: AnimatedBuilder(
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
                child: Text('当前行细节',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
              ),
              _buildSliderTile<double>(
                prefs: prefs,
                title: '已播字上浮高度',
                subtitle: '当前行已唱过的字向上浮起的高度（0 = 不上浮）',
                value: prefs.liftHeightPx,
                min: LyricPreferences.minLiftHeightPx,
                max: LyricPreferences.maxLiftHeightPx,
                label: '${prefs.liftHeightPx.toStringAsFixed(1)} px',
                onChanged: (v) => prefs.setLiftHeightPx(v),
              ),
              const Divider(height: 24),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text('间奏点（节奏点）',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
              ),
              _buildSliderTile<double>(
                prefs: prefs,
                title: '间奏点水平位置',
                subtitle: '整组圆点左边缘相对视口的水平起点（× 字号；'
                    '1.5 = 默认，比歌词左边界右移 0.5em）',
                value: prefs.interludeDotsStartX,
                min: LyricPreferences.minInterludeDotsStartX,
                max: LyricPreferences.maxInterludeDotsStartX,
                label:
                    '${prefs.interludeDotsStartX.toStringAsFixed(2)} ×字号',
                onChanged: (v) => prefs.setInterludeDotsStartX(v),
              ),
              _buildSliderTile<double>(
                prefs: prefs,
                title: '间奏点圆点大小',
                subtitle: '单个圆点的半径（× 字号；0.18 = 默认）',
                value: prefs.interludeDotRadius,
                min: LyricPreferences.minInterludeDotRadius,
                max: LyricPreferences.maxInterludeDotRadius,
                label:
                    '${prefs.interludeDotRadius.toStringAsFixed(2)} ×字号',
                onChanged: (v) => prefs.setInterludeDotRadius(v),
              ),
              _buildSliderTile<double>(
                prefs: prefs,
                title: '间奏点间距',
                subtitle: '相邻圆点圆心到圆心的距离（× 字号；0.9 = 默认）',
                value: prefs.interludeDotSpacing,
                min: LyricPreferences.minInterludeDotSpacing,
                max: LyricPreferences.maxInterludeDotSpacing,
                label:
                    '${prefs.interludeDotSpacing.toStringAsFixed(2)} ×字号',
                onChanged: (v) => prefs.setInterludeDotSpacing(v),
              ),
              const Divider(height: 24),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text('切行错峰（下方行滞后跟随）',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
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
              SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                title: const Text('错峰从当前行上方开始'),
                subtitle: const Text(
                    '开启：当前行的上一行领头回位，以下各行依次跟随；'
                    '关闭：从视口顶部开始错峰',
                  ),
                value: prefs.staggerFromCurrentLine,
                onChanged: (v) => prefs.setStaggerFromCurrentLine(v),
              ),
              const Divider(height: 24),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text('歌词效果',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
              ),
              // 动态颜色混色比例：仅「歌词动态颜色」开启时显示（开关在
              // 「播放页样式 > 歌词效果」页；AnimatedBuilder 监听 prefs，
              // 开关变化后进本页即自动显隐）
              if (prefs.useDynamicLyricColor)
                _buildSliderTile<double>(
                  prefs: prefs,
                  title: '动态颜色混色比例',
                  subtitle: '当前行颜色 = 白色与封面提取色的混色比例（需开启歌词动态颜色）',
                  value: prefs.dynamicColorMixRatio,
                  min: LyricPreferences.minDynamicColorMixRatio,
                  max: LyricPreferences.maxDynamicColorMixRatio,
                  label: '${(prefs.dynamicColorMixRatio * 100).round()}%',
                  onChanged: (v) => prefs.setDynamicColorMixRatio(v),
                ),
              // 歌词模糊强度：仅高斯模糊开启时显示（开关在播放页样式页，
              // AnimatedBuilder 监听 prefs，开关变化后进本页即自动显隐）
              if (prefs.useGaussianBlur)
                _buildSliderTile<double>(
                  prefs: prefs,
                  title: '歌词模糊强度',
                  subtitle: '非当前行高斯模糊强度倍数（需开启歌词高斯模糊）',
                  value: prefs.blurIntensity,
                  min: LyricPreferences.minBlurIntensity,
                  max: LyricPreferences.maxBlurIntensity,
                  label: prefs.blurIntensity.toStringAsFixed(1),
                  onChanged: (v) => prefs.setBlurIntensity(v),
                ),
              // 辉光强度：仅辉光效果开启时显示（开关在播放页样式页，
              // AnimatedBuilder 监听 prefs，开关变化后进本页即自动显隐）
              if (prefs.useGlowEffect)
                _buildSliderTile<double>(
                  prefs: prefs,
                  title: '辉光强度',
                  subtitle: '辉光亮度倍数，只调亮度不改光形（需开启歌词辉光效果）',
                  value: prefs.glowIntensity,
                  min: LyricPreferences.minGlowIntensity,
                  max: LyricPreferences.maxGlowIntensity,
                  label: '${(prefs.glowIntensity * 100).round()}%',
                  onChanged: (v) => prefs.setGlowIntensity(v),
                ),
              _buildGlowModeTile(prefs),
              // 触发阈值系数 / 固定时长滑块与判定方式一一对应：
              // 自适应 → 显示系数滑块；固定时长 → 显示固定时长滑块
              //（AnimatedBuilder 监听 prefs，切换判定方式后本页自动显隐）
              if (prefs.glowThresholdMode == GlowThresholdMode.adaptive)
                _buildSliderTile<double>(
                  prefs: prefs,
                  title: '辉光触发阈值',
                  subtitle: '触发阈值 = 歌词字长中位数 × 该系数（越小越易触发）',
                  value: prefs.glowThresholdFactor,
                  min: LyricPreferences.minGlowThresholdFactor,
                  max: LyricPreferences.maxGlowThresholdFactor,
                  label: prefs.glowThresholdFactor.toStringAsFixed(1),
                  onChanged: (v) => prefs.setGlowThresholdFactor(v),
                ),
              if (prefs.glowThresholdMode == GlowThresholdMode.fixed)
                _buildSliderTile<double>(
                  prefs: prefs,
                  title: '辉光固定时长',
                  subtitle: '字时长 ≥ 该固定阈值才触发辉光（固定判定模式）',
                  value: prefs.glowFixedThresholdMs,
                  min: LyricPreferences.minGlowFixedThresholdMs,
                  max: LyricPreferences.maxGlowFixedThresholdMs,
                  label: '${prefs.glowFixedThresholdMs.round()} ms',
                  onChanged: (v) => prefs.setGlowFixedThresholdMs(v),
                ),
              _buildFillModeTile(prefs),
            ],
          );
        },
        ),
      ),
    );
  }

  /// 「字内渐变样式」二选一按钮组（经典 ⇄ 扫光）。
  ///
  /// 与设置页「主题模式」同款 [M3EToggleButtonGroup]（M3E 挤压动画）。
  Widget _buildFillModeTile(LyricPreferences prefs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          title: const Text('字内渐变样式'),
          subtitle: const Text(
            '经典 = 宽过渡带（旧观感）；'
            '扫光 = 锐利且按字长/时长自适应、更快掠过字间空白（默认）',
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          // 切换器按内容宽度居中：M3EToggleButtonGroup 是左对齐的一排
          child: Center(
            child: M3EToggleButtonGroup(
              actions: const [
                M3EToggleButtonGroupAction(label: Text('经典')),
                M3EToggleButtonGroupAction(label: Text('扫光')),
              ],
              selectedIndex: prefs.fillMode == LyricFillMode.sweep ? 1 : 0,
              onSelectedIndexChanged: (index) {
                if (index == null) return;
                prefs.setFillMode(
                  index == 1 ? LyricFillMode.sweep : LyricFillMode.classic,
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  /// 「辉光判定方式」二选一按钮组（自适应 ⇄ 固定时长）。
  ///
  /// 与设置页「主题模式」同款 [M3EToggleButtonGroup]（M3E 挤压动画）：
  /// - 自适应 = 原有判定（BPM / 字长中位数 × 系数，随节奏自适应）
  /// - 固定时长 = 字时长 ≥ 固定阈值才触发（默认；阈值见「辉光固定时长」滑块）
  Widget _buildGlowModeTile(LyricPreferences prefs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          title: const Text('辉光判定方式'),
          subtitle: const Text(
            '自适应 = 按歌曲节奏 / 字长 × 系数推断阈值；'
            '固定时长 = 字时长 ≥ 固定阈值才触发辉光',
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          // 切换器按内容宽度居中：M3EToggleButtonGroup 是左对齐的一排
          child: Center(
            child: M3EToggleButtonGroup(
              actions: const [
                M3EToggleButtonGroupAction(label: Text('自适应')),
                M3EToggleButtonGroupAction(label: Text('固定时长')),
              ],
              selectedIndex:
                  prefs.glowThresholdMode == GlowThresholdMode.fixed ? 1 : 0,
              onSelectedIndexChanged: (index) {
                if (index == null) return;
                prefs.setGlowThresholdMode(
                  index == 1
                      ? GlowThresholdMode.fixed
                      : GlowThresholdMode.adaptive,
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  /// 二次确认后把本页全部参数恢复默认。
  ///
  /// **只重置本页 17 个参数**，绝不调用 [LyricPreferences.reset]
  /// （那会把字号/行距/动态颜色开关等不在本页的设置一并清掉）。
  Future<void> _confirmResetAll(
    BuildContext context,
    LyricPreferences prefs,
  ) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('恢复本页默认值'),
          content: const Text(
            '将把本页全部参数（非当前行缩放、当前行位置、已播字上浮高度、'
            '间奏点水平位置、间奏点圆点大小、间奏点间距、'
            '错峰上限/步长/衰减、错峰起点开关、歌词模糊强度、'
            '动态颜色混色比例、辉光强度、辉光触发阈值、'
            '辉光判定方式、辉光固定时长、字内渐变样式）'
            '恢复为默认值，确定继续吗？',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('恢复默认'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;

    AppHaptics.mediumImpact(HapticCategory.control);
    await prefs.setInactiveScale(LyricPreferences.defaultInactiveScale);
    await prefs.setAlignPosition(
        LyricPreferences.defaultAlignPositionForCurrentPlatform);
    await prefs.setLiftHeightPx(
        LyricPreferences.defaultLiftHeightPxForCurrentPlatform);
    await prefs.setInterludeDotsStartX(
        LyricPreferences.defaultInterludeDotsStartX);
    await prefs.setInterludeDotRadius(LyricPreferences.defaultInterludeDotRadius);
    await prefs.setInterludeDotSpacing(
        LyricPreferences.defaultInterludeDotSpacing);
    await prefs.setCascadeMaxDelayMs(
        LyricPreferences.defaultCascadeMaxDelayMsForCurrentPlatform);
    await prefs.setCascadeBaseStepMs(
        LyricPreferences.defaultCascadeBaseStepMsForCurrentPlatform);
    await prefs.setCascadeDecayX(LyricPreferences.defaultCascadeDecayX);
    await prefs
        .setStaggerFromCurrentLine(LyricPreferences.defaultStaggerFromCurrentLine);
    await prefs.setBlurIntensity(LyricPreferences.defaultBlurIntensity);
    // 动态颜色混色比例回到 15%（历史观感）
    await prefs.setDynamicColorMixRatio(
        LyricPreferences.defaultDynamicColorMixRatio);
    await prefs.setGlowThresholdFactor(LyricPreferences.defaultGlowThresholdFactor);
    // 辉光强度回到 100%（历史观感）
    await prefs.setGlowIntensity(LyricPreferences.defaultGlowIntensity);
    // 辉光判定方式回到固定时长（默认判定），固定时长阈值回到 1000ms
    await prefs.setGlowThresholdMode(GlowThresholdMode.fixed);
    await prefs
        .setGlowFixedThresholdMs(LyricPreferences.defaultGlowFixedThresholdMs);
    // 字内渐变样式回到 sweep 扫光（默认观感）
    await prefs.setFillMode(LyricFillMode.sweep);
    showToast('已恢复本页全部默认值');
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
          // tv: TV 构建换 RemoteSlider——M3ESlider 自带 Focus 吞四方向键；
          // TV 分支丢 M3ESliderDecoration 触觉参数（P-C）
          child: kTvBuild
              ? RemoteSlider(
                  // 不传 divisions → 无极连续滑块（无档位小圆点）
                  value: value,
                  min: min,
                  max: max,
                  label: label,
                  onChanged: onChanged,
                  onChangeEnd: onChanged,
                )
              : M3ESlider(
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
