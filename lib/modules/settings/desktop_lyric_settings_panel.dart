import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:m3e_core/m3e_core.dart';

import '../../core/build_flags.dart';
import '../../core/remote/remote_slider.dart';
import '../../core/services/desktop_lyric_service.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/utils/app_haptics.dart';
import 'settings_group_heading.dart';

/// 桌面歌词设置滑块的触感配置（**档位式**而非连续式）。
///
/// 与 settings_page.dart 的 [kSettingsSliderDecoration] 同参：M3ESlider 在
/// `divisions == null` 时会按最高 ~100 次/秒 走 MethodChannel 触发 vibrate，
/// 真机上马达饱和且通道洪泛。本面板只做跨 import 常量重复，不引入对
/// settings_page.dart 的反向依赖（会造成两个文件循环 import）。
const M3ESliderDecoration _panelSliderDecoration = M3ESliderDecoration(
  haptic: M3EHapticFeedback.medium,
  hapticConfig: M3EHapticConfig.discrete(),
);

/// 桌面歌词悬浮窗的**外观设置**：字号 / 行式 / 不透明度 / 已唱渐变 / 未唱色 / 锁定。
///
/// 嵌入在「设置 → 歌词 → 设备歌词」三级子页里（见 settings_page.dart 的
/// `_buildDeviceLyricSubpage`），替换原先只有「解锁桌面歌词」一行的局面。
///
/// ## 为什么不进悬浮窗内的原生面板
/// 悬浮窗里那块面板是 `FloatingLyricService.createSettingsPanel()` 手搓的
/// LinearLayout，改起来要重做 XML layout + 自定义 Drawable；而真正的问题是
/// **用户在 App 里根本找不到任何桌面歌词的配置入口**。本面板与原生面板共用
/// 同一份 SharedPreferences，通过 [DesktopLyricService] 收发，
/// 两端改动会自动同步（原生改动经 desktopLyricConfigChanged 回灌到这里）。
///
/// ## 三个刻意做进 UI 的现存行为
/// 1. 拖「已唱」色相会把渐变的**两端并成同一个色**（原生 makeColorSeekRow
///    的 onColor 里 `gradientStart = color; gradientEnd = color`），渐变就此
///    失效 —— 面板顶部状态 chip 会明写 渐变 / 单色。
/// 2. 配置**只在松手时才写盘**（persist），拖动中只推送原生预览 —— 与原生
///    SeekBar 的 onStopTrackingTouch 时机一致，避免写盘风暴。
/// 3. 锁定会给悬浮窗加 FLAG_NOT_TOUCHABLE，**代价是再也点不到它**，
///    这么重的后果不该藏在一个开关里 —— 做成一整条状态行写明后果。
///
/// 数据源为 [DesktopLyricService]（唯一真相），本控件只做读写转发，
/// 监听服务的 `_notify` 刷新 —— 原生面板改了配置，这里也会跟着变。
class DesktopLyricSettingsPanel extends StatefulWidget {
  const DesktopLyricSettingsPanel({super.key});

  @override
  State<DesktopLyricSettingsPanel> createState() =>
      _DesktopLyricSettingsPanelState();
}

