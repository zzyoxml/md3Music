import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/data/repositories/player_state_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

Song _song(String id, {bool isOnline = false}) {
  return Song(
    id: id,
    title: '测试歌$id',
    artist: '测试歌手',
    album: '测试专辑',
    duration: const Duration(minutes: 3),
    isOnline: isOnline,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('saveState + restoreState 完整回读', () async {
    final repo = PlayerStateRepository();
    final songs = [_song('1'), _song('2', isOnline: true)];
    await repo.saveState(
      currentSong: songs[1],
      playlist: songs,
      currentIndex: 1,
      position: const Duration(seconds: 95),
      loopMode: 'all',
      shuffleEnabled: true,
    );

    final state = await repo.restoreState();
    expect(state, isNotNull);
    expect(state!.currentSong.id, '2');
    expect(state.playlist.map((s) => s.id), ['1', '2']);
    expect(state.currentIndex, 1);
    expect(state.position, const Duration(seconds: 95));
    expect(state.loopMode, 'all');
    expect(state.shuffleEnabled, isTrue);
  });

  test('saveCursor 只更新游标字段，不触碰队列', () async {
    final repo = PlayerStateRepository();
    final songs = [_song('1'), _song('2')];
    await repo.saveState(
      currentSong: songs[0],
      playlist: songs,
      currentIndex: 0,
      position: Duration.zero,
      loopMode: 'off',
      shuffleEnabled: false,
    );

    // 模拟只写游标的高频路径（队列本体未重写）
    await repo.saveCursor(
      currentSong: songs[1],
      currentIndex: 1,
      position: const Duration(seconds: 42),
      loopMode: 'one',
      shuffleEnabled: false,
    );

    final state = await repo.restoreState();
    expect(state!.currentIndex, 1);
    expect(state.position, const Duration(seconds: 42));
    expect(state.loopMode, 'one');
    expect(state.playlist.map((s) => s.id), ['1', '2']);
  });

  test('clearState 后 restoreState 返回 null', () async {
    final repo = PlayerStateRepository();
    await repo.saveState(
      currentSong: _song('1'),
      playlist: [_song('1')],
      currentIndex: 0,
      position: Duration.zero,
      loopMode: 'off',
      shuffleEnabled: false,
    );

    await repo.clearState();
    expect(await repo.restoreState(), isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('player_current_song'), isNull);
    expect(prefs.getStringList('player_playlist'), isNull);
    expect(prefs.getInt('player_position'), isNull);
  });

  test('未保存过任何状态时 restoreState 返回 null', () async {
    final repo = PlayerStateRepository();
    expect(await repo.restoreState(), isNull);
  });

  test('currentSong JSON 损坏时 restoreState 返回 null（不抛异常）', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('player_current_song', '{not valid json');
    final repo = PlayerStateRepository();
    expect(await repo.restoreState(), isNull);
  });

  test('队列为空数组但当前歌存在时同样降级恢复', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'player_current_song',
      jsonEncode(_song('2').toJson()),
    );
    await prefs.setStringList('player_playlist', []);
    final repo = PlayerStateRepository();
    final state = await repo.restoreState();
    expect(state, isNotNull);
    expect(state!.currentSong.id, '2');
    expect(state.playlist.map((s) => s.id), ['2']);
  });

  test('队列缺失但当前歌存在时降级为单曲队列恢复', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'player_current_song',
      jsonEncode(_song('1').toJson()),
    );
    await prefs.setInt('player_position', 27270);
    // 队列键刻意不写（历史数据/写入失败场景）
    final repo = PlayerStateRepository();
    final state = await repo.restoreState();
    expect(state, isNotNull);
    expect(state!.currentSong.id, '1');
    expect(state.playlist.map((s) => s.id), ['1']);
    expect(state.position, const Duration(milliseconds: 27270));
  });
}
