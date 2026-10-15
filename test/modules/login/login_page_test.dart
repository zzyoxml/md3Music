// 页面用 material_ui 的 Scaffold/AppBar（其本地化检查认自家类型），
// 测试宿主必须同样用 material_ui 的 MaterialApp 提供配对的 MaterialLocalizations
// （不 import flutter/material，让 MaterialApp/TextField 解析到 material_ui 的同名类）。
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/modules/login/login_page.dart';
import 'package:md3music/providers/car_mode_provider.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';

import '../../test_helpers/fake_secure_storage.dart';

/// 只桩掉网络相关方法，其余走真实 Provider
class _StubKugouProvider extends KugouProvider {
  _StubKugouProvider() : super(registerDeviceOnStart: false);

  int captchaCalls = 0;
  final List<(String, String)> loginCalls = [];
  PhoneLoginResult nextLoginResult = const PhoneLoginResult(
    PhoneLoginStatus.success,
  );

  @override
  Future<void> generateQrCode() async {}

  @override
  Future<int?> checkQrCode() async => 1;

  @override
  Future<bool> sendLoginCaptcha(String mobile) async {
    captchaCalls++;
    return true;
  }

  @override
  Future<PhoneLoginResult> loginByPhone(String mobile, String code) async {
    loginCalls.add((mobile, code));
    return nextLoginResult;
  }
}

/// 兜底拦截单例 client 的真实请求（登录成功收尾的收藏同步会发出，
/// 不拦截会因 dio 15s 超时在 fake clock 下留下 pending Timer 导致用例失败）
class _EmptyApiAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      jsonEncode(const {'status': 0}),
      200,
      headers: const {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _StubKugouProvider provider;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    final client = KugouApiClient();
    client.dio.httpClientAdapter = _EmptyApiAdapter();
    final generation = KugouApiClient.markServerStarting();
    KugouApiClient.markServerReady(generation);
    await client.clearCookies();
    provider = _StubKugouProvider();
  });

  tearDown(() {
    provider.dispose();
    uninstallFakeSecureStorage();
  });

  Future<void> pumpPhoneTab(WidgetTester tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          // CarModePanelSuppressor 的 initState 会 read 它
          ChangeNotifierProvider<CarModeProvider>(
            create: (_) => CarModeProvider(),
          ),
          ChangeNotifierProvider<KugouProvider>.value(value: provider),
          // 登录成功收尾会 read FavoritesProvider 同步「我喜欢的」
          ChangeNotifierProvider<FavoritesProvider>(
            create: (_) => FavoritesProvider(syncOnStart: false),
          ),
        ],
        child: const MaterialApp(home: LoginPage()),
      ),
    );
    // initState postFrame → _initLogin（默认二维码 Tab）
    await tester.pump();
    // 切到「手机」Tab（label/icon 在 label 交叉淡入动画里渲染两份但位置重叠，
    // 取 .first 点按即命中同一按钮；无常驻动画，两拍即落定）
    await tester.tap(find.byIcon(Icons.phone_android).first);
    await tester.pump();
    await tester.pump();
  }

  Finder fieldFinder(String label) => find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == label,
      );

  testWidgets('发送验证码成功后焦点自动落到验证码框', (tester) async {
    await pumpPhoneTab(tester);

    await tester.enterText(fieldFinder('手机号'), '13800138000');
    await tester.pump();

    await tester.tap(find.text('发送'));
    await tester.pump();
    await tester.pump();

    expect(provider.captchaCalls, 1);
    final codeFocus = tester.widget<TextField>(fieldFinder('验证码')).focusNode!;
    expect(codeFocus.hasFocus, isTrue);
    expect(FocusManager.instance.primaryFocus, codeFocus);
    expect(find.text('验证码已发送'), findsOneWidget);

    // 排干 60s 倒计时 Timer
    await tester.pump(const Duration(seconds: 61));
  });

  testWidgets('输满 6 位验证码自动触发登录并走成功收尾', (tester) async {
    await pumpPhoneTab(tester);

    await tester.enterText(fieldFinder('手机号'), '13800138000');
    await tester.enterText(fieldFinder('验证码'), '123456');
    await tester.pump();
    // 登录成功收尾有 800ms 延迟后 pop，排干避免 Timer is still pending
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump();

    expect(provider.loginCalls, hasLength(1));
    expect(provider.loginCalls.first, ('13800138000', '123456'));
    expect(find.text('登录成功！'), findsOneWidget);
  });

  testWidgets('验证码未输满 6 位不自动触发登录', (tester) async {
    await pumpPhoneTab(tester);

    await tester.enterText(fieldFinder('手机号'), '13800138000');
    await tester.enterText(fieldFinder('验证码'), '12345');
    await tester.pump();

    expect(provider.loginCalls, isEmpty);
  });
}
