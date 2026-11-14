import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/search/search_page.dart';
import 'package:md3music/providers/car_mode_provider.dart';
import 'package:md3music/providers/device_provider.dart';
import 'package:md3music/providers/grid_columns_provider.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
// 页面用 material_ui 的 Scaffold/AppBar/ActionChip,其校验的是 material_ui 自家
// 的 MaterialLocalizations(与 flutter/material 同名不同型),测试容器必须与真实
// app 同款(见 explore_sections_cover_hero_test.dart 顶部说明)。
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../test_helpers/fake_secure_storage.dart';

/// 502 替身:搜索页 initState 会后台拉热搜与探索区数据,测试环境不能碰网络,
/// 让这些请求失败即可——历史区不依赖它们。
class _FailAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
        '{"status":0,"msg":"transport_error"}',
        502,
        headers: {Headers.contentTypeHeader: ['application/json']},
      );

  @override
  void close({bool force = false}) {}
}

/// fluttertoast 走 MethodChannel,内部还有 1s Future.delayed,
/// 不 mock 不排干分别会抛 MissingPluginException / 报 Timer is still pending。
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

/// SecondaryMiniPlayerHost / 音乐探索区 / PinchableGridView 所需的最小 Provider 集。
Widget _host(KugouProvider kugou) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<KugouProvider>.value(value: kugou),
      ChangeNotifierProvider<PlayerProvider>.value(value: PlayerProvider()),
      ChangeNotifierProvider<CarModeProvider>.value(value: CarModeProvider()),
      ChangeNotifierProvider<DeviceProvider>(create: (_) => DeviceProvider()),
      ChangeNotifierProvider<GridColumnsProvider>(
        create: (_) => GridColumnsProvider(),
      ),
      ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
    ],
    child: const MaterialApp(home: SearchPage()),
  );
}

Future<void> _pumpPage(WidgetTester tester) async {
  final kugou = KugouProvider(registerDeviceOnStart: false);
  addTearDown(kugou.dispose);
  await tester.pumpWidget(_host(kugou));
  // 排空 initState 的 postFrame 回调与历史加载。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpClientAdapter previous;

  setUp(() {
    previous = KugouApiClient().dio.httpClientAdapter;
    KugouApiClient().dio.httpClientAdapter = _FailAdapter();
    KugouApiClient.markServerReady(KugouApiClient.markServerStarting());
    installFakeSecureStorage();
  });

  tearDown(() {
    KugouApiClient().dio.httpClientAdapter = previous;
    uninstallFakeSecureStorage();
  });

  testWidgets('长按单条历史词条仅删除该条并持久化', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'search_history': ['周杰伦', '林俊杰'],
    });
    final toasts = _installToastMock();
    await _pumpPage(tester);

    expect(find.text('周杰伦'), findsOneWidget);
    expect(find.text('林俊杰'), findsOneWidget);

    await tester.longPress(find.text('周杰伦'));
    await tester.pump();
    // fluttertoast 内部有 1s Future.delayed,不排干会报 Timer is still pending。
    await tester.pump(const Duration(seconds: 2));

    expect(find.text('周杰伦'), findsNothing);
    expect(find.text('林俊杰'), findsOneWidget);
    expect(toasts, contains('已删除该搜索记录'));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('search_history'), ['林俊杰']);
  });

  testWidgets('清空先弹二次确认,取消不清空', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'search_history': ['周杰伦', '林俊杰'],
    });
    _installToastMock();
    await _pumpPage(tester);

    await tester.tap(find.text('清空'));
    await tester.pump();

    expect(find.text('清空搜索历史'), findsOneWidget);
    expect(find.textContaining('将删除全部 2 条搜索记录'), findsOneWidget);
    // 未确认前历史仍在;弹窗外的「清空」是段落头按钮,弹窗内的是确认键。
    expect(find.text('周杰伦'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('清空'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('周杰伦'), findsOneWidget);
    expect(find.text('林俊杰'), findsOneWidget);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('search_history'), ['周杰伦', '林俊杰']);
  });

  testWidgets('确认清空后历史全部消失并持久化', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'search_history': ['周杰伦', '林俊杰'],
    });
    final toasts = _installToastMock();
    await _pumpPage(tester);

    await tester.tap(find.text('清空'));
    await tester.pump();

    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('清空'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(find.text('周杰伦'), findsNothing);
    expect(find.text('林俊杰'), findsNothing);
    // 历史删空后整段(含清空按钮)由非空派生自动隐藏。
    expect(find.text('清空'), findsNothing);
    expect(toasts, contains('已清空搜索历史'));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('search_history'), isNull);
  });
}
