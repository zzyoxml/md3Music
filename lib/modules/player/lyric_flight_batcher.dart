import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;

import 'full_player_route.dart';

/// 播放页「歌词类提交」在**转场窗口内排队**，等 `playerExpansion` 落到 0/1 端点后一次性应用。
///
/// **为什么需要它**：真机 profile 实测两段 `gapMax≈49ms` 的巨帧，窗口内都恰好出现
/// `[RomaToggle] 歌词加载`，且 `pageBuilds` 各 5 次——也就是 loading 态、封面主色、
/// 正文首包、最终补全、失败兜底这几处 `setState` 全砸在飞行帧里，和封面形变抢同一批帧。
/// 歌词晚一个转场（400ms）出现没有观感损失：那段时间页面还在淡入、歌词本来不可读；
/// 而飞行帧被整页重建打断是直接可见的卡顿。
///
/// **只做排队，不改任何语义**：待应用的动作原封不动交给宿主闭包，由宿主在应用时刻
/// 复核 `mounted` 与代际（转场期间可能已经切歌、或页面实例已被交接给路由那一侧）。
/// 同帧内的多次 `setState` 只会让元素重建一次，所以 flush 是「一批改动、一次重建」，
/// 而不是把五次重建挪到端点后连打五帧。
///
/// 为什么不顺手把 `KugouProvider.notifyListeners()` 也管起来：两个播放页取歌词走的是
/// `context.read<KugouProvider>()`（不是 watch），provider 的通知不会掀动播放页整树；
/// 而别处的 watch 依赖这套通知的即时性，改它会牵连歌词之外的消费者。
class LyricFlightBatcher {
  LyricFlightBatcher({required this.isHostMounted});

  /// 宿主是否还活着。落位时若已卸载，排队的动作直接丢弃
  /// （对已卸载的 State 调 `setState` 会抛）。
  final bool Function() isHostMounted;

  final List<VoidCallback> _pending = <VoidCallback>[];
  bool _listening = false;
  bool _flushScheduled = false;

  /// 不在转场中 → 立即执行（保持原有行为）；转场中 → 排队并挂端点监听。
  void schedule(VoidCallback apply) {
    if (!_inFlight) {
      _traceNow();
      apply();
      return;
    }
    if (_kLyricTraceEnabled) {
      _trace('defer p=${_p3()} pending=${_pending.length + 1} → 排队等落位');
    }
    _pending.add(apply);
    if (_listening) return;
    _listening = true;
    playerExpansion.addListener(_onExpansion);
  }

  /// 立刻应用全部排队动作。正常由端点触发；宿主异常路径与测试可直接调。
  void flush() {
    _detach();
    if (_pending.isEmpty) return;
    final batch = List<VoidCallback>.of(_pending);
    _pending.clear();
    if (!isHostMounted()) {
      if (_kLyricTraceEnabled) {
        _trace('flush p=${_p3()} applied=${batch.length} → 宿主已卸载，丢弃');
      }
      return;
    }
    if (_kLyricTraceEnabled) {
      _trace('flush p=${_p3()} applied=${batch.length} → 落位后提交');
    }
    for (final apply in batch) {
      apply();
    }
  }

  /// 宿主 dispose：撤监听并丢队列——不能把提交带到已卸载的 State 上。
  ///
  /// **丢弃是安全的**：排队的内容全是「取词的启动」或「取词结果的提交」，宿主换成了
  /// 落位后存活的那个实例时，它会因 `_lastSongId` 为空而自己重新走一遍；`KugouProvider`
  /// 的 LRU 缓存保证那次重新走不发网络。
  void dispose() {
    if (_kLyricTraceEnabled) {
      _trace('dispose 丢弃 pending=${_pending.length} → 宿主在落位前被销毁，由存活实例重取');
    }
    _detach();
    _pending.clear();
  }

  /// 诊断日志的生效档（debug + profile）：release 连消息字符串都不拼。
  /// 判据与封面形变那条线同源（`player_cover_morph.dart` 的 [coverMorphPerfLogEnabled]），
  /// 但本文件不引它，就地用同一组常量写一次，免得 lyric 侧反向依赖播放页仪表。
  static const bool _kLyricTraceEnabled = kDebugMode || kProfileMode;

  /// 是否正处于转场窗口（开区间 `(0,1)`）。宿主用它决定「现在就启动取词」还是
  /// 「交给 [schedule] 延到落位后」——判定只在这里一处，别处不要再抄一份。
  bool get isInFlight => _inFlight;

  /// 转场窗口 = 开区间 `(0, 1)`，与封面形变层的绘制窗口同源。
  bool get _inFlight {
    final p = playerExpansion.value;
    return p > 0.0 && p < 1.0;
  }

  void _onExpansion() {
    if (_inFlight) return; // 还在飞，继续等落位
    if (_flushScheduled) return;
    _flushScheduled = true;
    // 不在端点那一帧冲刷：`playerExpansion` 写成 1.0 的同一批微任务里，本类监听先于
    // 形变层的端点 build 执行，同帧冲刷会把整页重建压在**着陆帧**上（真机实测
    // gapMax 49.2ms / 57.9ms，观感就是「松手那一下顿」）。让出一帧再提交。
    //
    // 用 `scheduleFrameCallback` 而不是 `addPostFrameCallback`：后者只把回调塞进列表、
    // **不会自己排帧**（`scheduler/binding.dart` 的 `addPostFrameCallback` 函数体就一句
    // `_postFrameCallbacks.add(callback)`）——落位后若没有任何东西再触发帧，提交就会一直
    // 悬着、歌词永远不更新。前者自带 scheduleFrame，回调落在下一帧的 beginFrame 阶段，
    // 此时 setState 仍然合法（不在 build 里）。
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _flushScheduled = false;
      // 落位后又立刻起了新一段转场：交给下一次落位，绝不把提交打进飞行帧。
      if (_inFlight) {
        if (_kLyricTraceEnabled) {
          _trace('skip p=${_p3()} → 又起新一段，提交继续等下一次落位');
        }
        return;
      }
      flush();
    });
  }

  /// 真机取证：把每一次调度判定连 `playerExpansion` 一起打出来。
  ///
  /// 为什么需要：上一轮只能靠日志时间戳反推，结果发现「歌词到达」与端点是**同一毫秒**
  /// ——说明这些提交根本没进队列（调度时 `p` 已是端点，走了立即执行分支）。
  /// 没有这条日志就只能继续猜，而猜错方向就是白做一轮。
  /// 立即执行分支的诊断（拼串也在判据内）：`schedule` 的这条路是真机最常见的一条。
  void _traceNow() {
    if (!_kLyricTraceEnabled) return;
    _trace('now p=${_p3()} pending=${_pending.length} → 立即执行（未排队）');
  }

  void _trace(String message) {
    if (!_kLyricTraceEnabled) return;
    // ignore: avoid_print
    print('[LyricBatch] $message');
  }

  String _p3() => playerExpansion.value.toStringAsFixed(3);

  void _detach() {
    if (!_listening) return;
    playerExpansion.removeListener(_onExpansion);
    _listening = false;
  }
}
