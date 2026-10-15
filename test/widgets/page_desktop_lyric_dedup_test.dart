import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' as services;
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/desktop_lyric_service.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/modules/player/full_player.dart';
import 'package:md3music/providers/comment_display_provider.dart';
import 'package:md3music/providers/device_provider.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/providers/listen_together_provider.dart';
import 'package:md3music/providers/local_favorites_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/services/kugou_api/kugou_endpoints.dart';
import 'package:md3music/main.dart' show appNavigatorKey;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/controlled_audio_service.dart';
import '../test_helpers/fake_secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('全屏页与桌面歌词同键并发时只查询并下载一次', (tester) async {
    final originalPhysicalSize = tester.view.physicalSize;
    final originalDevicePixelRatio = tester.view.devicePixelRatio;
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    SharedPreferences.setMockInitialValues({
      'settings_restore_memory': false,
      'settings_spectrum_dynamic_color': false,
    });
    installFakeSecureStorage();

    final client = KugouApiClient();
    await client.clearCookies();
    final originalBaseUrl = KugouEndpoints.baseUrl;
    final originalAdapter = client.dio.httpClientAdapter;
    final adapter = _PageDesktopLyricAdapter();
    client.updateBaseUrl('http://page-desktop-lyric.invalid');
    client.dio.httpClientAdapter = adapter;
    KugouApiClient.markServerReady();

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const services.MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (call) async => call.method == 'check' ? <String>['wifi'] : null,
    );
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
    final lockScreenPayloads = <Map<Object?, Object?>>[];
    messenger.setMockMethodCallHandler(
      const services.MethodChannel('com.md3music.md3music/floating_lyric'),
      (call) async {
        if (call.method == 'updateLockScreenLyricData' &&
            call.arguments is Map) {
          lockScreenPayloads.add(
            Map<Object?, Object?>.from(call.arguments as Map),
          );
        }
        return null;
      },
    );

    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final kugou = KugouProvider(registerDeviceOnStart: false);
    PlayerProvider? player;
    final desktopLyrics = DesktopLyricService.instance;
    try {
      await tester.runAsync(() async {
        player = PlayerProvider();
        await player!.audioReady.timeout(const Duration(seconds: 10));
      });
      final activePlayer = player!;
      final song = Song(
        id: 'shared-page-desktop-hash',
        title: 'Shared Integration Track',
        artist: 'Shared Artist',
        album: 'Integration Album',
        duration: const Duration(minutes: 3),
        url: 'https://audio.invalid/shared-integration.mp3',
        isOnline: true,
      );
      await tester.runAsync(() async {
        final play = activePlayer.playPlaylist([song], 0);
        await audio.waitForPlaylistLoads(1);
        await audio.completeSourceLoad(0);
        await play;
      });
      expect(activePlayer.currentSong?.id, song.id);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<PlayerProvider>.value(value: activePlayer),
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
          child: MaterialApp(
            navigatorKey: appNavigatorKey,
            home: const FullPlayer(dockMode: true),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(tester.takeException(), isNull);
      expect(find.byType(FullPlayer), findsOneWidget);
      for (
        var frame = 0;
        frame < 50 && !adapter.searchRequested.isCompleted;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(
        adapter.searchRequested.isCompleted,
        isTrue,
        reason: '全屏页未触发歌词搜索；适配器收到路径：${adapter.observedPaths}',
      );
      expect(adapter.searchRequestCount, 1);

      await desktopLyrics.setLockScreenLyricEnabled(true);
      // 测试音频替身在 source load 后可能仍为暂停态；锁屏歌词暂停 tick 是 1s。
      await tester.pump(const Duration(milliseconds: 1200));
      expect(adapter.searchRequestCount, 1);

      adapter.completeSearch();
      for (
        var frame = 0;
        frame < 50 && !adapter.bothLyricFormatsRequested.isCompleted;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(adapter.bothLyricFormatsRequested.isCompleted, isTrue);
      expect(adapter.lyricRequestCount, 2);
      expect(adapter.requestedFormats, containsAll(['lrc', 'krc']));
      adapter.completeLyrics();

      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
      expect(find.byType(FullPlayer), findsOneWidget);
      expect(
        kugou.lyric?.displayKrcLyric,
        contains('Shared lyric integration line'),
      );
      expect(
        lockScreenPayloads.any((payload) {
          final lines = payload['lines'];
          return lines is List &&
              lines.any(
                (line) =>
                    line is Map &&
                    line['text'] == 'Shared lyric integration line',
              );
        }),
        isTrue,
        reason: '桌面/锁屏服务应提交同一歌词查询的解析结果',
      );
      expect(adapter.searchRequestCount, 1);
      expect(adapter.lyricRequestCount, 2);
    } finally {
      await desktopLyrics.setLockScreenLyricEnabled(false);
      await tester.pumpWidget(const SizedBox.shrink());
      tester.view.physicalSize = originalPhysicalSize;
      tester.view.devicePixelRatio = originalDevicePixelRatio;
      player?.dispose();
      kugou.dispose();
      await tester.runAsync(() => audio.dispose());
      AudioServiceLoader.setTestOverride(null);
      client.updateBaseUrl(originalBaseUrl);
      client.dio.httpClientAdapter = originalAdapter;
      messenger.setMockMethodCallHandler(
        const services.MethodChannel('dev.fluttercommunity.plus/connectivity'),
        null,
      );
      messenger.setMockStreamHandler(
        const services.EventChannel(
          'dev.fluttercommunity.plus/connectivity_status',
        ),
        null,
      );
      messenger.setMockMethodCallHandler(
        const services.MethodChannel('com.md3music.md3music/home_widget'),
        null,
      );
      messenger.setMockMethodCallHandler(
        services.SystemChannels.platform,
        null,
      );
      messenger.setMockMethodCallHandler(
        const services.MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      messenger.setMockMethodCallHandler(
        const services.MethodChannel('com.md3music.md3music/floating_lyric'),
        null,
      );
      await client.clearCookies();
      uninstallFakeSecureStorage();
    }
  });
}

class _PageDesktopLyricAdapter implements HttpClientAdapter {
  final Completer<void> searchRequested = Completer<void>();
  final Completer<ResponseBody> _searchResponse = Completer<ResponseBody>();
  final Completer<void> bothLyricFormatsRequested = Completer<void>();
  final Completer<void> _lyricsReleased = Completer<void>();
  final List<String> requestedFormats = [];
  final List<String> observedPaths = [];
  int searchRequestCount = 0;
  int lyricRequestCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    observedPaths.add(options.path);
    if (options.path == KugouEndpoints.searchLyric) {
      searchRequestCount++;
      if (!searchRequested.isCompleted) searchRequested.complete();
      return _searchResponse.future;
    }
    if (options.path == KugouEndpoints.lyric) {
      lyricRequestCount++;
      final format = options.queryParameters['fmt']?.toString() ?? '';
      requestedFormats.add(format);
      if (lyricRequestCount == 2 && !bothLyricFormatsRequested.isCompleted) {
        bothLyricFormatsRequested.complete();
      }
      await _lyricsReleased.future;
      return _response({
        'data': {'decodeContent': '[00:00.00]Shared lyric integration line'},
      });
    }
    return _response(<String, Object?>{});
  }

  void completeSearch() {
    if (_searchResponse.isCompleted) return;
    _searchResponse.complete(
      _response({
        'candidates': [
          {'id': 'shared-integration-lyric-id', 'accesskey': 'fixture-key'},
        ],
      }),
    );
  }

  void completeLyrics() {
    if (!_lyricsReleased.isCompleted) _lyricsReleased.complete();
  }

  ResponseBody _response(Object body) => ResponseBody.fromString(
    jsonEncode(body),
    200,
    headers: const {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

  @override
  void close({bool force = false}) {}
}
