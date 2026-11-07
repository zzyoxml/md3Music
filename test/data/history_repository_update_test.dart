import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/data/repositories/history_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    HistoryRepository.debugResetForTest();
  });

  Song thinSong() => Song(
        id: 'abc',
        title: '未知歌曲',
        artist: '未知歌手',
        album: '',
        duration: Duration.zero,
        isOnline: true,
        albumAudioId: 'mix',
      );

  group('替换历史条目（元数据富化后就地修正）', () {
    test('同 id 条目被替换且位置不变', () async {
      final repo = HistoryRepository();
      await repo.addHistory(thinSong());
      await repo.addHistory(Song(
        id: 'xyz',
        title: '另一首',
        artist: '别的歌手',
        album: '',
        duration: Duration.zero,
        isOnline: true,
      ));

      await repo.replaceHistoryEntry(Song(
        id: 'abc',
        title: '某首歌',
        artist: '某歌手',
        album: '某专辑',
        duration: const Duration(seconds: 200),
        isOnline: true,
        albumAudioId: 'mix',
        artistId: '12345',
        albumId: '67890',
        artworkUri: 'https://img/x.jpg',
      ));

      final history = await repo.getHistory();
      expect(history.length, 2, reason: '替换不得新增条目');
      expect(history[0].id, 'xyz', reason: '位置不得改变（替换不重排）');
      expect(history[1].id, 'abc');
      expect(history[1].title, '某首歌');
      expect(history[1].artistId, '12345');
      expect(history[1].albumId, '67890');
    });

    test('不存在的 id 是 no-op（不插入、不报错）', () async {
      final repo = HistoryRepository();
      await repo.addHistory(thinSong());
      await repo.replaceHistoryEntry(Song(
        id: 'not-exist',
        title: '幽灵',
        artist: '幽灵',
        album: '',
        duration: Duration.zero,
        isOnline: true,
      ));
      final history = await repo.getHistory();
      expect(history.length, 1);
      expect(history[0].id, 'abc');
    });

    test('替换不改动播放计数（不是一次新播放）', () async {
      final repo = HistoryRepository();
      await repo.addHistory(thinSong());
      final before = (await repo.getPlayCounts())['abc'];
      await repo.replaceHistoryEntry(Song(
        id: 'abc',
        title: '某首歌',
        artist: '某歌手',
        album: '',
        duration: Duration.zero,
        isOnline: true,
      ));
      expect((await repo.getPlayCounts())['abc'], before);
      expect(before, 1, reason: '前置条件：addHistory 记了 1 次');
    });
  });
}
