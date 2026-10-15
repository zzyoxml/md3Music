import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/modules/user/profile_edit_page.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';

import '../../test_helpers/fake_secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late KugouApiClient client;
  late _ProfileApiAdapter adapter;
  late KugouProvider provider;
  late List<String> toasts;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    client = KugouApiClient();
    adapter = _ProfileApiAdapter();
    client.dio.httpClientAdapter = adapter;
    final generation = KugouApiClient.markServerStarting();
    KugouApiClient.markServerReady(generation);
    await client.setLoginCookies('token-abc', '10086');
    adapter.detailData = const {
      'nickname': '旧昵称',
      'signature': '旧签名',
      'sex': 1,
      'birthday': '2000-01-02',
      'province': '广东省',
      'city': '深圳市',
      'memo': '旧备注',
      'tags': ['a', 'b'],
    };
    provider = KugouProvider(registerDeviceOnStart: false);
    await provider.refreshUserInfo();
    toasts = _installToastMock();
  });

  tearDown(() {
    provider.dispose();
    uninstallFakeSecureStorage();
  });

  Future<void> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<KugouProvider>.value(
        value: provider,
        child: MaterialApp(home: const _RouteHost()),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-profile-edit')));
    await tester.pump();
  }

  /// ListView 懒构建：视口外的孩子不存在，先滚到可见再断言/交互
  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    if (finder.evaluate().isNotEmpty) return;
    await tester.scrollUntilVisible(
      finder,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
  }

  Future<void> tapSave(WidgetTester tester) async {
    await scrollTo(tester, find.text('保存'));
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pump();
    // fluttertoast 内部有 1s Future.delayed，不排干会报 Timer is still pending
    await tester.pump(const Duration(seconds: 2));
  }

  testWidgets('页面按用户信息预填各字段', (tester) async {
    await pumpHost(tester);

    expect(_textFieldValue(tester, 0), '旧昵称');
    expect(find.text('旧签名'), findsOneWidget);
    // 性别默认选中「男」（sex=1）
    expect(
      find.byWidgetPredicate(
        (w) => w is SegmentedButton<int> && w.selected.contains(1),
      ),
      findsOneWidget,
    );
    // 生日行显示模型换算后的 yyyy-MM-dd
    expect(find.text('2000-01-02'), findsOneWidget);
    // 往下滚动后再断言远端字段（懒列表滚动到深处会卸载顶部孩子）
    await scrollTo(tester, find.text('广东省'));
    expect(find.text('广东省'), findsOneWidget);
    expect(find.text('深圳市'), findsOneWidget);
    await scrollTo(tester, find.text('旧备注'));
    expect(find.text('旧备注'), findsOneWidget);
    await scrollTo(tester, find.text('a,b'));
    expect(find.text('a,b'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('保存只提交有变化的字段', (tester) async {
    await pumpHost(tester);

    await tester.enterText(find.byType(TextField).first, '新昵称');
    await tapSave(tester);

    expect(adapter.updateBodies, hasLength(1));
    expect(adapter.updateBodies.first, {'nickname': '新昵称'});
    expect(toasts, contains('资料已更新'));
  });

  testWidgets('资料没有变化时不发请求', (tester) async {
    await pumpHost(tester);

    await tapSave(tester);

    expect(adapter.updateBodies, isEmpty);
    expect(toasts, contains('资料没有变化'));
  });

  testWidgets('昵称清空后保存被拦截', (tester) async {
    await pumpHost(tester);

    await tester.enterText(find.byType(TextField).first, '');
    await tapSave(tester);

    expect(adapter.updateBodies, isEmpty);
    expect(toasts, contains('昵称不能为空'));
  });

  testWidgets('服务端业务失败时 toast 提示 msg 且不退出页面', (tester) async {
    adapter.updateResponse = const {'status': 0, 'error_code': 1, 'msg': '昵称含敏感词'};
    await pumpHost(tester);

    await tester.enterText(find.byType(TextField).first, '新昵称');
    await tapSave(tester);

    expect(toasts, contains('昵称含敏感词'));
    expect(find.byType(ProfileEditPage), findsOneWidget);
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

String _textFieldValue(WidgetTester tester, int index) {
  final widget = tester.widget<TextField>(find.byType(TextField).at(index));
  return widget.controller?.text ?? '';
}

class _RouteHost extends StatefulWidget {
  const _RouteHost();

  @override
  State<_RouteHost> createState() => _RouteHostState();
}

class _RouteHostState extends State<_RouteHost> {
  bool _showEdit = false;

  @override
  Widget build(BuildContext context) => _showEdit
      ? const ProfileEditPage()
      : Scaffold(
          body: Center(
            child: ElevatedButton(
              key: const ValueKey('open-profile-edit'),
              onPressed: () => setState(() => _showEdit = true),
              child: const Text('打开编辑资料'),
            ),
          ),
        );
}

class _ProfileApiAdapter implements HttpClientAdapter {
  /// /user/detail 的 data 段（测试可改写）
  Map<String, dynamic> detailData = const {};

  /// 捕获到的 /user/update 请求体
  final List<Map<String, dynamic>> updateBodies = [];

  Map<String, dynamic> updateResponse = const {'status': 1, 'error_code': 0};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    if (path == '/user/update') {
      final raw = await _readBody(options, requestStream);
      updateBodies.add(
        jsonDecode(utf8.decode(raw)) as Map<String, dynamic>,
      );
      return _json(updateResponse);
    }
    if (path == '/user/detail') {
      return _json({'status': 1, 'error_code': 0, 'data': detailData});
    }
    return _json(const {});
  }

  Future<List<int>> _readBody(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
  ) async {
    if (requestStream != null) {
      final chunks = await requestStream.toList();
      return [for (final c in chunks) ...c];
    }
    final data = options.data;
    if (data is String) return utf8.encode(data);
    return const [];
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
