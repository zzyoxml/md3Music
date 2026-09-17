import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/diagnostic_logger.dart';

/// 全局安全区兜底守卫：修正小米 HyperOS 小窗（Freeform）下的 `WindowInsets`
/// 误报，防止 `Scaffold` / `AppBar` 把 body 高度算成负数/接近 0 导致页面白屏。
///
/// ## 问题背景
/// HyperOS 的小窗基于 Android 多窗口 Freeform 方案实现。在小窗状态下，系统
/// 仍会把状态栏高度（`MediaQuery.padding.top`）报告为全屏值（如 28dp），但小窗
/// 整体可能只有 80~100dp 高。`Scaffold` 用该 padding 推导 AppBar 位置与 body
/// 可用高度，导致 body 高度塌陷为 0 以下，页面主体白屏（而底部导航栏、迷你
/// 播放器、全局背景层不受影响，因为它们独立于 body 之外）。
///
/// ## 修复策略
/// - 检测异常大的安全区（`padding.top/bottom >= 窗口高度 * [阈值]`，正常全屏
///   不可能达到，只有小窗才可能），将其钳制为 0，保证 body 保留最小可视高度。
/// - 监听原生 `window_mode` 通道，进入/退出小窗等窗口模式切换时强制 rebuild，
///   兜底刷新在 native 侧已经粘滞的错误 insets。
/// - 触发钳制时记录一次诊断日志，便于 adb 上机取证（[DiagnosticLogger]）。
///
/// 挂载位置：`MaterialApp.builder` 内、`DisplayScaleScope` 的 child、内容层
/// `Stack` 的外层，使 Scaffold / AppBar / NavigationBar 与所有
/// `MediaQuery.paddingOf` 消费点统一受益。
class SafeInsetsGuard extends StatefulWidget {
  const SafeInsetsGuard({super.key, required this.child});

  final Widget child;

  @override
  State<SafeInsetsGuard> createState() => _SafeInsetsGuardState();
}

class _SafeInsetsGuardState extends State<SafeInsetsGuard> {
  /// 原生窗口模式切换通道：进入/退出小窗时由 MainActivity 主动通知。
  static const MethodChannel _windowModeChannel =
      MethodChannel('com.md3music.md3music/window_mode');

  /// 触发钳制的安全区占比阈值：正常全屏下状态栏/底部手势条占比远低于此值，
  /// 只有小窗这种「安全区≈整窗高度」的异常场景才可能达到。
  static const double _insetHeightRatioThreshold = 0.4;

  /// 窗口模式剁变时是否已重建过，用于幂等去重（避免每次 insets 变都重建）。
  bool _notified = false;

  @override
  void initState() {
    super.initState();
    _windowModeChannel.setMethodCallHandler((call) async {
      if (call.method != 'onWindowModeChanged') return;
      // Flutter 的 MediaQuery 已随 metrics 自动更新，此处主要作为粘滞 insets
      // 未被 native 正确刷新时的兜底：强制重建以重新钳制。
      if (mounted) {
        setState(() => _notified = true);
      }
    });
  }

  @override
  void dispose() {
    _windowModeChannel.setMethodCallHandler(null);
    super.dispose();
  }

  /// 是否需要钳制（避免每次 build 都取整，仅在真正异常时收敛）。
  bool _needsClamp(MediaQueryData mq) {
    final h = mq.size.height;
    if (h <= 0) return false;
    return mq.padding.top >= h * _insetHeightRatioThreshold ||
        mq.padding.bottom >= h * _insetHeightRatioThreshold;
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    if (!_needsClamp(mq)) {
      _notified = false;
      return widget.child;
    }

    // 仅在首次触发时记录一次诊断采样（避免小窗内每帧刷屏）。
    if (!_notified) {
      _notified = true;
      DiagnosticLogger.instance.w(
        'SafeInsetsGuard 触发钳制: size=${mq.size}, '
        'padding.top=${mq.padding.top}, padding.bottom=${mq.padding.bottom}',
      );
    }

    // 把异常大的顶部/底部安全区钳制为 0（同步 padding 与 viewPadding，
    // 与 DisplayScaleScope.applyDisplayScale 保持同样的字段处理口径）。
    final clampedPadding =
        mq.padding.copyWith(top: 0.0, bottom: 0.0);
    final clampedViewPadding =
        mq.viewPadding.copyWith(top: 0.0, bottom: 0.0);
    return MediaQuery(
      data: mq.copyWith(
        padding: clampedPadding,
        viewPadding: clampedViewPadding,
      ),
      child: widget.child,
    );
  }
}