import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/core/services/login_expiry_monitor.dart';
import 'package:md3music/data/models/kugou_account.dart';
import 'package:md3music/main.dart' show appNavigatorKey;
import 'package:md3music/providers/kugou_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 后台登录态检查的行为约束：
/// - 首帧 attach 后满 10 分钟才首次检查，刚打开 app 不检查（不误弹）；
/// - 只有「确定已过期」才提示，且同一账号只弹一次；
/// - 无网络/未知结果不弹窗；
/// - 当天登录过的账号全天不弹窗。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  tearDown(() => LoginExpiryMonitor.instance.detach());

  Future<void> pumpApp(WidgetTester tester, _FakeKugouProvider kugou) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<KugouProvider>.value(value: kugou),
        ],
        child: MaterialApp(
          navigatorKey: appNavigatorKey,
          home: const Scaffold(body: Text('根页面')),
        ),
      ),
    );
    await tester.pump();
  }

  void installToastMock() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('PonnamKarthik/fluttertoast'),
      (call) async => null,
    );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('PonnamKarthik/fluttertoast'),
        null,
      );
    });
  }

  testWidgets('刚打开不检查：未满 10 分钟不调用 check，也不弹窗', (tester) async {
    final kugou = _FakeKugouProvider();
    addTearDown(kugou.dispose);
    installToastMock();
    await pumpApp(tester, kugou);

    LoginExpiryMonitor.instance.attach();
    await tester.pump(const Duration(minutes: 9));
    expect(kugou.checkCalls, 0);
    expect(find.text('登录已过期'), findsNothing);

    // 满 10 分钟才触发首次检查；结束后 detach 取消周期定时器，避免 pending timer。
    await tester.pump(const Duration(minutes: 1));
    await tester.pump(Duration.zero);
    expect(kugou.checkCalls, 1);
    LoginExpiryMonitor.instance.detach();
  });

  testWidgets('确定过期才弹窗且只弹一次；无网络不弹', (tester) async {
    final kugou = _FakeKugouProvider();
    addTearDown(kugou.dispose);
    installToastMock();
    await pumpApp(tester, kugou);

    LoginExpiryMonitor.instance.attach();

    // t=10min：未知（无网络）→ 不弹窗
    kugou.expiredResult = null;
    await tester.pump(LoginExpiryMonitor.checkInterval);
    await tester.pumpAndSettle();
    expect(kugou.checkCalls, 1);
    expect(find.text('登录已过期'), findsNothing);

    // t=20min：确定过期 → 弹窗一次
    kugou.expiredResult = true;
    await tester.pump(LoginExpiryMonitor.checkInterval);
    // check() 是 async（await checkCurrentTokenExpired），需要多 pump 几帧让弹窗落地。
    for (var i = 0; i < 5; i++) {
      await tester.pump(Duration.zero);
    }
    await tester.pumpAndSettle();
    expect(kugou.checkCalls, 2);
    expect(find.text('登录已过期'), findsOneWidget);

    // 用户暂不处理：下一个周期不再重复弹窗
    await tester.pump(LoginExpiryMonitor.checkInterval);
    await tester.pumpAndSettle();
    expect(find.text('登录已过期'), findsOneWidget);
    LoginExpiryMonitor.instance.detach();
  });

  testWidgets('当天重新登录过：即使之后检测到过期也不弹窗', (tester) async {
    final kugou = _FakeKugouProvider();
    addTearDown(kugou.dispose);
    installToastMock();
    // 模拟用户当天刚登录（epoch 秒），随后 token 失效。
    final today = DateTime.now();
    final loginTime = DateTime(today.year, today.month, today.day, 8)
        .millisecondsSinceEpoch ~/ 1000;
    kugou._accounts[0] = kugou._accounts[0].copyWith(loginTime: loginTime);
    await pumpApp(tester, kugou);

    LoginExpiryMonitor.instance.attach();
    kugou.expiredResult = true;
    await tester.pump(LoginExpiryMonitor.checkInterval);
    await tester.pumpAndSettle();

    // 当天登录过：不检查、不弹窗，避免刚登录后误打扰。
    expect(kugou.checkCalls, 0);
    expect(find.text('登录已过期'), findsNothing);
    LoginExpiryMonitor.instance.detach();
  });
}

class _FakeKugouProvider extends KugouProvider {
  _FakeKugouProvider() : super(registerDeviceOnStart: false);

  final List<KugouAccount> _accounts = [
    KugouAccount(userid: 'u1', nickname: '用户一', loginTime: 1),
  ];

  bool? expiredResult;
  int checkCalls = 0;

  @override
  bool get isLoggedIn => true;

  @override
  String? get userid => 'u1';

  @override
  List<KugouAccount> get savedAccounts => _accounts;

  @override
  Future<bool> checkCurrentTokenExpired() async {
    checkCalls++;
    if (expiredResult == true) {
      _accounts[0] = _accounts[0].copyWith(expired: true);
      notifyListeners();
    }
    return expiredResult ?? false;
  }

  @override
  Future<void> removeAccount(String userid) async {}
}
