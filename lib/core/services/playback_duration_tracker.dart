/// 播放事件时长累计器（CSCC `/user/listen/report` 的 `duration` 语义）。
///
/// 契约（对照参考文档「实际播放毫秒数，扣除暂停及拖动进度的影响」）：
/// - 只累计**真正出声的墙钟时间**：暂停期间不累计；
/// - **拖动进度不产生额外时长**：seek 期间时间轴跳变不计入；
/// - 同一首歌的**开始/结束必须使用一致的设备参数**，故本类只负责时长，
///   设备参数由上报方统一供给；
/// - 一首歌的「一段播放」= `start` 到 `end`；切歌视作前一首 `end`。
///
/// 本类是纯逻辑（无 Flutter/无 IO 依赖），便于单测；时间源通过 [nowMillis]
/// 注入，测试可完全控制时间轴。
class PlaybackDurationTracker {
  PlaybackDurationTracker({int Function()? nowMillis})
      : _nowMillis = nowMillis ?? (() => DateTime.now().millisecondsSinceEpoch);

  final int Function() _nowMillis;

  /// 当前是否有正在计时的播放段（即已 start 未 end）。
  bool get isTracking => _songId != null;

  /// 当前跟踪的歌曲 id（无则 null）。
  String? get songId => _songId;

  String? _songId;
  String? _mixsongid;

  /// 本段已累计的真实播放毫秒数（不含正在进行的这一段？含，实时累加）。
  int _accumulatedMs = 0;

  /// 最近一次进入「播放中」的时间戳（null = 暂停中/未开始）。
  int? _runningSinceMs;

  /// 开始一段播放。
  ///
  /// [songId] 数据层歌曲唯一 id（用于同曲去重判定，可为 local:// 形态）
  /// [mixsongid] CSCC 必填的 song mixsongid（= albumAudioId）
  /// [playing] 该曲此刻是否真的在出声。**必须如实传**：本类按墙钟计时，
  ///   若在「已切歌但尚未起播」（缓冲/暂停切歌）时就把表走起来，会把
  ///   静默等待时间算进 `duration` —— 这正是真机首测出现
  ///   `duration=392555ms`（远超实际收听）的原因：切歌时无条件起表，
  ///   把从切歌到真正出声之间的墙钟全计入了。
  ///   传 false 时只登记歌曲、不起表；待 [setPlaying] true 再起表。
  void start({
    required String songId,
    required String mixsongid,
    bool playing = true,
  }) {
    _songId = songId;
    _mixsongid = mixsongid;
    _accumulatedMs = 0;
    _runningSinceMs = playing ? _nowMillis() : null;
  }

  /// 播放/暂停状态变化。[playing] true = 进入播放，false = 进入暂停。
  ///
  /// 暂停时把已跑的一段并入累计并停表；恢复时重新起表。
  /// 幂等：重复同态调用不改变累计值。
  void setPlaying(bool playing) {
    if (!isTracking) return;
    if (playing) {
      _runningSinceMs ??= _nowMillis();
    } else if (_runningSinceMs != null) {
      final now = _nowMillis();
      _accumulatedMs += now - _runningSinceMs!;
      _runningSinceMs = null;
    }
  }

  /// 拖动进度：seek 期间的时间轴跳变不计入时长。
  ///
  /// 由于本类按墙钟计时而非 position 差值，seek 本身天然不产生额外时长。
  /// 此方法把**已跑的一段先并入累计**再重新起表，避免把 seek 的执行耗时算进去
  /// （USB 独占下 seek 可能触发流重建，耗时可达数百毫秒）。
  ///
  /// 注意必须「先结算再起表」：若只重置 [_runningSinceMs]，会把 seek 之前
  /// 已经播过的时间整段丢掉（这是本方法最初实现的缺陷，由单测锁定）。
  void onSeek() {
    if (!isTracking || _runningSinceMs == null) return;
    final now = _nowMillis();
    _accumulatedMs += now - _runningSinceMs!;
    _runningSinceMs = now;
  }

  /// 结束当前段并返回结果；无进行中的段时返回 null。
  ///
  /// [reason] 结束原因，决定上报的 `state` 取值。
  PlaybackSegment? end({PlaybackEndReason reason = PlaybackEndReason.completed}) {
    final segment = _take(reason);
    return segment;
  }

  /// 结账当前段但**不**改变「是否在计时」的外部语义 —— 与 [end] 等价，
  /// 供 `start` 之外需要「先取段、后另起一段」的调用方使用（见上报服务）。
  PlaybackSegment? snapshot({
    PlaybackEndReason reason = PlaybackEndReason.switched,
  }) =>
      _take(reason);

  PlaybackSegment? _take(PlaybackEndReason reason) {
    final songId = _songId;
    final mixsongid = _mixsongid;
    if (songId == null || mixsongid == null) return null;
    if (_runningSinceMs != null) {
      final now = _nowMillis();
      _accumulatedMs += now - _runningSinceMs!;
      _runningSinceMs = null;
    }
    final segment = PlaybackSegment(
      songId: songId,
      mixsongid: mixsongid,
      durationMs: _accumulatedMs,
      reason: reason,
    );
    _songId = null;
    _mixsongid = null;
    _accumulatedMs = 0;
    return segment;
  }

  /// 主动放弃当前段（不上报），例如关闭开关或退出登录。
  void discard() {
    _songId = null;
    _mixsongid = null;
    _accumulatedMs = 0;
    _runningSinceMs = null;
  }
}

/// 播放段结束原因 → CSCC `state` 取值。
///
/// 参考实现只给出默认值「完整播放」，其余取值属灰色地带；这里按语义最接近的
/// 中文枚举上报，未知/异常统一回落「完整播放」。
enum PlaybackEndReason {
  /// 正常播放到结尾
  completed,

  /// 切歌/换源导致提前结束
  switched,

  /// 用户主动停止
  stopped,
}

extension PlaybackEndReasonState on PlaybackEndReason {
  /// CSCC 事件字段 `state` 的取值。
  String get state {
    switch (this) {
      case PlaybackEndReason.completed:
        return '完整播放';
      case PlaybackEndReason.switched:
        return '切换下一首';
      case PlaybackEndReason.stopped:
        return '手动停止';
    }
  }
}

/// 一次播放段的结果。
class PlaybackSegment {
  const PlaybackSegment({
    required this.songId,
    required this.mixsongid,
    required this.durationMs,
    required this.reason,
  });

  final String songId;
  final String mixsongid;

  /// 实际播放毫秒数（已扣除暂停与拖动）。
  final int durationMs;
  final PlaybackEndReason reason;

  /// 时长是否达到上报门槛（过短不报，避免噪声与风控）。
  bool reachesThreshold(int minMs) => durationMs >= minMs;

  @override
  String toString() =>
      'PlaybackSegment($mixsongid, ${durationMs}ms, ${reason.state})';
}
