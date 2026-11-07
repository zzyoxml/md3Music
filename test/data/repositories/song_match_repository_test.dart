import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/repositories/song_match_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _key = 'local_song_match_map';

SongMatchInfo _info(
  String localId, {
  String hash = 'h_default',
  SongMatchSource source = SongMatchSource.manual,
  bool dismissed = false,
}) {
  return SongMatchInfo(
    localId: localId,
    hash: hash,
    title: '在线歌名',
    artist: '在线歌手',
    album: '在线专辑',
    albumAudioId: '12345',
    durationMs: 182000,
    source: source,
    dismissed: dismissed,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SongMatchRepository.debugResetForTest();
  });

  tearDown(() {
    SongMatchRepository.debugResetForTest();
  });

  test('put + get 往返；isMatched 判定', () async {
    final repo = SongMatchRepository();
    await repo.ensureLoaded();
    expect(repo.isMatched('local_/a.mp3'), isFalse);

    await repo.put(_info('local_/a.mp3'));
    final info = repo.get('local_/a.mp3');
    expect(info, isNotNull);
    expect(info!.hash, 'h_default');
    expect(info.albumAudioId, '12345');
    expect(repo.isMatched('local_/a.mp3'), isTrue);

    // 未匹配记录（无 hash）不算有效匹配
    await repo.put(const SongMatchInfo(localId: 'local_/b.mp3', hash: ''));
    expect(repo.isMatched('local_/b.mp3'), isFalse);
  });

  test('manual 覆盖 auto；dismiss 后自动匹配不可复活、manual 可复活', () async {
    final repo = SongMatchRepository();
    await repo.ensureLoaded();

    await repo.put(_info('local_/a.mp3', hash: 'auto1',
        source: SongMatchSource.auto));
    await repo.put(_info('local_/a.mp3', hash: 'manual1',
        source: SongMatchSource.manual));
    expect(repo.get('local_/a.mp3')!.hash, 'manual1');

    await repo.dismiss('local_/a.mp3');
    expect(repo.get('local_/a.mp3')!.dismissed, isTrue);
    expect(repo.isMatched('local_/a.mp3'), isFalse);

    // 自动匹配 put 不会复活否决记录（dismissed 保留，hash 清空语义在引擎侧
    // 由「dismissed 跳过」保证；这里验证 put 仍可被手动改选复活）
    await repo.put(_info('local_/a.mp3', hash: 'manual2',
        source: SongMatchSource.manual));
    expect(repo.get('local_/a.mp3')!.dismissed, isFalse);
    expect(repo.isMatched('local_/a.mp3'), isTrue);
  });

  test('markAttempted 记录冷却时间戳且不清除已有匹配', () async {
    final repo = SongMatchRepository();
    await repo.ensureLoaded();

    final before = DateTime.now().millisecondsSinceEpoch;
    await repo.markAttempted('local_/none.mp3');
    final info = repo.get('local_/none.mp3');
    expect(info, isNotNull);
    expect(info!.attemptedAt, greaterThanOrEqualTo(before));
    expect(repo.isMatched('local_/none.mp3'), isFalse);

    await repo.put(_info('local_/has.mp3'));
    await repo.markAttempted('local_/has.mp3');
    expect(repo.get('local_/has.mp3')!.hash, 'h_default');
  });

  test('flush 落盘后模拟重启可恢复', () async {
    final repo = SongMatchRepository();
    await repo.ensureLoaded();
    await repo.put(_info('local_/a.mp3', hash: 'persist1'));
    await repo.flush();

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    expect(raw, isNotNull);
    expect((jsonDecode(raw!) as Map<String, dynamic>).keys,
        contains('local_/a.mp3'));

    // 模拟重启：清内存缓存后重新加载
    SongMatchRepository.debugResetForTest();
    final repo2 = SongMatchRepository();
    await repo2.ensureLoaded();
    expect(repo2.get('local_/a.mp3')!.hash, 'persist1');
  });

  test('remove 与 clearAll', () async {
    final repo = SongMatchRepository();
    await repo.ensureLoaded();
    await repo.put(_info('local_/a.mp3'));
    await repo.put(_info('local_/b.mp3'));

    await repo.remove('local_/a.mp3');
    expect(repo.get('local_/a.mp3'), isNull);
    expect(repo.isMatched('local_/b.mp3'), isTrue);

    await repo.clearAll();
    expect(repo.get('local_/b.mp3'), isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(_key), isNull);
  });

  test('脏数据按空表处理不抛错', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, '{not valid json');

    final repo = SongMatchRepository();
    await repo.ensureLoaded();
    expect(repo.get('local_/x.mp3'), isNull);
  });

  test('toSong 构造在线歌曲', () async {
    final song = _info('local_/a.mp3', hash: 'h1').toSong();
    expect(song.id, 'h1');
    expect(song.isOnline, isTrue);
    expect(song.albumAudioId, '12345');
    expect(song.duration, const Duration(milliseconds: 182000));
  });

  test('单曲偏好位（preferOnlineLyrics/Cover）持久化往返', () async {
    final repo = SongMatchRepository();
    await repo.ensureLoaded();

    // 默认关闭
    final info = _info('local_/a.mp3');
    expect(info.preferOnlineLyrics, isFalse);
    expect(info.preferOnlineCover, isFalse);

    // 开启 + 落盘 + 模拟重启回读，只影响这一条记录
    await repo.put(info.copyWith(
      preferOnlineLyrics: true,
      preferOnlineCover: true,
    ));
    await repo.flush();
    SongMatchRepository.debugResetForTest();
    final repo2 = SongMatchRepository();
    await repo2.ensureLoaded();

    final restored = repo2.get('local_/a.mp3')!;
    expect(restored.preferOnlineLyrics, isTrue);
    expect(restored.preferOnlineCover, isTrue);
  });
}
