// 私人 FM 独立页的横屏两栏布局回归。
//
// 要害：横屏下「动作按钮 + 档位/歌池 + 即将播放」必须整体离开左列卡片，成为右列；
// 竖屏必须仍是上下堆叠（本页原先只有单栏，横竖共用一套 Column，改分栏时最容易
// 顺手把竖屏也改掉）。这里用**几何断言**钉住两栏/单栏的形态差异，而不是断言
// 某种具体实现（Row / Column / 组件树），这样内部重构不会误报。
//
// 判据用 dx / dy 而不是找同级的类型：按钮在右列时它的圆心必然在封面圆心的**右侧**；
// 单栏时它在封面**下方**。两者互斥，且与字号/密度无关。
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/theme/app_theme.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/modules/personal_fm/personal_fm_page.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeKugou extends KugouProvider {
  _FakeKugou(this.songs);

  final List<KugouSongDetail> songs;

  @override
  bool get isLoggedIn => true;

  @override
  List<KugouSongDetail> get personalFmSongs => songs;

  @override
  List<Song> get personalFmAsSongs => songs.map((e) => e.toSong()).toList();

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
  }) async => null;

  @override
  Future<void> getPersonalFm({
    String? mode,
    int? songPoolId,
    String? hash,
    String? songId,
    String? action,
    bool noCache = false,
    bool forceRefresh = false,
  }) async {}
}

class _FakePlayer extends PlayerProvider {
  Song? _song;

  @override
  Song? get currentSong => _song;

  @override
  bool get isPlaying => false;

  @override
  List<Song> get playlist => const [];

  @override
  int get currentIndex => -1;

  // 真实 getter 从 audio_service 回填（测试里没起引擎）。本页的播放器通知回调
  // 每次都会采这两个值，直接喂常量免得将来加了 notifyListeners 就挂。
  @override
  Duration get position => Duration.zero;

  @override
  Duration? get duration => null;

  void simulate(Song song) => _song = song;

  @override
  Future<void> next({bool autoPlay = true}) async {}

  @override
  Future<void> appendPlaylist(List<Song> songs) async {}
}

/// 收藏按钮走 Selector 读 [FavoritesProvider]；真实实现会去查库+发网（测试里两者
/// 都不存在），用内存账本顶掉。
class _FakeFavorites extends FavoritesProvider {
  @override
  Future<void> loadFavorites() async {}

  @override
  bool isFavorite(String songId) => false;
}

const List<KugouSongDetail> _songs = [
  KugouSongDetail(hash: 'h0', songName: 'song 0', artistName: 'a0'),
  KugouSongDetail(hash: 'h1', songName: 'song 1', artistName: 'a1'),
  KugouSongDetail(hash: 'h2', songName: 'song 2', artistName: 'a2'),
];

