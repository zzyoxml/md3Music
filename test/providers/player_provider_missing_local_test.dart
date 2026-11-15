import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/core/services/remote/remote_storage_config.dart';
import 'package:md3music/data/repositories/player_state_repository.dart';
import 'package:md3music/providers/player_provider.dart';

import '../support/controlled_audio_service.dart';

class _Audio extends ControlledAudioService {
  Future<void> stop() async => pause();
}

Song _song(String id, String path, {bool online = false}) => Song(
  id: id, title: id, artist: '歌手', album: '专辑',
  duration: const Duration(minutes: 3), localPath: path,
  isOnline: online, url: online ? 'https://example.com/$id.mp3' : null,
);

// 自动完成替身装载，不借助真实音频设备；缺失文件不应进入该装载步骤。
Future<void> _settle(Future<void> operation, _Audio audio) async {
  var done = false;
  final observed = operation.whenComplete(() => done = true);
  final clock = Stopwatch()..start();
  while (!done && clock.elapsed < const Duration(seconds: 8)) {
    for (var i = 0; i < audio.playlistLoads.length; i++) {
      if (!audio.playlistLoads[i].isCompleted) await audio.completeSourceLoad(i);
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  await observed.timeout(const Duration(seconds: 1));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late _Audio audio;
  late PlayerProvider player;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PlayerStateRepository.debugCursorFileOverride = () async => null;
    directory = await Directory('tmp').createTemp('missing-local-');
    audio = _Audio();
    AudioServiceLoader.setTestOverride(() async => audio);
    player = PlayerProvider();
    await player.audioReady;
  });
  tearDown(() async {
    await player.flushPersistence();
    player.dispose();
    await audio.dispose();
    AudioServiceLoader.setTestOverride(null);
    PlayerStateRepository.debugCursorFileOverride = null;
    await directory.delete(recursive: true);
  });

  test('已删除本地文件从队列移除并继续有效歌曲，随机还原也不会复活', () async {
    final valid = await File('${directory.path}/valid.mp3').writeAsBytes([1, 2, 3]);
    final missing = _song('missing', File('${directory.path}/missing.mp3').absolute.path);
    final good = _song('good', valid.absolute.path);
    await _settle(player.playPlaylist([missing, good], 0), audio);
    expect(player.playlist.map((s) => s.id), ['good']);
    expect(player.currentSong?.id, 'good');
    expect(player.currentIndex, 0);
    expect(audio.playlistLoads, hasLength(1));
    expect(await valid.readAsBytes(), [1, 2, 3]);
    await player.toggleShuffle();
    await player.toggleShuffle();
    expect(player.playlist.map((s) => s.id), ['good']);
    await player.flushPersistence();
    final prefs = await SharedPreferences.getInstance();
    expect(jsonDecode(prefs.getStringList('player_playlist')!.single)['id'], 'good');
  }, skip: !Platform.isWindows);

  test('连续缺失且队列清空时停止，不尝试装载或死循环', () async {
    final missing = File('${directory.path}/missing.mp3').absolute;
    await _settle(player.playPlaylist([
      _song('a', missing.path), _song('b', missing.uri.toString()),
    ], 0), audio);
    expect(player.playlist, isEmpty);
    expect(player.currentSong, isNull);
    expect(player.currentIndex, -1);
    expect(player.isPlaying, isFalse);
    expect(audio.playlistLoads, isEmpty);
  }, skip: !Platform.isWindows);

  test('暂停后文件被删除，再恢复时移除并播放下一首', () async {
    final file = await File('${directory.path}/delete.mp3').writeAsBytes([1]);
    final missing = _song('deleted-after-load', file.absolute.path);
    final online = _song('online', file.absolute.path, online: true);
    await _settle(player.playPlaylist([missing, online], 0), audio);
    await player.pause();
    await file.delete();
    await _settle(player.resume(), audio);
    expect(player.playlist.map((s) => s.id), ['online']);
    expect(player.currentSong?.id, 'online');
    expect(audio.playlistLoads, hasLength(2));
  }, skip: !Platform.isWindows);

  test('切到已删除的下一首，跳过它并继续后面的歌曲', () async {
    final file = await File('${directory.path}/valid.mp3').writeAsBytes([1]);
    await _settle(player.playPlaylist([
      _song('a', file.absolute.path),
      _song('missing', File('${directory.path}/missing.mp3').absolute.path),
      _song('b', file.absolute.path),
    ], 0), audio);
    await _settle(player.next(), audio);
    expect(player.playlist.map((s) => s.id), ['a', 'b']);
    expect(player.currentSong?.id, 'b');
    expect(player.currentIndex, 1);
  }, skip: !Platform.isWindows);

  test('在线歌曲不因同名本地缓存缺失被移除', () async {
    final song = _song('online', File('${directory.path}/missing.mp3').absolute.path, online: true);
    await _settle(player.playSong(song), audio);
    expect(player.playlist.single.id, 'online');
    expect(audio.playlistLoads, hasLength(1));
  });

  test('WebDAV和UNC路径不会被当作本机文件缺失而移除', () async {
    final remote = _song('webdav', File('${directory.path}/cache.mp3').absolute.path)
        .copyWith(remoteType: SongRemoteType.webdav, url: 'https://example.com/music.mp3');
    await _settle(player.playSong(remote), audio);
    expect(player.currentSong?.id, 'webdav');
    final unc = _song('unc', r'\\offline-server\share\song.mp3');
    await _settle(player.playSong(unc), audio);
    expect(player.currentSong?.id, 'unc');
  }, skip: !Platform.isWindows);

  test('冷启动移除缺失当前曲但保留队列且不自动起播', () async {
    final valid = await File('${directory.path}/valid.mp3').writeAsBytes([1]);
    final missing = _song('missing', File('${directory.path}/missing.mp3').absolute.path);
    final good = _song('good', valid.absolute.path);
    player.dispose();
    await PlayerStateRepository().saveState(
      currentSong: missing, playlist: [missing, good], currentIndex: 0,
      position: const Duration(seconds: 30), loopMode: 'off', shuffleEnabled: false,
    );
    player = PlayerProvider();
    await _settle(player.audioReady, audio);
    expect(player.playlist.map((s) => s.id), ['good']);
    expect(player.currentSong?.id, 'good');
    expect(player.position, Duration.zero);
    expect(audio.playCommandCount, 0);
    expect(player.isPlaying, isFalse);
  }, skip: !Platform.isWindows);

  test('缺失检查期间被新播放请求抢占，不删除新队列', () async {
    final valid = await File('${directory.path}/valid.mp3').writeAsBytes([1]);
    final oldPlay = player.playSong(_song('missing', File('${directory.path}/missing.mp3').absolute.path));
    final newPlay = player.playSong(_song('good', valid.absolute.path));
    await _settle(Future.wait([oldPlay, newPlay]).then((_) {}), audio);
    expect(player.playlist.map((s) => s.id), ['good']);
    expect(player.currentSong?.id, 'good');
  }, skip: !Platform.isWindows);
}
