// 「下一首播放」端到端：飞行路径 / 降级路径 / 双击防抖。
//
// 注意：与基座 song_list_item_trailing_actions_test.dart 一样**不 import
// flutter/material**——`SongListItem` 行内的 InkWell 解析到 material_ui 自家类
// （AGENTS §4.13），host 必须用 material_ui 的 Scaffold 才插得下配对的 Material
// （Icons/Rect/ValueKey/MaterialApp 等均由 material_ui 再导出）。
import 'package:flutter/services.dart' as services;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:just_audio/just_audio.dart' as just_audio;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/data/models/song.dart';
import 'package:md3music/modules/player/player_cover_morph.dart';
import 'package:md3music/providers/blacklist_provider.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/local_favorites_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/widgets/play_next_flight.dart';
import 'package:md3music/widgets/song_list_item.dart';
import '../support/controlled_audio_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const ballKey = ValueKey('play_next_flight_ball');
  const miniRect = Rect.fromLTWH(10, 700, 44, 44);

  final song = Song(
    id: 'play-next-flight-target',
    title: '测试曲目',
    artist: '歌手',
    album: '专辑',
    duration: const Duration(minutes: 3),
    url: 'https://audio.invalid/play-next-flight-target.mp3',
    isOnline: true,
  );

  setUp(() {
    PlayNextFlightController.instance.reset();
    PlayerCoverMorphBus.instance.reset();
  });

  Future<void> mockToast() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const services.MethodChannel('PonnamKarthik/fluttertoast'),
      (call) async => true,
    );
  }

  Future<_Env> boot({required bool hasCurrentSong}) async {
    await mockToast();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const services.EventChannel(
            'dev.fluttercommunity.plus/connectivity_status',
          ),
          MockStreamHandler.inline(
            onListen: (_, events) => events.success(<String>['wifi']),
          ),
        );
    final audio = _ImmediateAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final player = hasCurrentSong
        ? _WithSongPlayerProvider(song)
        : _NoSongPlayerProvider();
    await player.audioReady.timeout(const Duration(seconds: 10));
    return _Env(
      player: player,
      favorites: FavoritesProvider(syncOnStart: false),
      localFavorites: LocalFavoritesProvider(),
      audio: audio,
    );
  }

  Future<void> openMenuAndTapPlayNext(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('下一首播放'), findsOneWidget);
    await tester.tap(find.text('下一首播放'));
  }

  testWidgets('飞行路径：有歌 + 有迷你条矩形 → 收缩后起飞、落地自清除',
      (tester) async {
    // PlayerProvider 构造与 audioReady 需要真实异步 IO，必须放进 runAsync
    // （同 song_list_item_trailing_actions_test.dart 的 boot 用法）。
    final env = (await tester.runAsync(
      () => boot(hasCurrentSong: true),
    ))!;
    PlayerCoverMorphBus.instance.miniRect = miniRect;
    try {
      await tester.pumpWidget(env.host(SongListItem(song: song)));
      await tester.pump();

      await openMenuAndTapPlayNext(tester);
      // 收缩 220ms：首个带时长 pump 只建立动画基线，第二个才真正推进
      //（Task 3 实测规律，同 song_menu_header_shrink_test）。
      await tester.pump(const Duration(milliseconds: 300)); // 基线帧
      await tester.pump(const Duration(milliseconds: 250)); // 收缩完成
      await tester.pump(); // endOfFrame → pop + launch（微任务收尾）
      await tester.pump(); // 球上树（俯冲 t≈0）；sheet 退场动画此刻才开始
      expect(find.byKey(ballKey), findsOneWidget); // 球在飞
      expect((env.player as _WithSongPlayerProvider).insertCalls, 1);

      await tester.pump(const Duration(milliseconds: 300)); // 俯冲基线帧
      await tester.pump(const Duration(milliseconds: 550)); // sheet 退场完毕、俯冲完、展开中
      expect(find.text('下一首播放'), findsNothing); // 菜单退场动画已结束
      final midSize = tester.getSize(find.byKey(ballKey));
      expect(midSize.width, inInclusiveRange(32, 44)); // 展开中：32→44

      await tester.pumpAndSettle(); // 跑完展开 + 自清除
      expect(find.byKey(ballKey), findsNothing);
      expect(PlayNextFlightController.instance.spec.value, isNull);
      expect((env.player as _WithSongPlayerProvider).insertCalls, 1);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await env.dispose(tester);
    }
  });

  testWidgets('仅在线歌曲显示添加到歌单，本地歌曲仍可下一首播放', (tester) async {
    final env = (await tester.runAsync(
      () => boot(hasCurrentSong: false),
    ))!;
    const localSong = Song(
      id: 'local-menu-target',
      title: '本地歌曲',
      artist: '本地歌手',
      album: '本地专辑',
      duration: Duration(minutes: 3),
      localPath: '/music/local-menu-target.mp3',
    );
    try {
      await tester.pumpWidget(env.host(const SongListItem(song: localSong)));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('添加到歌单'), findsNothing);
      expect(find.text('下一首播放'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      await tester.pumpWidget(env.host(SongListItem(song: song)));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('添加到歌单'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await env.dispose(tester);
    }
  });

  testWidgets('降级路径：无播放歌曲 → 不收缩不飞行，旧行为 pop+toast',
      (tester) async {
    final env = (await tester.runAsync(
      () => boot(hasCurrentSong: false),
    ))!;
    try {
      await tester.pumpWidget(env.host(SongListItem(song: song)));
      await tester.pump();

      await openMenuAndTapPlayNext(tester);
      await tester.pumpAndSettle(); // sheet 退场动画
      // fluttertoast 在 channel 返回后还有 1s 的 `Future.delayed` 收尾计时器
      // （fluttertoast.dart 的 isCurrentlyShowingToast 复位），degrade 路径
      // toast 后立即结束会命中 "Timer is still pending"，把时钟拨过去。
      await tester.pump(const Duration(seconds: 2));

      expect(find.text('下一首播放'), findsNothing);
      expect(find.byKey(ballKey), findsNothing);
      expect((env.player as _NoSongPlayerProvider).insertCalls, 1);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await env.dispose(tester);
    }
  });

  testWidgets('飞行路径下双击「下一首播放」只入队一次、只飞一次', (tester) async {
    final env = (await tester.runAsync(
      () => boot(hasCurrentSong: true),
    ))!;
    PlayerCoverMorphBus.instance.miniRect = miniRect;
    try {
      await tester.pumpWidget(env.host(SongListItem(song: song)));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('下一首播放'));
      await tester.tap(find.text('下一首播放')); // 收缩期间第二击
      await tester.pump(const Duration(milliseconds: 300)); // 基线帧
      await tester.pump(const Duration(milliseconds: 250)); // 收缩完成
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300)); // 俯冲基线帧
      await tester.pump(const Duration(milliseconds: 550)); // sheet 退场 + 动画大半
      await tester.pumpAndSettle();

      expect((env.player as _WithSongPlayerProvider).insertCalls, 1);
      expect(find.byKey(ballKey), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await env.dispose(tester);
    }
  });
}

