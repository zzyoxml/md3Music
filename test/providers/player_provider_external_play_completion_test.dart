import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/media_notification_service.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/controlled_audio_service.dart';

/// Issue #190：暂停会作废播放请求；随后由 Media3 媒体卡片/锁屏/蓝牙恢复播放时，
/// 原生必须把明确的 PLAY 意图回传 Dart（走 `MediaNotificationService.onPlay` →
/// `resume()`）。否则曲尾 completed 因 request 为空被忽略，表现为播完不切歌。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const shortMp3 = Duration(seconds: 60);
  const guardWindow = Duration(seconds: 3);

  void installConnectivityMocks() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (call) async => call.method == 'check' ? <String>['wifi'] : null,
    );
    messenger.setMockStreamHandler(
      const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
      MockStreamHandler.inline(
        onListen: (_, events) => events.success(<String>['wifi']),
      ),
    );
  }

  Future<void> startPlaylist(
    PlayerProvider player,
    ControlledAudioService audio,
  ) async {
    final play = player.playPlaylist(
      <Song>[
        Song(
          id: 'external-a',
          title: 'A',
          artist: 'Artist',
          album: 'Album',
          duration: shortMp3,
          url: 'https://media.example/external-a.mp3',
          isOnline: true,
        ),
        Song(
          id: 'external-b',
          title: 'B',
          artist: 'Artist',
          album: 'Album',
          duration: shortMp3,
          url: 'https://media.example/external-b.mp3',
          isOnline: true,
        ),
      ],
      0,
    );
    await audio.waitForPlaylistLoads(1);
    await audio.completeSourceLoad(0);
    await play;
    audio.emitPlaying(true);
    await Future<void>.delayed(Duration.zero);
  }

  test('暂停后由原生媒体控件恢复，播完仍自动切歌', () async {
    SharedPreferences.setMockInitialValues({});
    installConnectivityMocks();
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    late final PlayerProvider player;
    try {
      player = PlayerProvider();
      await player.audioReady.timeout(const Duration(seconds: 10));
      await startPlaylist(player, audio);

      await player.pause();
      expect(player.isPlaying, isFalse);

      final onPlay = MediaNotificationService.onPlay;
      expect(onPlay, isNotNull, reason: 'PlayerProvider 应装配原生播放回调');
      onPlay!();
      // resume() 异步读取设置并下发 playCommand；等它完成请求登记。
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(player.isPlaying, isTrue);
      expect(audio.playCommandCount, greaterThan(1), reason: '原生播放回调应走 resume()');

      await Future<void>.delayed(guardWindow);
      player.debugFeedPositionForTest(shortMp3);
      audio.emitCompleted();
      await audio.waitForPlaylistLoads(2).timeout(const Duration(seconds: 2));
      await audio.completeSourceLoad(1);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(
        player.currentSong?.id,
        'external-b',
        reason: 'completed 时 request 非空，应自动切到下一首',
      );
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  });

  test('暂停后未恢复播放：completed 仍不得自动切歌', () async {
    SharedPreferences.setMockInitialValues({});
    installConnectivityMocks();
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    late final PlayerProvider player;
    try {
      player = PlayerProvider();
      await player.audioReady.timeout(const Duration(seconds: 10));
      await startPlaylist(player, audio);

      await player.pause();
      expect(player.isPlaying, isFalse);

      audio.emitCompleted();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(
        player.currentSong?.id,
        'external-a',
        reason: '没有恢复播放请求时不得跳过当前曲',
      );
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  });
}
