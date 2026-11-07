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
import 'package:md3music/services/kugou_api/kugou_models.dart';

import '../../test_helpers/fake_secure_storage.dart';

/// 只桩掉网络相关方法，其余走真实 Provider
class _StubKugouProvider extends KugouProvider {
  _StubKugouProvider() : super(registerDeviceOnStart: false);

  int captchaCalls = 0;
  final List<(String, String)> loginCalls = [];
  PhoneLoginResult nextLoginResult = const PhoneLoginResult(
    PhoneLoginStatus.success,
  );

  // ---- 微信 / QQ 扫码桩 ----

  /// 1x1 PNG，够 Image.memory 解码即可。
  static const String kQrBase64 =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

  int wxCreateCalls = 0;
  int qqCreateCalls = 0;
  int wxCheckCalls = 0;
  int qqCheckCalls = 0;

  /// 每次 check 依次返回的结果；用完后重复最后一个。
  List<WxScanResult> wxResults = const [
    WxScanResult(WxScanKind.waiting, message: '等待扫描...'),
  ];
  List<QqScanResult> qqResults = const [
    QqScanResult(QqScanKind.waiting, message: '等待 QQ 扫码...'),
  ];

  /// completeThirdPartyLogin 的调用记录。
  final List<(String, String)> completedLogins = [];

  KugouWxQrSession? wxSession = const KugouWxQrSession(
    uuid: 'wx-uuid-1',
    imageBase64: kQrBase64,
  );
  KugouQqQrSession? qqSession = const KugouQqQrSession(
    imageBase64: kQrBase64,
    qrsig: 'qrsig-1',
    ptqrtoken: 123456,
    ptLoginSig: 'sig-1',
    ptOpenloginData: 'openlogin-1',
    xloginUrl: 'https://xui.ptlogin2.qq.com/cgi-bin/xlogin?appid=1',
    cookie: 'qrsig=qrsig-1',
  );

  @override
  Future<void> generateQrCode() async {}

  @override
  Future<int?> checkQrCode() async => 1;

  @override
  Future<KugouWxQrSession?> createWxLoginQr() async {
    wxCreateCalls++;
    return wxSession;
  }

  @override
  Future<WxScanResult> checkWxLogin(String uuid) async {
    wxCheckCalls++;
    return wxResults[(wxCheckCalls - 1).clamp(0, wxResults.length - 1)];
  }

  @override
  Future<KugouQqQrSession?> createQqLoginQr() async {
    qqCreateCalls++;
    return qqSession;
  }

  @override
  Future<QqScanResult> checkQqLogin(KugouQqQrSession session) async {
    qqCheckCalls++;
    return qqResults[(qqCheckCalls - 1).clamp(0, qqResults.length - 1)];
  }

  @override
  Future<bool> completeThirdPartyLogin({
    required String token,
    required String userid,
    String? vipToken,
  }) async {
    completedLogins.add((token, userid));
    return true;
  }

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

  Future<void> pumpLoginPage(WidgetTester tester) async {
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
    // initState postFrame → _initLogin（默认酷狗扫码 Tab）
    await tester.pump();
  }

  /// 切到指定 Tab。label 在交叉淡入动画里渲染两份但位置重叠，
  /// 取 .first 点按即命中同一按钮。
  Future<void> switchTab(WidgetTester tester, String label) async {
    await tester.tap(find.text(label).first);
    await tester.pump();
    await tester.pump();
  }

  Future<void> pumpPhoneTab(WidgetTester tester) async {
    await pumpLoginPage(tester);
    await switchTab(tester, '手机');
  }

