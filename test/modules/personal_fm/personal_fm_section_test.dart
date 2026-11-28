import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/theme/app_theme.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/modules/personal_fm/personal_fm_core.dart';
import 'package:md3music/modules/personal_fm/personal_fm_section.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';
import 'package:md3music/widgets/wavy_playback_line.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一次行为回报（[KugouProvider.reportPersonalFmAction] 收到的参数快照）。
class _FeedbackReport {
  const _FeedbackReport({
    required this.action,
    required this.mode,
    required this.songPoolId,
    required this.hash,
    required this.songId,
    required this.curMark,
    required this.playtime,
    required this.isOverplay,
  });

  final String action;
  final String? mode;
  final int? songPoolId;
  final String? hash;
  final String? songId;
  final String? curMark;
  final int? playtime;
  final bool isOverplay;
}

class _FakeKugou extends KugouProvider {
  _FakeKugou(List<KugouSongDetail> songs) : songs = List.of(songs);

  final List<KugouSongDetail> songs;
  final List<String> movedToFirst = [];

  /// 每次行为回报收到的参数。**必须**覆盖 reportPersonalFmAction：不覆盖会打到
  /// 真实 KugouApiClient 的 Dio（测试里 127.0.0.1:8080 不存在，每条 FM 回报
  /// 都会刷一行 400 的 DioException 日志）。签名与 provider 侧不一致会被
  /// INVALID_OVERRIDE 抓住，改动时逐参数对照。
  final List<_FeedbackReport> feedbackReports = [];

  /// 每次拉列表用的档位参数，格式 'mode/songPoolId'。
  final List<String> loadedStations = [];

  /// 每次续播请求带的游标 hash，null 表示那一次是不带游标的退一步。
  final List<String?> fetchCursors = [];

  /// 续播请求依次返回的结果；排空后一律返回 null（模拟接口失败 / 无新歌）。
  final List<List<KugouSongDetail>?> fetchQueue = [];

  /// 「不喜欢」上报的返回值序列；按调用顺序消耗，排空后返回 null。
  /// null 模拟**请求本身失败**（`_get` 吞掉一切错误返回 null）。
  final List<List<KugouSongDetail>?> garbageQueue = [];

  @override
  bool get isLoggedIn => true;

  @override
  List<KugouSongDetail> get personalFmSongs => songs;

  @override
  List<Song> get personalFmAsSongs => songs.map((e) => e.toSong()).toList();

  @override
  void moveToFirst(KugouSongDetail song) => movedToFirst.add(song.hash);

  @override
  void appendFmSongs(List<KugouSongDetail> more) => songs.addAll(more);

  @override
  Future<List<KugouSongDetail>?> fetchMorePersonalFm({
    required String mode,
    required int songPoolId,
    String? hash,
    String? songId,
  }) async {
    fetchCursors.add(hash);
    return fetchQueue.isEmpty ? null : fetchQueue.removeAt(0);
  }

  @override
  Future<void> getPersonalFm({
    String? mode,
    int? songPoolId,
    String? hash,
    String? songId,
    String? action,
    bool noCache = false,
    bool forceRefresh = false,
  }) async {
    loadedStations.add('$mode/$songPoolId');
  }

  @override
  Future<List<KugouSongDetail>?> reportPersonalFmAction({
    required String action,
    String? mode,
    int? songPoolId,
    String? hash,
    String? songId,
    String? curMark,
    int? playtime,
    bool isOverplay = false,
  }) async {
    feedbackReports.add(
      _FeedbackReport(
        action: action,
        mode: mode,
        songPoolId: songPoolId,
        hash: hash,
        songId: songId,
        curMark: curMark,
        playtime: playtime,
        isOverplay: isOverplay,
      ),
    );
    if (action != 'garbage') return null;
    // 垃圾桶回报会带回替换批次；排空后返回 null（= 请求本身失败）。
    if (garbageQueue.isEmpty) return null;
    return garbageQueue.removeAt(0);
  }
}

class _FakePlayer extends PlayerProvider {
  Song? _song;
  bool _playing = false;
  List<Song> _queue = const [];
  int _index = -1;

  int resumeCalls = 0;
  int pauseCalls = 0;
  int playPlaylistCalls = 0;
  int nextCalls = 0;

  /// 每次 appendPlaylist 接进来的歌 id。
  final List<List<String>> appended = [];

  /// 让 appendPlaylist 在歌已经进队列之后抛异常，模拟真实实现里
  /// audio_service 队列同步失败那一段（player_provider L1548-1571）。
  bool throwAfterAppend = false;

  /// 可设定的采样值：FmRefill 每次收到播放器通知都会读 position/duration，
  /// 用来决定 play 回报的 playtime 与 is_overplay（真实实现里这两个 getter
  /// 由 audio_service 回填，测试里只能由这里喂值）。
  Duration positionValue = Duration.zero;
  Duration? durationValue;

  @override
  Duration get position => positionValue;

  @override
  Duration? get duration => durationValue;

  @override
  Song? get currentSong => _song;

  @override
  bool get isPlaying => _playing;

  @override
  List<Song> get playlist => _queue;

  @override
  int get currentIndex => _index;

  void simulate({Song? song, bool playing = false, int? index}) {
    _song = song;
    _playing = playing;
    if (index != null) _index = index;
    notifyListeners();
  }

  @override
  Future<void> resume({bool notifyRoom = true}) async => resumeCalls++;

  @override
  Future<void> pause({bool notifyRoom = true}) async => pauseCalls++;

