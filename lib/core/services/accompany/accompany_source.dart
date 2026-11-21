/// 伴唱伴奏来源。
///
/// 两条途径二选一：
/// - [online]：在线伴奏（酷狗按歌匹配另一条伴奏曲目，独立解码并行播放）；
/// - [onDevice]：端侧分离（本机把人声/伴奏拆开，单条输出管线）。
///
/// **为什么在线伴奏不再提供比例调节**：它是两条独立解码管线，两路 AudioTrack
/// 的排队深度不同，这层物理延迟差无法用媒体位置消除；比例一旦小于 1，两路
/// 同时出声就会听到错位。历史上的偏移滑块与自动对齐都没能解决，最终固定为
/// 纯伴奏（见 `AccompanyMix`）。
///
/// **端侧分离为什么没有错位**：只有一条输出管线，分离发生在 AudioProcessor 里，
/// 输出帧与输入帧一一对应，只有固定延迟（见 `kStemSeparateLatencyMs`）。
library;

enum AccompanySource {
  /// 在线伴奏：酷狗匹配另一条伴奏曲目。
  online(wireValue: 'online'),

  /// 端侧分离：本机实时分离原曲。
  onDevice(wireValue: 'on_device');

  const AccompanySource({required this.wireValue});

  /// 持久化用的稳定字符串（改名不影响存量数据）。
  final String wireValue;

  /// 设置项标题。
  String get label => switch (this) {
    AccompanySource.online => '在线伴奏',
    AccompanySource.onDevice => '端侧分离',
  };

  /// 设置项副标题。
  String get description => switch (this) {
    AccompanySource.online => '酷狗匹配这首歌的伴奏曲目（纯伴奏，原曲静音）',
    AccompanySource.onDevice => '本机实时分离人声与伴奏（需模型，仅 Android）',
  };

  /// 从持久化字符串解析；无法识别时回退 [online]（老数据/损坏值）。
  static AccompanySource parse(String? raw) {
    if (raw == null) return AccompanySource.online;
    for (final v in AccompanySource.values) {
      if (v.wireValue == raw) return v;
    }
    return AccompanySource.online;
  }
}