class _Env {
  _Env({
    required this.player,
    required this.favorites,
    required this.localFavorites,
    required this.audio,
  });

  final PlayerProvider player;
  final FavoritesProvider favorites;
  final LocalFavoritesProvider localFavorites;
  final _ImmediateAudioService audio;

  Future<void> dispose(WidgetTester tester) async {
    player.dispose();
    await tester.runAsync(audio.dispose);
    AudioServiceLoader.setTestOverride(null);
  }

  Widget host(Widget child) => MultiProvider(
        providers: [
          ChangeNotifierProvider<PlayerProvider>.value(value: player),
          ChangeNotifierProvider<FavoritesProvider>.value(value: favorites),
          ChangeNotifierProvider<LocalFavoritesProvider>.value(
            value: localFavorites,
          ),
          // 更多菜单内的「不感兴趣」tile 读黑名单状态（不拉取、不发请求）
          ChangeNotifierProvider<BlacklistProvider>(
            create: (_) => BlacklistProvider(),
          ),
        ],
        child: MaterialApp(
          // 弹出的更多菜单是 modal bottom sheet，需要有可用的 Scaffold 与
          // Overlay；飞行层挂在 sheet 之上的同一 Stack（模拟 app.dart 顶层）。
          home: Scaffold(
            body: Stack(
              children: [
                child,
                const PlayNextFlightLayer(),
              ],
            ),
          ),
        ),
      );
}

class _NoSongPlayerProvider extends PlayerProvider {
  int insertCalls = 0;

  @override
  Song? get currentSong => null;

  @override
  bool get isPlaying => false;

  @override
  Future<void> insertAfterCurrent(List<Song> songs) async {
    insertCalls++;
  }
}

class _WithSongPlayerProvider extends _NoSongPlayerProvider {
  _WithSongPlayerProvider(this.song);

  final Song song;

  @override
  Song? get currentSong => song;
}

class _ImmediateAudioService extends ControlledAudioService {
  @override
  Future<void> setPlaylist(
    List<just_audio.UriAudioSource> sources, {
    int startIndex = 0,
    Duration? initialPosition,
  }) async {}
}
