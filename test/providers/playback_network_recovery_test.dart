import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart' as services;
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/playback_recovery_budget.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/controlled_audio_service.dart';
import '../test_helpers/fake_secure_storage.dart';

/// 「有网但 API 不通」：全部请求在传输层返回 502（上游不可达包装）。
class _ApiDownAdapter implements HttpClientAdapter {
  int playbackUrlRequests = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path.contains('/song/url')) {
      playbackUrlRequests++;
    }
    return ResponseBody.fromString(
      jsonEncode({
        'status': 0,
        'error_code': 0,
        'error_msg': 'Dns Failed: simulate api unreachable',
      }),
      502,
      headers: const {'content-type': ['application/json']},
    );
  }
}

/// 前 N 次 /song/url（不含收藏页兜底）返回 502，之后返回空 url 的「解析失败」
/// 响应，用于验证断网→恢复事件会触发自动续播（重试计数增长）。
class _RecoverableAdapter implements HttpClientAdapter {
  int playbackUrlRequests = 0;
  final int failFirstN;

  _RecoverableAdapter(this.failFirstN);

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    // 只统计主解析请求（收藏页兜底带 ppage_id，单独计数会掩盖主链轮次）。
    final queryPpage = options.queryParameters['ppage_id'];
    final isMainSongUrl =
        options.path == '/song/url' &&
        (queryPpage == null || queryPpage.isEmpty);
    if (!options.path.contains('/song/url')) {
      // 非播放链接请求：给一个可解析的空结果，避免干扰主链断言。
      return ResponseBody.fromString(
        jsonEncode({'data': {'url': '', 'quality': '128'}}),
        200,
        headers: const {'content-type': ['application/json']},
      );
    }
    if (isMainSongUrl) playbackUrlRequests++;
    if (isMainSongUrl && playbackUrlRequests <= failFirstN) {
      return ResponseBody.fromString(
        jsonEncode({
          'status': 0,
          'error_code': 0,
          'error_msg': 'simulate transient api failure',
        }),
        502,
        headers: const {'content-type': ['application/json']},
      );
    }
    return ResponseBody.fromString(
      jsonEncode({'data': {'url': '', 'quality': '128'}}),
      200,
      headers: const {'content-type': ['application/json']},
    );
  }
}

