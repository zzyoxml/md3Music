import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/core/services/play_history_sync_service.dart';
import 'package:md3music/core/services/playback_duration_tracker.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/data/repositories/history_repository.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';

import '../../test_helpers/fake_secure_storage.dart';

/// 云端播放历史上传服务：阈值结账、开关/登录门控、pc 取本地计数、
/// 失败入 pending 持久化队列并在恢复后补传。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late KugouApiClient client;
  late _UploadApiAdapter adapter;
  late int clockMs;

  Song onlineSong(String id, {String? mxid}) {
    final mx = mxid ?? 'mx-$id';
    return Song(
      id: id,
      title: '歌$id',
      artist: '歌手',
      album: '专辑',
      duration: const Duration(minutes: 3),
      isOnline: true,
      albumAudioId: mx,
    );
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    HistoryRepository.debugResetForTest();
    client = KugouApiClient();
    adapter = _UploadApiAdapter();
    client.dio.httpClientAdapter = adapter;
    final generation = KugouApiClient.markServerStarting();
    KugouApiClient.markServerReady(generation);
    await client.clearCookies();
    clockMs = 1700000000000;
    PlayHistorySyncService.instance.tracker =
        PlaybackDurationTracker(nowMillis: () => clockMs);
  });

  tearDown(() {
    PlayHistorySyncService.instance.discard();
    HistoryRepository.debugResetForTest();
    uninstallFakeSecureStorage();
  });

  Future<void> seedCounts(Map<String, int> counts) async {
    // 登录 userid=10086 → 键带后缀；直接写 prefs，repo 首次读取即命中
    await SharedPreferences.getInstance().then(
      (prefs) => prefs.setString(
        'play_history_counts_10086',
        jsonEncode(counts),
      ),
    );
  }

  group('阈值与上传', () {
    setUp(() async {
      await client.setLoginCookies('token-abc', '10086');
    });

    test('播放不足 15s 不上传', () async {
      final service = PlayHistorySyncService.instance;
      await service.onSongStarted(song: onlineSong('s1'), playing: true);
      clockMs += 5000;
      await service.onSongEnded();

      expect(adapter.uploadQueries, isEmpty);
    });

    test('达阈值上传：mxid/ot/pc（pc 取本地计数）', () async {
      await seedCounts({'s2': 3});
      final service = PlayHistorySyncService.instance;
      await service.onSongStarted(song: onlineSong('s2'), playing: true);
      clockMs += 20000;
      await service.onSongEnded();

      expect(adapter.uploadQueries, hasLength(1));
      final q = adapter.uploadQueries.first;
      expect(q['mxid'], 'mx-s2');
      expect(q['pc'], '3');
      // 播放时间为秒级时间戳（接近测试起点时钟）。
      // 本地参数名是 `time`（与上游 JS / Rust 中继一致），不是上游 body 字段名 `ot`
      final time = int.parse(q['time']!);
      expect(time, greaterThan(1600000000));
      expect(q['time']!.length, lessThanOrEqualTo(10), reason: '秒级非毫秒');
    });

    test('本地计数缺失时不上传 pc（只追加记录）', () async {
      final service = PlayHistorySyncService.instance;
      await service.onSongStarted(song: onlineSong('s3'), playing: true);
      clockMs += 20000;
      await service.onSongEnded();

      expect(adapter.uploadQueries, hasLength(1));
      expect(adapter.uploadQueries.first.containsKey('pc'), isFalse);
    });

    test('无 albumAudioId 的本地歌曲不产生段、不上传', () async {
      final service = PlayHistorySyncService.instance;
      await service.onSongStarted(
        song: Song(
          id: 's4',
          title: '本地歌',
          artist: '歌手',
          album: '专辑',
          duration: const Duration(minutes: 3),
          isOnline: false,
          albumAudioId: null,
        ),
        playing: true,
      );
      clockMs += 30000;
      await service.onSongEnded();

      expect(adapter.uploadQueries, isEmpty);
      // 随后同 tracker 可正常用于下一首在线歌（段被正确跳过）
      await service.onSongStarted(song: onlineSong('s5'), playing: true);
      clockMs += 20000;
      await service.onSongEnded();
      expect(adapter.uploadQueries, hasLength(1));
      expect(adapter.uploadQueries.first['mxid'], 'mx-s5');
    });

    test('切歌边沿经 onSongStarted 结账上一段（snapshot 语义）', () async {
      await seedCounts({'a1': 1, 'a2': 1});
      final service = PlayHistorySyncService.instance;
      await service.onSongStarted(song: onlineSong('a1'), playing: true);
      clockMs += 20000;
      // 不调 onSongEnded，直接切下一首：上一首应在 onSongStarted 内部结账
      await service.onSongStarted(song: onlineSong('a2'), playing: true);
      clockMs += 20000;
      await service.onSongEnded();

      expect(adapter.uploadQueries, hasLength(2));
      expect(adapter.uploadQueries[0]['mxid'], 'mx-a1');
      expect(adapter.uploadQueries[1]['mxid'], 'mx-a2');
    });

    test('暂停期间不累计时长（20s 挂起但只出声 5s → 不上传）', () async {
      final service = PlayHistorySyncService.instance;
      await service.onSongStarted(song: onlineSong('p1'), playing: true);
      clockMs += 5000;
      service.onPlayingChanged(false);
      clockMs += 20000;
      service.onPlayingChanged(true);
      clockMs += 1000;
      await service.onSongEnded();

      expect(adapter.uploadQueries, isEmpty, reason: '实际出声仅 6s');
    });
  });

  group('门控', () {
    test('未登录不上传', () async {
      // 不 setLoginCookies
      final service = PlayHistorySyncService.instance;
      await service.onSongStarted(song: onlineSong('n1'), playing: true);
      clockMs += 30000;
      await service.onSongEnded();

      expect(adapter.uploadQueries, isEmpty);
    });

    test('开关关闭不上传且不残留段', () async {
      await client.setLoginCookies('token-abc', '10086');
      await SharedPreferences.getInstance().then(
        (prefs) => prefs.setBool('settings_upload_listening_duration', false),
      );
      final service = PlayHistorySyncService.instance;
      await service.onSongStarted(song: onlineSong('off1'), playing: true);
      clockMs += 30000;
      await service.onSongEnded();

      expect(adapter.uploadQueries, isEmpty);
    });
  });

  group('pending 队列', () {
    setUp(() async {
      await client.setLoginCookies('token-abc', '10086');
    });

    test('上传持续失败入队，恢复后 flushPending 补传成功并清空', () async {
      // settle 末尾会自动 flushPending，因此「入队」阶段需两连败：
      // 首次上传 + settle 内自动补传，队列才留得住
      adapter.alwaysFail = true;
      final service = PlayHistorySyncService.instance;
      await service.onSongStarted(song: onlineSong('f1'), playing: true);
      clockMs += 20000;
      await service.onSongEnded();

      expect(adapter.uploadQueries, hasLength(2), reason: '首次上传 + 自动补传');
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('play_history_pending_uploads_10086');
      expect(raw, isNotNull, reason: '两次失败后持久化待传条目');
      final queue = (jsonDecode(raw!) as List).cast<Map>();
      expect(queue.first['mxid'], 'mx-f1');
      expect(queue.first['ot'], isNotNull, reason: '保留原始播放时间');

      adapter.alwaysFail = false;
      await service.flushPending();

      expect(adapter.uploadQueries, hasLength(3));
      expect(adapter.uploadQueries.last['mxid'], 'mx-f1');
      final after = await SharedPreferences.getInstance();
      final remaining = after.getString('play_history_pending_uploads_10086');
      expect(
        remaining == null || (jsonDecode(remaining!) as List).isEmpty,
        isTrue,
        reason: '补传成功后清空队列',
      );
    });

    test('开关关闭时 flushPending 跳过（队列保留）', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('settings_upload_listening_duration', false);
      await prefs.setString(
        'play_history_pending_uploads_10086',
        jsonEncode([
          {'mxid': 'mx-q1', 'ot': 1700000000},
        ]),
      );

      await PlayHistorySyncService.instance.flushPending();

      expect(adapter.uploadQueries, isEmpty);
      final raw = await prefs.getString('play_history_pending_uploads_10086');
      expect(raw, isNotNull);
    });
  });
}

class _UploadApiAdapter implements HttpClientAdapter {
  /// 已发生的 /playhistory/upload 请求 query（按次序）。
  final List<Map<String, String>> uploadQueries = [];

  /// 置 true 时下一次 /playhistory/upload 返回 500（模拟上游失败）。
  bool failNext = false;

  /// 置 true 时所有 /playhistory/upload 恒 500（模拟持续离线）。
  bool alwaysFail = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    if (path == '/playhistory/upload') {
      uploadQueries.add(options.uri.queryParameters);
      if (alwaysFail || failNext) {
        failNext = false;
        return ResponseBody.fromString('', 500, statusMessage: 'server error');
      }
      return ResponseBody.fromString(
        jsonEncode({'status': 1, 'error_code': 0, 'data': null}),
        200,
        headers: const {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    return ResponseBody.fromString(
      jsonEncode(const {}),
      200,
      headers: const {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
