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
import 'package:md3music/modules/user/listen_stats_page.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/providers/listen_stats_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/local_favorites_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';

import '../../test_helpers/fake_secure_storage.dart';

/// 统计页数据源 = 云端播放历史（/user/history）聚合派生。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late KugouApiClient client;
  late _StatsApiAdapter adapter;
  late KugouProvider kugou;
  late ListenStatsProvider stats;
  late PlayerProvider player;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    client = KugouApiClient();
    adapter = _StatsApiAdapter();
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
        child: const MaterialApp(home: ListenStatsPage()),
      ),
    );
    // initState 拉历史 + 等级；M3ELoadingIndicator 常驻动画，固定拍数推进
    // 注意：总览卡数字计数动画（400ms）与柱状图/进度条交错入场（最长
    // 延迟 600ms + 400ms ≈ 1000ms）都在数据到达、页面重建后才启动，
    // pump 窗口必须覆盖到全部动画收敛，否则断言终值文本（"15 次"）会拿到
    // 动画中间值而失败。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
  }

  testWidgets('未登录：显示登录提示（provider 不门控请求，页面门控展示）',
      (tester) async {
    await pumpPage(tester);

    expect(find.text('登录后可查看听歌统计'), findsOneWidget);
  });

  group('已登录', () {
    setUp(() async {
      await client.setLoginCookies('token-abc', '10086');
      await kugou.refreshUserInfo();
    });

    testWidgets('渲染 4 卡总览 + 时间维度图 + 榜单 + 专辑 banner', (tester) async {
      await pumpPage(tester);

      // 4 卡总览（labels）
      expect(find.text('累计听歌'), findsOneWidget);
      expect(find.text('听歌等级'), findsOneWidget);
      expect(find.text('本周播放'), findsOneWidget);
      expect(find.text('累计播放'), findsOneWidget);
      // 次数合计：本周 10+5=15，累计 15+40=55（pc 累计口径）
      expect(find.text('15 次'), findsOneWidget);
      expect(find.text('55 次'), findsOneWidget);
      // 时间维度（历史条目带 ot → 柱状图与时段出现）
      expect(find.text('最近 7 天'), findsOneWidget);
      expect(find.text('时段偏好'), findsOneWidget);
      expect(find.textContaining('时间维度基于最近 3 条'), findsOneWidget);
      // 榜单
      expect(find.text('常听歌手'), findsOneWidget);
      expect(find.text('歌手C'), findsOneWidget);
      expect(find.text('歌手A'), findsOneWidget);
      expect(find.text('高频歌曲'), findsOneWidget);
      // 40 次同时出现在歌手行（歌手C）与高频歌曲行（总歌三），故 ≥1
      expect(find.text('40次'), findsWidgets);
      // 专辑 banner（专辑二 = 40 > 专辑一 10+5）
      expect(find.text('最常回访专辑'), findsOneWidget);
      expect(find.text('专辑二'), findsOneWidget);
      expect(find.text('40次 · 1首'), findsOneWidget);
    });

    testWidgets('历史无时间戳：时间维度区块降级隐藏', (tester) async {
      adapter.historyResponse = {
        'status': 1,
        'data': {
          'songs': [
            {
              'mxid': 1,
              'pc': 1,
              'info': {
                'name': '云歌一',
                'singername': '歌手A',
                'hash': 'h-nostamp',
                'timelen': 200000,
              },
            },
          ],
        },
      };
      await pumpPage(tester);

      expect(find.text('最近 7 天'), findsNothing);
      expect(find.text('时段偏好'), findsNothing);
      // 榜单不受影响
      expect(find.text('常听歌手'), findsOneWidget);
    });
  });
}

/// /user/history 的 Dio adapter mock（实机确认结构：songs[] + 嵌套 info{} + pc/ot）。
class _StatsApiAdapter implements HttpClientAdapter {
  final List<Map<String, String>> historyQueries = [];

  static int _secsAgo(int seconds) =>
      DateTime.now().millisecondsSinceEpoch ~/ 1000 - seconds;

  static Map<String, dynamic> _item(
    String hash,
    String name,
    String artist,
    String album,
    int pc,
    int ot,
  ) =>
      {
        'mxid': hash.hashCode & 0x7fffffff,
        'ot': ot,
        'pc': pc,
        'op': 1,
        'info': {
          'name': name,
          'singername': artist,
          'album_name': album,
          'hash': hash,
          'timelen': 200000,
        },
      };

  Map<String, dynamic> historyResponse = {
    'status': 1,
    'error_code': 0,
    'data': {
      'songs': [
        _item('w1', '周歌一', '歌手A', '专辑一', 10, _secsAgo(3600)),
        _item('w2', '周歌二', '歌手B', '专辑一', 5, _secsAgo(7200)),
        _item('t3', '总歌三', '歌手C', '专辑二', 40, _secsAgo(9 * 86400)),
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
      return _json(historyResponse);
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
