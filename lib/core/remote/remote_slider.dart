import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/remote_control_provider.dart';
import '../build_flags.dart';

/// 遥控模式下的滑块包装器（解决「滑块/进度条焦点收不回来」）。
///
/// Flutter 自带的 [Slider] 默认（traditional 导航模式）把**四个方向键全部**
/// 映射为调值（_AdjustSliderIntent），D-pad 一旦落到滑块上方向键就被吞掉，
/// 无法移出 → 表现为"返回不了"。
///
/// [RemoteSlider] 用 [MediaQuery] 把子树覆盖为
/// [NavigationMode.directional]：Slider 内置的 _directionalNavShortcutMap
/// 只消费左右键（调值），上下键**放行**到焦点遍历，由 D-pad 自然移出滑块。
///
/// **TV 构建（kTvBuild）下无视遥控模式三态开关、恒走 directional**：
/// Dpad.wrap 在 `_tvContentScope` 里无条件安装（只看 kTvBuild），滑杆保护
/// 必须与遍历引擎同开关——否则设备形态判定失败/判非 TV（不少盒子/投影的
/// uiModeManager 不报 TELEVISION）、启动异步初始化窗口期、或用户选
/// always_off 时，滑杆退回 traditional（四方向键全调值），按上下键就困死
/// 焦点（2026-10-07 用户实测）。与 TvFocusHighlight 是同一条教训：
/// TV 焦点组件不得按 [RemoteControlProvider.enabled] 门控。
///
/// 聚焦视觉不在此处叠加（TV 仓库原版用 RemoteFocusRing 包裹，本仓已改用
/// dpad 的 DpadThemeData 特效体系）：Slider 聚焦时使用 Material 自带的
/// focused 态（拇指 halo）。
///
/// 外层必须补一个 [Material]：Flutter 的 `Slider.build` 有
/// `assert(debugCheckHasMaterial(context))`（slider.dart:807），而本仓 UI 走
/// material_ui，树上没有 Flutter 的 `Material` 祖先 —— 设置页等挂载点上该断言
/// 在调试包直接抛错，被全局 `_FallbackErrorWidget` 顶成「此处内容加载出错」
/// （2026-10-04：TV 包设置页所有滑杆整片显示该占位）。
///
/// 遥控模式关闭时**原样返回 Slider**（不注入 FocusNode），触屏行为零变化。
/// （仅对非 TV 构建有意义：kTvBuild 下恒走 directional，见类注释。）
class RemoteSlider extends StatelessWidget {
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String? label;
  final Color? activeColor;
  final Color? inactiveColor;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;

  /// 可选透传给内部 [Slider]（默认 null＝Slider 自建节点，行为不变）。
  /// 仅供需要在测试中定位滑块焦点节点的用例使用。
  final FocusNode? focusNode;

  const RemoteSlider({
    super.key,
    required this.value,
    this.min = 0.0,
    this.max = 1.0,
    this.divisions,
    this.label,
    this.activeColor,
    this.inactiveColor,
    this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
    this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    // tv: TV 构建下 Dpad.wrap 无条件安装，滑杆保护必须与遍历引擎同开关，
    // 不得按 RemoteControlProvider.enabled 门控（判非 TV/启动窗口/always_off
    // 时滑杆退回 traditional，上下键困死焦点——见类注释）。
    // kTvBuild 为 const：非 TV 构建里 RemoteSlider 只出现在 kTvBuild 死分支，
    // 下方 watch 才会执行（provider 门控兜底，触屏行为零变化）。
    final remoteOn = kTvBuild || context.watch<RemoteControlProvider>().enabled;

    // 透明 Material 只提供祖先语义（Slider 的 debugCheckHasMaterial 断言），
    // 不铺色、不裁切、不接墨迹——滑杆自身的绘制完全不受影响。
    final slider = Material(
      type: MaterialType.transparency,
      child: Slider(
        value: value,
        focusNode: focusNode,
        min: min,
        max: max,
        divisions: divisions,
        label: label,
        activeColor: activeColor,
        inactiveColor: inactiveColor,
        onChanged: onChanged,
        onChangeStart: onChangeStart,
        onChangeEnd: onChangeEnd,
      ),
    );

    // 非 TV 构建且遥控模式关闭：原样返回，触屏行为零变化。
    if (!remoteOn) return slider;

    // directional 导航：左右调值、上下移出滑块（TV 构建恒走此分支）。
    return MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(navigationMode: NavigationMode.directional),
      child: slider,
    );
  }
}
