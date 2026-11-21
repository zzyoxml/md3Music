import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' as services;
import 'package:flutter_test/flutter_test.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/modules/player/am_artist_photo_cover.dart';
import 'package:md3music/modules/player/artist_photo_service.dart';
import 'package:md3music/modules/player/full_player_am.dart';
import 'package:md3music/modules/player/full_player_route.dart';
import 'package:md3music/modules/player/player_cover_morph.dart';
import 'package:md3music/modules/player/player_cover_morph_layer.dart';
import 'package:md3music/providers/comment_display_provider.dart';
import 'package:md3music/providers/device_provider.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/providers/listen_together_provider.dart';
import 'package:md3music/providers/local_favorites_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';
import 'package:md3music/widgets/apple_lyrics/apple_lyrics_view.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/controlled_audio_service.dart';

Song _song({
  String? artworkUri,
  String id = 'narrow-page-target',
  String? albumAudioId,
}) => Song(
  id: id,
  title: id == 'narrow-page-target'
      ? 'Narrow Layout Playback Target'
      : 'Narrow Layout Playback Target $id',
  artist: 'Layout Artist',
  album: 'Layout Album',
  duration: const Duration(minutes: 3),
  url: 'https://audio.invalid/track.mp3',
  artworkUri: artworkUri,
  albumAudioId: albumAudioId,
  isOnline: true,
);

void _mockPlatformChannels() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockStreamHandler(
    const services.EventChannel(
      'dev.fluttercommunity.plus/connectivity_status',
    ),
    MockStreamHandler.inline(
      onListen: (_, events) => events.success(<String>['wifi']),
    ),
  );
  messenger.setMockMethodCallHandler(
    const services.MethodChannel('com.md3music.md3music/home_widget'),
    (_) async => null,
  );
  messenger.setMockMethodCallHandler(
    services.SystemChannels.platform,
    (_) async => null,
  );
  messenger.setMockMethodCallHandler(
    const services.MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => switch (call.method) {
      'getTemporaryDirectory' ||
      'getApplicationSupportDirectory' ||
      'getApplicationDocumentsDirectory' ||
      'getDownloadsDirectory' => Directory.systemTemp.path,
      _ => null,
    },
  );
}

