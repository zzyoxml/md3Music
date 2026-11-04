import 'dart:convert';

// 页面用 material_ui 的 Scaffold/AppBar/TabBar（其本地化检查认自家类型），
// 测试宿主必须同样用 material_ui 的 MaterialApp 提供配对的 MaterialLocalizations
// （不 import flutter/material，让 MaterialApp 解析到 material_ui 的同名类）。
import 'package:material_ui/material_ui.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/modules/user/blacklist_page.dart';
import 'package:md3music/providers/blacklist_provider.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';

import '../../test_helpers/fake_secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late KugouApiClient client;
  late _BlacklistApiAdapter adapter;
  late KugouProvider provider;
  late BlacklistProvider blacklist;
  late List<String> toasts;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    client = KugouApiClient();
    adapter = _BlacklistApiAdapter();
    client.dio.httpClientAdapter = adapter;
    final generation = KugouApiClient.markServerStarting();
    KugouApiClient.markServerReady(generation);
    await client.clearCookies();
    toasts = _installToastMock();
    provider = KugouProvider(registerDeviceOnStart: false);
    blacklist = BlacklistProvider();
  });

  tearDown(() {
    provider.dispose();
    blacklist.dispose();
    uninstallFakeSecureStorage();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<KugouProvider>.value(value: provider),
          ChangeNotifierProvider<BlacklistProvider>.value(value: blacklist),
        ],
        child: const MaterialApp(home: BlacklistPage()),
      ),
    );
    // initState postFrame 拉当前 Tab：首帧 loading（M3ELoadingIndicator 是常驻
    // 动画，不能 pumpAndSettle），下一拍进入数据/错误态
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('未登录时显示提示且不发请求', (tester) async {
    await pumpPage(tester);

    expect(find.text('当前未登录，登录后可管理黑名单'), findsOneWidget);
    expect(adapter.listQueries, isEmpty);
  });

  group('已登录', () {
    setUp(() async {
      await client.setLoginCookies('token-abc', '10086');
      // 页面门控读的是 Provider 的 isLoggedIn（非 client 的），
      // 需要 refreshUserInfo 把 client 登录态同步进 Provider
      await provider.refreshUserInfo();
    });

    testWidgets('渲染歌曲黑名单条目、Tab 计数与移除按钮', (tester) async {
      await pumpPage(tester);

      // Tab 计数在加载后出现
      expect(find.text('不感兴趣 2'), findsOneWidget);
      // 条目：名称 + 标记时间 + 移除按钮
      expect(find.text('A - SongA'), findsOneWidget);
      expect(find.text('B - SongB'), findsOneWidget);
      expect(find.text('移除'), findsNWidgets(2));
      expect(find.textContaining('标记于'), findsNWidgets(2));
      // 歌手 Tab 尚未加载：请求只发了歌曲桶
      expect(adapter.listQueries, hasLength(1));
      expect(adapter.listQueries.first['label'], 'song');
    });

    testWidgets('切到歌手 Tab 拉取 singer 桶并渲染', (tester) async {
      await pumpPage(tester);

      await tester.tap(find.text('已屏蔽歌手'));
      // TabBarView 切换动画默认 300ms，拉满时窗让动画走完、歌手桶请求落定
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 400));

      expect(adapter.listQueries, hasLength(2));
      expect(adapter.listQueries.last['label'], 'singer');
      expect(find.text('已屏蔽歌手 1'), findsOneWidget);
      expect(find.text('歌手甲'), findsOneWidget);
      expect(find.textContaining('屏蔽于'), findsOneWidget);
    });

    testWidgets('移除需确认，确认后带 isDelete 请求、toast 并刷新', (tester) async {
      await pumpPage(tester);

      await tester.tap(find.text('移除').first);
      await tester.pump();
      expect(find.text('撤销不感兴趣'), findsOneWidget);
      expect(
        find.textContaining('确定撤销对「A - SongA」的不感兴趣吗'),
        findsOneWidget,
      );

      await tester.tap(find.text('确认撤销'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      // fluttertoast 内部有 1s Future.delayed，不排干会报 Timer is still pending
      await tester.pump(const Duration(seconds: 2));

      expect(adapter.editQueries, hasLength(1));
      expect(adapter.editQueries.first['hash'], 'hash-a');
      expect(adapter.editQueries.first['isDelete'], '1');
      expect(adapter.editQueries.first['name'], 'A - SongA');
      expect(adapter.editQueries.first['mixsongid'], '111');
      expect(toasts, contains('已撤销对「A - SongA」的不感兴趣'));
      // 移除成功后 force 重拉对齐（初次 1 次 + 重拉 1 次），服务端已无 hash-a
      expect(adapter.listQueries, hasLength(2));
      expect(find.text('A - SongA'), findsNothing);
      expect(find.text('B - SongB'), findsOneWidget);
      expect(find.text('不感兴趣 1'), findsOneWidget);
    });

    testWidgets('移除取消（弹窗点取消）不发请求', (tester) async {
      await pumpPage(tester);

      await tester.tap(find.text('移除').first);
      await tester.pump();
      await tester.tap(find.text('取消'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));

      expect(adapter.editQueries, isEmpty);
      expect(find.text('A - SongA'), findsOneWidget);
    });

    testWidgets('空黑名单显示空态文案', (tester) async {
      adapter.listResponse = {
        'status': 1,
        'error_code': 0,
        'data': {
          'label': 'song',
          'page': 1,
          'pagesize': 30,
          'total': 0,
          'items': [],
        },
      };
      await pumpPage(tester);

      expect(find.text('还没有标记不感兴趣的歌曲'), findsOneWidget);
      expect(
        find.textContaining('标记后不会出现在猜你喜欢'),
        findsOneWidget,
      );
    });

    testWidgets('拉取失败显示错误态与重试', (tester) async {
      adapter.listResponse = const {
        'status': 0,
        'error_code': 20010,
        'msg': '请先登录',
      };
      await pumpPage(tester);

      expect(find.text('获取黑名单失败，请检查网络后重试'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);

      adapter.listResponse = {
        'status': 1,
        'error_code': 0,
        'data': {
          'label': 'song',
          'page': 1,
          'pagesize': 30,
          'total': 1,
          'items': [
            {
              'song_k': 'hash-a',
              'song_v': '{"n":"A - SongA","m":"111","t":"1700000000"}',
              't': 1700000000,
            },
          ],
        },
      };
      await tester.tap(find.text('重试'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('A - SongA'), findsOneWidget);
    });
  });
}

List<String> _installToastMock() {
  final toasts = <String>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('PonnamKarthik/fluttertoast'),
    (MethodCall call) async {
      if (call.method == 'showToast') {
        toasts.add(
          (call.arguments as Map<Object?, Object?>?)?['msg'] as String? ?? '',
        );
      }
      return null;
    },
  );
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('PonnamKarthik/fluttertoast'),
      null,
    );
  });
  return toasts;
}

