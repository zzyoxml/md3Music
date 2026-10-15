import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/controlled_audio_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('CDN换源从平台最近位置恢复，不使用滞后的UI位置', () async {
    SharedPreferences.setMockInitialValues({});
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final player = PlayerProvider();
    try {
      await player.audioReady.timeout(const Duration(seconds: 10));
      final song = Song(
        id: 'cdn-stall-platform-position',
        title: 'CDN Stall Platform Position',
        artist: 'Artist',
        album: 'Album',
        duration: const Duration(minutes: 3),
        url: 'https://media.example/original.mp3',
        isOnline: true,
      );

      final initialPlay = player.playSong(song);
      await audio.waitForPlaylistLoads(1);
      await audio.completeSourceLoad(0);
      await initialPlay;
      audio.emitPlaying(true);

      const platformPosition = Duration(milliseconds: 61426);
      const staleUiPosition = Duration(milliseconds: 50667);
      audio.emitPosition(platformPosition);
      await Future<void>.delayed(Duration.zero);
      player.debugFeedPositionForTest(staleUiPosition);
      expect(player.platformPosition, platformPosition);
      expect(player.position, staleUiPosition);

      player.debugSetPrefetchedCdnUrlForTest(
        songId: song.id,
        url: 'https://media.example/refreshed.mp3',
        quality: '128',
      );
      final recovery = player.debugHandleCdnStallForTest();
      await audio.waitForPlaylistLoads(2);
      expect(audio.sourceInitialPositions[1], platformPosition);

      await audio.completeSourceLoad(1);
      await recovery;

      expect(player.position, platformPosition);
      expect(player.currentSong?.url, 'https://media.example/refreshed.mp3');
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  });

  test('缓冲充足不重建音源，余量到阈值时才通过位置流换源', () async {
    SharedPreferences.setMockInitialValues({});
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final player = PlayerProvider();
    try {
      await player.audioReady.timeout(const Duration(seconds: 10));
      final song = Song(
        id: 'cdn-stall-buffer-headroom',
        title: 'CDN Stall Buffer Headroom',
        artist: 'Artist',
        album: 'Album',
        duration: const Duration(minutes: 3),
        url: 'https://media.example/original.mp3',
        isOnline: true,
      );

      final initialPlay = player.playSong(song);
      await audio.waitForPlaylistLoads(1);
      await audio.completeSourceLoad(0);
      await initialPlay;
      audio.emitPlaying(true);

      const platformPosition = Duration(seconds: 46);
      // 首次窗口只建立平台位置基线，不应把启动前时间计入速率。
      await Future<void>.delayed(const Duration(seconds: 2, milliseconds: 50));
      audio.setDiagnosticSnapshot(
        position: platformPosition,
        bufferedPosition: const Duration(seconds: 65),
        speed: 1,
      );
      audio.emitPosition(platformPosition);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // 19秒余量高于保护阈值；慢速窗口应继续消耗缓冲，不应重建音源。
      await Future<void>.delayed(const Duration(seconds: 2, milliseconds: 50));
      audio.setDiagnosticSnapshot(
        position: platformPosition,
        bufferedPosition: const Duration(seconds: 65),
        speed: 1,
      );
      audio.emitPosition(platformPosition);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(audio.playlistLoads, hasLength(1));

      player.debugSetPrefetchedCdnUrlForTest(
        songId: song.id,
        url: 'https://media.example/refreshed.mp3',
        quality: '128',
      );

      // 余量恰为10秒时执行一次真实位置流回调，确认边界会触发换源。
      await Future<void>.delayed(const Duration(seconds: 2, milliseconds: 50));
      audio.setDiagnosticSnapshot(
        position: platformPosition,
        bufferedPosition: const Duration(seconds: 56),
        speed: 1,
      );
      audio.emitPosition(platformPosition);
      await audio.waitForPlaylistLoads(2);

      expect(audio.sourceInitialPositions[1], platformPosition);
      await audio.completeSourceLoad(1);
      final recoveryDeadline = DateTime.now().add(const Duration(seconds: 2));
      while (player.isResolvingUrl &&
          DateTime.now().isBefore(recoveryDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(player.isResolvingUrl, isFalse);
      expect(audio.playlistLoads, hasLength(2));
      // 换源URL在平台装载前已写入当前曲目。
      expect(player.currentSong?.url, 'https://media.example/refreshed.mp3');
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  });
}
