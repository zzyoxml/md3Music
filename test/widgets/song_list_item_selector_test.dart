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
import 'package:md3music/widgets/playing_spectrum_indicator.dart';
import 'package:md3music/widgets/song_list_item.dart';
import '../support/controlled_audio_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('歌曲行只响应自身播放和收藏状态，仍接收父级歌曲富化', (tester) async {
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
    late final _TestPlayerProvider player;
    await tester.runAsync(() async {
      player = _TestPlayerProvider();
      await player.audioReady.timeout(const Duration(seconds: 10));
    });
    final favorites = FavoritesProvider(syncOnStart: false);
    final localFavorites = LocalFavoritesProvider();
    final song = Song(
      id: 'selector-target',
      title: '原始标题',
      artist: '歌手',
      album: '专辑',
      duration: const Duration(minutes: 2),
      url: 'https://audio.invalid/selector-target.mp3',
      isOnline: true,
    );

    Widget host(Song item) => MultiProvider(
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
        home: Scaffold(body: _CountingSongListItem(song: item)),
      ),
    );

    _CountingSongListItem.buildCount = 0;
    try {
      await tester.pumpWidget(host(song));
      await tester.pump();
      expect(_CountingSongListItem.buildCount, 1);

      player.notifyListeners();
      await tester.pump();
      expect(
        _CountingSongListItem.buildCount,
        1,
        reason: '与该歌曲的当前/播放状态无关的播放器通知不应重建行',
      );

      favorites.syncFavoriteIds({'another-song'});
      await tester.pump();
      expect(_CountingSongListItem.buildCount, 1, reason: '收藏其他歌曲不应重建当前行');

      audio.emitPlaying(true);
      await tester.pump();
      expect(
        _CountingSongListItem.buildCount,
        1,
        reason: '非当前歌曲行不展示频谱，不应跟随全局播放状态重建',
      );
      audio.emitPlaying(false);
      await tester.pump();
      expect(_CountingSongListItem.buildCount, 1);

      favorites.syncFavoriteIds({'selector-target'});
      await tester.pump();
      expect(_CountingSongListItem.buildCount, 2);
      expect(find.byIcon(Icons.favorite), findsOneWidget);

      final enrichedSong = song.copyWith(title: '补全后的标题');
      await tester.pumpWidget(host(enrichedSong));
      await tester.pump();
      expect(find.text('补全后的标题'), findsOneWidget);

      final currentSong = Song(
        id: 'selector-target',
        title: '当前歌曲',
        artist: '歌手',
        album: '专辑',
        duration: const Duration(minutes: 2),
      );
      await tester.pumpWidget(host(currentSong));
      await tester.pump();
      final beforeCurrentSongChange = _CountingSongListItem.buildCount;
      player.setTestPlaybackState(currentSong: currentSong, isPlaying: false);
      await tester.pump();
      expect(player.currentSong?.id, currentSong.id);
      expect(
        _CountingSongListItem.buildCount,
        greaterThan(beforeCurrentSongChange),
      );
      expect(find.byType(PlayingSpectrumIndicator), findsOneWidget);

      final anotherSong = Song(
        id: 'another-current-song',
        title: '另一首',
        artist: '歌手',
        album: '专辑',
        duration: const Duration(minutes: 2),
      );
      final beforePlayStateChange = _CountingSongListItem.buildCount;
      player.setTestPlaybackState(currentSong: currentSong, isPlaying: true);
      await tester.pump();
      expect(
        _CountingSongListItem.buildCount,
        greaterThan(beforePlayStateChange),
      );
      player.setTestPlaybackState(currentSong: anotherSong, isPlaying: true);
      await tester.pump();
      expect(find.byType(PlayingSpectrumIndicator), findsNothing);
    } finally {
      player.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(audio.dispose);
      AudioServiceLoader.setTestOverride(null);
    }
  });
}

class _CountingSongListItem extends SongListItem {
  const _CountingSongListItem({required super.song});

  static int buildCount = 0;

  @override
  Widget build(BuildContext context) {
    buildCount++;
    return super.build(context);
  }
}

class _TestPlayerProvider extends PlayerProvider {
  Song? _testCurrentSong;
  bool _testIsPlaying = false;

  @override
  Song? get currentSong => _testCurrentSong;

  @override
  bool get isPlaying => _testIsPlaying;

  void setTestPlaybackState({
    required Song? currentSong,
    required bool isPlaying,
  }) {
    _testCurrentSong = currentSong;
    _testIsPlaying = isPlaying;
    notifyListeners();
  }
}

class _ImmediateAudioService extends ControlledAudioService {
  @override
  Future<void> setPlaylist(
    List<just_audio.UriAudioSource> sources, {
    int startIndex = 0,
    Duration? initialPosition,
  }) async {}
}
