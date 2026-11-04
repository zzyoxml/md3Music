import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/modules/mcp/mcp_confirmation.dart';
import 'package:md3music/modules/mcp/mcp_library_source.dart';
import 'package:md3music/modules/mcp/mcp_ports.dart';
import 'package:md3music/modules/mcp/mcp_tool.dart';
import 'package:md3music/modules/mcp/mcp_tools_library.dart';
import 'package:md3music/modules/mcp/mcp_tools_player.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';

Song _song() => const Song(
      id: 'h1',
      title: '晴天',
      artist: '周杰伦',
      album: '叶惠美',
      duration: Duration(seconds: 269),
    );

/// 构造带 [n] 首歌曲的歌单内容响应（KugouPlaylistSongs.songs 是 KugouSongDetail 列表）。
KugouPlaylistSongs _playlistWithSongs(int n) => KugouPlaylistSongs(
      songs: List<KugouSongDetail>.generate(
        n,
        (i) => KugouSongDetail(
          hash: 'ph$i',
          songName: '歌$i',
          duration: 200,
        ),
      ),
      total: n,
    );

McpPlayerSnapshot _playingSnapshot({double volume = 1.0}) =>
    McpPlayerSnapshot(
      song: _song(),
      playing: true,
      positionMs: 1000,
      durationMs: 269000,
      volume: volume,
      loopMode: 'all',
      shuffle: false,
      queueLength: 2,
      currentIndex: 0,
    );

/// [McpPlayerControl] 的假实现：记录调用序列，返回构造好的快照。
class FakePlayerControl implements McpPlayerControl {
  FakePlayerControl({
    McpPlayerSnapshot? snapshot,
    this.queueItems = const <Map<String, Object?>>[],
  }) : _snapshot = snapshot ?? McpPlayerSnapshot.empty();

  final McpPlayerSnapshot _snapshot;

  /// [queue] 的返回值，默认空队列。
  final List<Map<String, Object?>> queueItems;

  final List<String> calls = <String>[];

  @override
  McpPlayerSnapshot snapshot() => _snapshot;

  @override
  List<Map<String, Object?>> queue({int limit = 20}) =>
      queueItems.take(limit).toList(growable: false);

  @override
  Future<void> resume() async => calls.add('resume');

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> next() async => calls.add('next');

  @override
  Future<void> previous() async => calls.add('previous');

  @override
  Future<void> seek(Duration position) async =>
      calls.add('seek:${position.inMilliseconds}');

  @override
  Future<void> setVolume(double volume) async =>
      calls.add('volume:${volume.toStringAsFixed(2)}');

  @override
  Future<void> playSong(Song song) async => calls.add('play:${song.title}');

  @override
  Future<void> enqueue(Song song) async => calls.add('enqueue:${song.title}');

  @override
  Future<void> setLoopMode(String mode) async => calls.add('loop:$mode');

  @override
  Future<void> setShuffle(bool enabled) async => calls.add('shuffle:$enabled');

  @override
  Future<void> playAt(int index) async => calls.add('playAt:$index');

  @override
  Future<void> removeFromQueue(int index) async =>
      calls.add('removeAt:$index');

  @override
  Future<void> reorderQueue(int from, int to) async =>
      calls.add('move:$from->$to');

  @override
  Future<void> clearQueue() async => calls.add('clear');

  @override
  Future<void> playOnlinePlaylist(List<Song> songs, int startIndex) async =>
      calls.add('playList:${songs.length}@$startIndex');

  /// [waitForEvent] 的桩：null 时模拟"等到超时也没事件"（返回 null）。
  Future<String?> Function(McpWatchEvent, Duration)? onWaitForEvent;

  @override
  Future<String?> waitForEvent(McpWatchEvent event, Duration timeout) =>
      onWaitForEvent?.call(event, timeout) ?? Future<String?>.value(null);
}

/// 假的上游网关：直接返回构造好的模型，不触网。
///
/// 同时实现 [McpLibrarySource]，后续 Task 6 可以直接把
/// `FakeApiClient()` 当 `library` 传给 `buildMcpTools`。
class FakeApiClient implements KugouLibraryGateway, McpLibrarySource {
  /// 上一次请求实际下发的 pagesize，用于验证 limit 的钳制。
  int? lastPagesize;

  /// 搜索响应比请求量多返回的条数，用于验证上层截断。
  static const int extraPagesize = 5;

  List<KugouSongDetail> _fakeSongs(String keyword, int count) =>
      List<KugouSongDetail>.generate(
        count,
        (i) => KugouSongDetail(
          hash: 'h$i',
          songName: '$keyword-$i',
          duration: 100 + i,
          // 搜索候选带封面（模拟 /search 行为），用于验证 getSongDetail
          // 的封面补齐：/audio 无封面时按 hash 命中候选回填
          artworkUri: 'https://img.example/$keyword/$i',
        ),
      );

  @override
  Future<KugouSearchResult?> search(
    String keyword, {
    required int pagesize,
  }) async {
    lastPagesize = pagesize;
    // 故意多返回几条，用于验证 searchSongs 的截断逻辑
    return KugouSearchResult(
      songs: _fakeSongs(keyword, pagesize + extraPagesize),
      total: pagesize + extraPagesize,
    );
  }

  @override
  Future<KugouSongDetail?> songDetail(String hash) async => KugouSongDetail(
        hash: hash,
        songName: '晴天',
        artistName: '周杰伦',
        albumName: '叶惠美',
        duration: 269,
        // /audio 无封面字段（铁律 17）：detail 永远不带图，靠搜索命中补齐
      );

  @override
  Future<KugouLyric?> lyric(String hash) async => KugouLyric(
        content: 'kVc9aU 加密占位内容',
        decodedContent: '[00:01.00] 故事的小黄花',
      );

  @override
  Future<List<KugouSongDetail>> searchSongs(
    String keyword, {
    int limit = 10,
  }) async =>
      _fakeSongs(keyword, limit);

  @override
  Future<KugouSongDetail?> getSongDetail(String hash) => songDetail(hash);

  @override
  Future<String?> getLyric(String hash) async =>
      (await lyric(hash))?.decodedContent;

  // ---- 多维检索（Task 7）----
  //
  // 注意：本类同时实现 KugouLibraryGateway（pagesize）与 McpLibrarySource
  //（limit），同名方法只能有一个实现，故签名合并为两个可选命名参数，
  // 实际截断取两者的较小值。

  List<KugouAlbumBrief> albums = const <KugouAlbumBrief>[];
  List<KugouArtistBrief> artists = const <KugouArtistBrief>[];
  List<KugouPlaylistBrief> playlists = const <KugouPlaylistBrief>[];

  @override
  Future<List<KugouAlbumBrief>?> searchAlbums(String keywords,
      {int limit = 10, int pagesize = 20}) async =>
      albums.take(limit < pagesize ? limit : pagesize).toList(growable: false);

  @override
  Future<List<KugouArtistBrief>?> searchArtists(String keywords,
      {int limit = 10, int pagesize = 20}) async =>
      artists.take(limit < pagesize ? limit : pagesize).toList(growable: false);

  @override
  Future<List<KugouPlaylistBrief>?> searchPlaylists(String keywords,
      {int limit = 10, int pagesize = 20}) async =>
      playlists
          .take(limit < pagesize ? limit : pagesize)
          .toList(growable: false);

  // ---- 歌单内容（Task 8）----

  KugouPlaylistSongs? playlistSongs;

  @override
  Future<KugouPlaylistSongs?> getPlaylistSongs(String globalCollectionId,
      {int limit = 30, int pagesize = 30}) async =>
      playlistSongs;

  // ---- 推荐 / FM / 榜单 / 听歌历史（Task 9）----

  List<KugouSongDetail>? daily;
  List<KugouSongDetail>? fmSongs;
  KugouRankList? ranks;
  List<KugouSongDetail>? rankSongs;
  Map<String, dynamic>? listen;

  @override
  Future<List<KugouSongDetail>?> getDailyRecommend() async => daily;

  /// 网关侧方法名（端口侧为 getDailyRecommend），同一份数据。
  @override
  Future<List<KugouSongDetail>?> getRecommendDaily() async => daily;

