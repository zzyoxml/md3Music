import 'dart:async';

import '../../core/build_flags.dart';
import '../../core/layout/page_layout.dart';
import '../../core/remote/remote_slider.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:md3music/core/utils/app_text_context_menu.dart';
import 'package:md3music/core/utils/app_toast.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_animation_preset_store.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import '../../core/utils/app_haptics.dart';

/// 歌词动画调节子页面。
///
/// 集中调节 AM 歌词的逐行动画参数与歌词效果强度，全部为**无极**滑块（无档位小圆点）：
/// - 当前行细节：已播字上浮高度
/// - 歌词透明度：已播 / 未播歌词透明度（满 factor 目标 alpha）
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
/// 注意只重置本页 19 个参数，绝不调用 [LyricPreferences.reset]
/// （那会把字号/行距/动态颜色开关等不在本页的设置一并清掉）。
///
/// 监听 [LyricPreferences] 实时刷新；拖动中只刷新标签（onChanged），
/// 松手写入偏好（onChangeEnd），避免拖动过程反复触发歌词组件重渲染。
///
/// AppBar 的「动画预设」按钮弹出多档预设面板：保存当前设置为预设、
/// 点击切换、长按重命名、行尾按钮删除，并支持把参数复制为 JSON 或从剪贴板
/// 导入（导入前可逐个改名）。
/// 预设只包含本页 20 项参数，不含模糊/辉光/动态颜色开关。
class LyricAnimationSettingsPage extends StatefulWidget {
  const LyricAnimationSettingsPage({super.key});

  @override
  State<LyricAnimationSettingsPage> createState() =>
      _LyricAnimationSettingsPageState();
}

class _LyricAnimationSettingsPageState extends State<LyricAnimationSettingsPage> {
  @override
  void initState() {
    super.initState();
    // 预设仓库懒加载：不阻塞首帧，加载完成后由 ChangeNotifier 刷新面板
    unawaited(LyricAnimationPresetStore.instance.load());
  }

