import 'dart:async';

import 'package:flutter/widgets.dart';

import '../layout/bottom_chrome_scope.dart';
import '../layout/responsive_layout.dart';

/// 等一次进场转场收敛，再去做**会引起整页重建的重活**（拉数据、解析、排序、首屏建列表）。
///
/// 为什么需要它：这些活全部跑在 UI 线程上，一旦落在转场那几十帧里，就会把共享元素
/// 动画直接顶停（真机反馈「进歌单详情时，歌曲列表加载会阻塞动画」）。动画期间页面上
/// 本来只有页头 + 加载占位，列表早到几十毫秒没有任何收益，晚到 300ms 也看不出来。
///
/// 返回实际等待的毫秒数（0 = 没等），便于真机日志核对。
/// [timeout] 是兜底：路由动画可能因被 remove/中断而不再发 `completed`，超时后照常放行，
/// 绝不让数据加载永远不开始。
Future<int> waitUntilEntrySettled(
  Animation<double>? animation, {
  Duration timeout = const Duration(milliseconds: 900),
}) async {
  if (animation == null || animation.status == AnimationStatus.completed) {
    return 0;
  }
  final started = DateTime.now().millisecondsSinceEpoch;
  final done = Completer<void>();
  var detached = false;
  late final void Function(AnimationStatus) onStatus;
  onStatus = (AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    if (!detached) {
      detached = true;
      animation.removeStatusListener(onStatus);
    }
    if (!done.isCompleted) done.complete();
  };

  void detach() {
    if (detached) return;
    detached = true;
    animation.removeStatusListener(onStatus);
  }

  animation.addStatusListener(onStatus);
  await done.future.timeout(timeout, onTimeout: () {});
  detach();
  return DateTime.now().millisecondsSinceEpoch - started;
}

/// 等底部导航栏的**收起动画**结束，再放行会引起整页重建的重活。
///
/// 背景：二级态上报已推迟到进场转场收敛（`ResponsiveShellState
/// ._scheduleDepthReport` 的转场闸门，为了让框架 Hero 飞行期间 Tab 栈高度恒定），
/// 底栏收起动画（[kBottomChromeToggleDuration]，约 260ms）恰好在转场结束时启动；
/// 列表加载若在 [waitUntilEntrySettled] 后立刻开跑，正好撞上收起动画
/// （真机反馈：进歌单详情，列表首屏构建让底栏收起掉帧）。
///
/// 口径（任一命中即视为「已让位」，立即放行，不让加载白等）：
/// - 「二级页面隐藏菜单底栏」关闭——底栏根本不收起，进度恒 0，等不到；
/// - 无 [BottomChromeScope] 祖先 / 坞位不存在（横屏侧栏、桌面双栏、沉浸态、已收起）；
/// - 收起进度到 1.0。
/// [timeout] 是兜底：进度因任何原因读不到 1 也照常放行，绝不让加载永不开始。
Future<void> waitUntilBottomChromeSettled(
  BuildContext context, {
  Duration timeout = const Duration(milliseconds: 1200),
}) async {
  bool settled() {
    if (!kHideNavBarOnSecondaryPages.value) return true;
    final el =
        context.getElementForInheritedWidgetOfExactType<BottomChromeScope>();
    final scope = el?.widget as BottomChromeScope?;
    if (scope == null || !scope.hasBottomChrome) return true;
    return scope.bottomChromeCollapse >= 1.0;
  }

  if (settled()) return;
  final deadline = DateTime.now().add(timeout);
  while (context.mounted && DateTime.now().isBefore(deadline)) {
    // 进度逐帧更新（ResponsiveScaffold 的 AnimatedBuilder 每帧重建 scope），
    // 逐帧轮询读取即可；用 getElementFor 而非 dependOn，避免逐帧重建页面。
    await WidgetsBinding.instance.endOfFrame;
    if (!context.mounted) return;
    if (settled()) return;
  }
}
