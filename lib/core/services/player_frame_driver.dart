import 'dart:async';

import 'package:flutter/widgets.dart';

/// 播放页共享的 60fps 帧驱动。
///
/// **为什么需要它**：歌词（AppleLyricsView 省电模式限帧）与封面旋转/频谱
///（SpectrumArtwork）原本各自持有一个独立的 16ms [Timer]，两者启动时刻随机、
/// 相位错开 → 每 8.3ms 就有一方 `scheduleFrame`，在 120Hz 屏上整页实测
/// 115~120fps（功耗近似翻倍），而**单个组件都只要求 60fps**。
///
/// 把所有 60fps 驱动挂到同一节拍上即可让整页回到 60fps：各订阅者的更新率
/// 不变（仍是 60fps），无视觉降级，只是消除了帧提交的交错。
///
/// 语义：首个订阅者到来时启动定时器，最后一个订阅者离开时停掉（不留空转）；
/// App 退到后台/熄屏时一并停表，回到前台再按订阅情况恢复。
class PlayerFrameDriver with WidgetsBindingObserver {
  PlayerFrameDriver._() {
    WidgetsBinding.instance.addObserver(this);
  }

  static final PlayerFrameDriver instance = PlayerFrameDriver._();

  /// 步进周期（60fps）。与歌词的 eco 限帧、封面旋转步进保持同一节拍。
  static const Duration step = Duration(milliseconds: 16);

  Timer? _timer;
  final List<VoidCallback> _listeners = <VoidCallback>[];

  /// App 是否处于「引擎不产帧」的生命周期（后台 / 熄屏 / 失焦）。
  ///
  /// 闸门放在驱动侧而非各订阅方：一处停表即覆盖全部订阅者，订阅方不必各自
  /// 再记一份生命周期状态（对照 [FlowingBackground] 里那份是历史实现）。
  bool _suspended = false;

  /// 是否已有订阅者（诊断用）。
  bool get hasListeners => _listeners.isNotEmpty;

  /// 当前是否真的在产帧：挂起或无订阅者时为 false（诊断与测试用）。
  bool get isRunning => _timer != null;

  /// 订阅共享节拍。
  void addListener(VoidCallback listener) {
    if (_listeners.contains(listener)) return;
    _listeners.add(listener);
    _syncTimer();
  }

  /// 取消订阅；最后一个订阅者离开时停掉定时器。
  void removeListener(VoidCallback listener) {
    if (!_listeners.remove(listener)) return;
    _syncTimer();
  }

  /// 定时器的唯一收口：有订阅者且未被生命周期挂起时才跑。
  void _syncTimer() {
    if (_listeners.isNotEmpty && !_suspended) {
      _timer ??= Timer.periodic(step, _onTick);
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  /// 停表而非在 [_onTick] 里早退：早退省不掉定时器对 CPU 的周期性唤醒，
  /// 而引擎在后台不合成帧，这些 tick 全是纯功耗（§10.4.3）。
  ///
  /// 恢复后不重置任何订阅方的时间基线：挂起期间订阅关系不变，
  /// 用真实帧间隔推进的订阅方（如 SpectrumArtwork 的包络）自行钳制 dt。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final bool suspended = state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached;
    if (suspended == _suspended) return;
    _suspended = suspended;
    _syncTimer();
  }

  void _onTick(Timer timer) {
    // 拷贝快照：回调内可能增删订阅（如收敛停帧）
    final List<VoidCallback> snapshot = List<VoidCallback>.of(_listeners);
    for (final VoidCallback cb in snapshot) {
      // 同一拍较早的回调可能销毁另一个订阅者；跳过已移除项，避免对已卸载
      // Widget 再触发一次 setState。
      if (_listeners.contains(cb)) cb();
    }
  }
}