  @override
  Future<void> playOnlinePlaylist(List<Song> songs, int startIndex) async {
    playPlaylistCalls++;
    _queue = List.of(songs);
    _index = startIndex;
    _song = songs.isEmpty ? null : songs[startIndex];
    notifyListeners();
  }

  @override
  Future<void> appendPlaylist(List<Song> songs) async {
    appended.add(songs.map((s) => s.id).toList());
    _queue = [..._queue, ...songs];
    notifyListeners();
    // 真实实现先把歌塞进 _playlist，再去动 audio_service 队列：后半段抛异常时
    // 队列其实已经能继续放了。
    if (throwAfterAppend) throw StateError('audio_service 队列同步失败');
  }

  @override
  Future<void> next({bool autoPlay = true}) async {
    nextCalls++;
    if (_index + 1 < _queue.length) {
      _index++;
      _song = _queue[_index];
      notifyListeners();
    }
  }
}

class _FakeFavorites extends FavoritesProvider {
  /// 内存里的收藏集合与 toggle 记录：真实实现走 FavoritesRepository /
  /// KugouApiClient（测试里既没库也没网），双写断言只需要这份内存账本。
  final Set<String> favoriteIdSet = {};
  final List<Song> toggled = [];

  @override
  Future<void> loadFavorites() async {}

  @override
  bool isFavorite(String songId) => favoriteIdSet.contains(songId);

  @override
  Future<void> toggleFavorite(Song song) async {
    toggled.add(song);
    if (!favoriteIdSet.remove(song.id)) favoriteIdSet.add(song.id);
    notifyListeners();
  }
}

/// 对应 `_PersonalFmSectionState._kStationPrefKey`。
const String _kStationPrefKey = 'discover_fm_station_index';

/// 对应 `personal_fm_section.dart` 的 `_kCoverSize`。
const double _kCoverSize = 112.0;

/// curMark 是上游推荐令牌：红心 / play 回报必须原样带回（personal_fm_core 的
/// reportFmFeedback 读的就是它），给每首歌配上便于断言 token 真的走通了。
const List<KugouSongDetail> _songs = [
  KugouSongDetail(
    hash: 'h0',
    songName: 'song 0',
    artistName: 'a0',
    curMark: 'mark0',
  ),
  KugouSongDetail(
    hash: 'h1',
    songName: 'song 1',
    artistName: 'a1',
    curMark: 'mark1',
  ),
  KugouSongDetail(
    hash: 'h2',
    songName: 'song 2',
    artistName: 'a2',
    curMark: 'mark2',
  ),
  KugouSongDetail(
    hash: 'h3',
    songName: 'song 3',
    artistName: 'a3',
    curMark: 'mark3',
  ),
];

