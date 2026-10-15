// 歌曲行尾部操作策略（SongTrailingActions）渲染校验。
//
// 关注点：每个策略下到底出现了哪些行尾元素，尤其是
// favoriteOnly（只有收藏）与 favoriteAndMore（收藏 + 三点菜单）的差别
// ——发现页每日推荐 / 刷歌推荐详情页就靠后者拿回三点菜单。
import 'package:flutter/services.dart' as services;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:just_audio/just_audio.dart' as just_audio;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/data/models/song.dart';
import 'package:md3music/providers/blacklist_provider.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/local_favorites_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/widgets/song_list_item.dart';
import '../support/controlled_audio_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final song = Song(
    id: 'trailing-actions-target',
    title: '测试曲目',
    artist: '歌手',
    album: '专辑',
    duration: const Duration(minutes: 3),
    url: 'https://audio.invalid/trailing-actions-target.mp3',
    isOnline: true,
  );

  /// 起一套可用的 provider 环境。
  ///
  /// 结构照抄 `test/widgets/song_list_item_selector_test.dart`：`SongListItem`
  /// 只依赖 PlayerProvider.currentSong/isPlaying 与两个收藏 provider，用
  /// `_TestPlayerProvider` 把前两个覆盖成常量即可，不必真的起播放器。
  Future<_Env> boot() async {
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
    final player = _TestPlayerProvider();
    await player.audioReady.timeout(const Duration(seconds: 10));
    return _Env(
      player: player,
      favorites: FavoritesProvider(syncOnStart: false),
      localFavorites: LocalFavoritesProvider(),
      audio: audio,
    );
  }

  testWidgets('favoriteAndMore：收藏 + 三点，且不显示时长', (tester) async {
    final env = (await tester.runAsync(boot))!;
    try {
      await tester.pumpWidget(env.host(SongListItem(
        song: song,
        trailingActions: SongTrailingActions.favoriteAndMore,
      )));
      await tester.pump();

      expect(find.byIcon(Icons.favorite_border), findsOneWidget);
      expect(find.byIcon(Icons.more_vert), findsOneWidget);
      expect(find.text(song.displayDuration), findsNothing);
    } finally {
      await env.dispose(tester);
    }
  });

  testWidgets('favoriteOnly：只有收藏，没有三点', (tester) async {
    final env = (await tester.runAsync(boot))!;
    try {
      await tester.pumpWidget(env.host(SongListItem(
        song: song,
        trailingActions: SongTrailingActions.favoriteOnly,
      )));
      await tester.pump();

      expect(find.byIcon(Icons.favorite_border), findsOneWidget);
      expect(find.byIcon(Icons.more_vert), findsNothing);
    } finally {
      await env.dispose(tester);
    }
  });

  testWidgets('full：时长 + 收藏 + 三点', (tester) async {
    final env = (await tester.runAsync(boot))!;
    try {
      await tester.pumpWidget(env.host(SongListItem(song: song)));
      await tester.pump();

      expect(find.text(song.displayDuration), findsOneWidget);
      expect(find.byIcon(Icons.favorite_border), findsOneWidget);
      expect(find.byIcon(Icons.more_vert), findsOneWidget);
    } finally {
      await env.dispose(tester);
    }
  });

  testWidgets('favoriteAndMore 的三点能拉起更多菜单面板', (tester) async {
    final env = (await tester.runAsync(boot))!;
    try {
      await tester.pumpWidget(env.host(SongListItem(
        song: song,
        trailingActions: SongTrailingActions.favoriteAndMore,
      )));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();

      expect(find.text('下一首播放'), findsOneWidget);
      expect(find.text('添加到歌单'), findsOneWidget);
    } finally {
      // 先把 widget 树拆掉再释放 provider，避免 provider 在树里被通知。
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
      // 弹出的更多菜单是 modal bottom sheet，需要有可用的 Scaffold 与 Overlay。
      home: Scaffold(body: child),
    ),
  );
}

class _TestPlayerProvider extends PlayerProvider {
  @override
  Song? get currentSong => null;

  @override
  bool get isPlaying => false;
}

class _ImmediateAudioService extends ControlledAudioService {
  @override
  Future<void> setPlaylist(
    List<just_audio.UriAudioSource> sources, {
    int startIndex = 0,
    Duration? initialPosition,
  }) async {}
}
