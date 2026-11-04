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
import 'package:md3music/modules/user/play_history_page.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/providers/listen_stats_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/local_favorites_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/widgets/song_list_item.dart';

import '../../test_helpers/fake_secure_storage.dart';

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
        child: const MaterialApp(home: PlayHistoryPage()),
      ),
    );
    // initState 拉本地历史 + 云端首页；M3ELoadingIndicator 是常驻动画，
    // 不能 pumpAndSettle，用固定拍数推进到数据态
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

    testWidgets('未登录：云端 Tab 显示登录提示', (tester) async {
      await pumpPage(tester);

      expect(find.text('登录后可查看云端听歌历史'), findsOneWidget);
      // Tab 标签（M3EToggleButtonGroup 会重复渲染 label，按 ≥1 断言）
      expect(find.text('云端历史'), findsWidgets);
      expect(find.text('本地歌曲'), findsWidgets);
    });

  group('已登录', () {
    setUp(() async {
      await client.setLoginCookies('token-abc', '10086');
      await kugou.refreshUserInfo();
    });

    testWidgets('云端 Tab（默认）：渲染云端条目与相对时间', (tester) async {
      await pumpPage(tester);

      expect(find.text('云歌一'), findsOneWidget);
      expect(find.text('云歌二'), findsOneWidget);
      expect(find.text('共 2 条'), findsOneWidget);
      expect(find.text('播放记录已云端同步'), findsOneWidget);
      // 无游标 → 不出现加载更多指示
      expect(find.byKey(const ValueKey('history-load-more')), findsNothing);
    });

    testWidgets('有游标时显示已加载数与加载指示', (tester) async {
      adapter.historyResponses = [
        {
          'status': 1,
          'data': {
            'list': [
              {'hash': 'h1', 'filename': '云歌一', 'timestamp': 1700000000},
            ],
            'bp': 'cursor-1',
          },
        },
      ];
      await pumpPage(tester);

      expect(find.text('已加载 1 条'), findsOneWidget);
      // 列表尾部有加载更多指示（未再滚动则保持 pending 展示）
      expect(find.byKey(const ValueKey('history-load-more')), findsOneWidget);
    });

    testWidgets('切本地 Tab：显示本地空态（在线记录不进本地页）', (tester) async {
      await pumpPage(tester);

      await tester.tap(find.text('本地歌曲').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('暂无本地歌曲播放记录'), findsOneWidget);
      expect(find.text('在线歌曲的播放记录请查看「云端历史」'), findsOneWidget);
    });
  });
}

class _HistoryApiAdapter implements HttpClientAdapter {
  /// /user/history 按调用次序弹出的响应队列
  List<Map<String, dynamic>> historyResponses = [
    {
      'status': 1,
      'data': {
        'list': [
          {'hash': 'h1', 'filename': '云歌一', 'timestamp': 1700000000},
          {'hash': 'h2', 'filename': '云歌二', 'timestamp': 1700086400},
        ],
      },
    },
  ];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    if (path == '/user/history') {
      if (historyResponses.isNotEmpty) {
        return _json(historyResponses.removeAt(0));
      }
      return _json(
        const {
          'status': 1,
          'data': {'list': []},
        },
      );
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
