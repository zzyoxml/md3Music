import '../data/models/song.dart';

/// 交叉淡化备用源的提交凭据，确保异步准备仍属于当前曲间过渡。
class CrossfadePreparationTicket {
  const CrossfadePreparationTicket({
    required this.generation,
    required this.queueRevision,
    required this.currentIndex,
    required this.currentSongId,
    required this.targetIndex,
    required this.targetSong,
  });

  final int generation;
  final int queueRevision;
  final int currentIndex;
  final String? currentSongId;
  final int targetIndex;
  final Song targetSong;

  bool canCommit({
    required int currentGeneration,
    required int currentQueueRevision,
    required int currentIndex,
    required String? currentSongId,
    required List<Song> playlist,
  }) {
    if (generation != currentGeneration ||
        queueRevision != currentQueueRevision ||
        this.currentIndex != currentIndex ||
        this.currentSongId != currentSongId ||
        targetIndex < 0 ||
        targetIndex >= playlist.length) {
      return false;
    }
    final target = playlist[targetIndex];
    return target.id == targetSong.id &&
        target.albumId == targetSong.albumId &&
        target.albumAudioId == targetSong.albumAudioId;
  }
}