  @override
  Future<List<KugouSongDetail>?> getPersonalFm() async => fmSongs;

  @override
  Future<KugouRankList?> getRankList() async => ranks;

  @override
  Future<List<KugouSongDetail>?> getRankAudio(String rankId,
      {int limit = 30, int pagesize = 30}) async =>
      rankSongs;

  @override
  Future<Map<String, dynamic>?> getUserListen({int type = 0}) async => listen;
}

/// 只覆盖"没有歌词"分支的最小网关：[lyricResult] 为 null 表示上游无歌词。
class StubGateway implements KugouLibraryGateway {
  StubGateway(this.lyricResult);

  final KugouLyric? lyricResult;

  @override
  Future<KugouSearchResult?> search(
    String keyword, {
    required int pagesize,
  }) async =>
      const KugouSearchResult();

  @override
  Future<KugouSongDetail?> songDetail(String hash) async => null;

  @override
  Future<KugouLyric?> lyric(String hash) async => lyricResult;

  @override
  Future<List<KugouAlbumBrief>?> searchAlbums(String keywords,
          {int pagesize = 20}) async =>
      null;

  @override
  Future<List<KugouArtistBrief>?> searchArtists(String keywords,
          {int pagesize = 20}) async =>
      null;

  @override
  Future<List<KugouPlaylistBrief>?> searchPlaylists(String keywords,
          {int pagesize = 20}) async =>
      null;

  @override
  Future<KugouPlaylistSongs?> getPlaylistSongs(String globalCollectionId,
          {int pagesize = 30}) async =>
      null;

  @override
  Future<List<KugouSongDetail>?> getRecommendDaily() async => null;

  @override
  Future<List<KugouSongDetail>?> getPersonalFm() async => null;

  @override
  Future<KugouRankList?> getRankList() async => null;

  @override
  Future<List<KugouSongDetail>?> getRankAudio(String rankId,
          {int pagesize = 30}) async =>
      null;

  @override
  Future<Map<String, dynamic>?> getUserListen({int type = 0}) async => null;
}

/// 什么都不返回的 [McpLibrarySource]：用于覆盖"详情缺失"分支。
class EmptyApiClient implements McpLibrarySource {
  @override
  Future<KugouSongDetail?> getSongDetail(String hash) async => null;

  @override
  Future<String?> getLyric(String hash) async => null;

  @override
  Future<List<KugouSongDetail>> searchSongs(
    String keyword, {
    int limit = 10,
  }) async =>
      const <KugouSongDetail>[];

  @override
  Future<List<KugouAlbumBrief>?> searchAlbums(String keyword,
          {int limit = 10}) async =>
      null;

  @override
  Future<List<KugouArtistBrief>?> searchArtists(String keyword,
          {int limit = 10}) async =>
      null;

  @override
  Future<List<KugouPlaylistBrief>?> searchPlaylists(String keyword,
          {int limit = 10}) async =>
      null;

  @override
  Future<KugouPlaylistSongs?> getPlaylistSongs(String globalCollectionId,
          {int limit = 30}) async =>
      null;

  @override
  Future<List<KugouSongDetail>?> getDailyRecommend() async => null;

  @override
  Future<List<KugouSongDetail>?> getPersonalFm() async => null;

  @override
  Future<KugouRankList?> getRankList() async => null;

  @override
  Future<List<KugouSongDetail>?> getRankAudio(String rankId,
          {int limit = 30}) async =>
      null;

  @override
  Future<Map<String, dynamic>?> getUserListen({int type = 0}) async => null;
}

/// 本地曲库假源。
class FakeLocalLibrary implements McpLocalLibrarySource {
  FakeLocalLibrary(this.songs);
  final List<Song> songs;

  @override
  List<Song> search(String keyword, {int limit = 10}) => songs
      .where((s) =>
          s.title.contains(keyword) || s.artist.contains(keyword))
      .take(limit)
      .toList(growable: false);

  @override
  Song? findById(String id) {
    for (final s in songs) {
      if (s.id == id) return s;
    }
    return null;
  }
}

/// 假的曲库写源：记录调用序列，不触网。
class FakeLibraryWrite implements McpLibraryWriteSource {
  final calls = <String>[];

  @override
  Future<void> addSongToPlaylist(String hash, String listid) async =>
      calls.add('add:$hash->$listid');

  @override
  Future<void> createPlaylist(String name) async => calls.add('create:$name');
}

/// App 功能端口假实现：快照可定制，调用序列可断言。
class FakeAppFeatures implements McpAppFeaturesPort {
  final calls = <String>[];
  McpAppFeaturesSnapshot snap = const McpAppFeaturesSnapshot(
    sleepTimerMode: 'off',
    sleepTimerRemainingMs: null,
    eqEnabled: false,
    eqPresets: ['古典', '流行'],
    desktopLyricEnabled: false,
    outputMode: 'system',
    usbDeviceAvailable: false,
  );

  @override
  McpAppFeaturesSnapshot snapshot() => snap;

  @override
  Future<void> setSleepTimer(Duration? duration) async =>
      calls.add('sleep:${duration?.inMinutes}');

  @override
  Future<void> setEqEnabled(bool enabled) async => calls.add('eq:$enabled');

  @override
  Future<void> applyEqPreset(String name) async => calls.add('preset:$name');

  @override
  Future<void> setDesktopLyric(bool enabled) async =>
      calls.add('lyric:$enabled');
}

/// 只返回超长歌词的 [McpLibrarySource]：用于验证歌词截断。
class LongLyricApiClient implements McpLibrarySource {
  @override
  Future<KugouSongDetail?> getSongDetail(String hash) async => null;

  @override
  Future<String?> getLyric(String hash) async => '词' * 20000;

  @override
  Future<List<KugouSongDetail>> searchSongs(
    String keyword, {
    int limit = 10,
  }) async =>
      const <KugouSongDetail>[];

  @override
  Future<List<KugouAlbumBrief>?> searchAlbums(String keyword,
          {int limit = 10}) async =>
      null;

  @override
  Future<List<KugouArtistBrief>?> searchArtists(String keyword,
          {int limit = 10}) async =>
      null;

  @override
  Future<List<KugouPlaylistBrief>?> searchPlaylists(String keyword,
          {int limit = 10}) async =>
      null;

  @override
  Future<KugouPlaylistSongs?> getPlaylistSongs(String globalCollectionId,
          {int limit = 30}) async =>
      null;

  @override
  Future<List<KugouSongDetail>?> getDailyRecommend() async => null;

  @override
  Future<List<KugouSongDetail>?> getPersonalFm() async => null;

  @override
  Future<KugouRankList?> getRankList() async => null;

  @override
  Future<List<KugouSongDetail>?> getRankAudio(String rankId,
          {int limit = 30}) async =>
      null;

  @override
  Future<Map<String, dynamic>?> getUserListen({int type = 0}) async => null;
}

