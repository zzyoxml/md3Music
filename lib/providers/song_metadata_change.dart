import '../data/models/song.dart';

/// 判定「晚到的元数据」相对当前播放歌曲是否发生了实质变化。
///
/// 抽成纯函数是为了可测：这个判断守卫着 [PlayerProvider.updateCurrentSongMetadata]
/// 的整个方法体——返回 false 就直接 return，连带跳过紧随其后的
/// `refreshHistoryEntry`。历史上它只比对 title/artist/artworkUri，
/// 导致「时长从 0 补齐」这种变化被整体丢弃：一起听跟随端起播瞬间只有
/// hash 身份（时长为 0，标题是「未知歌曲」占位），富化补齐时长时标题/歌手/
/// 封面可能已经就位，于是三项全等、方法提前返回，历史条目永远停在「无时长」。
///
/// 因此 [duration] 必须纳入比对。
///
/// 注意这里用「变化」而非「一律重推」，是为了让回写保持幂等：
/// 富化可能多轮触发，重复传入同一份元数据不应造成推送风暴。
bool hasMetadataChanged(Song current, Song incoming) {
  return current.title != incoming.title ||
      current.artist != incoming.artist ||
      current.artworkUri != incoming.artworkUri ||
      current.duration != incoming.duration;
}
