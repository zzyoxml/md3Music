import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:md3music/core/services/lyricon_provider_service.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/providers/player_provider.dart';

import '../support/controlled_audio_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('首曲在连接前推送，连接成功补推当前曲，重复事件不重复拉取', () async {
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('com.md3music.md3music/lyricon');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (_) async => ['wifi'],
    );
    messenger.setMockStreamHandler(
      const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
      MockStreamHandler.inline(
        onListen: (_, events) => events.success(['wifi']),
      ),
    );
    final service = LyriconProviderService.instance;
    await service.initialize();
    await service.setEnabled(false);
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final player = PlayerProvider();
    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 30));
    Future<void> connection(String state) async {
      final reply = Completer<void>();
      messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('onConnectionStateChanged', state),
        ),
        (_) => reply.complete(),
      );
      await reply.future;
      await settle();
    }

    List<MethodCall> songCalls() =>
        calls.where((c) => c.method == 'setSong').toList();
    try {
      await player.audioReady.timeout(const Duration(seconds: 10));
      await service.setEnabled(true);
      const first = Song(
        id: 'first',
        title: '首曲',
        artist: '歌手',
        album: '专辑',
        duration: Duration(seconds: 180),
        isOnline: true,
        url: 'https://media.example/first.mp3',
      );
      final play = player.playPlaylist([first], 0);
      await audio.waitForPlaylistLoads(1).timeout(const Duration(seconds: 10));
      await audio.completeSourceLoad(0);
      await play;
      await settle();
      expect(service.state, LyriconConnectionState.connecting);
      expect(songCalls(), hasLength(1));
      player.debugFeedPositionForTest(const Duration(seconds: 12));

      calls.clear();
      await connection('connected');
      expect(songCalls(), hasLength(1), reason: '无需切到下一首，连接就绪后必须补推首曲');
      final song = (songCalls().single.arguments as Map)['song'] as Map;
      expect(song['id'], 'first');
      expect(song['startPositionMs'], 12000);
      expect(
        calls.map((c) => c.method),
        containsAllInOrder(['setSong', 'setPlaybackState', 'setPosition']),
      );
      await connection('connected');
      expect(songCalls(), hasLength(1), reason: '相同已连接事件保持去重');

      await connection('disconnected');
      await connection('reconnected');
      expect(songCalls(), hasLength(2), reason: '断开重连仍然补推');
      expect(player.currentSong?.id, 'first');
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
      await service.setEnabled(false);
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'),
        null,
      );
      messenger.setMockStreamHandler(
        const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
        null,
      );
    }
  });
}
