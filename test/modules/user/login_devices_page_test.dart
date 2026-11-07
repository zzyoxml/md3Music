import 'dart:convert';

// 页面用 material_ui 的 Scaffold/AppBar（其本地化检查认自家类型），
// 测试宿主必须同样用 material_ui 的 MaterialApp 提供配对的 MaterialLocalizations
// （不 import flutter/material，让 MaterialApp 解析到 material_ui 的同名类）。
import 'package:material_ui/material_ui.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/modules/user/login_devices_page.dart';
import 'package:md3music/modules/user/user_center_page.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';

import '../../test_helpers/fake_secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late KugouApiClient client;
  late _DeviceApiAdapter adapter;
  late KugouProvider provider;
  late List<String> toasts;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    client = KugouApiClient();
    adapter = _DeviceApiAdapter();
    client.dio.httpClientAdapter = adapter;
    final generation = KugouApiClient.markServerStarting();
    KugouApiClient.markServerReady(generation);
    await client.clearCookies();
    toasts = _installToastMock();
    provider = KugouProvider(registerDeviceOnStart: false);
  });

  tearDown(() {
    provider.dispose();
    uninstallFakeSecureStorage();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<KugouProvider>.value(
        value: provider,
        child: const MaterialApp(home: LoginDevicesPage()),
      ),
    );
    // initState 异步取数：首帧 loading（M3ELoadingIndicator 是常驻动画，
    // 不能 pumpAndSettle），下一拍进入数据/错误态
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  /// 未登录的排在前：单例 client 的登录态会被后续用例的 setLoginCookies 改写
  testWidgets('未登录时显示提示且不发请求', (tester) async {
    await pumpPage(tester);

    expect(find.text('当前未登录，请先登录后再管理设备'), findsOneWidget);
    expect(adapter.deviceFetches, 0);
  });

  group('已登录', () {
    setUp(() async {
      await client.setLoginCookies('token-abc', '10086');
      // 页面门控读的是 Provider 的 isLoggedIn（非 client 的），
      // 需要 refreshUserInfo 把 client 登录态同步进 Provider
      await provider.refreshUserInfo();
    });

    testWidgets('渲染摘要、本机标记与移除按钮', (tester) async {
      await pumpPage(tester);

      expect(find.text('当前账号已登录 2 台设备'), findsOneWidget);
      // 本机行：标题 + 本机 tag，且不出现移除按钮
      expect(find.text('Xiaomi 15'), findsOneWidget);
      expect(find.text('本机'), findsOneWidget);
      // 远端行：标题、新设备 tag、移除按钮、详情行
      expect(find.text('iPad'), findsOneWidget);
      expect(find.text('新设备'), findsOneWidget);
      expect(find.text('移除'), findsOneWidget);
      expect(find.text('扫码 · iPad'), findsOneWidget);
      expect(find.textContaining('活跃于 2024-01-02 03:04'), findsOneWidget);
      expect(find.text('手机 · 酷狗概念版'), findsOneWidget);
    });

    testWidgets('移除需确认，确认后带四元组请求并刷新列表', (tester) async {
      await pumpPage(tester);

      await tester.tap(find.text('移除'));
      await tester.pump();
      expect(find.text('移除登录设备'), findsOneWidget);
      expect(find.text('移除「iPad」后，该设备需要重新登录。'), findsOneWidget);

      await tester.tap(find.text('确认移除'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      // fluttertoast 内部有 1s Future.delayed，不排干会报 Timer is still pending
      await tester.pump(const Duration(seconds: 2));

      expect(adapter.kickQueries, hasLength(1));
      expect(adapter.kickQueries.first['t_mid'], 'MID-B');
      expect(adapter.kickQueries.first['t'], _DeviceApiAdapter.kickTime);
      expect(adapter.kickQueries.first['t_appid'], '3116');
      expect(adapter.kickQueries.first['t_clientver'], '10597');
      expect(toasts, contains('已移除「iPad」'));
      // kick 成功后自动刷新（初次加载 1 次 + 刷新 1 次）
      expect(adapter.deviceFetches, 2);
      // 刷新后该设备已不在列表 → 空态
      expect(find.text('暂无登录设备记录'), findsOneWidget);
    });

    testWidgets('业务失败（token 失效）显示错误态与重试', (tester) async {
      adapter.deviceResponse = const {
        'status': 0,
        'error_code': 20010,
        'msg': '请先登录',
      };
      await pumpPage(tester);

      expect(find.text('获取登录设备失败，登录状态可能已失效'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);

      adapter.deviceResponse = const {
        'status': 1,
        'local_device': {'mid': 'MID-A', 'dfid': 'DFID-A'},
        'data': {
          'li': [
            {
              'mid': 'MID-A',
              'mt': 'DFID-A',
              'dev': 'Xiaomi 15',
              'app': '酷狗概念版',
              't': '50',
              'ver': '10597',
              'appid': '3116',
              'new': '0',
              'login_type': 1,
            },
          ],
        },
      };
      await tester.tap(find.text('重试'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('当前账号已登录 1 台设备'), findsOneWidget);
    });
  });

  group('账号管理托盘入口', () {
    setUp(() async {
      await client.setLoginCookies('token-abc', '10086');
      await provider.refreshUserInfo();
    });

    testWidgets('托盘内出现「登录设备管理」入口，点按进入设备页', (tester) async {
      // 默认 800x600 视口下 sheet 内容会溢出屏幕底部（入口 tile 在 y≈650 不可点），
      // 拉高测试表面让面板内容完整落进视口
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      adapter.detailData = const {'nickname': '测试用户', 'userid': '10086'};
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<KugouProvider>.value(value: provider),
            // ScrollAwareAppBar 会 watch ThemeProvider 与 TabConfigProvider
            ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
            ChangeNotifierProvider<TabConfigProvider>(
              create: (_) => TabConfigProvider(),
            ),
          ],
          child: const MaterialApp(home: UserCenterPage()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 点用户卡片打开「账号管理」底部面板
      await tester.tap(find.text('测试用户'));
      await tester.pump();
      // m3e 面板入场是弹簧动画，pump(长间隔)只渲染一帧、面板停在半途
      // （实测 title 悬在 y≈1300/1400，内容整体落在视口外），必须逐帧推进到落定
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 33));
      }

      expect(find.text('账号管理'), findsOneWidget);
      expect(find.text('登录设备管理'), findsOneWidget);
      expect(find.text('登录新账号'), findsOneWidget);

      // 点入口 → rootNavigator 推入设备管理页
      await tester.tap(find.text('登录设备管理'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(LoginDevicesPage), findsOneWidget);
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

class _DeviceApiAdapter implements HttpClientAdapter {
  /// 与响应里远端设备 t 相同的时间串（供 kick 四元组与活跃时间断言）。
  /// 用本地时区构造，断言与跑测试的机器时区无关。
  static final String kickTime =
      (DateTime(2024, 1, 2, 3, 4).millisecondsSinceEpoch ~/ 1000).toString();

  /// 本机设备的更早活跃时间（与远端区分开，断言按行唯一匹配）
  static final String currentDeviceTime =
      (DateTime(2024, 1, 2, 3, 4).millisecondsSinceEpoch ~/ 1000 - 3600)
          .toString();

  /// /login/device 的响应体（测试可改写）
  Map<String, dynamic> deviceResponse = _defaultDeviceResponse();

  static Map<String, dynamic> _defaultDeviceResponse() => {
        'status': 1,
        'local_device': {'mid': 'MID-A', 'dfid': 'DFID-A'},
        'data': {
          'li': [
            {
              'mid': 'MID-A',
              'mt': 'DFID-A',
              'dev': 'Xiaomi 15',
              'app': '酷狗概念版',
              'loc': '广东省深圳市 联通',
              't': currentDeviceTime,
              'ver': '10597',
              'appid': '3116',
              'new': '0',
              'login_type': 1,
            },
            {
              'mid': 'MID-B',
              'mt': 'DFID-B',
              'dev': 'iPad',
              'app': 'iPad',
              'loc': '广东省深圳市 联通',
              't': kickTime,
              'ver': '10597',
              'appid': '3116',
              'new': kickTime,
              'login_type': 6,
            },
          ],
        },
      };

  /// kick 发生过之后，设备列表按“该设备已下线”返回空列表（模拟真实行为）
  Map<String, dynamic> get _effectiveDeviceResponse =>
      kickQueries.isEmpty ? deviceResponse : _emptyAfterKick;

  static const Map<String, dynamic> _emptyAfterKick = {
    'status': 1,
    'local_device': {'mid': 'MID-A', 'dfid': 'DFID-A'},
    'data': {'li': []},
  };

  int deviceFetches = 0;
  final List<Map<String, String>> kickQueries = [];

  /// /user/detail 的 data 段（托盘入口测试用，控制昵称展示）
  Map<String, dynamic> detailData = const {};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    if (path == '/login/device') {
      deviceFetches++;
      return _json(_effectiveDeviceResponse);
    }
    if (path == '/login/device/kick') {
      kickQueries.add(
        options.uri.queryParameters.map((k, v) => MapEntry(k, v)),
      );
      return _json(const {'status': 1, 'error_code': 0});
    }
    if (path == '/user/detail') {
      return _json({'status': 1, 'error_code': 0, 'data': detailData});
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
