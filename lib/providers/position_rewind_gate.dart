/// 位置回退闸门：抑制「换源装载期间位置从 0 重新计数」造成的假回退。
///
/// 背景：`just_audio` 的 `setUrl`（换源）会让播放器位置从 0 重新开始，直到随后
/// 的 `seek` 落地。这段窗口（`_setUrlAndPlay` 等 `ready` 最长 10s，再 seek）里
/// 若把这个 0 当作真实进度发布给 UI，会出现两类问题：
/// - 进度条 / 时间文字闪回 0:00；
/// - 歌词视图把行号判成第一行 → 滚动目标跳到「歌词开头」，装载完成后从开头
///   长距离滚回当前行（用户看到的就是「暂停后歌词从头滚到当前行」）。
///
/// 闸门语义：装载前 [arm]（以即将 seek 到的目标为下限），装载期间小于下限的
/// 采样被 [shouldSuppress] 判为假回退而丢弃；`seek` 落地后由调用方 [disarm]
/// 放行。内置 [timeout] 兜底：装载卡死超过时限时自动放行，避免位置永久冻结。
///
/// 详见 docs/2026-09-11-pause-lyric-scroll-from-top-analysis.md（方案 A）。
class PositionRewindGate {
  /// 闸门最长保持时间：`_setUrlAndPlay` 等 `ready` 的上限约 10s，留出余量。
  static const Duration timeout = Duration(seconds: 12);

  bool _armed = false;
  Duration _floor = Duration.zero;
  DateTime? _armedAt;

  /// 闸门是否处于开启状态（诊断 / 测试用）。
  bool get armed => _armed;

  /// 当前下限：装载结束后预计到达的位置（诊断 / 测试用）。
  Duration get floor => _floor;

  /// 开启闸门。
  ///
  /// [floor] 为即将 seek 到的目标位置（= 装载后的真实进度）。
  /// `floor <= 0` 表示没有明确目标（例如换源后确实要从 0 开始播），此时不开启。
  void arm(Duration floor, {DateTime? now}) {
    if (floor <= Duration.zero) {
      disarm();
      return;
    }
    _armed = true;
    _floor = floor;
    _armedAt = now ?? DateTime.now();
  }

  /// 关闭闸门：`seek` 落地、装载结束（含失败/异常）时调用。
  void disarm() {
    _armed = false;
    _floor = Duration.zero;
    _armedAt = null;
  }

  /// 判断本次位置采样是否为「换源假回退」，需要丢弃。
  ///
  /// 仅在「开启中 + 采样小于下限 + 未超时」时返回 true；超时则自动关闭闸门并
  /// 放行（装载卡死不能让对外位置永久冻结）。
  bool shouldSuppress(Duration value, {DateTime? now}) {
    if (!_armed) return false;
    final DateTime at = _armedAt ?? DateTime.now();
    if ((now ?? DateTime.now()).difference(at) > timeout) {
      disarm();
      return false;
    }
    return value < _floor;
  }
}