  @override
  Widget build(BuildContext context) {
    final prefs = LyricPreferences.instance;
    return Scaffold(
      appBar: AppBar(
        title: const Text('歌词动画'),
        actions: [
          IconButton(
            icon: const Icon(Icons.bookmarks_outlined),
            tooltip: '动画预设',
            onPressed: () => _openPresetSheet(context),
          ),
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
                min: LyricPreferences.minInactiveScaleForCurrentPlatform,
                max: LyricPreferences.maxInactiveScaleForCurrentPlatform,
                label: prefs.inactiveScale.toStringAsFixed(3),
                onChanged: (v) => prefs.setInactiveScale(v),
              ),
              _buildSliderTile<double>(
                prefs: prefs,
                title: '歌词当前行位置',
                value: prefs.alignPosition,
                min: LyricPreferences.minAlignPositionForCurrentPlatform,
                max: LyricPreferences.maxAlignPositionForCurrentPlatform,
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
                min: LyricPreferences.minLiftHeightPxForCurrentPlatform,
                max: LyricPreferences.maxLiftHeightPxForCurrentPlatform,
                label: '${prefs.liftHeightPx.toStringAsFixed(1)} px',
                onChanged: (v) => prefs.setLiftHeightPx(v),
              ),
              const Divider(height: 24),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text('歌词透明度',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
              ),
              _buildSliderTile<double>(
                prefs: prefs,
                title: '已播歌词透明度',
                subtitle: '当前行已唱过的字与上方已播行的亮度（逐字渐变与整行'
                    '同时生效；100% = 完全不透明）',
                value: prefs.playedOpacity,
                min: LyricPreferences.minPlayedOpacityForCurrentPlatform,
                max: LyricPreferences.maxPlayedOpacityForCurrentPlatform,
                label: '${(prefs.playedOpacity * 100).round()}%',
                onChanged: (v) => prefs.setPlayedOpacity(v),
              ),
              _buildSliderTile<double>(
                prefs: prefs,
                title: '未播歌词透明度',
                subtitle: '当前行未唱的字与其它行的暗度（0% = 完全隐藏，'
                    '默认 40%；高斯模糊全开时仅「调低」在模糊层生效）',
                value: prefs.unplayedOpacity,
                min: LyricPreferences.minUnplayedOpacityForCurrentPlatform,
                max: LyricPreferences.maxUnplayedOpacityForCurrentPlatform,
                label: '${(prefs.unplayedOpacity * 100).round()}%',
                onChanged: (v) => prefs.setUnplayedOpacity(v),
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
                min: LyricPreferences.minInterludeDotsStartXForCurrentPlatform,
                max: LyricPreferences.maxInterludeDotsStartXForCurrentPlatform,
                label:
                    '${prefs.interludeDotsStartX.toStringAsFixed(2)} ×字号',
                onChanged: (v) => prefs.setInterludeDotsStartX(v),
              ),
              _buildSliderTile<double>(
                prefs: prefs,
                title: '间奏点圆点大小',
                subtitle: '单个圆点的半径（× 字号；0.18 = 默认）',
                value: prefs.interludeDotRadius,
                min: LyricPreferences.minInterludeDotRadiusForCurrentPlatform,
                max: LyricPreferences.maxInterludeDotRadiusForCurrentPlatform,
                label:
                    '${prefs.interludeDotRadius.toStringAsFixed(2)} ×字号',
                onChanged: (v) => prefs.setInterludeDotRadius(v),
              ),
              _buildSliderTile<double>(
                prefs: prefs,
                title: '间奏点间距',
                subtitle: '相邻圆点圆心到圆心的距离（× 字号；0.9 = 默认）',
                value: prefs.interludeDotSpacing,
                min: LyricPreferences.minInterludeDotSpacingForCurrentPlatform,
                max: LyricPreferences.maxInterludeDotSpacingForCurrentPlatform,
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
                min: LyricPreferences.minCascadeMaxDelayMsForCurrentPlatform,
                max: LyricPreferences.maxCascadeMaxDelayMsForCurrentPlatform,
                label:
                    '${prefs.cascadeMaxDelayMs.round()} ms',
                onChanged: (v) => prefs.setCascadeMaxDelayMs(v),
              ),
              _buildSliderTile<double>(
                prefs: prefs,
                title: '错峰步长',
                subtitle: '相邻行的错峰时间间隔',
                value: prefs.cascadeBaseStepMs,
                min: LyricPreferences.minCascadeBaseStepMsForCurrentPlatform,
                max: LyricPreferences.maxCascadeBaseStepMsForCurrentPlatform,
                label: '${prefs.cascadeBaseStepMs.round()} ms',
                onChanged: (v) => prefs.setCascadeBaseStepMs(v),
              ),
              _buildSliderTile<double>(
                prefs: prefs,
                title: '错峰衰减',
                subtitle: '每越过一行步长 × 1/x（越大衰减越快）',
                value: prefs.cascadeDecayX,
                min: LyricPreferences.minCascadeDecayXForCurrentPlatform,
                max: LyricPreferences.maxCascadeDecayXForCurrentPlatform,
                label: '1/${prefs.cascadeDecayX.toStringAsFixed(2)}',
                onChanged: (v) => prefs.setCascadeDecayX(v),
              ),
              SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                title: const Text('错峰从当前行上方开始'),
                subtitle: const Text(
                    '开启：当前行的上一行领头回位，以下各行依次跟随；'
                    '关闭：从视口顶部开始错峰（慢歌提前预滚动消除当前行'
                    '滞后，快歌滞后固定为 3 倍步长）',
                  ),
                value: prefs.staggerFromCurrentLine,
                onChanged: (v) => prefs.setStaggerFromCurrentLine(v),
              ),
              if (!prefs.staggerFromCurrentLine)
                _buildSliderTile<double>(
                  prefs: prefs,
                  title: '预启动提前量微调',
                  subtitle: '级联比换行边界再提前这么多毫秒，给弹簧留收敛时间（0 = 恰在边界释放）',
                  value: prefs.preStartBiasMs,
                  min: LyricPreferences.minPreStartBiasMs,
                  max: LyricPreferences.maxPreStartBiasMs,
                  label: '${prefs.preStartBiasMs.round()} ms',
                  onChanged: (v) => prefs.setPreStartBiasMs(v),
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
                  min: LyricPreferences.minDynamicColorMixRatioForCurrentPlatform,
                  max: LyricPreferences.maxDynamicColorMixRatioForCurrentPlatform,
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
                  min: LyricPreferences.minBlurIntensityForCurrentPlatform,
                  max: LyricPreferences.maxBlurIntensityForCurrentPlatform,
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
                  min: LyricPreferences.minGlowIntensityForCurrentPlatform,
                  max: LyricPreferences.maxGlowIntensityForCurrentPlatform,
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
                  min: LyricPreferences.minGlowThresholdFactorForCurrentPlatform,
                  max: LyricPreferences.maxGlowThresholdFactorForCurrentPlatform,
                  label: prefs.glowThresholdFactor.toStringAsFixed(1),
                  onChanged: (v) => prefs.setGlowThresholdFactor(v),
                ),
              if (prefs.glowThresholdMode == GlowThresholdMode.fixed)
                _buildSliderTile<double>(
                  prefs: prefs,
                  title: '辉光固定时长',
                  subtitle: '字时长 ≥ 该固定阈值才触发辉光（固定判定模式）',
                  value: prefs.glowFixedThresholdMs,
                  min: LyricPreferences.minGlowFixedThresholdMsForCurrentPlatform,
                  max: LyricPreferences.maxGlowFixedThresholdMsForCurrentPlatform,
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
  /// **只重置本页 19 个参数**，绝不调用 [LyricPreferences.reset]
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
            '已播歌词透明度、未播歌词透明度、'
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
    await prefs.setInactiveScale(
        LyricPreferences.defaultInactiveScaleForCurrentPlatform);
    await prefs.setAlignPosition(
        LyricPreferences.defaultAlignPositionForCurrentPlatform);
    await prefs.setLiftHeightPx(
        LyricPreferences.defaultLiftHeightPxForCurrentPlatform);
    await prefs.setPlayedOpacity(
        LyricPreferences.defaultPlayedOpacityForCurrentPlatform);
    await prefs.setUnplayedOpacity(
        LyricPreferences.defaultUnplayedOpacityForCurrentPlatform);
    await prefs.setInterludeDotsStartX(
        LyricPreferences.defaultInterludeDotsStartXForCurrentPlatform);
    await prefs.setInterludeDotRadius(
        LyricPreferences.defaultInterludeDotRadiusForCurrentPlatform);
    await prefs.setInterludeDotSpacing(
        LyricPreferences.defaultInterludeDotSpacingForCurrentPlatform);
    await prefs.setCascadeMaxDelayMs(
        LyricPreferences.defaultCascadeMaxDelayMsForCurrentPlatform);
    await prefs.setCascadeBaseStepMs(
        LyricPreferences.defaultCascadeBaseStepMsForCurrentPlatform);
    await prefs.setCascadeDecayX(
        LyricPreferences.defaultCascadeDecayXForCurrentPlatform);
    await prefs
        .setStaggerFromCurrentLine(LyricPreferences.defaultStaggerFromCurrentLine);
    await prefs.setBlurIntensity(
        LyricPreferences.defaultBlurIntensityForCurrentPlatform);
    // 动态颜色混色比例回到 15%（历史观感）
    await prefs.setDynamicColorMixRatio(
        LyricPreferences.defaultDynamicColorMixRatioForCurrentPlatform);
    await prefs.setGlowThresholdFactor(
        LyricPreferences.defaultGlowThresholdFactorForCurrentPlatform);
    // 辉光强度回到 100%（历史观感）
    await prefs.setGlowIntensity(
        LyricPreferences.defaultGlowIntensityForCurrentPlatform);
    // 辉光判定方式回到固定时长（默认判定），固定时长阈值回到当前平台默认
    await prefs.setGlowThresholdMode(GlowThresholdMode.fixed);
    await prefs.setGlowFixedThresholdMs(
        LyricPreferences.defaultGlowFixedThresholdMsForCurrentPlatform);
    // 字内渐变样式回到 sweep 扫光（默认观感）
    await prefs.setFillMode(LyricFillMode.sweep);
    showToast('已恢复本页全部默认值');
  }

  /// 打开「动画预设」管理面板。
  Future<void> _openPresetSheet(BuildContext context) async {
    AppHaptics.tick(HapticCategory.control);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _AnimationPresetSheet(),
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

/// 「动画预设」底部管理面板。
///
/// - 保存当前设置为预设（弹窗自定义名称，同名覆盖）
/// - 点击预设行切换、长按重命名；行尾按钮删除（TV 遥控器无长按）
/// - 剪贴板 JSON 导入（导入前可逐个改名）/ 导出（当前设置、全部预设）
///
/// 面板同时监听预设仓库与 [LyricPreferences]：应用预设后对勾立即跟随。
class _AnimationPresetSheet extends StatelessWidget {
  const _AnimationPresetSheet();

  static const String _emptyHint =
      '还没有自定义预设。调好参数后点「保存当前设置为预设」，'
      '或用「从剪贴板导入」导入 JSON。';

  @override
  Widget build(BuildContext context) {
    final store = LyricAnimationPresetStore.instance;
    final theme = Theme.of(context);
    // 同时监听仓库与偏好：应用预设后 activePresetName 才能即时刷新对勾
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[
        store,
        LyricPreferences.instance,
      ]),
      builder: (context, _) {
        final activeName = store.activePresetName();
        final allPresets = store.allPresets;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.7,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '动画预设',
                          style: theme.textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: '关闭',
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                  FilledButton.icon(
                    onPressed: () => _saveCurrentAsPreset(context),
                    icon: const Icon(Icons.bookmark_add_outlined),
                    label: const Text('保存当前设置为预设'),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 4,
                    children: [
                      TextButton.icon(
                        onPressed: () => _importFromClipboard(context),
                        icon: const Icon(Icons.content_paste_go, size: 18),
                        label: const Text('从剪贴板导入'),
                      ),
                      TextButton.icon(
                        onPressed: () => _copyCurrentJson(context),
                        icon: const Icon(Icons.content_copy, size: 18),
                        label: const Text('复制当前设置'),
                      ),
                      TextButton.icon(
                        onPressed: () => _copyAllJson(context),
                        icon: const Icon(Icons.copy_all, size: 18),
                        label: const Text('复制全部预设'),
                      ),
                    ],
                  ),
                  const Divider(height: 20),
                  if (store.presets.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 4),
                      child: Text(
                        _emptyHint,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: allPresets.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final preset = allPresets[index];
                        final isActive = preset.name == activeName;
                        final isBuiltIn =
                            LyricAnimationPresetStore.isBuiltInPreset(
                          preset.name,
                        );
                        final platformLabel =
                            LyricAnimationPresetStore.platformLabel(
                          preset.platform,
                        );
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            isActive
                                ? Icons.check_circle
                                : Icons.bookmark_border,
                            color: isActive
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                          title: Text(preset.name),
                          subtitle: Text(
                            isBuiltIn
                                ? _builtInSubtitle(preset.name)
                                : (platformLabel.isEmpty
                                    ? '点击切换 · 长按重命名'
                                    : '$platformLabel · 点击切换 · 长按重命名'),
                          ),
                          onTap: () => _applyPreset(context, preset.name),
                          onLongPress: isBuiltIn
                              ? () => showToast('内置预设不可修改或删除')
                              : () =>
                                  _renamePreset(context, preset.name),
                          trailing: isBuiltIn
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.delete_outline),
                                  tooltip: '删除预设',
                                  onPressed: () =>
                                      _confirmDelete(context, preset.name),
                                ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 内置预设的副标题：名称下方的补充说明（如「完整动画」）+ 只读提示。
  String _builtInSubtitle(String name) {
    final note = LyricAnimationPresetStore.builtInPresetDescriptions[name];
    const hint = '内置兜底 · 点击应用（不可删除或修改）';
    return note == null || note.isEmpty ? hint : '$note · $hint';
  }

  Future<void> _applyPreset(BuildContext context, String name) async {
    await LyricAnimationPresetStore.instance.applyPreset(name);
    if (!context.mounted) return;
    AppHaptics.tick(HapticCategory.control);
    showToast('已切换到「$name」');
  }

  Future<void> _saveCurrentAsPreset(BuildContext context) async {
    final name = await _askPresetName(context);
    if (name == null || !context.mounted) return;
    final isNew =
        await LyricAnimationPresetStore.instance.saveCurrentAsPreset(name);
    if (!context.mounted) return;
    AppHaptics.mediumImpact(HapticCategory.control);
    showToast(isNew ? '已保存预设「$name」' : '已更新预设「$name」');
  }

  /// 名称输入弹窗；取消或空名返回 null。
  Future<String?> _askPresetName(BuildContext context) {
    return showDialog<String>(
      context: context,
      builder: (_) => _PresetNameDialog(
        title: '保存为预设',
        confirmLabel: '保存',
        reservedNames: LyricAnimationPresetStore.builtInPresetNames,
        existingNames: LyricAnimationPresetStore.instance.presets
            .map((preset) => preset.name)
            .toSet(),
      ),
    );
  }

  /// 重命名预设：弹窗预填旧名称，同名冲突时阻止确认。
  Future<void> _renamePreset(BuildContext context, String name) async {
    final store = LyricAnimationPresetStore.instance;
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => _PresetNameDialog(
        title: '重命名预设',
        confirmLabel: '重命名',
        initialName: name,
        allowOverwrite: false,
        reservedNames: LyricAnimationPresetStore.builtInPresetNames,
        existingNames: store.presets
            .where((preset) => preset.name != name)
            .map((preset) => preset.name)
            .toSet(),
      ),
    );
    if (newName == null || !context.mounted) return;
    if (newName == name) return;

    final renamed = await store.renamePreset(name, newName);
    if (!context.mounted) return;
    if (!renamed) {
      showToast('已存在同名预设', long: true);
      return;
    }
    AppHaptics.mediumImpact(HapticCategory.control);
    showToast('已重命名为「$newName」');
  }

  Future<void> _confirmDelete(BuildContext context, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('删除预设'),
          content: Text('确定删除「$name」吗？此操作不可撤销。'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(dialogContext).colorScheme.error,
              ),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !context.mounted) return;
    await LyricAnimationPresetStore.instance.deletePreset(name);
    if (!context.mounted) return;
    AppHaptics.mediumImpact(HapticCategory.control);
    showToast('已删除预设「$name」');
  }

  Future<void> _importFromClipboard(BuildContext context) async {
    String text;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      text = data?.text?.trim() ?? '';
    } catch (error) {
      debugPrint('[LyricAnimation] 读取剪贴板失败: $error');
      if (context.mounted) showToast('读取剪贴板失败');
      return;
    }
    if (text.isEmpty) {
      if (context.mounted) showToast('剪贴板为空，请先复制 JSON 文本');
      return;
    }

    // 先解析（不落盘），再弹出名称编辑弹窗，让用户在导入前自定义每一档名称
    final List<LyricAnimationPreset> presets;
    try {
      presets = LyricAnimationPresetStore.instance.parsePresetsFromJson(text);
    } on FormatException catch (error) {
      if (!context.mounted) return;
      showToast('导入失败：${error.message}', long: true);
      return;
    } catch (error) {
      debugPrint('[LyricAnimation] 解析 JSON 失败: $error');
      if (context.mounted) showToast('导入失败：$error', long: true);
      return;
    }
    if (!context.mounted) return;

    final names = await _askImportNames(context, presets);
    if (names == null || !context.mounted) return;

    try {
      final count = await LyricAnimationPresetStore.instance
          .importPresets(presets, names: names);
      if (!context.mounted) return;
      AppHaptics.mediumImpact(HapticCategory.control);
      showToast('已导入 $count 个预设');
    } catch (error) {
      debugPrint('[LyricAnimation] 导入预设失败: $error');
      if (!context.mounted) return;
      showToast('导入失败：$error', long: true);
    }
  }

  /// 导入名称编辑弹窗；默认名称在同一批导入内去重，用户可直接确认。
  Future<List<String>?> _askImportNames(
    BuildContext context,
    List<LyricAnimationPreset> presets,
  ) {
    final used = <String>{};
    final defaults = <String>[];
    for (final preset in presets) {
      var name = preset.name.trim().isEmpty ? '导入预设' : preset.name.trim();
      // 内置预设名称保留：默认展示名自动追加序号
      if (LyricAnimationPresetStore.isBuiltInPreset(name)) {
        var suffix = 2;
        var candidate = '$name $suffix';
        while (used.contains(candidate)) {
          suffix++;
          candidate = '$name $suffix';
        }
        name = candidate;
      }
      if (used.contains(name)) {
        var suffix = 2;
        var candidate = '$name $suffix';
        while (used.contains(candidate)) {
          suffix++;
          candidate = '$name $suffix';
        }
        name = candidate;
      }
      used.add(name);
      defaults.add(name);
    }
    return showDialog<List<String>>(
      context: context,
      builder: (_) => _ImportNamesDialog(
        initialNames: defaults,
        platformLabels: presets
            .map((preset) =>
                LyricAnimationPresetStore.platformLabel(preset.platform))
            .toList(growable: false),
      ),
    );
  }

  Future<void> _copyCurrentJson(BuildContext context) async {
    // 导出前输入预设名：导出的 JSON 会携带该名称，导入方可直接使用
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _PresetNameDialog(
        title: '导出当前设置',
        confirmLabel: '复制',
        initialName: '当前设置',
        existingNames: <String>{},
      ),
    );
    if (name == null || !context.mounted) return;

    final json =
        LyricAnimationPresetStore.instance.exportCurrentAsJson(name: name);
    try {
      await Clipboard.setData(ClipboardData(text: json));
      if (!context.mounted) return;
      AppHaptics.tick(HapticCategory.control);
      showToast('已复制「$name」为 JSON');
    } catch (error) {
      debugPrint('[LyricAnimation] 复制 JSON 失败: $error');
      if (context.mounted) showToast('复制失败：$error', long: true);
    }
  }

  Future<void> _copyAllJson(BuildContext context) async {
    final store = LyricAnimationPresetStore.instance;
    if (store.presets.isEmpty) {
      showToast('还没有可导出的预设');
      return;
    }
    final json = store.exportAllAsJson();
    try {
      await Clipboard.setData(ClipboardData(text: json));
      if (!context.mounted) return;
      AppHaptics.tick(HapticCategory.control);
      showToast('已复制全部 ${store.presets.length} 个预设为 JSON');
    } catch (error) {
      debugPrint('[LyricAnimation] 复制 JSON 失败: $error');
      if (context.mounted) showToast('复制失败：$error', long: true);
    }
  }
}

/// 预设名称输入弹窗（保存 / 重命名共用）。
///
/// 用独立 [StatefulWidget] 持有并释放 [TextEditingController]：
/// 若在 `showDialog` 返回后立即 dispose，弹窗退场动画期间 TextField 仍会
/// 读取该 controller，测试与非测试环境都会触发 "used after being disposed"。
///
/// [allowOverwrite] = true 时同名仅提示「将被覆盖」；false 时（重命名）
/// 同名视为冲突并禁用确认按钮。
class _PresetNameDialog extends StatefulWidget {
  const _PresetNameDialog({
    required this.title,
    required this.existingNames,
    this.initialName = '',
    this.allowOverwrite = true,
    this.reservedNames = const <String>{},
    this.confirmLabel = '保存',
  });

