import 'dart:convert';
import 'dart:async';
import 'dart:io';

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
    // 游标文件落盘在单元测试里隔离掉：默认走「偏好项单键」回退路径，
    // 避免 Windows 上 path_provider 真写到用户目录、跨用例串状态。
    PlayerStateRepository.debugCursorFileOverride = () async => null;
  });

  tearDown(() {
    PlayerStateRepository.debugCursorFileOverride = null;
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

  test('游标写入独立小文件：不再写偏好项，恢复优先读文件，清理会删文件', () async {
    final Directory dir = await Directory.systemTemp.createTemp('cursor_store');
    addTearDown(() async {
      PlayerStateRepository.debugCursorFileOverride = () async => null;
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    PlayerStateRepository.debugCursorFileOverride =
        () async => File('${dir.path}/playback_cursor.json');

    final repo = PlayerStateRepository();
    final songs = [_song('a'), _song('b')];
    await repo.saveState(
      currentSong: songs[1],
      playlist: songs,
      currentIndex: 1,
      position: const Duration(seconds: 30),
      loopMode: 'one',
      shuffleEnabled: true,
    );

    final prefs = await SharedPreferences.getInstance();
    // 关键回归：走小文件时不得再触碰偏好项（那会触发整表重写的 ~40ms 主线程开销）。
    expect(prefs.getString('player_cursor'), isNull);
    expect(prefs.getString('player_current_song'), isNull);
    final File file = File('${dir.path}/playback_cursor.json');
    expect(await file.exists(), isTrue);

    final state = await repo.restoreState();
    expect(state, isNotNull);
    expect(state!.currentSong.id, 'b');
    expect(state.playlist.map((song) => song.id), ['a', 'b']);
    expect(state.currentIndex, 1);
    expect(state.position, const Duration(seconds: 30));
    expect(state.loopMode, 'one');
    expect(state.shuffleEnabled, isTrue);

    await repo.clearState();
    expect(await file.exists(), isFalse);
    expect(await repo.restoreState(), isNull);
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

  test('队列中损坏条目被跳过，保留可解析的当前歌曲', () async {
    final currentSong = _song('valid-current');
    SharedPreferences.setMockInitialValues({
      'player_current_song': jsonEncode(currentSong.toJson()),
      'player_playlist': ['{not valid json', jsonEncode(currentSong.toJson())],
      'player_current_index': 0,
    });

    final state = await PlayerStateRepository().restoreState();
    expect(state, isNotNull);
    expect(state!.currentSong.id, currentSong.id);
    expect(state.playlist.map((song) => song.id), [currentSong.id]);
    expect(state.currentIndex, 0);
  });

  test('偏好字段类型损坏时使用安全默认值并降级为当前歌曲', () async {
    final currentSong = _song('typed-current');
    SharedPreferences.setMockInitialValues({
      'player_current_song': jsonEncode(currentSong.toJson()),
      'player_playlist': 'not-a-string-list',
      'player_current_index': 'not-an-int',
      'player_position': 'not-an-int',
      'player_loop_mode': false,
      'player_shuffle_enabled': 'not-a-bool',
    });

    final state = await PlayerStateRepository().restoreState();
    expect(state, isNotNull);
    expect(state!.currentSong.id, currentSong.id);
    expect(state.playlist.map((song) => song.id), [currentSong.id]);
    expect(state.currentIndex, 0);
    expect(state.position, Duration.zero);
    expect(state.loopMode, 'off');
    expect(state.shuffleEnabled, isFalse);
  });

  test('旧版歌曲字段缺失时仍能恢复并应用模型默认值', () async {
    const legacySong = {
      'id': 'legacy-song',
      'title': '旧版歌曲',
      'artist': '旧版歌手',
      'album': '旧版专辑',
      'duration': 90000,
    };
    SharedPreferences.setMockInitialValues({
      'player_current_song': jsonEncode(legacySong),
      'player_playlist': [jsonEncode(legacySong)],
      'player_current_index': 0,
    });

    final state = await PlayerStateRepository().restoreState();
    expect(state, isNotNull);
    expect(state!.currentSong.id, 'legacy-song');
    expect(state.currentSong.isOnline, isFalse);
    expect(state.currentSong.isCloud, isFalse);
    expect(state.currentSong.isLongAudio, isFalse);
    expect(state.currentSong.isLocallyFavorited, isFalse);
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

  test('较早的慢队列写入不会覆盖随后提交的最新队列和游标', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final repo = PlayerStateRepository(
      beforeWrite: (step) async {
        if (step == 'playlist.value' && !entered.isCompleted) {
          entered.complete();
          await release.future;
        }
      },
    );
    final queueWrite = repo.savePlaylist([_song('old')]);
    await entered.future;
    final latestQueueWrite = repo.savePlaylist([_song('latest'), _song('new')]);
    final cursorWrite = repo.saveCursor(
      currentSong: _song('new'),
      currentIndex: 1,
      position: const Duration(seconds: 12),
      loopMode: 'off',
      shuffleEnabled: false,
    );
    release.complete();
    await Future.wait([queueWrite, latestQueueWrite, cursorWrite]);

    final state = await repo.restoreState();
    expect(state!.playlist.map((song) => song.id), ['latest', 'new']);
    expect(state.currentSong.id, 'new');
    expect(state.currentIndex, 1);
    expect(state.position, const Duration(seconds: 12));
  });

  test('清空作为写入屏障执行，后续旧写不会复活已清队列', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final repo = PlayerStateRepository(
      beforeWrite: (step) async {
        if (step == 'cursor.write' && !entered.isCompleted) {
          entered.complete();
          await release.future;
        }
      },
    );
    final pendingCursor = repo.saveCursor(
      currentSong: _song('stale'),
      currentIndex: 0,
      position: Duration.zero,
      loopMode: 'off',
      shuffleEnabled: false,
    );
    await entered.future;
    final clear = repo.clearState();
    release.complete();
    await Future.wait([pendingCursor, clear]);
    expect(await repo.restoreState(), isNull);
  });

  test('flush 等待调用时已排队的持久化写入完成，且不包含其后新写入', () async {
    final gate = Completer<void>();
    final entered = Completer<void>();
    final repo = PlayerStateRepository(
      beforeWrite: (step) async {
        if (step != 'cursor.write' || entered.isCompleted) return;
        entered.complete();
        await gate.future;
      },
    );

    final firstWrite = repo.saveCursor(
      currentSong: _song('flush-target'),
      currentIndex: 0,
      position: const Duration(seconds: 8),
      loopMode: 'off',
      shuffleEnabled: false,
    );
    await entered.future;

    var flushed = false;
    final flush = repo.flush().then((_) => flushed = true);
    await Future<void>.value();
    expect(flushed, isFalse);

    // 排在 flush 之后提交的写入不属于本次屏障。
    final laterWrite = repo.saveCursor(
      currentSong: _song('later-write'),
      currentIndex: 0,
      position: const Duration(seconds: 9),
      loopMode: 'off',
      shuffleEnabled: false,
    );

    gate.complete();
    await flush;
    expect(flushed, isTrue);

    await Future.wait([firstWrite, laterWrite]);
    expect((await repo.restoreState())?.currentSong.id, 'later-write');
  });

  test('一个字段写失败会回传错误，但不阻塞后续清理屏障', () async {
    final repo = PlayerStateRepository(
      beforeWrite: (step) async {
        if (step == 'cursor.write') {
          throw StateError('injected write failure');
        }
      },
    );
    final failedWrite = repo.saveCursor(
      currentSong: _song('partial'),
      currentIndex: 0,
      position: Duration.zero,
      loopMode: 'off',
      shuffleEnabled: false,
    );
    await expectLater(failedWrite, throwsStateError);
    await repo.clearState();
    expect(await repo.restoreState(), isNull);
  });

  // 完整快照现由「游标小文件 + 队列偏好项」两段组成（旧版逐键 6 段已废弃）。
  for (final failedStep in ['state.cursor_store', 'state.playlist']) {
    test('完整快照写入在$failedStep失败后仍能降级恢复一致游标', () async {
      final originalSong = _song('original');
      await PlayerStateRepository().saveState(
        currentSong: originalSong,
        playlist: [originalSong],
        currentIndex: 0,
        position: const Duration(seconds: 5),
        loopMode: 'off',
        shuffleEnabled: false,
      );
      var injected = false;
      final repo = PlayerStateRepository(
        beforeWrite: (step) async {
          if (step == failedStep && !injected) {
            injected = true;
            throw StateError('injected failure at $step');
          }
        },
      );

      final updatedSongs = [_song('updated-1'), _song('updated-current')];
      await expectLater(
        repo.saveState(
          currentSong: updatedSongs[1],
          playlist: updatedSongs,
          currentIndex: 1,
          position: const Duration(seconds: 12),
          loopMode: 'all',
          shuffleEnabled: true,
        ),
        throwsStateError,
      );

      final state = await repo.restoreState();
      expect(injected, isTrue);
      expect(state, isNotNull);
      // 无论失败落在游标还是队列，恢复结果必须自洽：
      // 当前歌一定在队列里、索引指向它、进度落在曲目时长内。
      expect(state!.playlist[state.currentIndex].id, state.currentSong.id);
      expect(state.position.inMilliseconds, greaterThanOrEqualTo(0));
      expect(state.position, lessThanOrEqualTo(state.currentSong.duration));
    });
  }

  test('恢复时按当前歌曲校正索引并将进度限制在曲目时长内', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'player_current_song',
      jsonEncode(_song('2').toJson()),
    );
    await prefs.setStringList('player_playlist', [
      jsonEncode(_song('1').toJson()),
      jsonEncode(_song('2').toJson()),
    ]);
    await prefs.setInt('player_current_index', 0);
    await prefs.setInt(
      'player_position',
      const Duration(minutes: 9).inMilliseconds,
    );

    final state = await PlayerStateRepository().restoreState();
    expect(state!.currentIndex, 1);
    expect(state.playlist[state.currentIndex].id, state.currentSong.id);
    expect(state.position, const Duration(minutes: 3));
  });

  test('队列快照不含当前歌时降级为当前歌曲的单曲恢复', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'player_current_song',
      jsonEncode(_song('current').toJson()),
    );
    await prefs.setStringList('player_playlist', [
      jsonEncode(_song('stale').toJson()),
    ]);
    await prefs.setInt('player_current_index', 0);

    final state = await PlayerStateRepository().restoreState();
    expect(state!.playlist.map((song) => song.id), ['current']);
    expect(state.currentIndex, 0);
  });

  test('5000首队列flush后可完整恢复且游标仍指向当前歌曲', () async {
    final playlist = List.generate(5000, (index) => _song('large-$index'));
    final currentIndex = playlist.length - 1;
    final repo = PlayerStateRepository();

    await repo.savePlaylist(playlist);
    await repo.saveCursor(
      currentSong: playlist[currentIndex],
      currentIndex: currentIndex,
      position: const Duration(seconds: 30),
      loopMode: 'all',
      shuffleEnabled: true,
    );
    await repo.flush();

    final state = await repo.restoreState();
    expect(state, isNotNull);
    expect(state!.playlist, hasLength(5000));
    expect(state.currentIndex, currentIndex);
    expect(state.playlist[state.currentIndex].id, state.currentSong.id);
    expect(state.currentSong.id, 'large-4999');
    expect(state.position, const Duration(seconds: 30));
  });
}
