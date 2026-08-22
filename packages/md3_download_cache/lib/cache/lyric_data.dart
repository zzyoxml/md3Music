/// 歌词最小 DTO，与主工程 `KugouLyric` 解耦。
///
/// 包内 `StreamCacheManager` 只收/只产该结构；主工程私有接线层负责
/// 在 `KugouLyric` 与 `LyricData` 之间互转，包不 import 主工程类型。
class LyricData {
  final String content;
  final String? decodedContent;
  final String? decodedKrcContent;
  final String? translatedContent;
  final String? romaContent;

  const LyricData({
    required this.content,
    this.decodedContent,
    this.decodedKrcContent,
    this.translatedContent,
    this.romaContent,
  });
}