Song _onlineSong(String id) => Song(
      id: id,
      title: 'Network Recovery Target',
      artist: 'Artist',
      album: 'Album',
      duration: const Duration(minutes: 3),
      isOnline: true,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    // fluttertoast 无平台实现：给通道打桩，预算耗尽 toast 路径不产生未捕获错误。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const services.MethodChannel('PonnamKarthik/fluttertoast'),
      (call) async => null,
    );
  });

  tearDown(() {
    uninstallFakeSecureStorage();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const services.MethodChannel('PonnamKarthik/fluttertoast'),
      null,
    );
  });

  test(
    '有网但 API 不通：自动重试链前台自愈，全程不投放红色错误条',
    () async {
      final apiClient = KugouApiClient();
      await apiClient.clearCookies();
      await apiClient.setLoginCookies('fixture-token', 'fixture-user');
      final originalAdapter = apiClient.dio.httpClientAdapter;
      final adapter = _ApiDownAdapter();
      apiClient.dio.httpClientAdapter = adapter;
      KugouApiClient.markServerReady();

      const methodChannel = services.MethodChannel(
        'dev.fluttercommunity.plus/connectivity',
      );
      const eventChannel = services.EventChannel(
        'dev.fluttercommunity.plus/connectivity_status',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        if (call.method == 'check') return <String>['wifi'];
        return null;
      });
      messenger.setMockStreamHandler(
        eventChannel,
        MockStreamHandler.inline(
          onListen: (_, events) => events.success(<String>['wifi']),
        ),
      );

      final audio = ControlledAudioService();
      AudioServiceLoader.setTestOverride(() async => audio);
      // 前台秒级退避全部取零：把重试链压缩到瞬时完成，便于确定性断言。
      final budget = PlaybackRecoveryBudget(
        maxAttempts: 3,
        backoff: [Duration.zero, Duration.zero],
        foregroundBackoff: const [Duration.zero, Duration.zero],
      );
      final player = PlayerProvider(failedRecoveryBudget: budget);
      try {
        await player.audioReady.timeout(const Duration(seconds: 10));

        await player.playPlaylist([_onlineSong('recover-target')], 0);
        // 自动重试至少又打了 3 次播放链接请求（首次 + 自愈链）。
        for (var i = 0; i < 300 && adapter.playbackUrlRequests < 4; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(adapter.playbackUrlRequests, greaterThanOrEqualTo(4));

        // 网络类失败全程不展示常驻错误条（不出现需要点击的重试控件）。
        expect(player.resolveErrorForDisplay, isNull);
        // 内层仍保留诊断文案供诊断日志读取，仅 UI 层隐藏。
        expect(player.resolveError, isNotNull);
        expect(player.resolveError, contains('无法获取播放链接'));
        expect(player.currentSong?.id, 'recover-target');
      } finally {
        player.dispose();
        await audio.dispose();
        AudioServiceLoader.setTestOverride(null);
        apiClient.dio.httpClientAdapter = originalAdapter;
        messenger.setMockMethodCallHandler(methodChannel, null);
        messenger.setMockStreamHandler(eventChannel, null);
      }
    },
  );

  test(
    '断网→恢复事件自动续播，不展示红色错误条也不弹窗',
    () async {
      final apiClient = KugouApiClient();
      await apiClient.clearCookies();
      await apiClient.setLoginCookies('fixture-token', 'fixture-user');
      final originalAdapter = apiClient.dio.httpClientAdapter;
      final adapter = _RecoverableAdapter(1);
      apiClient.dio.httpClientAdapter = adapter;
      KugouApiClient.markServerReady();

      const methodChannel = services.MethodChannel(
        'dev.fluttercommunity.plus/connectivity',
      );
      const eventChannel = services.EventChannel(
        'dev.fluttercommunity.plus/connectivity_status',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var currentNetwork = <String>['none'];
      var subscribed = false;
      final eventController = StreamController<List<String>>();
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        if (call.method == 'check') return currentNetwork;
        return null;
      });
      messenger.setMockStreamHandler(
        eventChannel,
        MockStreamHandler.inline(
          onListen: (_, events) {
            // 订阅即刻回放当前网络态：无论监听注册早晚，断网态都能先到位。
            subscribed = true;
            events.success(currentNetwork);
            eventController.stream.listen((value) => events.success(value));
          },
        ),
      );

      final audio = ControlledAudioService();
      AudioServiceLoader.setTestOverride(() async => audio);
      final player = PlayerProvider(
        failedRecoveryBudget: PlaybackRecoveryBudget(
          maxAttempts: 20,
          backoff: [Duration.zero],
          foregroundBackoff: const [Duration.zero],
        ),
      );
      try {
        await player.audioReady.timeout(const Duration(seconds: 10));
        // 等网络监听完成订阅（EventChannel 的 listen 握手走异步消息），
        // 确保断网态在起播前就位，避免默认「有网」分类提前触发自愈链。
        for (var i = 0; i < 200 && !subscribed; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(subscribed, isTrue, reason: '网络监听应已完成订阅');
        currentNetwork = <String>['none'];
        eventController.add(<String>['none']);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // 断网状态下起播：解析失败进会话，静默等待网络恢复。
        await player.playPlaylist([_onlineSong('recover-event-target')], 0);
        // 让离线期的自动重试链收敛（预算有上限，不会风暴）。
        await Future<void>.delayed(const Duration(milliseconds: 150));
        final offlineRequestCount = adapter.playbackUrlRequests;
        expect(offlineRequestCount, greaterThan(0));
        // 静默窗：不再有新的解析请求，界面全程无红色错误条/弹窗。
        for (var i = 0; i < 30; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(
          adapter.playbackUrlRequests,
          offlineRequestCount,
          reason: '断网期间自愈预算耗尽后应安静等待，不持续打 API',
        );
        expect(player.resolveErrorForDisplay, isNull);

        // 断网→恢复：会话自动续播（无需用户操作）。
        currentNetwork = <String>['wifi'];
        eventController.add(<String>['wifi']);
        for (var i = 0; i < 300 && adapter.playbackUrlRequests <= offlineRequestCount; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(adapter.playbackUrlRequests, greaterThan(offlineRequestCount));
        expect(player.resolveErrorForDisplay, isNull);
      } finally {
        eventController.close();
        player.dispose();
        await audio.dispose();
        AudioServiceLoader.setTestOverride(null);
        apiClient.dio.httpClientAdapter = originalAdapter;
        messenger.setMockMethodCallHandler(methodChannel, null);
        messenger.setMockStreamHandler(eventChannel, null);
      }
    },
  );
}