void main() {
  // [KugouProvider] 构造会发一次 registerDevice，拦截器要等本地 API 服务器就绪
  // （测试里永远不会），那个 timeout(8s) 会留下待触发的 timer。
  setUpAll(KugouApiClient.markServerReady);

  Future<void> drainProviderStartup(WidgetTester tester) =>
      tester.pump(const Duration(seconds: 5));

  Future<void> pumpPage(
    WidgetTester tester, {
    required Size size,
    _FakePlayer? player,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final kugou = _FakeKugou(List.of(_songs));
    final fakePlayer = player ?? _FakePlayer();
    // 让播放器停在第一首上：卡片渲染的就是它，播放按钮画暂停。
    fakePlayer.simulate(_songs[0].toSong());

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<KugouProvider>.value(value: kugou),
          ChangeNotifierProvider<PlayerProvider>.value(value: fakePlayer),
          ChangeNotifierProvider<FavoritesProvider>(
            // loadFavorites 已被 override 成空实现（见 _FakeFavorites），
            // 构造时那次自动同步不会真去查库/发网。
            create: (_) => _FakeFavorites(),
          ),
          // ScrollAwareAppBar watch ThemeProvider（背景图开关），
          // centerPageTitle watch TabConfigProvider（标题对齐）。
          ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
          ChangeNotifierProvider<TabConfigProvider>(
            create: (_) => TabConfigProvider(),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: AppTheme.defaultSeedColor,
            ),
          ),
          home: const PersonalFmPage(),
        ),
      ),
    );
    await tester.pump();
  }

  /// 卡片封面：图片没 URL 时 _cover 仍给出一个 radius 24 的 [ClipRRect]（预告封面
  /// 是 12、其它封面是 16，24 只有 hero 用）。刻意不去量里面的占位图标：
  /// `_coverPlaceholder` 的图标边长是封面尺寸的 0.36 倍，量它等于在量一个魔法比例。
  Finder heroCover() => find.byWidgetPredicate(
    (w) => w is ClipRRect && w.borderRadius == BorderRadius.circular(24),
  );

  /// 档位/歌池切换器。不按文案取：m3e 的连体按钮组会同时构建「选中 / 未选中」
  /// 两套标签来测宽，同一个档位名在树里有两个 Text，按文案取是歧义的。
  Finder stationSwitcher() => find.byType(M3EToggleButtonGroup).first;

  testWidgets('横屏两栏：档位与队列在卡片右侧，动作按钮留在卡片内', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpPage(tester, size: const Size(900, 420));

    final cover = tester.getRect(heroCover());
    final play = tester.getCenter(find.byIcon(Icons.play_arrow));
    final heart = tester.getCenter(find.byIcon(Icons.favorite_border));
    final station = tester.getCenter(stationSwitcher());
    final queue = tester.getCenter(find.text('即将播放'));

    // 右列的两块：必须整体落在封面右侧。
    expect(
      station.dx,
      greaterThan(cover.right),
      reason: '档位/歌池切换必须在右列（封面右缘之外）',
    );
    expect(queue.dx, greaterThan(cover.right), reason: '队列必须在右列');

    // 动作行必须回到卡片内：在封面下方（纵向属于卡片），且没有越过封面右缘
    // 跑到右列去——右缘那条线正是左右两列的分界。
    expect(play.dy, greaterThan(cover.bottom), reason: '播放按钮在封面下方');
    expect(heart.dy, greaterThan(cover.bottom), reason: '红心在封面下方');
    expect(
      play.dx,
      lessThan(station.dx),
      reason: '动作按钮留在左列卡片里，不能和右列的切换器混在一起',
    );

    // 右列两块的上下次序：档位 → 队列。
    expect(station.dy, lessThan(queue.dy), reason: '档位切换在队列之上');

    await drainProviderStartup(tester);
  });

  testWidgets('竖屏仍是单栏：按钮在封面下方，队列在更下方', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpPage(tester, size: const Size(400, 900));

    final coverBottom = tester.getRect(heroCover()).bottom;
    final playCenter = tester.getCenter(find.byIcon(Icons.play_arrow));
    final queueCenter = tester.getCenter(find.text('即将播放'));

    expect(
      playCenter.dy,
      greaterThan(coverBottom),
      reason: '竖屏按钮必须在封面下方（上下堆叠），不能变成右侧两栏',
    );
    expect(
      queueCenter.dy,
      greaterThan(playCenter.dy),
      reason: '竖屏队列在按钮行之下',
    );

    await drainProviderStartup(tester);
  });

  testWidgets('横屏封面按视口高度收缩，右列档位与队列落进首屏', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpPage(tester, size: const Size(900, 420));

    final cover = tester.getRect(heroCover());
    // 竖屏走的是「按宽度封顶 320」；横屏左列只有 ~457dp 宽，若不引入高度约束，
    // 封面会取到宽度预算，把动作行整块顶出首屏。
    expect(
      cover.height,
      lessThan(300),
      reason: '横屏封面要受视口高度约束，不能沿用竖屏的 320 上限',
    );
    expect(cover.height, greaterThan(100), reason: '不能缩到不可辨');

    // 用户要的是「按钮留在卡片里」，那它就必须真的还在首屏内摸得到——这是
    // 卡片内部改横排 + 封面让出高度共同保证的结果。
    expect(
      tester.getCenter(find.byIcon(Icons.play_arrow)).dy,
      lessThan(420),
      reason: '动作按钮留在卡内，且必须落在首屏内',
    );

    // 分栏真正要换来的东西：右列的档位与标题在**首屏内**可见（分栏前它们被压到
    // 一整屏之下）。队列整块可能超出首屏，由整页 SingleChildScrollView 兜住。
    expect(
      tester.getCenter(stationSwitcher()).dy,
      lessThan(420),
      reason: '档位切换必须在首屏内',
    );
    expect(
      tester.getCenter(find.text('即将播放')).dy,
      lessThan(420),
      reason: '「即将播放」标题必须在首屏内',
    );

    await drainProviderStartup(tester);
  });

  // 常见的横屏手机尺寸。封面预算取 0.40 * 高，左列内宽约 (总宽-间距)/2 - 48，
  // 两列都装得下，且不该有任何 RenderFlex 溢出（溢出会以 FlutterError 抛出）。
  for (final size in const [Size(800, 400), Size(720, 360)]) {
    testWidgets('窄横屏 $size 两栏不溢出且右列仍在右侧', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpPage(tester, size: size);

      final cover = tester.getRect(heroCover());
      final station = tester.getCenter(stationSwitcher());
      expect(
        station.dx,
        greaterThan(cover.right),
        reason: '窄横屏下档位/歌池也必须留在右列（这才是腾出高度的手段）',
      );
      expect(find.text('即将播放'), findsOneWidget);

      await drainProviderStartup(tester);
    });
  }
}
