import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/data/repositories/settings_repository.dart';
import 'package:md3music/data/repositories/song_match_repository.dart';
import 'package:md3music/providers/song_match_provider.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

KugouSongDetail _candidate({
  required String hash,
  String songName = '晴天',
  String? artistName = '周杰伦',
  String? albumName = '叶惠美',
  int duration = 182,
  String? albumAudioId = '998877',
}) {
  return KugouSongDetail(
    hash: hash,
    songName: songName,
    artistName: artistName,
    albumName: albumName,
    duration: duration,
    albumAudioId: albumAudioId,
  );
}

Song _local({
  String title = '晴天.flac',
  String artist = '周杰伦',
  int seconds = 182,
}) {
  return Song(
    id: 'local_/music/$title',
    title: title,
    artist: artist,
    album: '',
    duration: Duration(seconds: seconds),
    localPath: '/music/$title',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SongMatchRepository.debugResetForTest();
    SongMatchProvider.debugSearchOverride = null;
  });

  tearDown(() {
    SongMatchProvider.debugSearchOverride = null;
  });

  group('pickBestCandidate 高置信门槛', () {
    test('标题+歌手+时长全中 → 命中', () {
      final song = _local();
      final best = SongMatchProvider.pickBestCandidate(song, [
        _candidate(hash: 'h1'),
      ]);
      expect(best, isNotNull);
      expect(best!.hash, 'h1');
      expect(best.source, SongMatchSource.auto);
      expect(best.localId, song.id);
    });

    test('时长差超过 2 秒（remix/live）不自动确认', () {
      final best = SongMatchProvider.pickBestCandidate(_local(), [
        _candidate(hash: 'h1', duration: 186),
      ]);
      expect(best, isNull);
    });

    test('候选时长未知不自动确认', () {
      final best = SongMatchProvider.pickBestCandidate(_local(), [
        _candidate(hash: 'h1', duration: 0),
      ]);
      expect(best, isNull);
    });

    test('歌手对不上不自动确认', () {
      final best = SongMatchProvider.pickBestCandidate(_local(), [
        _candidate(hash: 'h1', artistName: '林俊杰'),
      ]);
      expect(best, isNull);
    });

    test('本地歌手未知时放行（只看标题+时长）', () {
      final best = SongMatchProvider.pickBestCandidate(
        _local(title: '晴天.flac', artist: '未知艺术家'),
        [_candidate(hash: 'h1')],
      );
      expect(best, isNotNull);
    });

    test('合唱写法差异互含放行', () {
      final best = SongMatchProvider.pickBestCandidate(_local(), [
        _candidate(hash: 'h1', artistName: '周杰伦、费玉清'),
      ]);
      expect(best, isNotNull);
    });

    test('标题噪声（空格/标点/大小写）不影响相似度', () {
      final best = SongMatchProvider.pickBestCandidate(
        _local(title: 'Love Story (Taylor\'s Version).mp3'),
        [
          _candidate(
            hash: 'h1',
            songName: 'love story  taylors version',
          ),
        ],
      );
      expect(best, isNotNull);
    });
  });

  group('runAutoMatch 引擎', () {
    test('命中后落库 source=auto', () async {
      final provider = SongMatchProvider(autoStartOnCreate: false);
      var calls = 0;
      SongMatchProvider.debugSearchOverride = (keywords) async {
        calls++;
        expect(keywords, contains('晴天'));
        return KugouSearchResult(songs: [_candidate(hash: 'h_auto')], total: 1);
      };

      await provider.runAutoMatch(songs: [_local()]);

      expect(calls, 1);
      final repo = SongMatchRepository();
      expect(repo.isMatched(_local().id), isTrue);
      expect(repo.get(_local().id)!.source, SongMatchSource.auto);
      expect(provider.autoMatching, isFalse);
    });

    test('无结果时记冷却，冷却期内跳过，force 才重试', () async {
      final provider = SongMatchProvider(autoStartOnCreate: false);
      var calls = 0;
      SongMatchProvider.debugSearchOverride = (keywords) async {
        calls++;
        return null;
      };
      final song = _local();

      await provider.runAutoMatch(songs: [song]);
      expect(calls, 1);

      // 冷却期内不再搜索
      await provider.runAutoMatch(songs: [song]);
      expect(calls, 1);

      // force 忽略冷却
      await provider.runAutoMatch(songs: [song], force: true);
      expect(calls, 2);
    });

    test('dismissed 的歌曲自动匹配永不触碰', () async {
      final provider = SongMatchProvider(autoStartOnCreate: false);
      final song = _local();
      final repo = SongMatchRepository();
      await repo.ensureLoaded();
      await repo.dismiss(song.id);

      var calls = 0;
      SongMatchProvider.debugSearchOverride = (keywords) async {
        calls++;
        return null;
      };
      await provider.runAutoMatch(songs: [song], force: true);
      expect(calls, 0);
    });

    test('设置开关关闭时不搜索；force 忽略开关', () async {
      await SettingsRepository().setAutoMatchOnlineInfo(false);
      final provider = SongMatchProvider(autoStartOnCreate: false);
      var calls = 0;
      SongMatchProvider.debugSearchOverride = (keywords) async {
        calls++;
        return null;
      };

      await provider.runAutoMatch(songs: [_local()]);
      expect(calls, 0);

      await provider.runAutoMatch(songs: [_local()], force: true);
      expect(calls, 1);
    });

    test('已匹配的歌曲跳过', () async {
      final provider = SongMatchProvider(autoStartOnCreate: false);
      final repo = SongMatchRepository();
      await repo.ensureLoaded();
      final song = _local(title: '已有匹配.mp3');
      await repo.put(
        SongMatchProvider.infoFromCandidate(
            song.id, _candidate(hash: 'h_exist'), SongMatchSource.manual),
      );

      var calls = 0;
      SongMatchProvider.debugSearchOverride = (keywords) async {
        calls++;
        return null;
      };
      await provider.runAutoMatch(songs: [song], force: true);
      expect(calls, 0);
    });
  });

  test('normalizeForMatch / bigramSimilarity 基本行为', () {
    expect(
      SongMatchProvider.normalizeForMatch('Hello, World! '),
      'helloworld',
    );
    expect(
      SongMatchProvider.normalizeForMatch('晴天（Live）'),
      '晴天live',
    );
    expect(SongMatchProvider.bigramSimilarity('晴天', '晴天'), 1.0);
    expect(SongMatchProvider.bigramSimilarity('晴天', '雨'), lessThan(0.5));
  });

  group('单曲偏好：使用在线歌词/封面', () {
    test('只写目标歌曲的记录，其他歌曲不受扰动', () async {
      final provider = SongMatchProvider(autoStartOnCreate: false);
      final repo = SongMatchRepository();
      await repo.ensureLoaded();
      final a = _local(title: '歌A.mp3');
      final b = _local(title: '歌B.mp3');
      await repo.put(SongMatchProvider.infoFromCandidate(
          a.id, _candidate(hash: 'h_a'), SongMatchSource.manual));
      await repo.put(SongMatchProvider.infoFromCandidate(
          b.id, _candidate(hash: 'h_b'), SongMatchSource.manual));

      await provider.setUseOnlineLyrics(a, true);
      await provider.setUseOnlineCover(a, true);

      final infoA = repo.get(a.id)!;
      expect(infoA.preferOnlineLyrics, isTrue);
      expect(infoA.preferOnlineCover, isTrue);
      final infoB = repo.get(b.id)!;
      expect(infoB.preferOnlineLyrics, isFalse);
      expect(infoB.preferOnlineCover, isFalse);

      // 关闭回退
      await provider.setUseOnlineLyrics(a, false);
      expect(repo.get(a.id)!.preferOnlineLyrics, isFalse);
    });

    test('未匹配 / dismissed 时 no-op', () async {
      final provider = SongMatchProvider(autoStartOnCreate: false);
      final repo = SongMatchRepository();
      await repo.ensureLoaded();
      final unmatched = _local(title: '未匹配.mp3');
      final dismissed = _local(title: '已否决.mp3');
      await repo.dismiss(dismissed.id);

      // 不抛错、不产生记录
      await provider.setUseOnlineLyrics(unmatched, true);
      await provider.setUseOnlineCover(unmatched, true);
      expect(repo.get(unmatched.id), isNull);

      await provider.setUseOnlineLyrics(dismissed, true);
      expect(repo.get(dismissed.id)!.preferOnlineLyrics, isFalse);
    });
  });

  group('云盘歌曲匹配', () {
    Song _cloud({
      String id = 'cloudhash_001',
      String title = '晴天.mp3',
      String artist = '周杰伦',
      int seconds = 182,
    }) {
      return Song(
        id: id,
        title: title,
        artist: artist,
        album: '',
        duration: Duration(seconds: seconds),
        isOnline: true,
        isCloud: true,
      );
    }

    test('matchInfoForSong 三态：本地可查 / 纯在线恒 null / 云盘可查', () async {
      final repo = SongMatchRepository();
      await repo.ensureLoaded();
      final local = _local();
      final cloud = _cloud();
      await repo.put(SongMatchProvider.infoFromCandidate(
          local.id, _candidate(hash: 'h_local'), SongMatchSource.manual));
      await repo.put(SongMatchProvider.infoFromCandidate(
          cloud.id, _candidate(hash: 'h_cloud'), SongMatchSource.manual));

      // 本地：isOnline=false → 查记忆
      expect(matchInfoForSong(local)!.hash, 'h_local');
      // 纯在线：isOnline=true 且非云盘 → 恒 null
      final online = local.copyWith(isOnline: true, id: 'officialhash');
      expect(matchInfoForSong(online), isNull);
      // 云盘：isOnline=true 但 isCloud=true → 查记忆
      expect(matchInfoForSong(cloud)!.hash, 'h_cloud');
    });

    test('matchedSongFor 对云盘返回匹配结果，对纯在线返回 null', () async {
      final provider = SongMatchProvider(autoStartOnCreate: false);
      final repo = SongMatchRepository();
      await repo.ensureLoaded();
      final cloud = _cloud();
      await repo.put(SongMatchProvider.infoFromCandidate(
          cloud.id, _candidate(hash: 'h_cloud'), SongMatchSource.manual));

      final matched = provider.matchedSongFor(cloud);
      expect(matched, isNotNull);
      expect(matched!.id, 'h_cloud');
      // 纯在线歌曲不产生匹配
      expect(
        provider.matchedSongFor(cloud.copyWith(isCloud: false)),
        isNull,
      );
    });

    test('onCloudListLoaded：云盘歌曲命中后以云盘 id 落库', () async {
      final provider = SongMatchProvider(autoStartOnCreate: false);
      var calls = 0;
      SongMatchProvider.debugSearchOverride = (keywords) async {
        calls++;
        expect(keywords, contains('晴天'));
        return KugouSearchResult(songs: [_candidate(hash: 'h_cloud_auto')], total: 1);
      };
      final cloud = _cloud();

      await provider.onCloudListLoaded([cloud]);

      expect(calls, 1);
      final repo = SongMatchRepository();
      // 键为云盘歌曲 id（云盘 hash），非官方 hash
      expect(repo.isMatched(cloud.id), isTrue);
      expect(repo.get(cloud.id)!.hash, 'h_cloud_auto');
      expect(repo.get(cloud.id)!.source, SongMatchSource.auto);
    });

    test('onCloudListLoaded：dismissed / 已匹配 / 冷却的云盘歌曲跳过', () async {
      final provider = SongMatchProvider(autoStartOnCreate: false);
      final repo = SongMatchRepository();
      await repo.ensureLoaded();
      final dismissed = _cloud(id: 'cloudhash_d', title: '已否决.mp3');
      final matched = _cloud(id: 'cloudhash_m', title: '已有匹配.mp3');
      await repo.dismiss(dismissed.id);
      await repo.put(SongMatchProvider.infoFromCandidate(
          matched.id, _candidate(hash: 'h_m'), SongMatchSource.manual));

      var calls = 0;
      SongMatchProvider.debugSearchOverride = (keywords) async {
        calls++;
        return null;
      };
      await provider.onCloudListLoaded([dismissed, matched]);
      expect(calls, 0);
    });

    test('onCloudListLoaded：设置开关关闭时不搜索', () async {
      await SettingsRepository().setAutoMatchOnlineInfo(false);
      final provider = SongMatchProvider(autoStartOnCreate: false);
      var calls = 0;
      SongMatchProvider.debugSearchOverride = (keywords) async {
        calls++;
        return null;
      };

      await provider.onCloudListLoaded([_cloud()]);
      expect(calls, 0);
    });
  });
}