void main() {
  // [KugouProvider] 的构造函数会发一次 registerDevice 请求，拦截器要等本地 API
  // 服务器就绪（测试里永远不会），那个 timeout(8s) 会留下待触发的 timer。
  setUpAll(KugouApiClient.markServerReady);

  /// 放掉启动请求留下的 dio 计时器，否则测试结束时会因 pending timer 失败。
  Future<void> drainProviderStartup(WidgetTester tester) =>
      tester.pump(const Duration(seconds: 5));

  Future<void> pumpSection(
    WidgetTester tester, {
    required _FakeKugou kugou,
    required _FakePlayer player,
    _FakeFavorites? favorites,
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<KugouProvider>.value(value: kugou),
          ChangeNotifierProvider<PlayerProvider>.value(value: player),
          ChangeNotifierProvider<FavoritesProvider>(
            create: (_) => favorites ?? _FakeFavorites(),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: AppTheme.defaultSeedColor,
              brightness: brightness,
            ),
          ),
          home: const Scaffold(body: PersonalFmSection()),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('电台续到列表第二首：卡片换成那一首，播放态不翻成暂停', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final kugou = _FakeKugou(_songs);
    final player = _FakePlayer();
    await pumpSection(tester, kugou: kugou, player: player);

    player.simulate(song: _songs[0].toSong(), playing: true);
    await tester.pump();
    expect(find.text('song 0'), findsOneWidget);
    expect(find.byIcon(Icons.pause), findsOneWidget);

    // 电台自己续到下一首：列表顺序不变，只有播放器的当前曲目变了。
    player.simulate(song: _songs[1].toSong(), playing: true);
    await tester.pump();

    expect(find.text('song 1'), findsOneWidget, reason: '卡片该换成正在播的这首');
    expect(find.text('song 0'), findsNothing, reason: '不该停在上一首');
    expect(find.byIcon(Icons.pause), findsOneWidget, reason: '仍在播，按钮是暂停');
    expect(find.byIcon(Icons.play_arrow), findsNothing);
    expect(
      find.byTooltip('播放：song 2'),
      findsOneWidget,
      reason: '预告该从正在播的下一首开始',
    );
    expect(find.byTooltip('播放：song 1'), findsNothing, reason: '正在播的不再是预告');

    await drainProviderStartup(tester);
  });

  testWidgets('暂停在电台某一首上：点播放是 resume，不从头重放也不重排列表', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final kugou = _FakeKugou(_songs);
    final player = _FakePlayer();
    await pumpSection(tester, kugou: kugou, player: player);

    player.simulate(song: _songs[1].toSong(), playing: false);
    await tester.pump();
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();

    expect(player.resumeCalls, 1);
    expect(player.playPlaylistCalls, 0, reason: '不该把这首从头重放');
    expect(kugou.movedToFirst, isEmpty, reason: '不该重排电台列表');

    await drainProviderStartup(tester);
  });

  testWidgets('播放器不在本电台上：点播放从列表第一首起播', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final kugou = _FakeKugou(_songs);
    final player = _FakePlayer();
    await pumpSection(tester, kugou: kugou, player: player);

    expect(find.text('song 0'), findsOneWidget, reason: '没起播时预告列表第一首');
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();

    expect(player.playPlaylistCalls, 1);
    expect(player.resumeCalls, 0);

    await drainProviderStartup(tester);
  });

  testWidgets('起播时挂上补货回调，队列快放完能续上（无限电台）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final kugou = _FakeKugou(_songs);
    final player = _FakePlayer();
    await pumpSection(tester, kugou: kugou, player: player);

    expect(player.onPlaylistEnd, isNull, reason: '没起播前不该占着回调槽位');
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();
    expect(player.onPlaylistEnd, isNotNull, reason: '本区块起播的队列由本区块补货');

    await drainProviderStartup(tester);
  });

  testWidgets('队列已经不是本电台的：交还槽位，不去要新歌', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final kugou = _FakeKugou(_songs);
    final player = _FakePlayer();
    await pumpSection(tester, kugou: kugou, player: player);

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();
    expect(player.onPlaylistEnd, isNotNull);
    // 起播那次预补要的是本电台自己的队列，不算「给别人要歌」。
    final fetchesAtStart = kugou.fetchCursors.length;

    // 用户从别处起播了别的歌，回调还挂着。
    player.simulate(
      song: const Song(
        id: 'other',
        title: '别处的歌',
        artist: 'x',
        album: '',
        duration: Duration(seconds: 60),
      ),
      playing: true,
    );
    await tester.pump();

    expect(
      player.onPlaylistEnd,
      isNull,
      reason: '占着槽位会把普通歌单的「播完回到第一首」兜底一起遮蔽掉',
    );
    expect(
      kugou.fetchCursors.length,
      fetchesAtStart,
      reason: '不该给别人的队列要新歌',
    );
    expect(player.nextCalls, 0, reason: '不是本电台的队列，不该推它切歌');

    await drainProviderStartup(tester);
  });

  testWidgets('起播就先接一批：不把补货压到队列见底那一刻', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final kugou = _FakeKugou(_songs);
    final player = _FakePlayer();
    kugou.fetchQueue.add(const [
      KugouSongDetail(hash: 'h4', songName: 'song 4'),
    ]);
    await pumpSection(tester, kugou: kugou, player: player);

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();

    expect(kugou.fetchCursors, ['h3'], reason: '用起播那一批的最后一首当游标');
    expect(player.appended, [
      ['h4'],
    ], reason: '起播后立刻接一批，别等这一批放到底');
    expect(player.playlist.length, 5);
    expect(player.nextCalls, 0, reason: '预补不该动播放位置');

    await drainProviderStartup(tester);
  });

  // 主症状：发现页切走一次区块就 dispose（app.dart 的 AnimatedSwitcher 按 tab id
  // 换子树），而队列还在放。补货一旦挂在 State 的 mounted 上，这里就永久停摆。
  testWidgets('区块被销毁后，队列播完照样补货并续播', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final kugou = _FakeKugou(_songs);
    final player = _FakePlayer();
    // 第一批是起播时的预补，第二批才是队列播完那一次。
    kugou.fetchQueue.addAll([
      const [KugouSongDetail(hash: 'h4', songName: 'song 4')],
      const [KugouSongDetail(hash: 'h5', songName: 'song 5')],
    ]);
    await pumpSection(tester, kugou: kugou, player: player);

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();
    final onQueueEnd = player.onPlaylistEnd;
    expect(onQueueEnd, isNotNull);

    await tester.pumpWidget(const SizedBox());
    expect(find.byType(PersonalFmSection), findsNothing, reason: '区块已销毁');

    await onQueueEnd!();
    await tester.pump();

    expect(kugou.fetchCursors, ['h3', 'h4'], reason: '游标跟着上一批的最后一首走');
    expect(player.appended, [
      ['h4'],
      ['h5'],
    ], reason: '区块没了也要往队列上接');
    expect(player.nextCalls, 1, reason: '接完要推一把 next，否则播放器停在原地');

    await drainProviderStartup(tester);
  });

  testWidgets('队列末尾第一次要不到歌：退避后重试，仍能续上', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final kugou = _FakeKugou(_songs);
    final player = _FakePlayer();
    // 起播预补先要走一批，之后第一轮带游标和退一步都空，第二轮带游标要到了。
    kugou.fetchQueue.addAll([
      const [KugouSongDetail(hash: 'h4', songName: 'song 4')],
      null,
      null,
      const [KugouSongDetail(hash: 'h5', songName: 'song 5')],
    ]);
    await pumpSection(tester, kugou: kugou, player: player);

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();

    final pending = player.onPlaylistEnd!();
    await tester.pump();
    expect(player.nextCalls, 0, reason: '第一轮没补上，先不该切歌');

    await tester.pump(const Duration(milliseconds: 700));
    await pending;

    expect(kugou.fetchCursors, ['h3', 'h4', null, 'h4']);
    expect(player.nextCalls, 1, reason: '重试补上了就该续播');

    await drainProviderStartup(tester);
  });

  testWidgets('提前补货失败后，还停在同一首上时允许再试', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final kugou = _FakeKugou(_songs);
    final player = _FakePlayer();
    await pumpSection(tester, kugou: kugou, player: player);

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();
    // 起播预补要不到歌，队列仍是原来 4 首。
    expect(kugou.fetchCursors, ['h3', null], reason: '带游标要不到就退一步再要');
    expect(player.appended, isEmpty);
    kugou.fetchCursors.clear();

    // 播到剩 3 首，命中阈值；这一次接口还是给不出歌。
    player.simulate(song: _songs[1].toSong(), playing: true, index: 1);
    await tester.pump();
    expect(kugou.fetchCursors, ['h3', null]);
    expect(player.appended, isEmpty);

    // 仍停在同一首上：下一次通知该再试，而不是被烧掉的下标挡住。
    kugou.fetchQueue.add(const [
      KugouSongDetail(hash: 'h4', songName: 'song 4'),
    ]);
    player.simulate(song: _songs[1].toSong(), playing: true, index: 1);
    await tester.pump();

    expect(player.appended, [
      ['h4'],
    ], reason: '一次失败不该把这个下标永久烧掉');

    await drainProviderStartup(tester);
  });

  // 主症状：切后台期间队列放到底，补货撞上网络抖动。三次重试用尽后如果就此收手，
  // 播放器停在最后一首（next 到末尾就 pause），提前补货那条路又被烧掉的下标挡着，
  // 这条队列就永久不补货了——回前台怎么点都恢复不过来。
  testWidgets('队列末尾重试全用尽后：后续通知仍能补货，并自己推一把续播', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final kugou = _FakeKugou(_songs);
    final player = _FakePlayer();
    await pumpSection(tester, kugou: kugou, player: player);

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();
    // 播到队列最后一首，起播预补和提前补货都没要到歌。
    player.simulate(song: _songs[3].toSong(), playing: true, index: 3);
    await tester.pump();

    final pending = player.onPlaylistEnd!();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 1300));
    await pending;
    expect(player.nextCalls, 0, reason: '三轮都没补上，这时确实推不动');
    expect(player.appended, isEmpty);

    // 网络恢复。播放器 pause 在最后一首会发一次通知，这一次必须能重新要歌。
    kugou.fetchQueue.add(const [
      KugouSongDetail(hash: 'h4', songName: 'song 4'),
    ]);
    player.simulate(song: _songs[3].toSong(), playing: false, index: 3);
    await tester.pump();

    expect(player.appended, [
      ['h4'],
    ], reason: '重试用尽不该让这条队列永久停摆');
    expect(player.nextCalls, 1, reason: '停摆过就没人推 next 了，得自己推');

    await drainProviderStartup(tester);
  });

  // appendPlaylist 先把歌塞进 _playlist 再动 audio_service 队列，后半段抛异常时
  // 队列其实已经能继续放了。这时报「没补上」会让 onQueueEnd 白白放弃一条补满的队列。
  testWidgets('接歌后半段抛异常但队列已变长：算补上了，照常续播', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final kugou = _FakeKugou(_songs);
    final player = _FakePlayer();
    kugou.fetchQueue.addAll([
      const [KugouSongDetail(hash: 'h4', songName: 'song 4')],
      const [KugouSongDetail(hash: 'h5', songName: 'song 5')],
    ]);
    await pumpSection(tester, kugou: kugou, player: player);

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();

    player.throwAfterAppend = true;
    await player.onPlaylistEnd!();
    await tester.pump();

    expect(player.playlist.map((s) => s.id), contains('h5'), reason: '歌已经进队列了');
    expect(player.nextCalls, 1, reason: '队列变长了就该续播，不该当成补货失败');

    await drainProviderStartup(tester);
  });

  testWidgets('槽位空了但队列还在放：点播放补挂续播器，不重放当前这首', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final kugou = _FakeKugou(_songs);
    final player = _FakePlayer();
    await pumpSection(tester, kugou: kugou, player: player);

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();
    // 模拟续播器已经退场（区块重建过等），槽位空着但队列还是本电台的。
    player.onPlaylistEnd = null;
    player.simulate(song: _songs[1].toSong(), playing: false, index: 1);
    await tester.pump();

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();

    expect(
      player.onPlaylistEnd,
      isNotNull,
      reason: '槽位空着的队列放完就走「回到第一首」兜底，不再是电台',
    );
    expect(player.resumeCalls, 1, reason: '仍是 resume');
    expect(player.playPlaylistCalls, 1, reason: '不该把这首从头重放');

    await drainProviderStartup(tester);
  });

  testWidgets('档位按钮与播放按钮横向居中对齐', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final kugou = _FakeKugou(_songs);
    final player = _FakePlayer();
    await pumpSection(tester, kugou: kugou, player: player);

    player.simulate(song: _songs[0].toSong(), playing: true);
    await tester.pump();

    expect(
      tester.getCenter(find.byTooltip('电台档位：红心')).dx,
      tester.getCenter(find.byIcon(Icons.pause)).dx,
    );

    await drainProviderStartup(tester);
  });

  testWidgets('律动线贯穿整卡不留边距，中线落在两枚按钮圆心正中', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final kugou = _FakeKugou(_songs);
    final player = _FakePlayer();
    await pumpSection(tester, kugou: kugou, player: player);

    player.simulate(song: _songs[0].toSong(), playing: true);
    await tester.pump();

    final card = tester.getRect(
      find
          .descendant(
            of: find.byType(PersonalFmSection),
            matching: find.byType(Material),
          )
          .first,
    );
    final wave = tester.getRect(find.byType(WavyPlaybackLine));
    final cover = tester.getRect(find.byTooltip('打开播放详情'));
    final play = tester.getCenter(find.byIcon(Icons.pause));
    final station = tester.getCenter(find.byTooltip('电台档位：红心'));

    expect(wave.left, card.left, reason: '左端贴卡片左边，不留边距');
    expect(wave.right, card.right, reason: '右端贴卡片右边，不留边距');
    expect(wave.left, lessThan(cover.left), reason: '要伸到封面底下才谈得上被覆盖');
    expect(
      wave.center.dy,
      (play.dy + station.dy) / 2,
      reason: '3 + 10 + 3 的缝把中线放在两枚按钮圆心正中',
    );
    expect(cover.height, _kCoverSize, reason: '封面高度决定行高，卡片不该被撑开');

    await drainProviderStartup(tester);
  });

  // 深色主题下 surfaceDim 与 surface 同值，用它做托盘展开后看起来就是没有背景。
  for (final brightness in Brightness.values) {
    testWidgets('抽屉那一层的底色与卡面、页面底色都不同（$brightness）', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final kugou = _FakeKugou(_songs);
      final player = _FakePlayer();
      await pumpSection(
        tester,
        kugou: kugou,
        player: player,
        brightness: brightness,
      );

      final section = find.byType(PersonalFmSection);
      final cs = Theme.of(tester.element(section)).colorScheme;
      // 区块里第一个 Material 就是抽屉那一层（卡面是它的子级）。
      final drawerLayer = tester.widget<Material>(
        find.descendant(of: section, matching: find.byType(Material)).first,
      );

      expect(drawerLayer.color, isNotNull);
      expect(drawerLayer.color, isNot(cs.surface), reason: '与页面底色同色就看不出抽屉');
      expect(
        drawerLayer.color,
        isNot(cs.surfaceContainerLow),
        reason: '与卡面同色就没有层级',
      );

      await drainProviderStartup(tester);
    });
  }

  testWidgets('恢复上次选的档位：列表已有内容时只同步档位，不重拉', (tester) async {
    SharedPreferences.setMockInitialValues({_kStationPrefKey: 2});
    final kugou = _FakeKugou(_songs);
    final player = _FakePlayer();
    await pumpSection(tester, kugou: kugou, player: player);
    await tester.pump();

    expect(find.byTooltip('电台档位：小众'), findsOneWidget, reason: '不该回到默认档');
    expect(
      kugou.loadedStations,
      isEmpty,
      reason: '发现页首屏已按保存档位拉过一批（DiscoverPage._loadAllData），区块只同步档位',
    );

    await drainProviderStartup(tester);
  });

  testWidgets('恢复上次选的档位：列表为空时按保存档补拉一次', (tester) async {
    SharedPreferences.setMockInitialValues({_kStationPrefKey: 2});
    final kugou = _FakeKugou(const []);
    final player = _FakePlayer();
    await pumpSection(tester, kugou: kugou, player: player);
    await tester.pump();

    expect(find.byTooltip('电台档位：小众'), findsOneWidget);
    expect(
      kugou.loadedStations,
      ['small/1'],
      reason: '列表为空（首拉失败等）时补拉保存档，否则卡片永远空着',
    );

    await drainProviderStartup(tester);
  });

  testWidgets('正在放本电台的歌时恢复档位：只改档位，不重拉列表', (tester) async {
    SharedPreferences.setMockInitialValues({_kStationPrefKey: 2});
    final kugou = _FakeKugou(_songs);
    final player = _FakePlayer()
      ..simulate(song: _songs[1].toSong(), playing: true);
    await pumpSection(tester, kugou: kugou, player: player);
    await tester.pump();

    expect(find.byTooltip('电台档位：小众'), findsOneWidget);
    expect(kugou.loadedStations, isEmpty, reason: '重拉会把队列与列表的对应关系冲掉');

    await drainProviderStartup(tester);
  });

  testWidgets('换档位会记住选择', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final kugou = _FakeKugou(_songs);
    final player = _FakePlayer();
    await pumpSection(tester, kugou: kugou, player: player);

    // 抽屉收起时高度为 0，里面的分段控件点不到，先展开。
    await tester.tap(find.byTooltip('电台档位：红心'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('探索'));
    await tester.pump();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(_kStationPrefKey), 1);
    expect(kugou.loadedStations, ['normal/2'], reason: '换档同时拉这一档的歌单');

    await drainProviderStartup(tester);
  });

  // ===== 行为回报（红心双写 / 档位契约 / FmRefill 的 play 回报） =====

  testWidgets('收藏按钮双写：先写本地收藏，再带 curMark 上报红心/取消红心', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final kugou = _FakeKugou(_songs);
    final player = _FakePlayer();
    final favorites = _FakeFavorites();
    await pumpSection(
      tester,
      kugou: kugou,
      player: player,
      favorites: favorites,
    );

    // 未起播时卡片渲染列表第一首（h0）。第一次点收藏：本地写入 + click_red。
    await tester.tap(find.byTooltip('收藏'));
    await tester.pump();

    expect(favorites.toggled.map((s) => s.id).toList(), ['h0'], reason: '本地收藏那一次写不能少');
    expect(favorites.isFavorite('h0'), isTrue);
    expect(kugou.feedbackReports, hasLength(1));
    final red = kugou.feedbackReports.single;
    expect(red.action, 'click_red');
    expect(red.hash, 'h0');
    expect(
      red.curMark,
      'mark0',
      reason: '本功能的要害：推荐令牌必须原样带回，缺了上游定位不到这条推荐',
    );
    expect(red.mode, 'normal');
    expect(red.songPoolId, 0, reason: '默认档红心 = normal/0');

    // Selector 翻实心跳后第二次点：本地取消 + cancel_red（取切换**前**的状态）。
    expect(find.byTooltip('取消收藏'), findsOneWidget);
    await tester.tap(find.byTooltip('取消收藏'));
    await tester.pump();

    expect(favorites.isFavorite('h0'), isFalse);
    expect(kugou.feedbackReports.last.action, 'cancel_red');
    expect(kugou.feedbackReports.last.curMark, 'mark0');

    await drainProviderStartup(tester);
  });

  testWidgets('收藏回报跟着当前档位：切到探索后上报的是 normal/2', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final kugou = _FakeKugou(_songs);
    final player = _FakePlayer();
    await pumpSection(tester, kugou: kugou, player: player);

    // 抽屉收起时点不到分段控件，先展开再切档（与「换档位会记住选择」同一路径）。
    await tester.tap(find.byTooltip('电台档位：红心'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('探索'));
    await tester.pump();

    await tester.tap(find.byTooltip('收藏'));
    await tester.pump();

    expect(kugou.feedbackReports, hasLength(1));
    expect(kugou.feedbackReports.single.mode, 'normal');
    expect(
      kugou.feedbackReports.single.songPoolId,
      2,
      reason: '档位取区块当前选中的那一档，不是写死的默认档',
    );

    await drainProviderStartup(tester);
  });

  test('档位表契约：电台追加在第 4 位，前 3 档的下标与 (mode, songPoolId) 不许动', () {
    // 档位下标持久化在 SharedPreferences 并被原生小部件镜像，重排会静默错位老用户的档位。
    expect(kFmStations, hasLength(4));
    expect(kFmStations[0].label, '红心');
    expect(kFmStations[0].mode, 'normal');
    expect(kFmStations[0].songPoolId, 0);
    expect(kFmStations[1].label, '探索');
    expect(kFmStations[1].mode, 'normal');
    expect(kFmStations[1].songPoolId, 2);
    expect(kFmStations[2].label, '小众');
    expect(kFmStations[2].mode, 'small');
    expect(kFmStations[2].songPoolId, 1);
    expect(kFmStations[3].label, '电台');
    expect(kFmStations[3].mode, 'radio');
  });

  test('restoreStationIndex：越界与负数回落默认档，新档 3 能恢复', () async {
    SharedPreferences.setMockInitialValues({_kStationPrefKey: 99});
    expect(await PersonalFmWidgetActions.restoreStationIndex(), 0);

    SharedPreferences.setMockInitialValues({_kStationPrefKey: -1});
    expect(await PersonalFmWidgetActions.restoreStationIndex(), 0);

    SharedPreferences.setMockInitialValues({_kStationPrefKey: 3});
    expect(
      await PersonalFmWidgetActions.restoreStationIndex(),
      3,
      reason: '上界随档位表扩到 4，第 4 档存进去要读得回来',
    );
  });

  testWidgets('切歌只给上一首补一次 play 回报：带 curMark 与 playtime，同首不重复', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final kugou = _FakeKugou(_songs);
    final player = _FakePlayer();
    await pumpSection(tester, kugou: kugou, player: player);

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();
    expect(
      kugou.feedbackReports.where((r) => r.action == 'play'),
      isEmpty,
      reason: '起播的第一首没有上一首，不该凭空报一条',
    );

    // 停在 h0 中途：同首的再次通知只刷新采样，不回报。
    player.positionValue = const Duration(seconds: 50);
    player.durationValue = const Duration(seconds: 60);
    player.simulate(song: _songs[0].toSong(), playing: true);
    await tester.pump();
    expect(
      kugou.feedbackReports.where((r) => r.action == 'play'),
      isEmpty,
      reason: '同一切歌只报一次，重复通知不能再报',
    );

    // 切到 h1：给上一首 h0 补一次 play，playtime 用最后一次采到的位置。
    player.simulate(song: _songs[1].toSong(), playing: true, index: 1);
    await tester.pump();
    final plays = kugou.feedbackReports.where((r) => r.action == 'play').toList();
    expect(plays, hasLength(1));
    expect(plays.single.hash, 'h0');
    expect(plays.single.curMark, 'mark0', reason: 'play 回报同样要带令牌');
    expect(plays.single.playtime, 50);
    expect(plays.single.mode, 'normal');
    expect(plays.single.songPoolId, 0);
    expect(
      plays.single.isOverplay,
      false,
      reason: '50/60 离曲尾还远，不该报成听完',
    );

    // 再次通知仍停在 h1：不重复报 h0。
    player.simulate(song: _songs[1].toSong(), playing: true, index: 1);
    await tester.pump();
    expect(
      kugou.feedbackReports.where((r) => r.action == 'play'),
      hasLength(1),
      reason: '同首的第二次通知不产生第二笔回报',
    );

    // 距总时长 2 秒内切到 h2：h1 这笔要报成听完。
    player.positionValue = const Duration(seconds: 59);
    player.simulate(song: _songs[1].toSong(), playing: true, index: 1);
    player.simulate(song: _songs[2].toSong(), playing: true, index: 2);
    await tester.pump();
    final plays2 = kugou.feedbackReports.where((r) => r.action == 'play').toList();
    expect(plays2, hasLength(2));
    expect(plays2.last.hash, 'h1');
    expect(plays2.last.playtime, 59);
    expect(
      plays2.last.isOverplay,
      true,
      reason: '59/60 落在曲尾 2 秒容差内，按听完报',
    );

    // 播放器换到本续播器不拥有的歌：先给**本家电台**欠着的 h2 补一笔再退场
    // （「听完一首电台歌去点普通歌单」是最常见的路径，不收尾这次收听就丢了），
    // 但绝不能给别处的歌报 play。
    player.simulate(
      song: const Song(
        id: 'other',
        title: '别处的歌',
        artist: 'x',
        album: '',
        duration: Duration(seconds: 60),
      ),
      playing: true,
    );
    await tester.pump();
    final playsOnLeave =
        kugou.feedbackReports.where((r) => r.action == 'play').toList();
    expect(playsOnLeave, hasLength(3), reason: '退场前把欠着的 h2 补报掉');
    expect(playsOnLeave.last.hash, 'h2');
    expect(
      playsOnLeave.any((r) => r.hash == 'other'),
      isFalse,
      reason: '不属于本电台的队列不该回报',
    );
    expect(player.onPlaylistEnd, isNull);

    await drainProviderStartup(tester);
  });

  testWidgets('队列到底：最后一首按听完上报（is_overplay=true，playtime=总时长）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final kugou = _FakeKugou(_songs);
    final player = _FakePlayer();
    await pumpSection(tester, kugou: kugou, player: player);

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();

    // 播到最后一首：切歌那次会先给 h0 报一笔 play（未听完），采到 200/210。
    player.positionValue = const Duration(seconds: 200);
    player.durationValue = const Duration(seconds: 210);
    player.simulate(song: _songs[3].toSong(), playing: true, index: 3);
    await tester.pump();

    // 队列到底。补货要不到歌（fetchQueue 为空），三轮重试用尽，但回报已经发出。
    final pending = player.onPlaylistEnd!();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 1300));
    await pending;

    final overplays = kugou.feedbackReports
        .where((r) => r.action == 'play' && r.isOverplay)
        .toList();
    expect(overplays, hasLength(1), reason: '只有到底这一首算听完');
    expect(overplays.single.hash, 'h3');
    expect(overplays.single.curMark, 'mark3');
    expect(
      overplays.single.playtime,
      210,
      reason: '到底这一刻已播时长即总时长，不走切歌那条差 2 秒的判定',
    );

    await drainProviderStartup(tester);
  });

  testWidgets('队列到底且补货成功：同一首只报一次 play，不被 next() 补第二笔', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    const prefetched = KugouSongDetail(
      hash: 'h8',
      songName: 'song 8',
      artistName: 'a8',
      duration: 180,
      curMark: 'mark8',
    );
    const extra = KugouSongDetail(
      hash: 'h9',
      songName: 'song 9',
      artistName: 'a9',
      duration: 210,
      curMark: 'mark9',
    );
    final kugou = _FakeKugou(_songs);
    final player = _FakePlayer();
    await pumpSection(tester, kugou: kugou, player: player);

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();

    // 切到最后一首会先触发「提前补货」那一路，必须单独喂它一批：留同一批给两次
    // 补货的话，预取先把歌吃掉，onQueueEnd 只能转去等 Future.delayed 重试，
    // 而 FakeAsync 的时钟不再自己前进，测试会挂到超时。
    kugou.fetchQueue.add(const [prefetched]);
    player.positionValue = const Duration(seconds: 200);
    player.durationValue = const Duration(seconds: 210);
    player.simulate(song: _songs[3].toSong(), playing: true, index: 3);
    await tester.pump();
    expect(player.appended, isNotEmpty, reason: '提前补货那一路要真的跑完');

    // 这一批才是留给「队列到底」的：报完 h3 会 appendPlaylist + next()，
    // 这两步各通知一次播放器，正是「同一首被报两遍」的现场。
    kugou.fetchQueue.add(const [extra]);
    final pending = player.onPlaylistEnd!();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 1300));
    await pending;

    expect(player.nextCalls, greaterThan(0), reason: '接上新歌必须推进一把');
    // 队列此刻是 h0..h3 + 预取的 h8 + 到底补的 h9，next() 走到的正是 h8。
    expect(player.currentSong?.id, 'h8');

    final h3Reports = kugou.feedbackReports.where((r) => r.hash == 'h3').toList();
    expect(h3Reports, hasLength(1), reason: '每首只报一次 play 是硬约束');
    expect(h3Reports.single.action, 'play');
    expect(h3Reports.single.isOverplay, isTrue);
    expect(
      h3Reports.single.playtime,
      210,
      reason: '到底那一笔按听完报，不能被 next() 的切歌补出一笔更小的 false',
    );
    expect(
      kugou.feedbackReports.where((r) => r.hash == 'h8' || r.hash == 'h9'),
      isEmpty,
      reason: '刚接上的歌还没听，不该有回报',
    );

    await drainProviderStartup(tester);
  });

  // ===== 不喜欢按钮（取代底排右下角那张预告封面） =====

  testWidgets('底排右端两枚同规格圆角矩形置右，上排圆心与底排逐一对齐', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final kugou = _FakeKugou(_songs);
    final player = _FakePlayer();
    // 播在 h0 上：播放按钮画暂停，上排才有可比的圆心。
    player.simulate(song: _songs[0].toSong(), playing: true);
    // 400dp 宽下卡内右栏 212dp：两枚 48 按钮 + 两份缝占 112，还能放 1 张预告封面。
    await pumpSection(tester, kugou: kugou, player: player);

    expect(find.byTooltip('不喜欢'), findsOneWidget, reason: '按钮必须常驻在底排');
    expect(find.byTooltip('播放：song 1'), findsOneWidget);
    expect(
      find.byTooltip('播放：song 2'),
      findsNothing,
      reason: '末两格都是按钮的（不喜欢取代了原先右下角那张预告封面）',
    );

    final dislike = tester.getRect(find.byTooltip('不喜欢'));
    final station = tester.getRect(find.byTooltip('电台档位：红心'));
    final favorite = tester.getRect(find.byTooltip('收藏'));
    final play = tester.getCenter(find.byIcon(Icons.pause));
    expect(
      dislike.height,
      station.height,
      reason: '两枚按钮同规格（都是 48 圆角矩形）',
    );
    expect(dislike.width, station.width);
    // 对齐基准是**底排**（两枚按钮间留一份封面缝）；上排收藏与播放之间垫同样的
    // 缝宽去迁就它——用户报的「上方按钮没和下方对齐」修的就是这一对。
    expect(
      station.left - dislike.right,
      closeTo(8, 0.01),
      reason: '不喜欢与档位之间留一份封面缝',
    );
    expect(
      dislike.center.dx,
      closeTo(favorite.center.dx, 0.01),
      reason: '不喜欢对上收藏的圆心',
    );
    expect(
      station.center.dx,
      closeTo(play.dx, 0.01),
      reason: '档位对上播放按钮的圆心',
    );

    await drainProviderStartup(tester);
  });

  testWidgets('点不喜欢：上报 garbage（带 curMark 与当前档位）并切下一首', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final kugou = _FakeKugou(_songs);
    final player = _FakePlayer();
    player.simulate(song: _songs[0].toSong(), playing: true);
    kugou.garbageQueue.add(const [
      KugouSongDetail(hash: 'h9', songName: 'song 9', curMark: 'mark9'),
    ]);
    await pumpSection(tester, kugou: kugou, player: player);

    await tester.tap(find.byTooltip('不喜欢'));
    await tester.pump();

    expect(kugou.feedbackReports, hasLength(1));
    final report = kugou.feedbackReports.single;
    expect(report.action, 'garbage');
    expect(report.hash, 'h0', reason: '作用于卡片正在渲染的这一首');
    expect(
      report.curMark,
      'mark0',
      reason: '推荐令牌必须原样带回，缺了上游定位不到这条推荐',
    );
    expect(report.mode, 'normal');
    expect(report.songPoolId, 0);

    expect(
      kugou.songs.map((s) => s.hash),
      contains('h9'),
      reason: '替换批次要接进电台列表',
    );
    expect(player.appended, [
      ['h9'],
    ], reason: '替换批次同样要进播放队列');
    expect(player.nextCalls, 1, reason: '不喜欢之后必须往前走');

    await drainProviderStartup(tester);
  });

  testWidgets('不喜欢上报失败：仍然切歌，不被一次反馈 ping 卡住', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final kugou = _FakeKugou(_songs);
    final player = _FakePlayer();
    player.simulate(song: _songs[0].toSong(), playing: true);
    // garbageQueue 为空 → _FakeKugou 返回 null（请求本身失败）。
    await pumpSection(tester, kugou: kugou, player: player);

    await tester.tap(find.byTooltip('不喜欢'));
    await tester.pump();

    expect(kugou.feedbackReports.single.action, 'garbage');
    expect(player.appended, isEmpty, reason: '没有替换批次可接');
    expect(player.nextCalls, 1, reason: '上报失败也必须推进');

    // showToast 走平台通道并留一个 1s Timer，显式推进消化。
    await tester.pump(const Duration(seconds: 2));
    await drainProviderStartup(tester);
  });

  testWidgets('播放器不在本电台上：不喜欢只换一批推荐，不推别人的队列', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final kugou = _FakeKugou(_songs);
    final player = _FakePlayer();
    // 没起播：卡片渲染列表第一首，但播放器放的是别处（currentSong 为 null）。
    kugou.garbageQueue.add(const [
      KugouSongDetail(hash: 'h9', songName: 'song 9'),
    ]);
    await pumpSection(tester, kugou: kugou, player: player);

    await tester.tap(find.byTooltip('不喜欢'));
    await tester.pump();

    expect(kugou.feedbackReports.single.hash, 'h0');
    expect(
      kugou.loadedStations,
      ['normal/0'],
      reason: '不在本电台上就重拉推荐，而不是替用户起播',
    );
    expect(
      player.nextCalls,
      0,
      reason: 'next() 推的是别人的队列，绝不能在这里调',
    );

    await drainProviderStartup(tester);
  });

  // 所有权的账：替换批次不是续播器自己要来的，不认领的话它随后播到这些歌时会
  // 以为自己被换下台而 retire，这条电台从此不再补货。
  testWidgets('替换批次被续播器认领：播到它时电台不退场', (tester) async {
    SharedPreferences.setMockInitialValues({});
    const replacement = KugouSongDetail(
      hash: 'h9',
      songName: 'song 9',
      artistName: 'a9',
      curMark: 'mark9',
    );
    final kugou = _FakeKugou(_songs);
    final player = _FakePlayer();
    await pumpSection(tester, kugou: kugou, player: player);

    // 起播本电台，占住补货槽位。
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();
    expect(player.onPlaylistEnd, isNotNull);

    kugou.garbageQueue.add(const [replacement]);
    await tester.tap(find.byTooltip('不喜欢'));
    await tester.pump();
    expect(player.appended, [
      ['h9'],
    ]);

    // 电台续播到刚接进来的这首：所有权已登记，不该被判定成「队列换主」。
    player.simulate(song: replacement.toSong(), playing: true);
    await tester.pump();

    expect(
      player.onPlaylistEnd,
      isNotNull,
      reason: '替换批次必须被续播器认领，否则播到它就退场、电台不再补货',
    );

    await drainProviderStartup(tester);
  });
}
