import 'package:flutter/foundation.dart';

/// 视频播放页（MV / 场景音乐视频）正在前台的全局标志。
///
/// **为什么需要它**：桌面方向键层（`core/widgets/desktop_playback_keys.dart`）把
/// 裸方向键吃成「调音量 / 调进度」。视频页进出时会 `pause()` 背景音频、退出时再
/// `resume()`，音频播放器仍握着上一首的位置 —— 若键盘方向键在视频页继续落到那个
/// 暂停的播放器上，用户退出 MV 再继续播放时会从被悄悄改动过的位置起播（视频里
/// 按左右键看不出任何变化，纯属暗改）。
///
/// 与 `playerDragActive` / `kSuppressResidentMiniPlayer` 同一套「宿主置位、全局层
/// 让行」模式：置位期间方向键整层放行，交给视频页自己的控件（TV 构建下是
/// `_tvVideoFocus` 的 ←/→ ±10s）。
///
/// **为什么不用 `PipService.setVideoActive`**：那条是给原生画中画用的
/// MethodChannel 调用，Dart 侧没有可读状态，拿不到就来判断。
///
/// **为什么用引用计数而不是布尔翻转**：退出动画期间新旧两个视频页可能短暂并存，
/// 布尔翻转会被先 dispose 的那一个提前清掉，让方向键在仍在播放的页面上生效。
final ValueNotifier<bool> kVideoPlaybackActive = ValueNotifier<bool>(false);

int _videoPlaybackRefs = 0;

/// 视频页进入（`initState`）。与 [exitVideoPlayback] 成对调用。
void enterVideoPlayback() {
  _videoPlaybackRefs++;
  kVideoPlaybackActive.value = true;
}

/// 视频页离开（`dispose`）。末个离开者才真正清标志。
void exitVideoPlayback() {
  if (_videoPlaybackRefs > 0) _videoPlaybackRefs--;
  if (_videoPlaybackRefs == 0) kVideoPlaybackActive.value = false;
}