Widget _host(PlayerProvider player, KugouProvider kugou, Widget page) =>
    MultiProvider(
      providers: [
        ChangeNotifierProvider<PlayerProvider>.value(value: player),
        ChangeNotifierProvider<KugouProvider>.value(value: kugou),
        ChangeNotifierProvider(create: (_) => DeviceProvider()),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(
          create: (_) => FavoritesProvider(syncOnStart: false),
        ),
        ChangeNotifierProvider(create: (_) => LocalFavoritesProvider()),
        ChangeNotifierProvider(create: (_) => CommentDisplayProvider()),
        ChangeNotifierProvider(create: (_) => ListenTogetherProvider()),
      ],
      child: MaterialApp(home: page),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 注入按 hash 出图的写真服务。只给 1 张：>1 张会起 Timer.periodic
  /// 轮播，pumpAndSettle 会挂死（09d705d 同款隔离手法）。
  void injectPhotos(Map<String, List<String>> byHash) {
    final previous = ArtistPhotoService.instance;
    addTearDown(() => ArtistPhotoService.instance = previous);
    ArtistPhotoService.instance = ArtistPhotoService(
      fetcher: (uri) async {
        final urls = byHash[uri.queryParameters['hash']] ?? const <String>[];
        if (urls.isEmpty) return '{"status":1,"data":[]}';
        return '{"status":1,"data":[[{"imgs":{"320":['
            '${urls.map((u) => '{"sizable_portrait":"$u"}').join(',')}'
            ']}}]]}';
      },
    );
  }

  Future<PlayerProvider> startPlayer(
    WidgetTester tester, {
    String songId = 'narrow-page-target',
  }) async {
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    late PlayerProvider player;
    await tester.runAsync(() async {
      final p = PlayerProvider();
      player = p;
      await p.audioReady.timeout(const Duration(seconds: 10));
      final load = p.playPlaylist([_song(id: songId)], 0);
      await audio.waitForPlaylistLoads(1);
      await audio.completeSourceLoad(0);
      await load;
      audio.emitPlaying(true);
    });
    return player;
  }

  testWidgets('写真生效：专辑 tab 出现写真封面、方形封面让位、标题仍在', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      'use_am_style_player': true,
      'use_artist_photo_background': true,
    });
    _mockPlatformChannels();
    KugouProvider.restoreLyric = (_) async => const KugouLyric(
      content: '[00:00.00]test lyric',
      decodedContent: '[00:00.00]test lyric',
    );
    injectPhotos({
      'narrow-page-target': ['https://photo.invalid/a.jpg'],
    });

    final player = await startPlayer(tester);
    final kugou = KugouProvider(registerDeviceOnStart: false);
    try {
      await tester.pumpWidget(
        _host(player, kugou, const AmStyleFullPlayer()),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull);
      // 写真封面挂进专辑 tab（双层遮罩都在 = 渐变模糊生效）
      expect(find.byType(AmArtistPhotoCover), findsOneWidget);
      expect(find.byKey(const Key('amArtistPhotoMasterFade')), findsOneWidget);
      expect(find.byKey(const Key('amArtistPhotoSharpMask')), findsOneWidget);
      // 写真背景覆盖整页而非仅限 PageView，消除顶栏/控制区交界的裁剪接缝。
      final photoRect = tester.getRect(
        find.byKey(const Key('amArtistPhotoMasterFade')),
      );
      expect(photoRect.top, lessThanOrEqualTo(1));
      expect(photoRect.bottom, greaterThanOrEqualTo(799));
      // 方形封面（形变槽位）已让位
      expect(find.byType(PlayerCoverSlot), findsNothing);
      // 标题块叠在写真下缘
      expect(find.text('Narrow Layout Playback Target'), findsOneWidget);
    } finally {
      player.dispose();
    }
  });

  testWidgets('写真只在封面页：竖屏停在歌词页时不渲染写真背景', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // 打开即停在歌词页：窄屏下标 0=歌单 1=封面 2=歌词。用全局信号而不是手势，
    // 保证「停在歌词页」这一前提是确定的（否证见下方 AppleLyricsView 断言）。
    final originalTabIndex = playerTabIndex.value;
    addTearDown(() => playerTabIndex.value = originalTabIndex);
    playerTabIndex.value = 2;
    SharedPreferences.setMockInitialValues({
      'use_am_style_player': true,
      'use_artist_photo_background': true,
    });
    _mockPlatformChannels();
    KugouProvider.restoreLyric = (_) async => const KugouLyric(
      content: '[00:00.00]test lyric',
      decodedContent: '[00:00.00]test lyric',
    );
    // 写真数据照常注入：本用例要证明的是「有图也不在歌词页画」，不是「没图」
    injectPhotos({
      'narrow-page-target': ['https://photo.invalid/a.jpg'],
    });

    final player = await startPlayer(tester);
    final kugou = KugouProvider(registerDeviceOnStart: false);
    try {
      await tester.pumpWidget(
        _host(player, kugou, const AmStyleFullPlayer()),
      );
      // 停在歌词页时 AppleLyricsView 的 Ticker 与 PlayerFrameDriver 都在跑，
      // pumpAndSettle 在这类页面上永不收敛；写真拉取只走 async 微任务，
      // 有界推进 1 秒虚拟时间足够落地。
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(tester.takeException(), isNull);
      // 前提确认：确实停在歌词页（否则下面的负例断言毫无意义）
      expect(find.byType(AppleLyricsView), findsOneWidget);
      // 写真层整层不构建：歌词页不该再有写真背景（用户反馈的缺陷）
      expect(find.byType(AmArtistPhotoCover), findsNothing);
    } finally {
      player.dispose();
    }
  });

  testWidgets('写真背景透明度：设置值接到写真层（遮罩浓度越大写真越淡）', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      'use_am_style_player': true,
      'use_artist_photo_background': true,
      // 与默认 0.55 拉开差距，避免「恰好等于默认值」蒙混过关
      'artist_photo_opacity': 0.9,
    });
    _mockPlatformChannels();
    KugouProvider.restoreLyric = (_) async => const KugouLyric(
      content: '[00:00.00]test lyric',
      decodedContent: '[00:00.00]test lyric',
    );
    // 唯一 song id：Controller 的写真缓存是 static（跨用例共享）
    injectPhotos({
      'opacity-target': ['https://photo.invalid/o.jpg'],
    });

    final player = await startPlayer(tester, songId: 'opacity-target');
    final kugou = KugouProvider(registerDeviceOnStart: false);
    try {
      await tester.pumpWidget(
        _host(player, kugou, const AmStyleFullPlayer()),
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(tester.takeException(), isNull);
      final photo = tester.widget<AmArtistPhotoCover>(
        find.byType(AmArtistPhotoCover),
      );
      // 设置 0.9 是「遮罩浓度」→ 写真层自身不透明度 0.1（与 MD3 同一套取值）
      expect(photo.opacity, closeTo(0.1, 1e-6));
    } finally {
      player.dispose();
    }
  });

  testWidgets('界面设置中开关即时刷新，并保持弹层打开', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      'use_am_style_player': true,
      'use_artist_photo_background': true,
    });
    _mockPlatformChannels();
    KugouProvider.restoreLyric = (_) async => const KugouLyric(
      content: '[00:00.00]test lyric',
      decodedContent: '[00:00.00]test lyric',
    );
    injectPhotos({
      'narrow-page-target': ['https://photo.invalid/a.jpg'],
    });
    final player = await startPlayer(tester);
    final kugou = KugouProvider(registerDeviceOnStart: false);
    try {
      await tester.pumpWidget(
        _host(player, kugou, const AmStyleFullPlayer()),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.more_horiz));
      await tester.pumpAndSettle();
      await tester.tap(find.text('界面设置'));
      await tester.pumpAndSettle();
      Finder tile(String title) => find.ancestor(
        of: find.text(title),
        matching: find.byType(SwitchListTile),
      );
      final dynamicCover = tile('专辑动态封面');
      expect(tester.widget<SwitchListTile>(dynamicCover).value, isTrue);
      await tester.ensureVisible(dynamicCover);
      await tester.tap(dynamicCover);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(dynamicCover).value, isFalse);
      expect(find.text('界面设置'), findsOneWidget);
      final photo = tile('歌手写真背景');
      expect(tester.widget<SwitchListTile>(photo).value, isTrue);
      await tester.ensureVisible(photo);
      await tester.tap(photo);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(photo).value, isFalse);
      expect(find.byType(AmArtistPhotoCover), findsNothing);
      expect(find.text('界面设置'), findsOneWidget);
      expect(find.text('3D 封面'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      player.dispose();
      kugou.dispose();
    }
  });

  testWidgets('关闭写真开关：方形封面回来、写真封面不渲染', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      'use_am_style_player': true,
      'use_artist_photo_background': false,
    });
    _mockPlatformChannels();
    KugouProvider.restoreLyric = (_) async => const KugouLyric(
      content: '[00:00.00]test lyric',
      decodedContent: '[00:00.00]test lyric',
    );
    injectPhotos({
      'narrow-page-target': ['https://photo.invalid/a.jpg'],
    });

    final player = await startPlayer(tester);
    final kugou = KugouProvider(registerDeviceOnStart: false);
    try {
      await tester.pumpWidget(
        _host(player, kugou, const AmStyleFullPlayer()),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull);
      expect(find.byType(AmArtistPhotoCover), findsNothing);
      expect(find.byType(PlayerCoverSlot), findsWidgets);
    } finally {
      player.dispose();
    }
  });

  testWidgets('写真拉不到图（该歌无图）：方形封面保持，不出现空屏', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      'use_am_style_player': true,
      'use_artist_photo_background': true,
    });
    _mockPlatformChannels();
    KugouProvider.restoreLyric = (_) async => const KugouLyric(
      content: '[00:00.00]test lyric',
      decodedContent: '[00:00.00]test lyric',
    );
    injectPhotos({}); // 任何 hash 都返回空

    // 唯一 song id：Controller 的静态缓存按 hash（=song id）跨用例共享，
    // 复用 'narrow-page-target' 会命中第 1 用例缓存的写真 → 本用例失真。
    final player = await startPlayer(tester, songId: 'no-photo-target');
    final kugou = KugouProvider(registerDeviceOnStart: false);
    try {
      await tester.pumpWidget(
        _host(player, kugou, const AmStyleFullPlayer()),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull);
      expect(find.byType(AmArtistPhotoCover), findsNothing);
      expect(find.byType(PlayerCoverSlot), findsWidgets);
    } finally {
      player.dispose();
    }
  });

  testWidgets('横屏写真：整页遮罩无分栏裁剪，图片仍占左侧40%', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1264, 681);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      'use_am_style_player': true,
      'use_artist_photo_background': true,
    });
    _mockPlatformChannels();
    KugouProvider.restoreLyric = (_) async => const KugouLyric(
      content: '[00:00.00]test lyric',
      decodedContent: '[00:00.00]test lyric',
    );
    injectPhotos({
      'narrow-page-target': ['https://photo.invalid/a.jpg'],
    });

    final player = await startPlayer(tester);
    final kugou = KugouProvider(registerDeviceOnStart: false);
    try {
      await tester.pumpWidget(
        _host(player, kugou, const AmStyleFullPlayer()),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull);
      // 遮罩/滤镜覆盖整页，图片内容仍只占左侧 40%；不能在 505.6dp 处裁剪。
      expect(find.byKey(const Key('amArtistPhotoRightFade')), findsOneWidget);
      expect(
        find.byKey(const Key('amArtistPhotoSharpRight')),
        findsOneWidget,
      );
      final box = tester.getRect(
        find.byKey(const Key('amArtistPhotoRightFade')),
      );
      expect(box.width, closeTo(1264, 1));
      final photos = find.descendant(
        of: find.byType(AmArtistPhotoCover),
        matching: find.byType(CachedNetworkImage),
      );
      expect(tester.getSize(photos.first).width, closeTo(505.6, 0.01));
      final blur = find.descendant(
        of: find.byType(AmArtistPhotoCover),
        matching: find.byType(ImageFiltered),
      );
      expect(tester.getSize(blur).width, closeTo(1264, 1));
      expect(box.left, 0.0);
      // 左栏不再渲染方形封面槽位（写真已移出左栏）
      expect(find.byType(PlayerCoverSlot), findsNothing);
      // 标题仍在（贴左下）
      expect(find.text('Narrow Layout Playback Target'), findsOneWidget);
    } finally {
      player.dispose();
    }
  });

  // 追加：写真功能开着、但 fetcher 挂起不返回（模拟未缓存歌曲
  // 转场起点的空窗），断言封面形变从第一次 build 就被抑制。
  testWidgets('功能开+写真未落地：coverSuppressed 起点即为 true（不飞封面）', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      'use_am_style_player': true,
      'use_artist_photo_background': true,
    });
    _mockPlatformChannels();
    KugouProvider.restoreLyric = (_) async => const KugouLyric(
      content: '[00:00.00]test lyric',
      decodedContent: '[00:00.00]test lyric',
    );
    // 挂起不返回 + 唯一 hash（避开 static 缓存）
    final previous = ArtistPhotoService.instance;
    addTearDown(() => ArtistPhotoService.instance = previous);
    ArtistPhotoService.instance = ArtistPhotoService(
      fetcher: (_) => Completer<String>().future,
    );

    final player = await startPlayer(tester, songId: 'slow-photo-target');
    final kugou = KugouProvider(registerDeviceOnStart: false);
    final bus = PlayerCoverMorphBus.instance;
    addTearDown(() => bus.coverSuppressed = false);
    try {
      await tester.pumpWidget(
        _host(player, kugou, const AmStyleFullPlayer()),
      );
      await tester.pump(); // 走完 post-frame 排期（fetcher 挂起，写真不会落地）

      // 写真没落地（方封面兜底仍显示），但封面形变必须已被抑制
      expect(bus.coverSuppressed, isTrue);
      expect(find.byType(AmArtistPhotoCover), findsNothing);
      expect(find.byType(PlayerCoverSlot), findsWidgets);
    } finally {
      player.dispose();
    }
  });
}
