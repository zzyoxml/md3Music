import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/providers/playlist_prefetch_ticket.dart';

Song song({String id = 'track', String? albumId = 'album', String? url}) =>
    Song(
      id: id,
      title: id,
      artist: 'artist',
      album: 'album',
      duration: const Duration(minutes: 3),
      isOnline: true,
      albumId: albumId,
      albumAudioId: 'audio-$albumId',
      url: url,
    );

void main() {
  group('PlaylistPrefetchTicket', () {
    final target = song();
    final ticket = PlaylistPrefetchTicket(
      queueRevision: 4,
      quality: 'lossless',
      userId: 'user-1',
      song: target,
    );

    bool canCommit({
      int revision = 4,
      String quality = 'lossless',
      String? userId = 'user-1',
      List<Song>? playlist,
    }) => ticket.canCommit(
      currentQueueRevision: revision,
      currentQuality: quality,
      currentUserId: userId,
      currentPlaylist: playlist ?? [target],
    );

    test('相同队列、账号、音质与条目时允许提交', () {
      expect(canCommit(), isTrue);
    });

    test('队列清空、替换或重排后的旧请求均不可提交', () {
      expect(canCommit(revision: 5), isFalse);
      expect(canCommit(revision: 5, playlist: [song(id: 'other')]), isFalse);
    });

    test('切换账号或音质后旧结果不可提交', () {
      expect(canCommit(userId: 'user-2'), isFalse);
      expect(canCommit(quality: 'high'), isFalse);
    });

    test('不会给同 ID 的不同专辑条目或已有 URL 的条目提交', () {
      expect(canCommit(playlist: [song(albumId: 'different-album')]), isFalse);
      expect(
        canCommit(playlist: [song(url: 'https://cdn.invalid/audio')]),
        isFalse,
      );
    });

    test('相同条目的重复队列项仍可复用同一预取 URL', () {
      expect(canCommit(playlist: [target, song()]), isTrue);
    });
  });
}