  final String title;
  final Set<String> existingNames;
  final String initialName;
  final bool allowOverwrite;

  /// 保留名称（如内置默认预设），输入后禁用确认。
  final Set<String> reservedNames;
  final String confirmLabel;

  @override
  State<_PresetNameDialog> createState() => _PresetNameDialogState();
}

class _PresetNameDialogState extends State<_PresetNameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final trimmed = _controller.text.trim();
    final reserved = widget.reservedNames.contains(trimmed);
    final conflict =
        trimmed.isNotEmpty && widget.existingNames.contains(trimmed);
    final blocked = trimmed.isEmpty ||
        reserved ||
        (conflict && !widget.allowOverwrite);
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: LyricAnimationPresetStore.maxNameLength,
        contextMenuBuilder: buildAppTextContextMenu,
        decoration: InputDecoration(
          hintText: '例如：慢歌错峰、现场感',
          helperText: reserved
              ? '该名称为内置预设保留'
              : (conflict
                  ? (widget.allowOverwrite ? '同名预设将被覆盖' : '已存在同名预设')
                  : null),
        ),
        onChanged: (_) => setState(() {}),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed:
              blocked ? null : () => Navigator.of(context).pop(trimmed),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// 导入预设时的名称编辑弹窗：每档预设一个输入框，可逐个改名后确认。
///
/// [platformLabels] 与 [initialNames] 一一对应，用于展示来源平台标签。
class _ImportNamesDialog extends StatefulWidget {
  const _ImportNamesDialog({
    required this.initialNames,
    required this.platformLabels,
  });

