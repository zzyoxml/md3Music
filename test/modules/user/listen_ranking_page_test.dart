import 'dart:convert';

// 页面用 material_ui 的 Scaffold/AppBar（其本地化检查认自家类型），测试宿主
// 必须同样用 material_ui 的 MaterialApp（不 import flutter/material）。
import 'package:material_ui/material_ui.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/modules/player/secondary_mini_player.dart';
import 'package:md3music/modules/user/listen_ranking_page.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/providers/listen_stats_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/local_favorites_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';

import '../../test_helpers/fake_secure_storage.dart';

/// 排行页数据源 = 云端播放历史（/user/history）聚合派生：
/// 断言渲染排名/累计次数、类型切换不重复请求、空态与未登录态。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late KugouApiClient client;
  late _HistoryApiAdapter adapter;
  late KugouProvider kugou;
  late ListenStatsProvider stats;
  late PlayerProvider player;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    client = KugouApiClient();
    adapter = _HistoryApiAdapter();
    client.dio.httpClientAdapter = adapter;
    final generation = KugouApiClient.markServerStarting();
    KugouApiClient.markServerReady(generation);
    await client.clearCookies();
    kugou = KugouProvider(registerDeviceOnStart: false);
    stats = ListenStatsProvider();
    player = PlayerProvider();
  });

  tearDown(() {
    kugou.dispose();
    stats.dispose();
    player.dispose();
    uninstallFakeSecureStorage();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<KugouProvider>.value(value: kugou),
          ChangeNotifierProvider<ListenStatsProvider>.value(value: stats),
          ChangeNotifierProvider<PlayerProvider>.value(value: player),
          // SongListItem.build 硬 select 收藏集合，harness 必须提供；
          // syncOnStart=false 防止构造期自动同步云收藏（FakeAsync 下 Dio Timer 挂起）
          ChangeNotifierProvider<FavoritesProvider>(
            create: (_) => FavoritesProvider(syncOnStart: false),
          ),
          ChangeNotifierProvider<LocalFavoritesProvider>(
            create: (_) => LocalFavoritesProvider(),
          ),
        ],
        child: const MaterialApp(home: ListenRankingPage()),
      ),
    );
    // M3ELoadingIndicator 是常驻动画，不能 pumpAndSettle
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('未登录：显示登录提示（provider 不门控请求，页面门控展示）',
      (tester) async {
    await pumpPage(tester);

    expect(find.text('登录后可查看云端听歌排行'), findsOneWidget);
  });

  group('已登录', () {
    setUp(() async {
      await client.setLoginCookies('token-abc', '10086');
      await kugou.refreshUserInfo();
    });

    testWidgets('渲染排行列表（按累计次数排序）与统计入口', (tester) async {
      await pumpPage(tester);

      expect(find.text('共 2 首'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      expect(find.text('12次'), findsOneWidget, reason: '累计次数来自 pc');
      expect(find.text('3次'), findsOneWidget);
      expect(find.byIcon(Icons.insights_outlined), findsOneWidget);
    });

    testWidgets('切换「全部累计」复用同一份历史派生数据（不重复请求）', (tester) async {
      await pumpPage(tester);

      final queriesBefore = adapter.historyQueries.length;
      expect(queriesBefore, greaterThan(0));

      await tester.tap(find.text('全部累计').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // 双榜同源于一次历史拉取，切换只是本地重排 → 不再发请求
      expect(adapter.historyQueries, hasLength(queriesBefore));
      expect(find.text('12次'), findsOneWidget);
    });

    testWidgets('云端为空：显示空态文案', (tester) async {
      adapter.historyResponses = [
        {
          'status': 1,
          'data': {'songs': <Object?>[]},
        },
      ];
      await pumpPage(tester);

      expect(find.text('最近一周暂无听歌记录'), findsOneWidget);
      expect(find.text('播放在线歌曲后会自动同步到云端'), findsOneWidget);
    });
  });
}

/// /user/history 的 Dio adapter mock（实机确认结构：songs[] + 嵌套 info{}）。
class _HistoryApiAdapter implements HttpClientAdapter {
  final List<Map<String, String>> historyQueries = [];

  /// 按调用次序弹出的响应队列（默认首先生效 [defaultResponse]）。
  List<Map<String, dynamic>> historyResponses = [];

  static Map<String, dynamic> _item(
    String hash,
    String name,
    String artist,
    int pc,
  ) =>
      {
        'mxid': hash.hashCode & 0x7fffffff,
        'ot': DateTime.now().millisecondsSinceEpoch ~/ 1000 - 600,
        'pc': pc,
        'op': 1,
        'info': {
          'name': name,
          'singername': artist,
          'hash': hash,
          'timelen': 200000,
        },
      };

  late Map<String, dynamic> defaultResponse = {
    'status': 1,
    'error_code': 0,
    'data': {
      'songs': [
        _item('hash-a', '遥远的她', '陈奕迅', 12),
        _item('hash-b', '心淡', '容祖儿', 3),
      ],
      'has_more': 0,
    },
  };

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    if (path == '/user/history') {
      historyQueries.add(options.uri.queryParameters);
      if (historyResponses.isNotEmpty) {
        return _json(historyResponses.removeAt(0));
      }
      return _json(defaultResponse);
    }
    return _json(const {});
  }

  ResponseBody _json(Map<String, dynamic> obj) => ResponseBody.fromString(
        jsonEncode(obj),
        200,
        headers: const {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );

  @override
  void close({bool force = false}) {}
}