class _BlacklistApiAdapter implements HttpClientAdapter {
  /// /blacklist/list 的歌曲桶响应（测试可改写）；歌手桶固定 1 条
  Map<String, dynamic> listResponse = {
    'status': 1,
    'error_code': 0,
    'data': {
      'label': 'song',
      'page': 1,
      'pagesize': 30,
      'total': 2,
      'items': [
        {
          'song_k': 'hash-a',
          'song_v': '{"n":"A - SongA","m":"111","t":"1700000000"}',
          't': 1700000000,
        },
        {
          'song_k': 'hash-b',
          'song_v': '{"n":"B - SongB","m":"222","t":"1700000001"}',
          't': 1700000001,
        },
      ],
    },
  };

  /// 移除发生过之后，歌曲桶按“该条目已移除”返回（模拟真实行为）
  Map<String, dynamic> get _effectiveListResponse =>
      editQueries.isEmpty ? listResponse : _afterRemove;

  static final Map<String, dynamic> _afterRemove = {
    'status': 1,
    'error_code': 0,
    'data': {
      'label': 'song',
      'page': 1,
      'pagesize': 30,
      'total': 1,
      'items': [
        {
          'song_k': 'hash-b',
          'song_v': '{"n":"B - SongB","m":"222","t":"1700000001"}',
          't': 1700000001,
        },
      ],
    },
  };

  static const Map<String, dynamic> _singerResponse = {
    'status': 1,
    'error_code': 0,
    'data': {
      'label': 'singer',
      'page': 1,
      'pagesize': 30,
      'total': 1,
      'items': [
        {
          'singer_k': '3520',
          'singer_v': '{"n":"歌手甲","t":"1700000000"}',
          't': 1700000000,
        },
      ],
    },
  };

  /// /blacklist 编辑响应体
  Map<String, dynamic> editResponse = const {
    'status': 1,
    'error_code': 0,
    'data': '操作成功',
  };

  final List<Map<String, String>> listQueries = [];
  final List<Map<String, String>> editQueries = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    if (path == '/blacklist/list') {
      listQueries.add(
        options.uri.queryParameters.map((k, v) => MapEntry(k, v)),
      );
      final label = options.uri.queryParameters['label'];
      if (label == 'singer') return _json(_singerResponse);
      return _json(_effectiveListResponse);
    }
    if (path == '/blacklist') {
      editQueries.add(
        options.uri.queryParameters.map((k, v) => MapEntry(k, v)),
      );
      return _json(editResponse);
    }
    if (path == '/user/detail') {
      return _json(const {
        'status': 1,
        'error_code': 0,
        'data': {'nickname': '测试用户', 'userid': '10086'},
      });
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
