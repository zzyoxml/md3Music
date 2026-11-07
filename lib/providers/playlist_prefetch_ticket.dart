import '../data/models/song.dart';

/// 后台预取结果的提交凭据，避免过期 URL 写入后来被挪到相同索引的歌曲。
class PlaylistPrefetchTicket {
  const PlaylistPrefetchTicket({
    required this.queueRevision,
    required this.quality,
    required this.userId,
    required this.song,
  });

  final int queueRevision;
  final String quality;
  final String? userId;
  final Song song;

  bool canCommit({
    required int currentQueueRevision,
    required String currentQuality,
    required String? currentUserId,
    required List<Song> currentPlaylist,
  }) {
    if (queueRevision != currentQueueRevision ||
        quality != currentQuality ||
        userId != currentUserId) {
      return false;
    }
    return currentPlaylist.any(
      (candidate) =>
          candidate.isOnline &&
          candidate.id == song.id &&
          candidate.albumId == song.albumId &&
          candidate.albumAudioId == song.albumAudioId &&
          candidate.url == null,
    );
  }
}
