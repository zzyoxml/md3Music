import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/theme/app_theme.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/modules/personal_fm/personal_fm_section.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';
import 'package:md3music/widgets/wavy_playback_line.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeKugou extends KugouProvider {
  _FakeKugou(List<KugouSongDetail> songs) : songs = List.of(songs);

  final List<KugouSongDetail> songs;
  final List<String> movedToFirst = [];

  /// 每次拉列表用的档位参数，格式 'mode/songPoolId'。
  final List<String> loadedStations = [];

  /// 每次续播请求带的游标 hash，null 表示那一次是不带游标的退一步。
  final List<String?> fetchCursors = [];

  /// 续播请求依次返回的结果；排空后一律返回 null（模拟接口失败 / 无新歌）。
  final List<List<KugouSongDetail>?> fetchQueue = [];

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
    bool forceRefresh = false,
  }) async {
    loadedStations.add('$mode/$songPoolId');
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
  Future<void> resume() async => resumeCalls++;

  @override
  Future<void> pause() async => pauseCalls++;

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
  @override
  Future<void> loadFavorites() async {}

  @override
  bool isFavorite(String songId) => false;
}

/// 对应 `_PersonalFmSectionState._kStationPrefKey`。
const String _kStationPrefKey = 'discover_fm_station_index';

/// 对应 `personal_fm_section.dart` 的 `_kCoverSize`。
const double _kCoverSize = 112.0;

const List<KugouSongDetail> _songs = [
  KugouSongDetail(hash: 'h0', songName: 'song 0', artistName: 'a0'),
  KugouSongDetail(hash: 'h1', songName: 'song 1', artistName: 'a1'),
  KugouSongDetail(hash: 'h2', songName: 'song 2', artistName: 'a2'),
  KugouSongDetail(hash: 'h3', songName: 'song 3', artistName: 'a3'),
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
            create: (_) => _FakeFavorites(),
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

  testWidgets('恢复上次选的档位，并按它把列表重新拉一次', (tester) async {
    SharedPreferences.setMockInitialValues({_kStationPrefKey: 2});
    final kugou = _FakeKugou(_songs);
    final player = _FakePlayer();
    await pumpSection(tester, kugou: kugou, player: player);
    await tester.pump();

    expect(find.byTooltip('电台档位：小众'), findsOneWidget, reason: '不该回到默认档');
    expect(kugou.loadedStations, [
      'small/1',
    ], reason: '发现页的初始加载不带档位参数，恢复非默认档后要按它重新拉');

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
}
