// 私人 FM 横屏：歌曲、推荐选项和队列依次纵向排列。
// 验证真实几何位置，动作按钮继续留在 FM 卡片中，竖屏保持单栏。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/theme/app_theme.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/modules/personal_fm/personal_fm_page.dart';
import 'package:md3music/modules/personal_fm/personal_fm_page_preferences.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeKugou extends ChangeNotifier implements KugouProvider {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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

  testWidgets('桌面横屏三行等宽对齐，歌曲操作留在卡片内', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpPage(tester, size: const Size(1920, 1080));
    final hero = tester.getRect(find.byKey(const ValueKey('fm-hero-card')));
    final controls = tester.getRect(find.byKey(const ValueKey('fm-recommendation-controls')));
    final queue = tester.getRect(find.byKey(const ValueKey('fm-upcoming-queue')));
    expect(controls.left, closeTo(hero.left, .1));
    expect(controls.right, closeTo(hero.right, .1));
    expect(queue.left, closeTo(hero.left, .1));
    expect(queue.right, closeTo(hero.right, .1));
    expect(controls.top, closeTo(hero.bottom + 16, .1));
    expect(queue.top, closeTo(controls.bottom + 16, .1));
    expect(hero.width, lessThanOrEqualTo(900));
    expect(tester.getCenter(find.byIcon(Icons.play_arrow)).dy, lessThan(hero.bottom));
    expect(find.byKey(const ValueKey('fm-recommendation-summary')), findsNothing);
    expect(tester.takeException(), isNull);
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
    expect(queueCenter.dy, greaterThan(playCenter.dy), reason: '竖屏队列在按钮行之下');

    await drainProviderStartup(tester);
  });

  for (final size in const [Size(900, 420), Size(800, 400), Size(720, 360)]) {
    testWidgets('横屏 $size 单列等宽且无溢出', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpPage(tester, size: size);
      final hero = tester.getRect(find.byKey(const ValueKey('fm-hero-card')));
      final controls = tester.getRect(find.byKey(const ValueKey('fm-recommendation-controls')));
      final queue = tester.getRect(find.byKey(const ValueKey('fm-upcoming-queue')));
      expect(controls.left, closeTo(hero.left, .1));
      expect(controls.right, closeTo(hero.right, .1));
      expect(queue.left, closeTo(hero.left, .1));
      expect(queue.right, closeTo(hero.right, .1));
      expect(controls.top, greaterThanOrEqualTo(hero.bottom));
      expect(queue.top, greaterThan(controls.bottom));
      expect(tester.takeException(), isNull);
      await drainProviderStartup(tester);
    });
  }
  for (final size in const [Size(400, 900), Size(900, 420)]) {
    testWidgets('选择卡片可点击并持久化 $size', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpPage(tester, size: size);
      final mode = find.byKey(const ValueKey('fm-mode-small'));
      await tester.ensureVisible(mode);
      await tester.pumpAndSettle();
      await tester.tap(mode);
      await tester.pumpAndSettle();
      final pool = find.byKey(const ValueKey('fm-pool-1'));
      await tester.ensureVisible(pool);
      await tester.pumpAndSettle();
      await tester.tap(pool);
      await tester.pumpAndSettle();
      final selection = await PersonalFmPagePreferences.load();
      expect(selection.mode, 'small');
      expect(selection.songPoolId, 1);
      final selectedSemantics = find.ancestor(
        of: pool,
        matching: find.byType(Semantics),
      );
      expect(
        tester.widget<Semantics>(selectedSemantics.first).properties.selected,
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await drainProviderStartup(tester);
    });
  }
}