class _DesktopLyricSettingsPanelState
    extends State<DesktopLyricSettingsPanel> {
  final DesktopLyricService _svc = DesktopLyricService.instance;

  /// 「自调颜色」是否展开 = 当前配色模式是不是「自调颜色」。
  ///
  /// 刻意**不**存成本地 bool：这里的展开/收起就是模式本身，收起等价于切回
  /// 「预设配色」（并把渐变恢复成上次选中的那组预设）。用本地 bool 的话，
  /// 原生悬浮窗里切了模式，这一页的展开态不会跟着动，两端立刻不一致。
  bool get _colorExpanded =>
      _svc.colorMode == DesktopLyricService.kColorModeCustom;

  /// 拖动过程中的临时值（尚未写盘）。松手后由 [DesktopLyricService] 落盘，
  /// 这里重新 null 让 UI 回到读服务字段。
  double? _draggingFontSize;
  double? _draggingOpacity;
  double? _draggingSungHue;
  double? _draggingUnsungHue;

  @override
  void initState() {
    super.initState();
    _svc.addListener(_onServiceChanged);
  }

  @override
  void dispose() {
    _svc.removeListener(_onServiceChanged);
    super.dispose();
  }

  void _onServiceChanged() {
    if (mounted) setState(() {});
  }

  ColorScheme get _cs => Theme.of(context).colorScheme;

  Color get _g1 => Color(_svc.gradientStart).withValues(alpha: 1);
  Color get _g2 => Color(_svc.gradientEnd).withValues(alpha: 1);
  Color get _unplayed => Color(_svc.unplayedColor).withValues(alpha: 1);
  bool get _isGradient => _svc.gradientStart != _svc.gradientEnd;

  @override
  Widget build(BuildContext context) {
    final child = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildPreview(),
        _buildColorSection(),
        _buildTypeSection(),
        _buildSurfaceSection(),
      ],
    );
    // tv: 整块面板是一个焦点区，四个色板与两条操作行是区里的停点
    if (!kTvBuild) return child;
    return DpadRegion(
      memoryKey: 'settings/desktop-lyric',
      debugLabel: 'desktop-lyric-panel',
      child: child,
    );
  }

  // ==========================================================================
  // 预览：整个面板里唯一能被复述出来的东西
  // ==========================================================================

  /// 所见即所得的预览。
  ///
  /// 悬浮窗可能压在任何界面上，这里铺一层"假的下层内容"（渐变 + 两条卡片
  /// 骨架），上面才是悬浮窗本体 —— 不这么做，调不透明度等于没得调。
  Widget _buildPreview() {
    final fontSize = _svc.fontSize;
    final alpha = _svc.opacity / 100.0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      // Stack 里两个 child 都是 Positioned.fill，本身不产生尺寸 —— 必须显式
      // 给出高度，否则在 Sliver/ListView 的无界主轴约束下会 RenderBox 报错。
      child: SizedBox(
        height: 128,
        width: double.infinity,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppSpacing.md),
          child: Stack(
            children: [
            // 假装的下层界面
            Positioned.fill(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      _cs.primaryContainer.withValues(alpha: 0.55),
                      _cs.surface,
                      _cs.secondaryContainer.withValues(alpha: 0.45),
                    ],
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 84,
                      height: 10,
                      decoration: BoxDecoration(
                        color: _cs.onSurface.withValues(alpha: 0.45),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: _cs.onSurface.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // 悬浮窗本体：圆角 16 / 黑底 alpha = opacity / padding 20-12
            Positioned.fill(
              child: Container(
                alignment: Alignment.center,
                // 水平 20 对齐原生 rootView 的 `setPadding(dp(20), …, dp(20), …)`。
                // 少了这层，预览里歌词可用的横向空间会比真机悬浮窗宽 40dp ——
                // 32sp 时预览刚好挤下、真机却已经要换行/省略，预览就会**美化**实际
                // 效果（2026-10-10 在真机上把字号拉满后对比确认）。
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                decoration: BoxDecoration(
                  color: _cs.scrim.withValues(alpha: alpha),
                  borderRadius: BorderRadius.circular(AppSpacing.md),
                  boxShadow: [
                    BoxShadow(
                      color: _cs.shadow.withValues(alpha: 0.35),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                // 只撑满宽度、不撑满高度：撑满高度会让外层 Container 的
                // alignment: center 失效，歌词被顶到预览卡上沿（2026-10-10 实测）。
                // 宽度必须 tight，否则 Text 拿到无界宽度、渐变 shader 无从建立。
                child: SizedBox(
                  width: double.infinity,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildPreviewLine(
                        '夜色像潮水漫过这条街',
                        progress: 0.62,
                        fontSize: fontSize,
                        emphasized: true,
                      ),
                      if (_svc.doubleLine) ...[
                        const SizedBox(height: 2),
                        _buildPreviewLine(
                          '我们把没说完的话留给明天',
                          progress: 0,
                          fontSize: fontSize,
                          emphasized: false,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

  /// 一句预览歌词：底层是未唱色，上层按 [progress] 裁切出已经唱过的渐变部分。
  ///
  /// 这是原生 `GradientTextView` 的简化模型 —— 它用 Canvas clip + LinearGradient
  /// shader 做逐字着色，这里用两层 Stack + ClipRect 达到同样的视觉效果。
  Widget _buildPreviewLine(
    String text, {
    required double progress,
    required double fontSize,
    required bool emphasized,
  }) {
    // 只画文字本身：已唱渐变 / 未唱色，不加描边、阴影、底板 —— 与原生
    // GradientTextView 保持一致（2026-10-10 用户要求去掉一切多余样式）。
    final base = TextStyle(
      fontSize: fontSize,
      height: 1.34,
      fontWeight: emphasized ? FontWeight.w700 : FontWeight.w400,
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints cons) {
        return Stack(
          children: [
            Text(
              text,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: base.copyWith(color: _unplayed.withValues(alpha: 0.92)),
            ),
            ClipRect(
              clipper: _LeadingFractionClipper(progress),
              child: Text(
                text,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: base.copyWith(
                  foreground: Paint()
                    ..shader = LinearGradient(colors: [_g1, _g2])
                        .createShader(
                          Rect.fromLTWH(0, 0, cons.maxWidth, fontSize * 1.34),
                        ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // ==========================================================================
  // 配色
  // ==========================================================================

  Widget _buildColorSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsGroupHeading('配色'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              ...DesktopLyricService.gradientPresets
                  .asMap()
                  .entries
                  .map((e) => _buildPresetSwatch(e.key, e.value.$1, e.value.$2)),
              // 第 5 个：「自定义」。画的是自定义槽位当前的颜色，随自调实时更新；
              // 预设是常量，自调的产物只进这个槽位。
              _buildCustomSwatch(),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        _buildDisclosure(
          label: '自调颜色',
          hint: _isGradient ? '渐变' : '单色',
          expanded: _colorExpanded,
          accent: _g1,
          onTap: () {
            AppHaptics.lightImpact(HapticCategory.control);
            // 展开 = 进入自调颜色；收起 = 切回预设配色（渐变恢复成上次选中的预设）。
            // 展开态本身由 colorMode 派生，这里不需要 setState。
            _svc.setColorMode(
              _colorExpanded
                  ? DesktopLyricService.kColorModePreset
                  : DesktopLyricService.kColorModeCustom,
            );
          },
        ),
        AnimatedSize(
          duration: kThemeAnimationDuration,
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _colorExpanded
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Column(
                    children: [
                      _buildHueRow(
                        label: '已唱',
                        value: _draggingSungHue ??
                            _hueOf(_svc.gradientStart).toDouble(),
                        color: _colorFromHue(
                          _draggingSungHue ??
                              _hueOf(_svc.gradientStart).toDouble(),
                        ),
                        onChanged: (v) {
                          AppHaptics.tick(HapticCategory.control);
                          setState(() => _draggingSungHue = v);
                          // 与原生一致：拖"已唱"会把渐变两端并成一个色
                          final c = _argbFromHue(v);
                          // ignore: discarded_futures
                          _svc.setGradient(start: c, end: c, persist: false);
                        },
                        onEnd: (v) async {
                          setState(() => _draggingSungHue = null);
                          final c = _argbFromHue(v);
                          await _svc.setGradient(start: c, end: c);
                        },
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      _buildHueRow(
                        label: '未唱',
                        value: _draggingUnsungHue ??
                            _hueOf(_svc.unplayedColor).toDouble(),
                        color: _colorFromHue(
                          _draggingUnsungHue ??
                              _hueOf(_svc.unplayedColor).toDouble(),
                        ),
                        onChanged: (v) {
                          AppHaptics.tick(HapticCategory.control);
                          setState(() => _draggingUnsungHue = v);
                          // ignore: discarded_futures
                          _svc.setUnplayedColor(
                            _argbFromHue(v),
                            persist: false,
                          );
                        },
                        onEnd: (v) async {
                          setState(() => _draggingUnsungHue = null);
                          await _svc.setUnplayedColor(_argbFromHue(v));
                        },
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        '拖动"已唱"会把渐变两端合并为同一颜色，'
                        '恢复渐变请重新选择上方预设。',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: _cs.onSurfaceVariant,
                              height: 1.5,
                            ),
                      ),
                    ],
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  Widget _buildPresetSwatch(int index, int start, int end) {
    return _buildSwatch(
      index: index,
      start: start,
      end: end,
      // 选中态跟配色模式走（模式是唯一真相），与原生面板同一规则：
      // 预设配色 → 按真实颜色值匹配；自调颜色 → 只亮「自定义」。
      selected: _svc.colorMode == DesktopLyricService.kColorModePreset &&
          _svc.matchedPresetIndex == index,
      onTap: () => _svc.selectGradientPreset(index),
    );
  }

  /// 第 5 个「自定义」色块：画的是**自定义槽位**当前的颜色，随自调结果实时更新。
  Widget _buildCustomSwatch() {
    return _buildSwatch(
      index: DesktopLyricService.gradientPresets.length,
      start: _svc.customStart,
      end: _svc.customEnd,
      selected: _svc.colorMode == DesktopLyricService.kColorModeCustom &&
          _svc.isCustomGradient,
      onTap: () => _svc.selectCustomGradient(),
    );
  }

  Widget _buildSwatch({
    required int index,
    required int start,
    required int end,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final c1 = Color(start).withValues(alpha: 1);
    final c2 = Color(end).withValues(alpha: 1);
    final swatch = Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [c1, c2],
        ),
        borderRadius: BorderRadius.circular(AppSpacing.sm),
        border: Border.all(
          color: _cs.outline.withValues(alpha: 0.4),
        ),
        boxShadow: selected
            ? [
                BoxShadow(
                  color: c2.withValues(alpha: 0.55),
                  blurRadius: 16,
                  spreadRadius: -2,
                ),
              ]
            : null,
      ),
    );
    final child = AnimatedContainer(
      duration: kThemeChangeDuration,
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppSpacing.sm + 2),
        border: Border.all(
          width: 2,
          color: selected ? c1 : Colors.transparent,
        ),
      ),
      padding: const EdgeInsets.all(2),
      child: swatch,
    );
    if (!kTvBuild) {
      return InkWell(
        borderRadius: BorderRadius.circular(AppSpacing.sm + 2),
        onTap: () {
          AppHaptics.lightImpact(HapticCategory.control);
          // ignore: discarded_futures
          onTap();
        },
        child: child,
      );
    }
    return DpadFocusable(
      onSelect: () {
        AppHaptics.lightImpact(HapticCategory.control);
        // ignore: discarded_futures
        onTap();
      },
      child: child,
    );
  }

  /// 折叠触发：`hint` 位显示渐变/单色状态 —— 把"拖色相会合并两端"这条
  /// 隐藏行为摊到界面上，而不是让用户发现渐变莫名不见了。
  Widget _buildDisclosure({
    required String label,
    required String hint,
    required bool expanded,
    required Color accent,
    required VoidCallback onTap,
  }) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Icon(
            expanded ? Icons.expand_less : Icons.expand_more,
            size: 18,
            color: _cs.onSurfaceVariant,
          ),
          const SizedBox(width: AppSpacing.xs),
          Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: _cs.onSurface,
                ),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(AppSpacing.xxs),
            ),
            child: Text(
              hint,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: accent,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
        ],
      ),
    );
    if (!kTvBuild) return InkWell(onTap: onTap, child: row);
    return DpadFocusable(onSelect: onTap, child: row);
  }

  /// 色相条：轨道是全色相环，滑块头染成当前选中的颜色本身。
  ///
  /// 这里刻意不用 M3ESlider —— 它只支持纯色轨道，而这里需要的是彩虹渐变；
  /// 备注给 AGENTS 约定 7 的例外。
  Widget _buildHueRow({
    required String label,
    required double value,
    required Color color,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onEnd,
  }) {
    final sliderChildren = <Widget>[
      Text(
        label,
        style: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: _cs.onSurfaceVariant),
      ),
      Expanded(
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: Colors.transparent,
            inactiveTrackColor: Colors.transparent,
            overlayColor: Colors.transparent,
            trackHeight: 12,
            trackShape: const _RainbowTrackShape(),
            thumbShape: const RoundSliderThumbShape(
              enabledThumbRadius: 9,
              disabledThumbRadius: 9,
              pressedElevation: 2,
            ),
            thumbColor: color,
          ),
          // kTvBuild 时 M3ESlider 会吞四方向键，必须换 RemoteSlider（P-C）
          child: kTvBuild
              ? RemoteSlider(
                  value: value,
                  min: 0,
                  max: 360,
                  divisions: 360,
                  label: '${value.round()}°',
                  activeColor: color,
                  onChanged: onChanged,
                  onChangeEnd: onEnd,
                )
              : Slider(
                  value: value,
                  min: 0,
                  max: 360,
                  divisions: 360,
                  label: '${value.round()}°',
                  onChanged: onChanged,
                  onChangeEnd: onEnd,
                ),
        ),
      ),
      SizedBox(
        width: 40,
        child: Text(
          '${value.round()}°',
          textAlign: TextAlign.end,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: _cs.onSurface,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
        ),
      ),
    ];
    return Row(children: sliderChildren);
  }

  // ==========================================================================
  // 版式：字号 / 行式
  // ==========================================================================

  Widget _buildTypeSection() {
    final fontSize = _draggingFontSize ?? _svc.fontSize;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsGroupHeading('版式'),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Row(
            children: [
              Text(
                '字号',
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: _cs.onSurface),
              ),
              const Spacer(),
              Text(
                '${fontSize.round()} sp',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: _cs.primary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              _buildStepper(
                glyphSize: 11,
                tooltip: '减小字号',
                enabled: fontSize > DesktopLyricService.minFontSize,
                onTap: () async {
                  AppHaptics.lightImpact(HapticCategory.control);
                  final next = (fontSize - 2)
                      .clamp(
                        DesktopLyricService.minFontSize,
                        DesktopLyricService.maxFontSize,
                      );
                  await _svc.setFontSize(next);
                },
              ),
              Expanded(
                // kTvBuild 时 M3ESlider 会吞四方向键，必须换 RemoteSlider（P-C）
                child: kTvBuild
                    ? RemoteSlider(
                        value: fontSize,
                        min: DesktopLyricService.minFontSize,
                        max: DesktopLyricService.maxFontSize,
                        divisions: 20,
                        label: '${fontSize.round()} sp',
                        onChanged: (v) {
                          AppHaptics.tick(HapticCategory.control);
                          setState(() => _draggingFontSize = v);
                          // ignore: discarded_futures
                          _svc.setFontSize(v, persist: false);
                        },
                        onChangeEnd: (v) async {
                          setState(() => _draggingFontSize = null);
                          await _svc.setFontSize(v);
                        },
                      )
                    : M3ESlider(
                        decoration: _panelSliderDecoration,
                        value: fontSize,
                        min: DesktopLyricService.minFontSize,
                        max: DesktopLyricService.maxFontSize,
                        divisions: 20,
                        label: '${fontSize.round()} sp',
                        onChanged: (v) {
                          AppHaptics.tick(HapticCategory.control);
                          setState(() => _draggingFontSize = v);
                          // ignore: discarded_futures
                          _svc.setFontSize(v, persist: false);
                        },
                        onChangeEnd: (v) async {
                          setState(() => _draggingFontSize = null);
                          await _svc.setFontSize(v);
                        },
                      ),
              ),
              _buildStepper(
                glyphSize: 18,
                tooltip: '增大字号',
                enabled: fontSize < DesktopLyricService.maxFontSize,
                onTap: () async {
                  AppHaptics.lightImpact(HapticCategory.control);
                  final next = (fontSize + 2)
                      .clamp(
                        DesktopLyricService.minFontSize,
                        DesktopLyricService.maxFontSize,
                      );
                  await _svc.setFontSize(next);
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Row(
            children: [
              Text(
                '行式',
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: _cs.onSurface),
              ),
              const Spacer(),
              SizedBox(
                height: 40,
                child: SegmentedButton<bool>(
                  // 容器固定 40 高，关闭额外触控留白，避免文字被推低 4px。
                  style: SegmentedButton.styleFrom(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  segments: const [
                    ButtonSegment<bool>(value: false, label: Text('单行')),
                    ButtonSegment<bool>(value: true, label: Text('双行')),
                  ],
                  selected: <bool>{_svc.doubleLine},
                  showSelectedIcon: false,
                  onSelectionChanged: (Set<bool> next) async {
                    AppHaptics.lightImpact(HapticCategory.control);
                    await _svc.setDoubleLine(next.first);
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// A− / A+：字形本身就在说明它做什么，不需要额外的文案。
  Widget _buildStepper({
    required double glyphSize,
    required String tooltip,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    final child = Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: _cs.surfaceContainerHighest.withValues(
          alpha: enabled ? 0.7 : 0.28,
        ),
        borderRadius: BorderRadius.circular(AppSpacing.sm),
      ),
      child: Text(
        'A',
        style: TextStyle(
          fontSize: glyphSize,
          fontWeight: FontWeight.w700,
          height: 1,
          color: enabled ? _cs.onSurface : _cs.onSurfaceVariant,
        ),
      ),
    );
    final tap = enabled
        ? () {
            AppHaptics.lightImpact(HapticCategory.control);
            onTap();
          }
        : null;
    if (!kTvBuild) {
      return Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: tap,
          borderRadius: BorderRadius.circular(AppSpacing.sm),
          child: child,
        ),
      );
    }
    return DpadFocusable(onSelect: tap ?? () {}, child: child);
  }

  // ==========================================================================
  // 外观：不透明度 / 锁定
  // ==========================================================================

  Widget _buildSurfaceSection() {
    final opacity = _draggingOpacity ?? _svc.opacity.toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsGroupHeading('外观'),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Row(
            children: [
              Text(
                '不透明度',
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: _cs.onSurface),
              ),
              const Spacer(),
              Text(
                '${opacity.round()}%',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: _cs.primary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 0, 10, 0),
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: Colors.transparent,
              inactiveTrackColor: Colors.transparent,
              overlayColor: Colors.transparent,
              trackHeight: 18,
              trackShape: _AlphaTrackShape(checkerA: _checkerA, checkerB: _checkerB),
              thumbShape: const RoundSliderThumbShape(
                enabledThumbRadius: 6,
                disabledThumbRadius: 6,
              ),
              thumbColor: _cs.onPrimary,
            ),
            child: kTvBuild
                ? RemoteSlider(
                    value: opacity,
                    min: 0,
                    max: 100,
                    divisions: 100,
                    label: '${opacity.round()}%',
                    onChanged: (v) {
                      AppHaptics.tick(HapticCategory.control);
                      setState(() => _draggingOpacity = v);
                      // ignore: discarded_futures
                      _svc.setOpacity(v.round(), persist: false);
                    },
                    onChangeEnd: (v) async {
                      setState(() => _draggingOpacity = null);
                      await _svc.setOpacity(v.round());
                    },
                  )
                : Slider(
                    value: opacity,
                    min: 0,
                    max: 100,
                    divisions: 100,
                    label: '${opacity.round()}%',
                    onChanged: (v) {
                      AppHaptics.tick(HapticCategory.control);
                      setState(() => _draggingOpacity = v);
                      // ignore: discarded_futures
                      _svc.setOpacity(v.round(), persist: false);
                    },
                    onChangeEnd: (v) async {
                      setState(() => _draggingOpacity = null);
                      await _svc.setOpacity(v.round());
                    },
                  ),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        _buildLockRow(),
      ],
    );
  }

  Color get _checkerA => _cs.onSurface.withValues(alpha: 0.06);
  Color get _checkerB => _cs.onSurface.withValues(alpha: 0.20);

  /// 锁定：一整条状态行，而不是一个开关。
  ///
  /// 锁定会让悬浮窗变成 FLAG_NOT_TOUCHABLE —— 既能穿透，也意味着
  /// **悬浮窗自身再也点不到**，只能从设置页或通知栏解锁。这么重的后果
  /// 必须写清楚再让用户按。
  Widget _buildLockRow() {
    final locked = _svc.locked;
    final accent = _cs.error;
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: locked ? 0.14 : 0.07),
          borderRadius: BorderRadius.circular(AppSpacing.md),
          border: Border.all(color: accent.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Icon(locked ? Icons.lock : Icons.lock_open, size: 18, color: accent),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    locked ? '已锁定 · 点击穿透' : '锁定歌词',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: _cs.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    locked
                        ? '悬浮窗已不可点击，需在此处或通知栏解锁'
                        : '开启后悬浮窗不再接收触摸，手指可穿过它操作下层界面',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: _cs.onSurfaceVariant,
                          height: 1.4,
                        ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (!kTvBuild) {
      return InkWell(
        borderRadius: BorderRadius.circular(AppSpacing.md),
        onTap: () async {
          AppHaptics.lightImpact(HapticCategory.control);
          if (locked) {
            await _svc.unlock();
          } else {
            await _svc.lock();
          }
        },
        child: row,
      );
    }
    return DpadFocusable(
      onSelect: () async {
        AppHaptics.lightImpact(HapticCategory.control);
        if (locked) {
          await _svc.unlock();
        } else {
          await _svc.lock();
        }
      },
      child: row,
    );
  }

  // ==========================================================================
  // 颜色工具
  // ==========================================================================

  /// 原生用 `Color.colorToHSV` 取色相做 SeekBar 初值，这里等价实现。
  int _hueOf(int argb) {
    final hsv = HSVColor.fromColor(Color(argb).withValues(alpha: 1));
    return hsv.hue.round();
  }

  /// 原生用 `Color.HSVToColor(floatArrayOf(hue, 1f, 1f))`，饱和度与明度恒为 1。
  /// `toARGB32()` 即 0xAARRGGBB —— 与原生 ARGB int 同构，可直接进 SharedPreferences。
  int _argbFromHue(double hue) {
    return HSVColor.fromAHSV(1, hue, 1, 1).toColor().toARGB32();
  }

  Color _colorFromHue(double hue) => HSVColor.fromAHSV(1, hue, 1, 1).toColor();
}

/// 按行内进度裁掉右侧 —— 用来把"已唱过的部分"着色为渐变、其余保持未唱色。
class _LeadingFractionClipper extends CustomClipper<Rect> {
  const _LeadingFractionClipper(this.fraction);

  final double fraction;

  @override
  Rect getClip(Size size) {
    return Rect.fromLTRB(0, 0, size.width * fraction.clamp(0.0, 1.0), size.height);
  }

  @override
  bool shouldReclip(covariant _LeadingFractionClipper oldClipper) {
    return oldClipper.fraction != fraction;
  }
}

/// 全色相环轨道：色相条没有"已选/未选"的语义，整条都要画满色环。
class _RainbowTrackShape extends RoundedRectSliderTrackShape {
  const _RainbowTrackShape();

  static const List<Color> _rainbow = [
    Color(0xFFFF0000),
    Color(0xFFFFFF00),
    Color(0xFF00FF00),
    Color(0xFF00FFFF),
    Color(0xFF0000FF),
    Color(0xFFFF00FF),
    Color(0xFFFF0000),
  ];

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    Offset? secondaryOffset,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    if (sliderTheme.trackHeight case final double trackHeight) {
      final trackLeft = offset.dx;
      final trackTop = offset.dy + (parentBox.size.height - trackHeight) / 2;
      final trackWidth = parentBox.size.width;
      final rect = Rect.fromLTWH(trackLeft, trackTop, trackWidth, trackHeight);
      final rrect = RRect.fromRectAndRadius(
        rect,
        Radius.circular(trackHeight / 2),
      );
      final canvas = context.canvas;
      canvas.drawRRect(
        rrect,
        Paint()
          ..shader = const LinearGradient(colors: _rainbow)
              .createShader(rect),
      );
      canvas.drawRRect(
        rrect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = const Color(0x42FFFFFF),
      );
    }
  }
}

/// 不透明度轨道：**这块轨道本身就是答案**。
///
/// 棋盘格表示"透出去"，上面叠一层从全透到近乎全黑的渐层 —— 滑块停在哪，
/// 悬浮窗的背景就是哪个透明度。比一个灰色滑杆诚实得多。
class _AlphaTrackShape extends RoundedRectSliderTrackShape {
  const _AlphaTrackShape({required this.checkerA, required this.checkerB});

  final Color checkerA;
  final Color checkerB;

  static const double _cell = 6;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    Offset? secondaryOffset,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    final trackHeight = sliderTheme.trackHeight ?? 8;
    final trackLeft = offset.dx;
    final trackTop = offset.dy + (parentBox.size.height - trackHeight) / 2;
    final trackWidth = parentBox.size.width;
    final rect = Rect.fromLTWH(trackLeft, trackTop, trackWidth, trackHeight);
    final canvas = context.canvas;
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(
      rect,
      Radius.circular(trackHeight / 2),
    ));
    // 1) 棋盘格
    final checkerPaint = Paint();
    for (double y = rect.top; y < rect.bottom; y += _cell) {
      for (double x = rect.left; x < rect.right; x += _cell) {
        final odd = (((x - rect.left) ~/ _cell) + ((y - rect.top) ~/ _cell)) % 2;
        checkerPaint.color = odd == 0 ? checkerA : checkerB;
        canvas.drawRect(
          Rect.fromLTWH(
            x,
            y,
            _cell.clamp(0, rect.right - x).toDouble(),
            _cell.clamp(0, rect.bottom - y).toDouble(),
          ),
          checkerPaint,
        );
      }
    }
    // 2) 0 → 92% 的黑：与原生 opacity × 255 / 100 同一换算
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: const [Color(0x00000000), Color(0xEB000000)],
        ).createShader(rect),
    );
    canvas.restore();
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(trackHeight / 2)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0x42FFFFFF),
    );
  }
}
