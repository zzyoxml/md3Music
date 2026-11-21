import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/providers/crossfade_preparation_ticket.dart';

Song song(String id, {String? albumId, String? albumAudioId}) => Song(
  id: id,
  title: id,
  artist: 'artist',
  album: 'album',
  duration: const Duration(minutes: 3),
  isOnline: true,
  url: 'https://media.example/$id.mp3',
  albumId: albumId,
  albumAudioId: albumAudioId,
);

void main() {
  group('CrossfadePreparationTicket', () {
    final current = song('current');
    final target = song('next', albumId: 'album-1', albumAudioId: 'audio-1');
    final ticket = CrossfadePreparationTicket(
      generation: 3,
      queueRevision: 8,
      currentIndex: 0,
      currentSongId: current.id,
      targetIndex: 1,
      targetSong: target,
    );

    bool canCommit({
      int generation = 3,
      int queueRevision = 8,
      int currentIndex = 0,
      String? currentSongId = 'current',
      List<Song>? playlist,
    }) => ticket.canCommit(
      currentGeneration: generation,
      currentQueueRevision: queueRevision,
      currentIndex: currentIndex,
      currentSongId: currentSongId,
      playlist: playlist ?? [current, target],
    );

    test('只有原曲间身份仍有效时才允许提交', () {
      expect(canCommit(), isTrue);
      expect(canCommit(generation: 4), isFalse);
      expect(canCommit(queueRevision: 9), isFalse);
      expect(canCommit(currentIndex: 1), isFalse);
      expect(canCommit(currentSongId: 'replaced'), isFalse);
    });

    test('目标被移除、重排或同ID替换为不同专辑版本时丢弃', () {
      expect(canCommit(playlist: [current]), isFalse);
      expect(canCommit(playlist: [target, current]), isFalse);
      expect(
        canCommit(
          playlist: [
            current,
            song('next', albumId: 'album-2'),
          ],
        ),
        isFalse,
      );
    });
  });
}
