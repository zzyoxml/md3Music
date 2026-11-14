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

/// 「seek 后播进一段再暂停恢复」的落点回归钉。
///
/// 缺陷现象：拖动/跳转到 Q 后正常播放一段时间（平台位置已推进到 Q+Δ），
/// 暂停再恢复时落点被拉回旧的 seek 目标 Q，丢掉已播进度。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Song onlineSong(String id, {String? url}) => Song(
    id: id,
    title: 'Resume Position',
    artist: 'Artist',
    album: 'Album',
    duration: const Duration(minutes: 3),
    url: url,
    isOnline: true,
  );

  const seekTarget = Duration(seconds: 45);
  const advancedPosition = Duration(seconds: 55);

  test('seek 到 Q 后播进 Δ，暂停恢复：落点是 Q+Δ 而不是旧 seek 目标 Q', () async {
    SharedPreferences.setMockInitialValues({});
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final player = PlayerProvider();
    try {
      await player.audioReady.timeout(const Duration(seconds: 10));
      final song = onlineSong(
        'seek-then-play-resume',
        url: 'https://media.example/seek.mp3',
      );

      final play = player.playSong(song);
      await audio.waitForPlaylistLoads(1).timeout(const Duration(seconds: 5));
      await audio.completeSourceLoad(0);
      await play;
      audio.emitPlaying(true);
      await Future<void>.delayed(Duration.zero);

      await player.seek(seekTarget);
      // 平台位置推进到 Q+Δ（UI 以平台上报为准）。
      audio.emitPosition(advancedPosition);
      await Future<void>.delayed(Duration.zero);
      expect(player.position, advancedPosition);

      await player.pause();
      await player.resume();

      expect(
        audio.playlistLoads.length,
        1,
        reason: '源已装载完成，恢复播放不得重载',
      );
      expect(
        player.position,
        advancedPosition,
        reason: '恢复后位置必须是暂停位置 Q+Δ，不能被旧 seek 目标拉回 Q',
      );
      expect(
        audio.lastSeekPosition,
        seekTarget,
        reason: '恢复过程不得再发一次指向旧 seek 目标的平台 seek',
      );
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  });

  test('冷启动恢复装载中跳转，播进一段后暂停恢复：落点仍是 Q+Δ', () async {
    const restorePosition = Duration(milliseconds: 12000);
    final restored = onlineSong('restore-then-resume');
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
      // 恢复装载在途（loading）：此时拖动进度条，seek 会被 fork 静默丢弃。
      await audio.waitForPlaylistLoads(1).timeout(const Duration(seconds: 5));
      await player.seek(seekTarget);
      await audio.completeSourceLoad(0);
      await player.audioReady.timeout(const Duration(seconds: 10));

      await player.resume();
      expect(audio.playlistLoads.length, 1);

      audio.emitPosition(advancedPosition);
      await Future<void>.delayed(Duration.zero);
      expect(player.position, advancedPosition);

      await player.pause();
      await player.resume();

      expect(
        audio.playlistLoads.length,
        1,
        reason: '源已装载完成，暂停恢复不得重载',
      );
      expect(
        player.position,
        advancedPosition,
        reason: '恢复后位置必须是 Q+Δ，不能被降级成旧 seek 目标 Q',
      );
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
      api.dio.httpClientAdapter = originalAdapter;
      await api.clearCookies();
      uninstallFakeSecureStorage();
    }
  });

  test('暂停后平台丢源（idle）触发重载：落点必须是暂停位置 Q+Δ', () async {
    SharedPreferences.setMockInitialValues({});
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final player = PlayerProvider();
    try {
      await player.audioReady.timeout(const Duration(seconds: 10));
      final song = onlineSong(
        'reload-landing',
        url: 'https://media.example/reload.mp3',
      );

      final play = player.playSong(song);
      await audio.waitForPlaylistLoads(1).timeout(const Duration(seconds: 5));
      await audio.completeSourceLoad(0);
      await play;
      audio.emitPlaying(true);
      await Future<void>.delayed(Duration.zero);

      await player.seek(seekTarget);
      audio.emitPosition(advancedPosition);
      await Future<void>.delayed(Duration.zero);
      expect(player.position, advancedPosition);

      await player.pause();
      // 暂停后平台丢失源状态（输出通路重建 / 播放器被回收），resume 必须重载。
      audio.emitProcessingState(just_audio.ProcessingState.idle);
      await Future<void>.delayed(Duration.zero);

      final resumeFuture = player.resume();
      await audio.waitForPlaylistLoads(2).timeout(const Duration(seconds: 5));
      expect(
        audio.sourceInitialPositions.last,
        advancedPosition,
        reason: '重载落点必须是暂停位置 Q+Δ，不能是旧 seek 目标 Q',
      );
      expect(
        audio.sourceInitialPositions.last,
        isNot(seekTarget),
        reason: '旧 seek 目标已被播放推进越过，不得作为恢复点',
      );
      await audio.completeSourceLoad(1);
      await resumeFuture;
      expect(player.position, advancedPosition);
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  });

  test('装载窗口遗留的 seek 记账不得在后续重载里把进度拉回 Q', () async {
    SharedPreferences.setMockInitialValues({});
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final player = PlayerProvider();
    try {
      await player.audioReady.timeout(const Duration(seconds: 10));
      final song = onlineSong(
        'stale-pending-seek',
        url: 'https://media.example/stale.mp3',
      );

      final play = player.playSong(song);
      await audio.waitForPlaylistLoads(1).timeout(const Duration(seconds: 5));
      // 装载窗口内拖动：seek 被 fork 丢弃，落点记进 pending。
      await player.seek(seekTarget);
      // 装载仍在途时点播放：新请求作废旧装载，pending 因此没有被落地。
      await player.resume();
      await audio.completeSourceLoad(0);
      await play;
      audio.emitPlaying(true);
      audio.emitPosition(advancedPosition);
      await Future<void>.delayed(Duration.zero);
      expect(player.position, advancedPosition);
      expect(audio.lastSeekPosition, seekTarget);

      await player.pause();
      audio.emitProcessingState(just_audio.ProcessingState.idle);
      await Future<void>.delayed(Duration.zero);

      final seekCountBeforeResume = audio.seekCount;
      final resumeFuture = player.resume();
      await audio.waitForPlaylistLoads(2).timeout(const Duration(seconds: 5));
      expect(
        audio.sourceInitialPositions.last,
        advancedPosition,
        reason: '重载落点必须是暂停位置 Q+Δ',
      );
      expect(
        audio.seekCount,
        seekCountBeforeResume,
        reason: '重载不得再把遗留的 seek 记账落地到 Q',
      );
      await audio.completeSourceLoad(1);
      await resumeFuture;
      expect(player.position, advancedPosition);
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  });
}

/// 解析成功：回一个可播放链接（冷启动恢复会重新解析在线地址）。
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