  /// 销毁页面以排干轮询 Timer（否则 testWidgets 会报 pending timer）。
  Future<void> disposePage(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
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

  testWidgets('登录页有 4 个登录方式 Tab', (tester) async {
    await pumpLoginPage(tester);

    for (final label in ['酷狗', '手机', '微信', 'QQ']) {
      expect(find.text(label), findsWidgets, reason: '缺少「$label」入口');
    }
    await disposePage(tester);
  });

  testWidgets('切到微信 Tab 会生成二维码并进入轮询', (tester) async {
    await pumpLoginPage(tester);
    await switchTab(tester, '微信');

    expect(provider.wxCreateCalls, 1);
    expect(find.text('请使用微信扫一扫'), findsOneWidget);
    expect(find.text('刷新微信二维码'), findsOneWidget);
    // 二维码图片（Image.memory）
    expect(find.byType(Image), findsWidgets);

    // 第一个 2s tick 触发一次轮询
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(provider.wxCheckCalls, 1);

    await disposePage(tester);
  });

  testWidgets('微信扫码成功：落凭证 + 提示登录成功', (tester) async {
    provider.wxResults = const [
      WxScanResult(
        WxScanKind.success,
        token: 'wx-token',
        userid: '9001',
        vipToken: 'vip-1',
      ),
    ];
    await pumpLoginPage(tester);
    await switchTab(tester, '微信');

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    // 成功收尾有 800ms 延迟后 pop
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump();

    expect(provider.completedLogins, hasLength(1));
    expect(provider.completedLogins.first, ('wx-token', '9001'));
    expect(find.text('登录成功！'), findsOneWidget);
  });

  testWidgets('微信二维码过期后停止轮询并提示', (tester) async {
    provider.wxResults = const [
      WxScanResult(WxScanKind.expired, message: '二维码已过期，请刷新重试'),
    ];
    await pumpLoginPage(tester);
    await switchTab(tester, '微信');

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.text('二维码已过期，请刷新重试'), findsOneWidget);

    // 终态后不再轮询
    await tester.pump(const Duration(seconds: 6));
    expect(provider.wxCheckCalls, 1);

    await disposePage(tester);
  });

  testWidgets('切到 QQ Tab 会生成二维码并进入轮询', (tester) async {
    await pumpLoginPage(tester);
    await switchTab(tester, 'QQ');

    expect(provider.qqCreateCalls, 1);
    expect(find.text('请使用手机 QQ 扫一扫'), findsOneWidget);
    expect(find.text('刷新 QQ 二维码'), findsOneWidget);
    // 风控提示常驻在 QQ Tab
    expect(find.textContaining('QQ 扫码受上游风控影响时可能不可用'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(provider.qqCheckCalls, 1);

    await disposePage(tester);
  });

  testWidgets('QQ 扫码成功：落凭证 + 提示登录成功', (tester) async {
    provider.qqResults = const [
      QqScanResult(
        QqScanKind.success,
        token: 'qq-token',
        userid: '8001',
      ),
    ];
    await pumpLoginPage(tester);
    await switchTab(tester, 'QQ');

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump();

    expect(provider.completedLogins, hasLength(1));
    expect(provider.completedLogins.first, ('qq-token', '8001'));
    expect(find.text('登录成功！'), findsOneWidget);
  });

  testWidgets('QQ 被上游拦截：提示且不重试', (tester) async {
    provider.qqResults = const [
      QqScanResult(
        QqScanKind.blocked,
        message: 'QQ 扫码接口被上游拦截，请稍后重试或改用微信/酷狗扫码',
      ),
    ];
    await pumpLoginPage(tester);
    await switchTab(tester, 'QQ');

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(
      find.text('QQ 扫码接口被上游拦截，请稍后重试或改用微信/酷狗扫码'),
      findsOneWidget,
    );
    expect(provider.completedLogins, isEmpty);

    // 终态后不再打上游（重试只会持续触发风控）
    await tester.pump(const Duration(seconds: 8));
    expect(provider.qqCheckCalls, 1);

    await disposePage(tester);
  });

  testWidgets('切 Tab 会取消上一 Tab 的轮询', (tester) async {
    await pumpLoginPage(tester);
    await switchTab(tester, '微信');
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    final wxCalls = provider.wxCheckCalls;
    expect(wxCalls, 1);

    await switchTab(tester, 'QQ');
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();

    // 微信侧不再增长，QQ 侧开始轮询
    expect(provider.wxCheckCalls, wxCalls);
    expect(provider.qqCheckCalls, greaterThanOrEqualTo(1));

    await disposePage(tester);
  });
}
