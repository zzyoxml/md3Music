import 'dart:async';

import '../../providers/player_provider.dart';
import 'windows_taskbar.dart';

/// 把 [PlayerProvider] 的播放状态编排成任务栏进度条更新。
///
/// ## 为什么单独一个同步器
///
/// 任务栏进度有两个性质完全不同的数据源：
///
/// - **位置**走 `player.positionNotifier`（约 200ms 一次，**不**触发
///   `notifyListeners`，这是既有性能优化的结果）；
/// - **播放态 / 时长 / 当前歌曲**走 `notifyListeners`（低频、事件驱动）。
///
/// 如果位置也照搬 200ms 推给 Shell，任务栏会每秒被重绘 5 次——Windows 任务栏
/// 的重绘代价远高于应用内一条进度条。因此这里做 **1s 节流**，并且节流窗口内
/// 的最后一次更新会在窗口末尾补推（只丢中间值，不丢末态）。
///
/// 反过来，播放/暂停/切歌这类**语义事件**必须立即生效（暂停后进度条要马上
/// 变黄、切歌后不能停在上一个进度），所以它们会重置节流窗口并立刻推送。
///
/// ## 挂载口径
///
/// 与 `FmWidgetSync` 同模式：App 首帧后 `attach(player)`，`dispose` 时
/// `detach()`。非 Windows 平台 attach 直接返回，零开销、零通道调用。
class WindowsTaskbarSync {
  WindowsTaskbarSync._();

  static final WindowsTaskbarSync instance = WindowsTaskbarSync._();

  /// 位置推送的最小间隔。
  ///
  /// 取 1s：任务栏进度条只有几百像素宽，1s 一格的视觉步进完全够用，而
  /// 1s/次的重绘开销可以忽略。AGENTS 里「进度条类细微变化默认 4fps」说的是
  /// **应用内**自绘控件；系统任务栏是外部进程重绘，代价更高，故更稀。
  static const Duration minInterval = Duration(seconds: 1);

  PlayerProvider? _player;
  Timer? _throttle;
  /// 节流窗口内是否还有未推送的位置更新（窗口末尾补推用）。
  bool _pending = false;

  /// 绑定播放器并立刻推一拍（恢复播放场景首帧就有进度）。
  void attach(PlayerProvider player) {
    if (!WindowsTaskbar.supported) return;
    if (identical(_player, player)) return;
    detach();
    _player = player;
    player.positionNotifier.addListener(_onPositionChanged);
    player.addListener(_onPlayerChanged);
    _push();
  }

  /// 解绑并取消节流定时器。
  void detach() {
    final player = _player;
    _player = null;
    _throttle?.cancel();
    _throttle = null;
    _pending = false;
    if (player == null) return;
    player.positionNotifier.removeListener(_onPositionChanged);
    player.removeListener(_onPlayerChanged);
  }

  /// 高频位置更新：节流推送，窗口末尾补推最后一次。
  void _onPositionChanged() {
    if (_player == null) return;
    if (_throttle != null) {
      _pending = true;
      return;
    }
    _push();
    _throttle = Timer(minInterval, () {
      _throttle = null;
      if (!_pending) return;
      _pending = false;
      _push();
    });
  }

  /// 播放态 / 切歌 / 时长变化：语义事件，立即推送并重置节流窗口。
  void _onPlayerChanged() {
    if (_player == null) return;
    _throttle?.cancel();
    _throttle = null;
    _pending = false;
    _push();
  }

  void _push() {
    final player = _player;
    if (player == null) return;
    final song = player.currentSong;
    final duration = player.duration ?? Duration.zero;
    // 没有当前歌曲、或时长还没回填（在线源刚起播 / 电台）时不显示进度：
    // 留一条 0% 的假进度比不显示更容易被误读成「卡住了」。
    final visible = song != null && duration > Duration.zero;
    // ignore: discarded_futures
    WindowsTaskbar.setState(
      position: player.position,
      duration: duration,
      isPlaying: player.isPlaying,
      visible: visible,
    );
  }
}