void main() {
  group('播放器快照', () {
    test('空快照投影出全空曲目字段', () {
      final json = McpPlayerSnapshot.empty().toJson();
      expect(json['title'], isNull);
      expect(json['artist'], isNull);
      expect(json['album'], isNull);
      expect(json['playing'], isFalse);
      expect(json['position_ms'], 0);
      expect(json['duration_ms'], 0);
      expect(json['queue_length'], 0);
      expect(json['current_index'], -1);
    });

    test('带曲目快照投影出曲目信息与毫秒进度', () {
      final json = _playingSnapshot().toJson();
      expect(json['title'], '晴天');
      expect(json['artist'], '周杰伦');
      expect(json['album'], '叶惠美');
      expect(json['playing'], isTrue);
      expect(json['position_ms'], 1000);
      expect(json['duration_ms'], 269000);
      expect(json['loop_mode'], 'all');
      expect(json['shuffle'], isFalse);
      expect(json['queue_length'], 2);
      expect(json['current_index'], 0);
    });

    test('音量压缩到两位小数', () {
      expect(
        _playingSnapshot(volume: 0.567).toJson()['volume'],
        0.57,
      );
      expect(_playingSnapshot(volume: 1.0).toJson()['volume'], 1.0);
    });

    test('快照带 hash 与音质字段', () {
      final song = const Song(
        id: 'h1',
        title: '晴天',
        artist: '周杰伦',
        album: '叶惠美',
        duration: Duration(seconds: 269),
        isOnline: true,
        quality: 'flac',
      );
      final json = McpPlayerSnapshot(
        song: song,
        playing: true,
        positionMs: 0,
        durationMs: 269000,
        volume: 1.0,
        loopMode: 'off',
        shuffle: false,
        queueLength: 1,
        currentIndex: 0,
      ).toJson();
      expect(json['hash'], 'h1');
      expect(json['quality'], 'flac');
      expect(McpPlayerSnapshot.empty().toJson()['hash'], isNull);
    });

    test('FakePlayerControl 按顺序记录调用', () async {
      final control = FakePlayerControl();
      await control.resume();
      await control.pause();
      await control.next();
      await control.previous();
      await control.seek(const Duration(seconds: 30));
      await control.setVolume(0.5);
      await control.playSong(_song());
      await control.enqueue(_song());
      expect(control.calls, <String>[
        'resume',
        'pause',
        'next',
        'previous',
        'seek:30000',
        'volume:0.50',
        'play:晴天',
        'enqueue:晴天',
      ]);
    });
  });

  group('曲库源', () {
    test('KugouApiClientLibrarySource.searchSongs 截断到 limit', () async {
      final fake = FakeApiClient();
      final source = KugouApiClientLibrarySource(fake);
      final songs = await source.searchSongs('周杰伦', limit: 3);
      expect(songs, hasLength(3));
      expect(songs.first.hash, 'h0');
      expect(fake.lastPagesize, 3);
    });

    test('KugouApiClientLibrarySource.searchSongs limit 上钳到 30', () async {
      final fake = FakeApiClient();
      final source = KugouApiClientLibrarySource(fake);
      final songs = await source.searchSongs('周杰伦', limit: 100);
      expect(songs, hasLength(30));
      expect(fake.lastPagesize, 30);
    });

    test('KugouApiClientLibrarySource.getSongDetail 透传 hash', () async {
      final source = KugouApiClientLibrarySource(FakeApiClient());
      final detail = await source.getSongDetail('abc');
      expect(detail, isNotNull);
      expect(detail!.hash, 'abc');
      expect(detail.songName, '晴天');
    });

    test('getSongDetail 封面补齐：/audio 无图时按 hash 命中搜索候选', () async {
      final source = KugouApiClientLibrarySource(FakeApiClient());
      // 'h0' 同时存在于搜索候选（_fakeSongs 生成 h0..hN，候选带封面）
      final detail = await source.getSongDetail('h0');
      expect(detail, isNotNull);
      expect(detail!.hash, 'h0');
      expect(detail.artworkUri, 'https://img.example/晴天 周杰伦/0');
    });

    test('getSongDetail 封面补齐：候选未命中时原样返回（无封面不抛）', () async {
      final source = KugouApiClientLibrarySource(FakeApiClient());
      // 'abc' 不在搜索候选里 → 不命中 → 返回 /audio 原始 detail
      final detail = await source.getSongDetail('abc');
      expect(detail, isNotNull);
      expect(detail!.hash, 'abc');
      expect(detail.artworkUri, isNull);
    });

    test('KugouApiClientLibrarySource.getLyric 优先解码内容', () async {
      final source = KugouApiClientLibrarySource(FakeApiClient());
      expect(await source.getLyric('h1'), contains('[00:01.00]'));
    });

    test('KugouApiClientLibrarySource.getLyric 上游无歌词时返回 null', () async {
      final source = KugouApiClientLibrarySource(StubGateway(null));
      expect(await source.getLyric('h1'), isNull);
    });

    test('KugouApiClientLibrarySource.getLyric 空白歌词返回 null', () async {
      final source = KugouApiClientLibrarySource(
        StubGateway(const KugouLyric(content: '   ', decodedContent: '  ')),
      );
      expect(await source.getLyric('h1'), isNull);
    });
  });

  group('播放器工具', () {
    test('md3_get_player_state 返回投影快照', () async {
      final control = FakePlayerControl(snapshot: _playingSnapshot(volume: 0.5));
      final registry = McpToolRegistry(buildPlayerTools(control));
      final res = await registry.execute('md3_get_player_state', <String, Object?>{});
      expect(res.isError, isFalse);
      final data = res.data! as Map<String, Object?>;
      expect(data['title'], '晴天');
      expect(data['artist'], '周杰伦');
      expect(data['position_ms'], 1000);
      expect(data['duration_ms'], 269000);
      expect(data['volume'], 0.5);
      expect(data['loop_mode'], 'all');
      expect(data['queue_length'], 2);
    });

    test('md3_get_player_state 无曲目时曲目字段为空', () async {
      final registry = McpToolRegistry(buildPlayerTools(FakePlayerControl()));
      final res = await registry.execute('md3_get_player_state', <String, Object?>{});
      final data = res.data! as Map<String, Object?>;
      expect(data['title'], isNull);
      expect(data['playing'], isFalse);
      expect(data['current_index'], -1);
    });

    test('md3_get_queue 返回队列条目与当前索引', () async {
      final control = FakePlayerControl(
        snapshot: _playingSnapshot(),
        queueItems: <Map<String, Object?>>[
          <String, Object?>{'index': 0, 'title': '晴天', 'artist': '周杰伦', 'album': '叶惠美'},
          <String, Object?>{'index': 1, 'title': '稻香', 'artist': '周杰伦', 'album': '魔杰座'},
        ],
      );
      final registry = McpToolRegistry(buildPlayerTools(control));
      final res = await registry.execute('md3_get_queue', <String, Object?>{});
      final data = res.data! as Map<String, Object?>;
      expect(data['current_index'], 0);
      expect(data['total'], 2);
      expect(data['items'], hasLength(2));
      expect((data['items']! as List).first as Map, containsPair('title', '晴天'));
    });

    test('md3_get_queue 拒绝越界 limit', () async {
      final registry = McpToolRegistry(buildPlayerTools(FakePlayerControl()));
      expect(
        (await registry.execute(
          'md3_get_queue',
          <String, Object?>{'limit': 51},
        )).isError,
        isTrue,
      );
    });

    test('md3_resume 在无曲目时返回错误而不调用控制层', () async {
      final control = FakePlayerControl();
      final registry = McpToolRegistry(buildPlayerTools(control));
      final res = await registry.execute('md3_resume', <String, Object?>{});
      expect(res.isError, isTrue);
      expect(control.calls, isEmpty);
    });

    test('md3_resume 有曲目时调用控制层', () async {
      final control = FakePlayerControl(snapshot: _playingSnapshot());
      final registry = McpToolRegistry(buildPlayerTools(control));
      final res = await registry.execute('md3_resume', <String, Object?>{});
      expect(res.isError, isFalse);
      expect(control.calls, ['resume']);
    });

    test('md3_pause 调用控制层并回执文本', () async {
      final control = FakePlayerControl();
      final registry = McpToolRegistry(buildPlayerTools(control));
      final res = await registry.execute('md3_pause', <String, Object?>{});
      expect(res.isError, isFalse);
      expect(res.text, '已暂停');
      expect(control.calls, ['pause']);
    });

    test('md3_next / md3_previous 转发到控制层', () async {
      final control = FakePlayerControl();
      final registry = McpToolRegistry(buildPlayerTools(control));
      await registry.execute('md3_next', <String, Object?>{});
      await registry.execute('md3_previous', <String, Object?>{});
      expect(control.calls, ['next', 'previous']);
    });

    test('md3_seek 到达控制层时以毫秒为单位', () async {
      final control = FakePlayerControl();
      final registry = McpToolRegistry(buildPlayerTools(control));
      final res = await registry.execute(
        'md3_seek',
        <String, Object?>{'position_ms': 30000},
      );
      expect(res.isError, isFalse);
      expect(control.calls, ['seek:30000']);
    });

    test('md3_seek 拒绝负数', () async {
      final control = FakePlayerControl();
      final registry = McpToolRegistry(buildPlayerTools(control));
      final res = await registry.execute(
        'md3_seek',
        <String, Object?>{'position_ms': -1},
      );
      expect(res.isError, isTrue);
      expect(res.text, contains('参数错误'));
      expect(control.calls, isEmpty);
    });

    test('md3_seek 拒绝非整数', () async {
      final control = FakePlayerControl();
      final registry = McpToolRegistry(buildPlayerTools(control));
      expect(
        (await registry.execute(
          'md3_seek',
          <String, Object?>{'position_ms': 'abc'},
        )).isError,
        isTrue,
      );
      expect(control.calls, isEmpty);
    });

    test('md3_set_volume 在合法区间内调用控制层', () async {
      final control = FakePlayerControl();
      final registry = McpToolRegistry(buildPlayerTools(control));
      final res = await registry.execute(
        'md3_set_volume',
        <String, Object?>{'volume': 0.25},
      );
      expect(res.isError, isFalse);
      expect(control.calls, ['volume:0.25']);
    });

    test('md3_set_volume 拒绝越界值', () async {
      final control = FakePlayerControl();
      final registry = McpToolRegistry(buildPlayerTools(control));
      expect(
        (await registry.execute(
          'md3_set_volume',
          <String, Object?>{'volume': 1.5},
        )).isError,
        isTrue,
      );
      expect(control.calls, isEmpty);
    });

    test('md3_toggle 播放中则暂停', () async {
      final control = FakePlayerControl(snapshot: _playingSnapshot());
      final registry = McpToolRegistry(buildPlayerTools(control));
      final res = await registry.execute('md3_toggle', <String, Object?>{});
      expect(res.isError, isFalse);
      expect(control.calls, ['pause']);
    });

    test('md3_toggle 暂停中则继续', () async {
      final control = FakePlayerControl();
      final registry = McpToolRegistry(buildPlayerTools(control));
      await registry.execute('md3_toggle', <String, Object?>{});
      expect(control.calls, ['resume']);
    });

    test('md3_set_loop_mode 只接受 off/one/all', () async {
      final control = FakePlayerControl();
      // 注入时钟：同一写工具连续调用会被 400ms 防抖拦截，逐秒推进避免误伤
      var sec = 0;
      final registry = McpToolRegistry(buildPlayerTools(control),
          clock: () => DateTime(2026, 1, 1, 0, 0, sec++));
      await registry.execute('md3_set_loop_mode', <String, Object?>{'mode': 'one'});
      expect(control.calls, ['loop:one']);
      final bad = await registry.execute(
        'md3_set_loop_mode',
        <String, Object?>{'mode': 'random'},
      );
      expect(bad.isError, isTrue);
      expect(control.calls, ['loop:one']);
    });

    test('md3_set_shuffle 转发布尔', () async {
      final control = FakePlayerControl();
      final registry = McpToolRegistry(buildPlayerTools(control));
      await registry.execute('md3_set_shuffle', <String, Object?>{'enabled': true});
      expect(control.calls, ['shuffle:true']);
    });

    test('md3_adjust_volume 基于当前音量做增量并钳制', () async {
      final control =
          FakePlayerControl(snapshot: _playingSnapshot(volume: 0.8));
      // 注入时钟：同一写工具连续调用会被 400ms 防抖拦截，逐秒推进避免误伤
      var sec = 0;
      final registry = McpToolRegistry(buildPlayerTools(control),
          clock: () => DateTime(2026, 1, 1, 0, 0, sec++));
      await registry.execute('md3_adjust_volume', <String, Object?>{'delta': -0.3});
      await registry.execute('md3_adjust_volume', <String, Object?>{'delta': -5});
      await registry.execute('md3_adjust_volume', <String, Object?>{'delta': 2});
      expect(control.calls, ['volume:0.50', 'volume:0.00', 'volume:1.00']);
    });

    test('md3_skip 基于当前进度做快进快退并钳制到曲目范围', () async {
      final control = FakePlayerControl(
        snapshot: McpPlayerSnapshot(
          song: _song(),
          playing: true,
          positionMs: 260000,
          durationMs: 269000,
          volume: 1.0,
          loopMode: 'off',
          shuffle: false,
          queueLength: 1,
          currentIndex: 0,
        ),
      );
      // 注入时钟：同一写工具连续调用会被 400ms 防抖拦截，逐秒推进避免误伤
      var sec = 0;
      final registry = McpToolRegistry(buildPlayerTools(control),
          clock: () => DateTime(2026, 1, 1, 0, 0, sec++));
      await registry.execute('md3_skip', <String, Object?>{'seconds': 30});
      expect(control.calls, ['seek:269000']);
      await registry.execute('md3_skip', <String, Object?>{'seconds': -3600});
      expect(control.calls, ['seek:269000', 'seek:0']);
    });

    test('md3_play_queue_index 越界被拒绝', () async {
      final control = FakePlayerControl(snapshot: _playingSnapshot());
      // 注入时钟：同一写工具连续调用会被 400ms 防抖拦截，逐秒推进避免误伤
      var sec = 0;
      final registry = McpToolRegistry(buildPlayerTools(control),
          clock: () => DateTime(2026, 1, 1, 0, 0, sec++));
      final bad = await registry.execute(
        'md3_play_queue_index',
        <String, Object?>{'index': 2},
      );
      expect(bad.isError, isTrue);
      final ok = await registry.execute(
        'md3_play_queue_index',
        <String, Object?>{'index': 1},
      );
      expect(ok.isError, isFalse);
      expect(control.calls, ['playAt:1']);
    });

    test('md3_remove_queue_item 校验队列非空与索引范围', () async {
      final control = FakePlayerControl();
      final registry = McpToolRegistry(buildPlayerTools(control));
      expect(
        (await registry.execute(
          'md3_remove_queue_item',
          <String, Object?>{'index': 0},
        )).isError,
        isTrue,
      );
      final empty = control.calls;
      expect(empty, isEmpty);
    });

    test('md3_move_queue_item 转发 from/to', () async {
      final control = FakePlayerControl(snapshot: _playingSnapshot());
      final registry = McpToolRegistry(buildPlayerTools(control));
      await registry.execute(
        'md3_move_queue_item',
        <String, Object?>{'from': 0, 'to': 1},
      );
      expect(control.calls, ['move:0->1']);
    });

    test('md3_clear_queue 调用清空（需确认）', () async {
      final control = FakePlayerControl(snapshot: _playingSnapshot());
      final broker = McpConfirmationBroker();
      final registry = McpToolRegistry(
        buildPlayerTools(control),
        confirmations: broker,
      );
      final pending = registry.execute('md3_clear_queue', <String, Object?>{});
      broker.resolve(broker.pending.value!.id, true);
      await pending;
      expect(control.calls, ['clear']);
    });

    test('md3_wait_for_player_event 返回事件结果', () async {
      final control = FakePlayerControl()
        ..onWaitForEvent = (event, timeout) async => 'track_changed';
      final registry = McpToolRegistry(buildPlayerTools(control));
      final res = await registry.execute('md3_wait_for_player_event',
          <String, Object?>{'event': 'track_change', 'timeout_ms': 1000});
      final data = res.data! as Map<String, Object?>;
      expect(data['timed_out'], isFalse);
      expect(data['event'], 'track_changed');
    });

    test('md3_wait_for_player_event 超时返回 timed_out', () async {
      final registry =
          McpToolRegistry(buildPlayerTools(FakePlayerControl()));
      final res = await registry.execute('md3_wait_for_player_event',
          <String, Object?>{'event': 'pause', 'timeout_ms': 1000});
      expect((res.data! as Map)['timed_out'], isTrue);
    });

    test('非法事件名被拒绝', () async {
      final registry =
          McpToolRegistry(buildPlayerTools(FakePlayerControl()));
      final res = await registry.execute('md3_wait_for_player_event',
          <String, Object?>{'event': 'skip'});
      expect(res.isError, isTrue);
    });

    test('只读模式下写工具被拦截而读工具仍可用', () async {
      final control = FakePlayerControl(snapshot: _playingSnapshot());
      final registry = McpToolRegistry(buildPlayerTools(control));
      registry.readOnly = true;
      final names = registry
          .visibleTools()
          .map((t) => t.name)
          .toList(growable: false);
      expect(names, <String>[
        'md3_get_player_state',
        'md3_get_queue',
        'md3_wait_for_player_event',
      ]);
      final res = await registry.execute('md3_pause', <String, Object?>{});
      expect(res.isError, isTrue);
      expect(control.calls, isEmpty);
      expect(
        (await registry.execute('md3_get_player_state', <String, Object?>{})).isError,
        isFalse,
      );
    });
  });

  group('调用日志与防抖', () {
    test('写操作 400ms 内重复调用被防抖拦截（注入时钟）', () async {
      var now = DateTime(2026, 1, 1);
      final control = FakePlayerControl(snapshot: _playingSnapshot());
      final registry = McpToolRegistry(buildPlayerTools(control),
          clock: () => now);
      await registry.execute('md3_next', <String, Object?>{});
      final again = await registry.execute('md3_next', <String, Object?>{});
      expect(again.isError, isTrue);
      expect(again.text, contains('频繁'));
      now = now.add(const Duration(milliseconds: 500));
      final third = await registry.execute('md3_next', <String, Object?>{});
      expect(third.isError, isFalse);
      expect(control.calls, ['next', 'next']);
    });

    test('onCall 回调携带参数摘要', () async {
      String? summary;
      final control = FakePlayerControl(snapshot: _playingSnapshot());
      final registry = McpToolRegistry(
        buildPlayerTools(control),
        onCall: (tool, ok, args) => summary = args,
      );
      await registry.execute('md3_seek', <String, Object?>{'position_ms': 1000});
      expect(summary, contains('position_ms'));
    });
  });

  group('检索类工具', () {
    test('md3_search_songs 只投影 5 个字段', () async {
      final control = FakePlayerControl();
      final library = FakeApiClient();
      final registry = McpToolRegistry(
          buildMcpTools(control: control, library: library));
      final res = await registry.execute(
        'md3_search_songs',
        <String, Object?>{'keyword': '晴天'},
      );
      expect(res.isError, isFalse);
      final data = res.data! as Map<String, Object?>;
      expect(data['keyword'], '晴天');
      expect(data['count'], 10);
      final items = data['items']! as List;
      expect(items.first as Map, allOf(<Matcher>[
        containsPair('hash', 'h0'),
        containsPair('name', '晴天-0'),
      ]));
      expect(
        (items.first as Map).keys,
        unorderedEquals(<String>['hash', 'name', 'artist', 'album', 'duration_ms']),
      );
      // KugouSongDetail.duration 单位是秒，投影后必须是毫秒
      expect((items.first as Map)['duration_ms'], 100000);
    });

    test('md3_search_songs 拒绝空关键词', () async {
      final registry = McpToolRegistry(
          buildMcpTools(control: FakePlayerControl(), library: FakeApiClient()));
      expect(
        (await registry.execute(
          'md3_search_songs',
          <String, Object?>{'keyword': ''},
        )).isError,
        isTrue,
      );
    });

    test('md3_search_songs 拒绝越界 limit', () async {
      final registry = McpToolRegistry(
          buildMcpTools(control: FakePlayerControl(), library: FakeApiClient()));
      expect(
        (await registry.execute(
          'md3_search_songs',
          <String, Object?>{'keyword': '晴天', 'limit': 31},
        )).isError,
        isTrue,
      );
    });

    test('md3_get_lyric 超长截断到 8000 字符', () async {
      final registry = McpToolRegistry(
          buildMcpTools(control: FakePlayerControl(), library: LongLyricApiClient()));
      final res = await registry.execute('md3_get_lyric', <String, Object?>{'hash': 'x'});
      expect(res.isError, isFalse);
      final data = res.data! as Map<String, Object?>;
      expect((data['lyric']! as String).length, 8000);
      expect(data['truncated'], isTrue);
      expect(data['hash'], 'x');
    });

    test('md3_get_lyric 短歌词不截断', () async {
      final registry = McpToolRegistry(
          buildMcpTools(control: FakePlayerControl(), library: FakeApiClient()));
      final res = await registry.execute('md3_get_lyric', <String, Object?>{'hash': 'h1'});
      final data = res.data! as Map<String, Object?>;
      expect(data['lyric'], contains('[00:01.00]'));
      expect(data['truncated'], isFalse);
    });

    test('md3_get_lyric 无歌词时返回错误', () async {
      final registry = McpToolRegistry(
          buildMcpTools(control: FakePlayerControl(), library: EmptyApiClient()));
      final res = await registry.execute('md3_get_lyric', <String, Object?>{'hash': 'x'});
      expect(res.isError, isTrue);
      expect(res.text, contains('未找到'));
    });

    test('md3_play_keyword 播放首个搜索结果', () async {
      final control = FakePlayerControl();
      final registry = McpToolRegistry(
          buildMcpTools(control: control, library: FakeApiClient()));
      final res = await registry.execute(
        'md3_play_keyword',
        <String, Object?>{'keyword': '晴天'},
      );
      expect(res.isError, isFalse);
      expect(control.calls, ['play:晴天-0']);
      final data = res.data! as Map<String, Object?>;
      expect(data['title'], '晴天-0');
      expect(data['hash'], 'h0');
    });

    test('md3_play_keyword 无结果时返回错误', () async {
      final control = FakePlayerControl();
      final registry = McpToolRegistry(
          buildMcpTools(control: control, library: EmptyApiClient()));
      final res = await registry.execute(
        'md3_play_keyword',
        <String, Object?>{'keyword': '不存在'},
      );
      expect(res.isError, isTrue);
      expect(control.calls, isEmpty);
    });

    test('md3_play_song 详情缺失时返回错误', () async {
      final control = FakePlayerControl();
      final registry = McpToolRegistry(
          buildMcpTools(control: control, library: EmptyApiClient()));
      final res = await registry.execute('md3_play_song', <String, Object?>{'hash': 'x'});
      expect(res.isError, isTrue);
      expect(control.calls, isEmpty);
    });

    test('md3_play_song 按 hash 取详情后立即播放', () async {
      final control = FakePlayerControl();
      final registry = McpToolRegistry(
          buildMcpTools(control: control, library: FakeApiClient()));
      final res = await registry.execute('md3_play_song', <String, Object?>{'hash': 'h9'});
      expect(res.isError, isFalse);
      expect(control.calls, ['play:晴天']);
      final data = res.data! as Map<String, Object?>;
      expect(data['playing'], isTrue);
      expect(data['title'], '晴天');
      expect(data['artist'], '周杰伦');
    });

    test('md3_enqueue_song 插入队列而不打断当前播放', () async {
      final control = FakePlayerControl();
      final registry = McpToolRegistry(
          buildMcpTools(control: control, library: FakeApiClient()));
      final res = await registry.execute(
        'md3_enqueue_song',
        <String, Object?>{'hash': 'h2'},
      );
      expect(res.isError, isFalse);
      expect(control.calls, ['enqueue:晴天']);
      final data = res.data! as Map<String, Object?>;
      expect(data['enqueued'], isTrue);
      expect(data['title'], '晴天');
    });

    test('md3_enqueue_song 详情缺失时返回错误', () async {
      final control = FakePlayerControl();
      final registry = McpToolRegistry(
          buildMcpTools(control: control, library: EmptyApiClient()));
      final res = await registry.execute(
        'md3_enqueue_song',
        <String, Object?>{'hash': 'x'},
      );
      expect(res.isError, isTrue);
      expect(control.calls, isEmpty);
    });

    test('注册表按 group 过滤工具', () async {
      final registry = McpToolRegistry(buildMcpTools(
        control: FakePlayerControl(),
        library: FakeApiClient(),
      ));
      registry.enabledGroups = const <String>{'player'};
      final names =
          registry.visibleTools().map((t) => t.name).toList(growable: false);
      expect(names, contains('md3_get_player_state'));
      expect(names, isNot(contains('md3_search_songs')));
      // 分组关闭的工具调用也被拒
      final res = await registry
          .execute('md3_search_songs', <String, Object?>{'keyword': 'x'});
      expect(res.isError, isTrue);
    });

    test('md3_search_albums 投影 id/name/artist/year', () async {
      final fake = FakeApiClient()
        ..albums = const [
          KugouAlbumBrief(id: 'a1', name: '叶惠美', artistName: '周杰伦', year: 2003),
        ];
      final registry = McpToolRegistry(
          buildMcpTools(control: FakePlayerControl(), library: fake));
      final res = await registry.execute(
        'md3_search_albums',
        <String, Object?>{'keyword': '叶惠美'},
      );
      expect(res.isError, isFalse);
      final items = (res.data! as Map<String, Object?>)['items']! as List;
      expect((items.first as Map)['id'], 'a1');
      expect((items.first as Map)['name'], '叶惠美');
    });

    test('md3_search_playlists 投影 global_collection_id', () async {
      final fake = FakeApiClient()
        ..playlists = const [
          KugouPlaylistBrief(
              id: 'p1', name: '华语经典', songCount: 30, globalCollectionId: 'gc1'),
        ];
      final registry = McpToolRegistry(
          buildMcpTools(control: FakePlayerControl(), library: fake));
      final res = await registry.execute(
        'md3_search_playlists',
        <String, Object?>{'keyword': '华语'},
      );
      final items = (res.data! as Map<String, Object?>)['items']! as List;
      expect((items.first as Map)['global_collection_id'], 'gc1');
    });

    test('md3_search_artists 投影 id/name', () async {
      final fake = FakeApiClient()
        ..artists = const [
          KugouArtistBrief(id: 'ar1', name: '周杰伦'),
        ];
      final registry = McpToolRegistry(
          buildMcpTools(control: FakePlayerControl(), library: fake));
      final res = await registry.execute(
        'md3_search_artists',
        <String, Object?>{'keyword': '周杰伦'},
      );
      expect(res.isError, isFalse);
      final items = (res.data! as Map<String, Object?>)['items']! as List;
      expect((items.first as Map)['id'], 'ar1');
      expect((items.first as Map)['name'], '周杰伦');
    });

    test('md3_get_song_detail 投影详情字段', () async {
      final registry = McpToolRegistry(
          buildMcpTools(control: FakePlayerControl(), library: FakeApiClient()));
      final res =
          await registry.execute('md3_get_song_detail', <String, Object?>{'hash': 'abc'});
      final data = res.data! as Map<String, Object?>;
      expect(data['hash'], 'abc');
      expect(data['name'], '晴天');
    });

    test('md3_get_song_detail 详情缺失时返回错误', () async {
      final registry = McpToolRegistry(
          buildMcpTools(control: FakePlayerControl(), library: EmptyApiClient()));
      final res =
          await registry.execute('md3_get_song_detail', <String, Object?>{'hash': 'x'});
      expect(res.isError, isTrue);
    });

    test('md3_get_playlist_songs 投影歌曲列表', () async {
      final fake = FakeApiClient()..playlistSongs = _playlistWithSongs(2);
      final registry = McpToolRegistry(
          buildMcpTools(control: FakePlayerControl(), library: fake));
      final res = await registry.execute('md3_get_playlist_songs',
          <String, Object?>{'global_collection_id': 'gc1'});
      expect(res.isError, isFalse);
      final data = res.data! as Map<String, Object?>;
      expect(data['global_collection_id'], 'gc1');
      expect(data['total'], 2);
      expect(data['count'], 2);
      final items = data['items']! as List;
      expect((items.first as Map)['hash'], 'ph0');
      expect((items.first as Map)['name'], '歌0');
    });

    test('md3_play_playlist 触发整单播放且立即返回', () async {
      final control = FakePlayerControl();
      final fake = FakeApiClient()..playlistSongs = _playlistWithSongs(3);
      final registry = McpToolRegistry(
          buildMcpTools(control: control, library: fake));
      final res = await registry.execute(
          'md3_play_playlist', <String, Object?>{'global_collection_id': 'gc1'});
      expect(res.isError, isFalse);
      expect(control.calls, ['playList:3@0']);
      final data = res.data! as Map<String, Object?>;
      expect(data['playing'], isTrue);
      expect(data['queued'], 3);
    });

    test('md3_play_playlist 歌单为空时返回错误且不播放', () async {
      final control = FakePlayerControl();
      final fake = FakeApiClient()
        ..playlistSongs = const KugouPlaylistSongs(songs: [], total: 0);
      final registry = McpToolRegistry(
          buildMcpTools(control: control, library: fake));
      final res = await registry.execute(
          'md3_play_playlist', <String, Object?>{'global_collection_id': 'gc1'});
      expect(res.isError, isTrue);
      expect(control.calls, isEmpty);
    });

    test('md3_get_daily_recommend 返回推荐曲目投影', () async {
      final fake = FakeApiClient()
        ..daily = [
          KugouSongDetail(hash: 'd1', songName: '推荐歌', duration: 100),
        ];
      final registry = McpToolRegistry(
          buildMcpTools(control: FakePlayerControl(), library: fake));
      final res = await registry.execute(
          'md3_get_daily_recommend', <String, Object?>{});
      expect(res.isError, isFalse);
      final data = res.data! as Map<String, Object?>;
      expect(data['count'], 1);
      expect(((data['items']! as List).first as Map)['hash'], 'd1');
    });

    test('md3_get_daily_recommend 未登录（空返回）时报错', () async {
      final registry = McpToolRegistry(
          buildMcpTools(control: FakePlayerControl(), library: FakeApiClient()));
      final res = await registry.execute(
          'md3_get_daily_recommend', <String, Object?>{});
      expect(res.isError, isTrue);
      expect(res.text, contains('未登录'));
    });

    test('md3_play_daily_recommend 取推荐整单播放', () async {
      final control = FakePlayerControl();
      final fake = FakeApiClient()
        ..daily = [
          KugouSongDetail(hash: 'd1', songName: '推荐歌', duration: 100),
          KugouSongDetail(hash: 'd2', songName: '推荐歌2', duration: 100),
        ];
      final registry = McpToolRegistry(
          buildMcpTools(control: control, library: fake));
      final res =
          await registry.execute('md3_play_daily_recommend', <String, Object?>{});
      expect(res.isError, isFalse);
      expect(control.calls, ['playList:2@0']);
      expect((res.data! as Map)['queued'], 2);
    });

    test('md3_play_personal_fm 空返回时报错且不播放', () async {
      final control = FakePlayerControl();
      final registry = McpToolRegistry(
          buildMcpTools(control: control, library: FakeApiClient()));
      final res =
          await registry.execute('md3_play_personal_fm', <String, Object?>{});
      expect(res.isError, isTrue);
      expect(control.calls, isEmpty);
    });

    test('md3_play_personal_fm 播放一轮 FM 歌曲', () async {
      final control = FakePlayerControl();
      final fake = FakeApiClient()
        ..fmSongs = [
          KugouSongDetail(hash: 'f1', songName: 'FM歌', duration: 100),
        ];
      final registry = McpToolRegistry(
          buildMcpTools(control: control, library: fake));
      final res =
          await registry.execute('md3_play_personal_fm', <String, Object?>{});
      expect(res.isError, isFalse);
      expect(control.calls, ['playList:1@0']);
    });

    test('md3_get_toplist 投影榜单 id/name/song_count', () async {
      final fake = FakeApiClient()
        ..ranks = const KugouRankList(ranks: [
          KugouRank(id: '8888', name: '飙升榜', songCount: 100),
          KugouRank(id: '6666', name: '热歌榜', songCount: 300),
        ]);
      final registry = McpToolRegistry(
          buildMcpTools(control: FakePlayerControl(), library: fake));
      final res = await registry.execute('md3_get_toplist', <String, Object?>{});
      expect(res.isError, isFalse);
      final data = res.data! as Map<String, Object?>;
      expect(data['count'], 2);
      final items = data['items']! as List;
      expect((items.first as Map)['id'], '8888');
      expect((items.first as Map)['name'], '飙升榜');
      expect((items.first as Map)['song_count'], 100);
    });

    test('md3_play_rank 取榜单歌曲并整单播放', () async {
      final control = FakePlayerControl();
      final fake = FakeApiClient()
        ..rankSongs = [
          KugouSongDetail(hash: 'r1', songName: '榜一', duration: 100),
        ];
      final registry =
          McpToolRegistry(buildMcpTools(control: control, library: fake));
      final res = await registry.execute(
          'md3_play_rank', <String, Object?>{'rank_id': '8888'});
      expect(res.isError, isFalse);
      expect(control.calls, ['playList:1@0']);
    });

    test('md3_play_rank 榜单无歌曲时返回错误', () async {
      final control = FakePlayerControl();
      final registry =
          McpToolRegistry(buildMcpTools(control: control, library: FakeApiClient()));
      final res = await registry.execute(
          'md3_play_rank', <String, Object?>{'rank_id': '8888'});
      expect(res.isError, isTrue);
      expect(control.calls, isEmpty);
    });

    test('md3_get_listen_history 解析不了结构时返回截断原文', () async {
      final fake = FakeApiClient()
        ..listen = {'data': {'info': '不是列表'}};
      final registry = McpToolRegistry(
          buildMcpTools(control: FakePlayerControl(), library: fake));
      final res = await registry.execute(
          'md3_get_listen_history', <String, Object?>{});
      final data = res.data! as Map<String, Object?>;
      expect(data['items'], isEmpty);
      expect(data['raw_truncated'], isNotNull);
    });

    test('md3_get_listen_history 识别 data.info 列表时投影条目并跳过无 hash 项', () async {
      final fake = FakeApiClient()
        ..listen = {
          'data': {
            'info': [
              {'hash': 'lh1', 'filename': '历史歌1', 'timestamp': 1700000000},
              {'hash': '', 'filename': '无hash'},
            ],
          },
        };
      final registry = McpToolRegistry(
          buildMcpTools(control: FakePlayerControl(), library: fake));
      final res = await registry.execute(
          'md3_get_listen_history', <String, Object?>{});
      final data = res.data! as Map<String, Object?>;
      expect(data['count'], 1);
      final items = data['items']! as List;
      expect((items.first as Map)['hash'], 'lh1');
      expect((items.first as Map)['name'], '历史歌1');
      expect((items.first as Map)['timestamp'], 1700000000);
      expect(data.containsKey('raw_truncated'), isFalse);
    });

    test('md3_get_listen_history 上游 null 时返回错误', () async {
      final registry = McpToolRegistry(
          buildMcpTools(control: FakePlayerControl(), library: FakeApiClient()));
      final res = await registry.execute(
          'md3_get_listen_history', <String, Object?>{});
      expect(res.isError, isTrue);
    });

    test('buildMcpTools 装配全部工具且只读模式隐藏写工具', () async {
      final registry = McpToolRegistry(buildMcpTools(
        control: FakePlayerControl(),
        library: FakeApiClient(),
        localLibrary: FakeLocalLibrary(const []),
      ));
      final names = registry.visibleTools().map((t) => t.name).toList(growable: false);
      expect(names, hasLength(37));
      expect(names, contains('md3_get_player_state'));
      expect(names, contains('md3_search_songs'));
      expect(names, contains('md3_search_local_songs'));
      expect(names, contains('md3_play_local_song'));
      expect(names, contains('md3_toggle'));
      expect(names, contains('md3_set_loop_mode'));
      expect(names, contains('md3_play_queue_index'));
      expect(names, contains('md3_clear_queue'));

      registry.readOnly = true;
      final readOnlyNames =
          registry.visibleTools().map((t) => t.name).toList(growable: false);
      expect(readOnlyNames, hasLength(14));
      expect(readOnlyNames, isNot(contains('md3_play_keyword')));
    });
  });

  group('本地曲库工具', () {
    test('md3_search_local_songs 投影本地歌曲', () async {
      final local = FakeLocalLibrary([
        const Song(
            id: 'local1',
            title: '本地晴天',
            artist: '周杰伦',
            album: '本地',
            duration: Duration(seconds: 100)),
      ]);
      final registry = McpToolRegistry(buildMcpTools(
        control: FakePlayerControl(),
        library: FakeApiClient(),
        localLibrary: local,
      ));
      final res = await registry.execute(
          'md3_search_local_songs', <String, Object?>{'keyword': '晴天'});
      final items = (res.data! as Map)['items']! as List;
      expect((items.first as Map)['id'], 'local1');
      expect((items.first as Map)['is_online'], isFalse);
    });

    test('md3_search_local_songs 不传 localLibrary 时工具不存在', () async {
      final registry = McpToolRegistry(buildMcpTools(
        control: FakePlayerControl(),
        library: FakeApiClient(),
      ));
      final names = registry.visibleTools().map((t) => t.name).toList(growable: false);
      expect(names, isNot(contains('md3_search_local_songs')));
      expect(
        (await registry.execute(
          'md3_search_local_songs',
          <String, Object?>{'keyword': '晴天'},
        )).isError,
        isTrue,
      );
    });

    test('md3_play_local_song 未找到时返回错误', () async {
      final local = FakeLocalLibrary(const []);
      final registry = McpToolRegistry(buildMcpTools(
        control: FakePlayerControl(),
        library: FakeApiClient(),
        localLibrary: local,
      ));
      expect(
        (await registry.execute(
          'md3_play_local_song',
          <String, Object?>{'id': 'nope'},
        )).isError,
        isTrue,
      );
    });

    test('md3_play_local_song 按 id 播放本地歌曲', () async {
      final control = FakePlayerControl();
      final local = FakeLocalLibrary([
        const Song(
            id: 'local1',
            title: '本地晴天',
            artist: '周杰伦',
            album: '本地',
            duration: Duration(seconds: 100)),
      ]);
      final registry = McpToolRegistry(buildMcpTools(
        control: control,
        library: FakeApiClient(),
        localLibrary: local,
      ));
      final res = await registry.execute(
          'md3_play_local_song', <String, Object?>{'id': 'local1'});
      expect(res.isError, isFalse);
      expect(control.calls, ['play:本地晴天']);
      final data = res.data! as Map<String, Object?>;
      expect(data['playing'], isTrue);
      expect(data['title'], '本地晴天');
      expect(data['artist'], '周杰伦');
    });
  });

  group('曲库写工具', () {
    test('md3_add_song_to_playlist 需确认并转发 hash/listid，回执含歌名', () async {
      final write = FakeLibraryWrite();
      final broker = McpConfirmationBroker();
      final registry = McpToolRegistry(
        buildMcpTools(
          control: FakePlayerControl(),
          library: FakeApiClient(),
          libraryWrite: write,
        ),
        confirmations: broker,
      );
      final future = registry.execute('md3_add_song_to_playlist',
          <String, Object?>{'hash': 'h1', 'listid': '123'});
      broker.resolve(broker.pending.value!.id, true);
      final res = await future;
      expect(res.isError, isFalse);
      expect(write.calls, ['add:h1->123']);
      final data = res.data! as Map<String, Object?>;
      expect(data['title'], '晴天');
      expect(data['listid'], '123');
    });

    test('md3_add_song_to_playlist detail 缺失时返回可读错误且不转发', () async {
      final write = FakeLibraryWrite();
      final registry = McpToolRegistry(buildMcpTools(
        control: FakePlayerControl(),
        library: EmptyApiClient(),
        libraryWrite: write,
      ));
      // 跳过二次确认，聚焦 detail 缺失分支
      registry.confirmationEnabled = false;
      final res = await registry.execute(
          'md3_add_song_to_playlist', <String, Object?>{'hash': 'x', 'listid': '1'});
      expect(res.isError, isTrue);
      expect(res.text, contains('未找到'));
      expect(write.calls, isEmpty);
    });

    test('md3_create_playlist 需确认并转发歌单名', () async {
      final write = FakeLibraryWrite();
      final broker = McpConfirmationBroker();
      final registry = McpToolRegistry(
        buildMcpTools(
          control: FakePlayerControl(),
          library: FakeApiClient(),
          libraryWrite: write,
        ),
        confirmations: broker,
      );
      final future = registry.execute(
          'md3_create_playlist', <String, Object?>{'name': '我的歌单'});
      broker.resolve(broker.pending.value!.id, true);
      final res = await future;
      expect(res.isError, isFalse);
      expect(write.calls, ['create:我的歌单']);
      expect(res.text, contains('我的歌单'));
    });

    test('libraryWrite 未注入时不产生 library_write 组工具', () {
      final registry = McpToolRegistry(buildMcpTools(
        control: FakePlayerControl(),
        library: FakeApiClient(),
      ));
      expect(
        registry.visibleTools().where((t) => t.group == kMcpGroupLibraryWrite),
        isEmpty,
      );
      // 上游无"收藏单曲"模块（Task 11 决策门）：收藏类工具永不装配
      expect(registry.find('md3_favorite_song'), isNull);
      expect(registry.find('md3_unfavorite_song'), isNull);
    });

    test('装配 libraryWrite 后工具总数 39，含两个写工具', () {
      final registry = McpToolRegistry(buildMcpTools(
        control: FakePlayerControl(),
        library: FakeApiClient(),
        localLibrary: FakeLocalLibrary(const []),
        libraryWrite: FakeLibraryWrite(),
      ));
      final names =
          registry.visibleTools().map((t) => t.name).toList(growable: false);
      expect(names, hasLength(39));
      expect(names, contains('md3_add_song_to_playlist'));
      expect(names, contains('md3_create_playlist'));
      expect(names, isNot(contains('md3_favorite_song')));
      expect(names, isNot(contains('md3_unfavorite_song')));
    });
  });

  group('App 功能工具', () {
    test('md3_set_sleep_timer 分钟数与取消', () async {
      final app = FakeAppFeatures();
      // 注入时钟：同一写工具连续调用会被 400ms 防抖拦截，逐秒推进避免误伤
      var sec = 0;
      final registry = McpToolRegistry(
        buildMcpTools(
          control: FakePlayerControl(),
          library: FakeApiClient(),
          appFeatures: app,
        ),
        clock: () => DateTime(2026, 1, 1, 0, 0, sec++),
      );
      await registry.execute(
          'md3_set_sleep_timer', <String, Object?>{'minutes': 30});
      await registry.execute(
          'md3_set_sleep_timer', <String, Object?>{'minutes': 0});
      expect(app.calls, ['sleep:30', 'sleep:null']);
    });

    test('md3_set_sleep_timer 越界分钟数被拒绝', () async {
      final app = FakeAppFeatures();
      final registry = McpToolRegistry(buildMcpTools(
        control: FakePlayerControl(),
        library: FakeApiClient(),
        appFeatures: app,
      ));
      final res = await registry.execute(
          'md3_set_sleep_timer', <String, Object?>{'minutes': 481});
      expect(res.isError, isTrue);
      expect(app.calls, isEmpty);
    });

    test('md3_apply_eq_preset 校验预设名', () async {
      final app = FakeAppFeatures();
      // 注入时钟：非法名与合法名两次连续调用需要跨过 400ms 防抖
      var sec = 0;
      final registry = McpToolRegistry(
        buildMcpTools(
          control: FakePlayerControl(),
          library: FakeApiClient(),
          appFeatures: app,
        ),
        clock: () => DateTime(2026, 1, 1, 0, 0, sec++),
      );
      // 跳过二次确认，聚焦预设名校验分支（确认行为单独用例覆盖）
      registry.confirmationEnabled = false;
      final bad = await registry.execute(
          'md3_apply_eq_preset', <String, Object?>{'name': '不存在'});
      expect(bad.isError, isTrue);
      expect(bad.text, contains('古典'));
      await registry.execute('md3_apply_eq_preset', <String, Object?>{'name': '流行'});
      expect(app.calls, ['preset:流行']);
    });

    test('md3_set_eq_enabled / md3_set_desktop_lyric 转发布尔', () async {
      final app = FakeAppFeatures();
      final registry = McpToolRegistry(buildMcpTools(
        control: FakePlayerControl(),
        library: FakeApiClient(),
        appFeatures: app,
      ));
      // 跳过二次确认，聚焦转发（确认行为单独用例覆盖）
      registry.confirmationEnabled = false;
      await registry.execute(
          'md3_set_eq_enabled', <String, Object?>{'enabled': true});
      await registry.execute(
          'md3_set_desktop_lyric', <String, Object?>{'enabled': true});
      expect(app.calls, ['eq:true', 'lyric:true']);
    });

    test('App 功能写工具要求二次确认（无 broker 时拒绝）', () async {
      final app = FakeAppFeatures();
      final registry = McpToolRegistry(buildMcpTools(
        control: FakePlayerControl(),
        library: FakeApiClient(),
        appFeatures: app,
      ));
      // md3_set_sleep_timer 不要求确认，直接放行
      await registry.execute(
          'md3_set_sleep_timer', <String, Object?>{'minutes': 15});
      expect(app.calls, ['sleep:15']);
      // 其余三个要求确认：无 broker（保守默认）一律拒绝
      final rejectCases = <String, Map<String, Object?>>{
        'md3_set_eq_enabled': <String, Object?>{'enabled': false},
        'md3_apply_eq_preset': <String, Object?>{'name': '古典'},
        'md3_set_desktop_lyric': <String, Object?>{'enabled': false},
      };
      for (final entry in rejectCases.entries) {
        final res = await registry.execute(entry.key, entry.value);
        expect(res.isError, isTrue, reason: entry.key);
        expect(res.text, contains('未确认'), reason: entry.key);
      }
      expect(app.calls, ['sleep:15']);
    });

    test('md3_set_eq_enabled 经 broker 确认后执行', () async {
      final app = FakeAppFeatures();
      final broker = McpConfirmationBroker();
      final registry = McpToolRegistry(
        buildMcpTools(
          control: FakePlayerControl(),
          library: FakeApiClient(),
          appFeatures: app,
        ),
        confirmations: broker,
      );
      final future =
          registry.execute('md3_set_eq_enabled', <String, Object?>{'enabled': true});
      broker.resolve(broker.pending.value!.id, true);
      final res = await future;
      expect(res.isError, isFalse);
      expect(app.calls, ['eq:true']);
    });

    test('md3_get_app_features 输出模式只读投影', () async {
      final app = FakeAppFeatures();
      final registry = McpToolRegistry(buildMcpTools(
        control: FakePlayerControl(),
        library: FakeApiClient(),
        appFeatures: app,
      ));
      final res =
          await registry.execute('md3_get_app_features', <String, Object?>{});
      final data = res.data! as Map<String, Object?>;
      expect(data['output_mode'], 'system');
      expect(data['eq'], <String, Object?>{
        'enabled': false,
        'presets': ['古典', '流行'],
      });
      expect(data['sleep_timer'], <String, Object?>{
        'mode': 'off',
        'remaining_ms': isNull,
      });
      expect(data['desktop_lyric_enabled'], isFalse);
      expect(data['usb_device_available'], isFalse);
    });

    test('装配 appFeatures 后工具总数 44，5 个工具归 app_features 组', () {
      final registry = McpToolRegistry(buildMcpTools(
        control: FakePlayerControl(),
        library: FakeApiClient(),
        localLibrary: FakeLocalLibrary(const []),
        libraryWrite: FakeLibraryWrite(),
        appFeatures: FakeAppFeatures(),
      ));
      final names =
          registry.visibleTools().map((t) => t.name).toList(growable: false);
      expect(names, hasLength(44));
      final appGroup =
          registry.visibleTools().where((t) => t.group == kMcpGroupAppFeatures);
      expect(
        appGroup.map((t) => t.name).toList(growable: false),
        unorderedEquals(<String>[
          'md3_get_app_features',
          'md3_set_sleep_timer',
          'md3_set_eq_enabled',
          'md3_apply_eq_preset',
          'md3_set_desktop_lyric',
        ]),
      );
    });

    test('appFeatures 未注入时不产生 app_features 组工具', () {
      final registry = McpToolRegistry(buildMcpTools(
        control: FakePlayerControl(),
        library: FakeApiClient(),
        localLibrary: FakeLocalLibrary(const []),
        libraryWrite: FakeLibraryWrite(),
      ));
      expect(
        registry.visibleTools().where((t) => t.group == kMcpGroupAppFeatures),
        isEmpty,
      );
      expect(
        registry.visibleTools().map((t) => t.name).toList(growable: false),
        hasLength(39),
      );
      expect(registry.find('md3_get_app_features'), isNull);
      expect(registry.find('md3_set_sleep_timer'), isNull);
      expect(registry.find('md3_set_eq_enabled'), isNull);
      expect(registry.find('md3_apply_eq_preset'), isNull);
      expect(registry.find('md3_set_desktop_lyric'), isNull);
    });
  });
}
