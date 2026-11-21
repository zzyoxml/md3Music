import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as just_audio;
import 'package:md3music/data/models/song.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/controlled_audio_service.dart';
import '../test_helpers/fake_secure_storage.dart';

/// 冷启动恢复 / 暂停恢复的「是否重载源」回归钉。
///
/// 三条各钉一个独立缺陷：
/// 1. buffering 中 seek 后暂停再恢复不得重载源（否则平台从 0:00 重播）；
/// 2. 冷启动恢复装载成功后点播放沿用恢复定位，不得再装载一次；
/// 3. 播完（completed）后点播放必须从头重播（保留原有重播语义）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Song onlineSong(String id, {String? url}) => Song(
    id: id,
    title: 'Resume Source',
    artist: 'Artist',
    album: 'Album',
    duration: const Duration(minutes: 3),
    url: url,
    isOnline: true,
  );

  test('buffering 中 seek 后暂停再恢复：不重载源，仅下发播放命令', () async {
    SharedPreferences.setMockInitialValues({});
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final player = PlayerProvider();
    try {
      await player.audioReady.timeout(const Duration(seconds: 10));
      final song = onlineSong(
        'buffering-seek-resume',
        url: 'https://media.example/buffering.mp3',
      );

      final play = player.playSong(song);
      await audio.waitForPlaylistLoads(1).timeout(const Duration(seconds: 5));
      await audio.completeSourceLoad(0);
      await play;
      expect(audio.playCommandCount, 1);

      // 拖动松手后平台重新缓冲：旧实现把 buffering 误判成「源没装载」→
      // 全量重载且不带定位，平台从 0:00 重播。
      audio.emitProcessingState(just_audio.ProcessingState.buffering);
      await Future<void>.delayed(Duration.zero);
      await player.seek(const Duration(seconds: 45));
      await player.pause();
      await player.resume();

      expect(
        audio.playlistLoads.length,
        1,
        reason: '源已装载完成，恢复播放不得再走 setUrl 重载',
      );
      expect(audio.playCommandCount, 2, reason: '只应新增一次 playCommand');
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  });

  test('冷启动恢复装载成功后点播放：沿用恢复定位，不触发重载', () async {
    const restorePosition = Duration(milliseconds: 12000);
    final restored = onlineSong(
      'restore-seek-target',
      url: 'https://media.example/stale-from-last-session.mp3',
    );
    SharedPreferences.setMockInitialValues({
      'settings_default_quality_wifi': 'high',
      'settings_default_quality_mobile': 'high',
      'player_current_song': jsonEncode(restored.toJson()),
      'player_playlist': [jsonEncode(restored.toJson())],
      'player_current_index': 0,
      'player_position': restorePosition.inMilliseconds,
    });
    installFakeSecureStorage();
    final api = KugouApiClient();
    await api.clearCookies();
    await api.setLoginCookies('fixture-token', 'fixture-user');
    final originalAdapter = api.dio.httpClientAdapter;
    api.dio.httpClientAdapter = _ResolveSuccessAdapter();
    KugouApiClient.markServerReady();

    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final player = PlayerProvider();
    try {
      await audio.waitForPlaylistLoads(1).timeout(const Duration(seconds: 5));
      await audio.completeSourceLoad(0);
      await player.audioReady.timeout(const Duration(seconds: 10));

      expect(audio.sourceInitialPositions.length, 1);
      expect(
        audio.sourceInitialPositions.first,
        restorePosition,
        reason: '恢复装载必须以持久化位置作为 initialPosition',
      );

      await player.resume();
      expect(
        audio.playlistLoads.length,
        1,
        reason: '恢复已装载成功，点播放只是继续，不得再重载一遍',
      );
      expect(audio.playCommandCount, 1);
      expect(player.currentSong?.id, 'restore-seek-target');
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
      api.dio.httpClientAdapter = originalAdapter;
      await api.clearCookies();
      uninstallFakeSecureStorage();
    }
  });

  test('播完（completed）后点播放：从头重播', () async {
    SharedPreferences.setMockInitialValues({});
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final player = PlayerProvider();
    try {
      await player.audioReady.timeout(const Duration(seconds: 10));
      final song = onlineSong(
        'completed-replay',
        url: 'https://media.example/completed.mp3',
      );

      final play = player.playSong(song);
      await audio.waitForPlaylistLoads(1).timeout(const Duration(seconds: 5));
      await audio.completeSourceLoad(0);
      await play;
      audio.emitPlaying(true);
      // 先暂停：作废播放请求后 completed 会被忽略（不自动切歌），
      // 平台停在 completed，模拟「播完后用户点播放」。
      await player.pause();
      audio.emitCompleted();
      // 事件流是异步投递的：等一拍让 completed 真正落到 processingState。
      await Future<void>.delayed(Duration.zero);

      final resume = player.resume();
      await audio.waitForPlaylistLoads(2).timeout(const Duration(seconds: 5));
      expect(
        audio.sourceInitialPositions[1],
        isNull,
        reason: '播完重播必须从 0 开始，不能把末尾位置带进 initialPosition',
      );

      await audio.completeSourceLoad(1);
      await resume;
      expect(audio.playCommandCount, 2);
      expect(audio.playlistLoads.length, 2);
      expect(player.currentSong?.id, 'completed-replay');
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  });
}

/// 解析成功：回一个可播放链接（冷启动恢复会丢弃持久化里的旧 URL 重新解析）。
class _ResolveSuccessAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/song/url' ||
        options.uri.path == '/song/url/new') {
      return ResponseBody.fromString(
        jsonEncode({
          'data': {
            'url': ['https://media.example/resolved.flac'],
            'quality': 'flac',
          },
        }),
        200,
        headers: const {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    return ResponseBody.fromString(
      '{"error":"unexpected"}',
      503,
      headers: const {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
