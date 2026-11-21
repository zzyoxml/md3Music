/// —— 伴唱（伴奏轨）混音纯逻辑层 ——
///
/// 与 [AudioService] 里的交叉淡化纯逻辑层（`crossfadeGains`）同风格：
/// 无副作用、不触碰播放器，便于单测。
///
/// **伴唱固定为纯伴奏**（[AccompanyMix.mix] 恒为 1.0，原曲静音）。
///
/// 为什么不再提供比例调节：在线伴奏是**两条独立解码管线**（原曲与伴奏各自
/// 一个 `AudioPlayer`、各自一个 `AudioTrack`），两路的排队深度不同，这层物理
/// 延迟差无法用媒体位置对齐消除。一旦比例小于 1，原曲与伴奏会同时出声，
/// 错位立刻可闻 —— 这正是历史上偏移滑块与自动对齐一路加到现在仍对不上的
/// 根因。固定纯伴奏从物理上消除了「两路同时出声」这个前提。
///
/// 端侧模型分离只有**一条**输出管线，不存在上述问题，但它也不需要比例调节
/// 之外的语义扩展，因此复用同一个常量。
library;

/// 伴唱混音比例。
///
/// [mix] 为伴奏占比，取值恒为 [accompanyOnly]（1.0）。保留该类是为了让
/// 上层（AudioService / PlayerProvider / 音量子系统）沿用既有签名，避免
/// 大范围改接口。
class AccompanyMix {
  /// 伴奏占比：固定 1.0（纯伴奏，原曲静音）。
  final double mix;

  const AccompanyMix._(this.mix);

  /// 纯伴奏：原曲静音，只听伴奏（伴唱开启时的唯一形态）。
  static const AccompanyMix accompanyOnly = AccompanyMix._(1.0);

  /// 是否为「纯原曲」——此时伴唱轨无意义（可省掉一路解码）。
  bool get isOriginalOnly => false;

  /// 是否为「纯伴奏」——原曲静音。
  bool get isAccompanyOnly => true;

  /// 按 [userVolume] 与响度衰减 [attenuation] 换算两路的目标音量。
  ///
  /// - 原曲：恒为 0（纯伴奏，原曲静音）
  /// - 伴奏：`userVolume`
  ///
  /// [attenuation] 是主播放器的响度归一衰减倍率，对原曲一路生效；伴奏轨
  /// **不参与响度归一**（它是另一首歌，响度不同，套用原曲的衰减会误压），
  /// 故伴奏一路只按用户音量缩放。纯伴奏下原曲静音，该参数实际不再影响输出，
  /// 保留是为了签名稳定。
  ({double original, double accompany}) volumes({
    required double userVolume,
    double attenuation = 1.0,
  }) {
    final base = userVolume.clamp(0.0, 1.0);
    return (original: 0.0, accompany: base);
  }

  @override
  bool operator ==(Object other) =>
      other is AccompanyMix && (other.mix - mix).abs() < 1e-9;

  @override
  int get hashCode => mix.hashCode;

  @override
  String toString() => 'AccompanyMix(mix: $mix)';
}

/// 伴唱轨与主播放器的最大允许位置偏差（毫秒）。
///
/// 两路各自解码、各自推进，位置会缓慢漂移（起播点不同、网络缓冲时机不同）。
/// 偏差超过该阈值时把伴唱轨重新定位到主播放器当前位置，保证「歌词唱到哪、
/// 伴奏就跟到哪」。
///
/// 阈值取 250ms：旧值 500ms 让「刚好卡在阈值边缘」的偏差（实测 499ms）永远
/// 不触发校正，听感就是伴奏一直慢半拍；250ms 已能被多数场景容忍，同时由
/// 2s seek 冷却兜住频繁校正的开销。
const int kAccompanyMaxDriftMs = 250;

/// 伴唱轨是否需要重新对齐到 [mainPositionMs]。
///
/// 偏差超过 [kAccompanyMaxDriftMs] 才校正：过小的抖动频繁 seek 反而制造
/// 卡顿（每次 seek 都要重新缓冲）。
bool accompanyNeedsResync({
  required int mainPositionMs,
  required int accompanyPositionMs,
}) {
  final drift = (mainPositionMs - accompanyPositionMs).abs();
  return drift > kAccompanyMaxDriftMs;
}

/// 伴唱轨当前能否执行校正性 seek。
///
/// `just_audio.seek()` 在 `ProcessingState.loading` 时**静默丢弃**
/// （见 fork `just_audio.dart` 的 `case ProcessingState.loading: return;`），
/// 因此伴唱轨尚未 ready 时发起的 seek 不会生效 —— 这正是「伴奏有概率无法
/// 对齐」的主因：刚起播时的校正被吞掉，且此后伴唱轨若无位置事件就再无
/// 校正机会。
///
/// 判定只看 ready 态；idle（未装载）与 loading（装载中）都不可 seek。
bool accompanyCanResync({required bool ready}) => ready;
