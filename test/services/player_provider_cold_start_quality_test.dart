import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/controlled_audio_service.dart';
import '../test_helpers/fake_secure_storage.dart';

/// 冷启动恢复的音质链路回归钉（见 AGENTS「判断功能状态必须基于日志/证据」）。
///
/// 三条各钉一个独立缺陷：
/// 1. 恢复上次播放的在线歌必须丢弃旧链接重新解析（否则实际档位永不回填）；
/// 2. 解析失败后 `_isResolvingUrl` 必须归位（否则状态反馈常驻「正在解析」）；
/// 3. 离线文件读不到音质档时按容器如实展示，不停在「检测中」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Song onlineSong(String id, {String? url}) => Song(
    id: id,
    title: 'Cold Start Quality',
    artist: 'Artist',
    album: 'Album',
    duration: const Duration(minutes: 3),
    url: url,
    isOnline: true,
  );

  test('冷启动恢复在线歌：丢弃旧链接重新解析并显示实际档位', () async {
    final stale = onlineSong(
      'cold-start-resolve',
      url: 'https://media.example/stale-from-last-session.mp3',
    );
    SharedPreferences.setMockInitialValues({
      // 偏好定为 Hi-Res，实际回 flac —— 只有真的走过解析才会显示「无损音质」。
      'settings_default_quality_wifi': 'high',
      'settings_default_quality_mobile': 'high',
      'player_current_song': jsonEncode(stale.toJson()),
      'player_playlist': [jsonEncode(stale.toJson())],
      'player_current_index': 0,
      'player_position': 15000,
    });
    installFakeSecureStorage();
    final api = KugouApiClient();
    await api.clearCookies();
    await api.setLoginCookies('fixture-token', 'fixture-user');
    final originalAdapter = api.dio.httpClientAdapter;
    final adapter = _PlaybackUrlAdapter(quality: 'flac');
    api.dio.httpClientAdapter = adapter;
    KugouApiClient.markServerReady();

    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final player = PlayerProvider();
    try {
      await audio.waitForPlaylistLoads(1).timeout(const Duration(seconds: 5));
      await audio.completeSourceLoad(0);
      await player.audioReady.timeout(const Duration(seconds: 10));

      expect(
        adapter.playbackUrlRequestCount,
        greaterThanOrEqualTo(1),
        reason: '上次会话的 URL 已过期，冷启动必须重新解析',
      );
      expect(
        player.currentSong?.url,
        'https://media.example/resolved.flac',
        reason: '当前歌用的必须是新解析出来的链接，不是持久化里那条旧的',
      );
      expect(player.currentQualityLabel, '无损音质');
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
      api.dio.httpClientAdapter = originalAdapter;
      await api.clearCookies();
      uninstallFakeSecureStorage();
    }
  });

  test('解析失败后正在解析标志归位，音质回落到偏好档位而不是卡在解析态',
      () async {
    final song = onlineSong('cold-start-resolve-fail');
    SharedPreferences.setMockInitialValues({
      'settings_default_quality_wifi': 'high',
      'settings_default_quality_mobile': 'high',
      'player_current_song': jsonEncode(song.toJson()),
      'player_playlist': [jsonEncode(song.toJson())],
      'player_current_index': 0,
      'player_position': 5000,
    });
    installFakeSecureStorage();
    final api = KugouApiClient();
    await api.clearCookies();
    await api.setLoginCookies('fixture-token', 'fixture-user');
    final originalAdapter = api.dio.httpClientAdapter;
    final adapter = _FailingPlaybackUrlAdapter();
    api.dio.httpClientAdapter = adapter;
    KugouApiClient.markServerReady();

    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final player = PlayerProvider();
    try {
      await player.audioReady.timeout(const Duration(seconds: 10));
      expect(adapter.playbackUrlRequestCount, greaterThanOrEqualTo(1));

      expect(
        player.isResolvingUrl,
        isFalse,
        reason: '失败分支绕过了共享收尾，必须自己复位（否则状态反馈常驻「正在解析」）',
      );
      expect(
        player.currentQualityLabel,
        isNot(PlayerProvider.unknownQualityLabel),
        reason: '在线歌永远不该是检测占位',
      );
      expect(player.currentQualityLabel, 'Hi-Res');
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
      api.dio.httpClientAdapter = originalAdapter;
      await api.clearCookies();
      uninstallFakeSecureStorage();
    }
  });

  test('离线文件没有音质档时按容器如实展示', () async {
    SharedPreferences.setMockInitialValues({
      'settings_restore_memory': false,
    });
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final player = PlayerProvider();
    try {
      await player.audioReady.timeout(const Duration(seconds: 10));

      final cases = <({String path, String label})>[
        // MediaStore 读不到 bitrate 时 quality 为 null（LocalMusicRepository
        // ._inferQuality 的 null 分支），过去这里永远显示「检测中」。
        (path: '/music/no-bitrate.mp3', label: 'MP3 音质'),
        (path: '/music/no-bitrate.flac', label: '无损音质'),
      ];
      for (final item in cases) {
        final load = player.playPlaylist([
          Song(
            id: 'local-${item.path}',
            title: 'Local Without Quality',
            artist: 'Artist',
            album: 'Album',
            duration: const Duration(minutes: 3),
            localPath: item.path,
          ),
        ], 0);
        await audio.waitForPlaylistLoads(1).timeout(const Duration(seconds: 5));
        expect(
          player.currentQualityLabel,
          item.label,
          reason: '${item.path} 不该出现检测占位',
        );
        await audio.completeSourceLoad(0);
        await load;
        audio.playlistLoads.clear();
      }
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  });
}

/// 解析成功：回指定音质的新链接。
class _PlaybackUrlAdapter implements HttpClientAdapter {
  _PlaybackUrlAdapter({required this.quality});

  final String quality;
  int playbackUrlRequestCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/song/url' ||
        options.uri.path == '/song/url/new') {
      playbackUrlRequestCount++;
      return ResponseBody.fromString(
        jsonEncode({
          'data': {
            'url': ['https://media.example/resolved.$quality'],
            'quality': quality,
          },
        }),
        200,
        headers: const {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    return ResponseBody.fromString(
      '{}',
      200,
      headers: const {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 所有请求都失败（拿不到链接）。
class _FailingPlaybackUrlAdapter implements HttpClientAdapter {
  int playbackUrlRequestCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/song/url' ||
        options.uri.path == '/song/url/new') {
      playbackUrlRequestCount++;
    }
    return ResponseBody.fromString(
      '{"error":"temporary"}',
      503,
      headers: const {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
