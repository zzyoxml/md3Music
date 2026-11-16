import 'dart:async';

import 'package:flutter/widgets.dart';

/// tv: 歌词页遥控焦点状态机——焦点行移动、OK 跳段、自动跟随的暂停/恢复。
///
/// ## 为什么不放在 widget 里
///
/// 同 [TvSeekStepper] / [TvVolumeStepper]：TV 构建下的接线会被 AOT 树摇剔除，
/// `flutter test` 执行不到，必须把判断收进普通构建同样编译的类。
///
/// ## 交互口径
///
/// - 进入歌词区（首次获得焦点）：焦点行 = 当前播放行（[enter] 的 `currentIndex`）；
/// - 上 / 下：焦点行 ∓1，边界夹取（不越界、不循环）；
/// - OK：把焦点行 seek 到它的时间戳（[commit] + `timeMsOfLine`），随后跟随暂停；
/// - 用户**任何**操作（enter / move / commit）都置 `following = false`，
///   静默 [followResumeDelay] 后恢复自动跟随（`following = true`）。
///   这条是「看得见自己在哪一行」与「不要一直抢回去」之间的折中。
class TvLyricsFocus {
  TvLyricsFocus({
    required this.lineCount,
    required this.onSeek,
    this.followResumeDelay = defaultFollowResumeDelay,
  });

  /// 操作后恢复自动跟随的静默时长。
  static const Duration defaultFollowResumeDelay = Duration(seconds: 4);

  /// 当前歌词行数（惰性读取：切歌/重解析会变）。
  final int Function() lineCount;

  /// OK 提交出口：把该行时间戳（毫秒）交给播放器 seek。
  final ValueChanged<int> onSeek;

  final Duration followResumeDelay;

  int? _focused;

  /// 焦点行下标；null = 尚未进入歌词区（或已退出）。
  int? get focusedIndex => _focused;

  bool _following = true;
  Timer? _resume;

  /// 是否仍随播放进度自动滚动。
  bool get following => _following;

  /// 进入歌词区：焦点行落在 [currentIndex]，并暂停自动跟随。
  void enter({required int currentIndex}) {
    final count = lineCount();
    if (count <= 0) return;
    _focused = currentIndex.clamp(0, count - 1);
    _suspendFollow();
  }

  /// 离开歌词区：清焦点行，立即恢复跟随。
  void exit() {
    _focused = null;
    _resume?.cancel();
    _resume = null;
    _following = true;
  }

  /// 上/下移动焦点行（仅上/下消费；左右返回 false 放行）。
  bool move(TraversalDirection direction) {
    if (direction != TraversalDirection.up &&
        direction != TraversalDirection.down) {
      return false;
    }
    final count = lineCount();
    if (count <= 0) return false;
    // 未进入时按当前行进入（调用方负责传 currentIndex；此处保守夹取）。
    final int from = _focused ?? 0;
    _focused = (from + (direction == TraversalDirection.down ? 1 : -1))
        .clamp(0, count - 1);
    _suspendFollow();
    return true;
  }

  /// OK：以焦点行时间戳 seek 一次。
  void commit({required int Function(int index) timeMsOfLine}) {
    final int? index = _focused;
    if (index == null) return;
    final count = lineCount();
    if (index < 0 || index >= count) return;
    onSeek(timeMsOfLine(index));
    _suspendFollow();
  }

  void _suspendFollow() {
    _following = false;
    _resume?.cancel();
    _resume = Timer(followResumeDelay, () {
      _following = true;
    });
  }

  /// 只取消 Timer（页面 dispose 时调用，AGENTS §10.4 第 7 条）。
  void dispose() {
    _resume?.cancel();
    _resume = null;
    _focused = null;
  }
}
