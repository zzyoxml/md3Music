// 「要不要把播放位置推给原生」的纯判定策略。
//
// ## 为什么必须按平台分开
//
// 同一段节流逻辑在 Android 与 Windows 上的**正确间隔完全不同**，原因不是
// 性能口味，而是两个平台的系统层是否自己外推时间轴：
//
// - **Android**：`PlaybackStateCompat` 传入 `STATE_PLAYING` + `position` 后，
//   SystemUI 会**按 elapsed 自行推进**通知进度条。所以 30s 一次只作基线校正，
//   每秒上报反而会让魅族等 ROM 的媒体卡片高频重建（实测主线程/raster/binder
//   持续空转、暂停都降不下功耗）。
// - **Windows SMTC**：**没有这个机制**。
//   `SystemMediaTransportControlsTimelineProperties.Position` 就是 App 最后一次
//   `UpdateTimelineProperties` 写进去的值，系统不会自己走。若沿用 30s，播控中心、
//   任务栏进度条与第三方歌词工具（TaskbarLyrics / AF Media Bar）看到的是
//   「进度冻结 30 秒、然后猛跳一下」。按 Position 取歌词行索引的工具会一直停在
//   同一句 —— 这正是「工具能识别歌曲、歌词却不滚动」的直接原因。
//
// 代价对比：Windows 的一次 `UpdateTimelineProperties` 只是一次属性写入，
// 不重建媒体卡片、不触发 Explorer 重绘，远比 Android 的 `showNotification`
// 便宜，1s 一次完全可接受。
//
// ## 为什么抽成纯函数
//
// 与 `windows/runner/taskbar_progress.h` 同口径：把「间隔怎么定」从 Provider 的
// 状态机里剥离出来，才能用单元测试钉住平台差异。写错这里的表现是「歌词不滚动」，
// 编译期与普通用例都不会报错。
//
// 回归：`test/core/services/notification_position_gate_test.dart`。
import 'package:flutter/foundation.dart';

/// Windows 的位置上报间隔：必须自己推进，1s 一次。
const Duration kWindowsNotificationPositionInterval = Duration(seconds: 1);

/// Android / 其它平台：系统自己外推，30s 一次作基线校正。
const Duration kDefaultNotificationPositionInterval = Duration(seconds: 30);

/// 当前平台该用的位置上报间隔。
///
/// 口径用 [defaultTargetPlatform] 而非 `Platform.isWindows`：后者在 Windows 宿主上
/// 跑 `flutter test` 时同样为 true，会把宿主平台泄漏进本应跑 Android 语义的测试
/// （与本仓 `WindowsFullscreen.supported`、`WindowsTaskbar.supported` 同一教训）。
Duration notificationPositionInterval({
  TargetPlatform? platform,
  bool isWeb = kIsWeb,
}) {
  if (isWeb) return kDefaultNotificationPositionInterval;
  final target = platform ?? defaultTargetPlatform;
  return target == TargetPlatform.windows
      ? kWindowsNotificationPositionInterval
      : kDefaultNotificationPositionInterval;
}

/// 是否该在这一拍把位置推下去。
///
/// 规则：
/// - 暂停时不推：位置不再变化，且暂停瞬间已由 `playingStream(false)` 推过最终态。
/// - 从未推过（[lastPush] 为 null）时立即推：恢复播放 / 起播的首帧就要有正确基线，
///   否则第三方工具要等一整个间隔才拿到第一个位置。
/// - 否则按 [interval] 节流（缺省取 [notificationPositionInterval]）。
bool shouldPushNotificationPosition({
  required bool isPlaying,
  required DateTime? lastPush,
  required DateTime now,
  Duration? interval,
  TargetPlatform? platform,
}) {
  if (!isPlaying) return false;
  final effective = interval ?? notificationPositionInterval(platform: platform);
  if (lastPush == null) return true;
  return now.difference(lastPush) >= effective;
}