  final List<String> initialNames;
  final List<String> platformLabels;

  @override
  State<_ImportNamesDialog> createState() => _ImportNamesDialogState();
}

class _ImportNamesDialogState extends State<_ImportNamesDialog> {
  late final List<TextEditingController> _controllers;

  @override
  void initState() {
    super.initState();
    _controllers = widget.initialNames
        .map((name) => TextEditingController(text: name))
        .toList(growable: false);
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  /// 输入框标题：单档显示「预设名称」，多档显示序号，并附带来源平台标签。
  String _labelFor(int index, bool single) {
    final platform =
        index < widget.platformLabels.length ? widget.platformLabels[index] : '';
    if (single) {
      return platform.isEmpty ? '预设名称' : '预设名称（$platform）';
    }
    return platform.isEmpty ? '预设 ${index + 1}' : '预设 ${index + 1}（$platform）';
  }

  @override
  Widget build(BuildContext context) {
    final single = _controllers.length == 1;
    final sourceLabels =
        widget.platformLabels.where((label) => label.isNotEmpty).toSet();
    final sourceHint =
        sourceLabels.isEmpty ? '' : '来源平台：${sourceLabels.join(' / ')}。';
    return AlertDialog(
      title: const Text('导入预设'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '$sourceHint共 ${_controllers.length} 个预设，可修改名称后导入。'
                '同名预设会被覆盖。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              for (var i = 0; i < _controllers.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(
                    controller: _controllers[i],
                    maxLength: LyricAnimationPresetStore.maxNameLength,
                    contextMenuBuilder: buildAppTextContextMenu,
                    decoration: InputDecoration(
                      labelText: _labelFor(i, single),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            _controllers.map((controller) => controller.text.trim()).toList(),
          ),
          child: const Text('导入'),
        ),
      ],
    );
  }
}
