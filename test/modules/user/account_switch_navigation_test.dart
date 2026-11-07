import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/data/models/kugou_account.dart';
import 'package:md3music/modules/user/user_center_page.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeKugouProvider kugou;
  late _FakeFavoritesProvider favorites;
  late GlobalKey<NavigatorState> nestedNavigatorKey;
  late List<String> toasts;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    kugou = _FakeKugouProvider();
    favorites = _FakeFavoritesProvider();
    nestedNavigatorKey = GlobalKey<NavigatorState>();
    toasts = _installToastMock();
  });

  tearDown(() {
    kugou.dispose();
    favorites.dispose();
  });

  Future<void> pumpNestedPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<KugouProvider>.value(value: kugou),
          ChangeNotifierProvider<FavoritesProvider>.value(value: favorites),
          ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
          ChangeNotifierProvider<TabConfigProvider>(
            create: (_) => TabConfigProvider(),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                const Text('根页面仍在'),
                Expanded(
                  child: Navigator(
                    key: nestedNavigatorKey,
                    onGenerateRoute: (_) => MaterialPageRoute<void>(
                      builder: (_) => const UserCenterPage(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> openAccountSheet(WidgetTester tester) async {
    await tester.tap(find.text('测试用户'));
    await tester.pump();
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 33));
    }
    expect(find.text('账号管理'), findsOneWidget);
  }

  Future<void> confirmSwitch(WidgetTester tester) async {
    await tester.tap(find.text('目标账号'));
    await tester.pump();
    expect(find.text('切换账号'), findsOneWidget);
    await tester.tap(find.text('切换'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 700));
  }

  Future<void> pumpRouteAnimations(WidgetTester tester) async {
    // M3E 底部面板使用逐帧积分的弹簧动画，大间隔单帧 pump 不会推进到结束态。
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 33));
    }
  }

  testWidgets('嵌套导航中切换成功关闭账号面板但保留用户中心和根页面', (
    tester,
  ) async {
    await pumpNestedPage(tester);
    await openAccountSheet(tester);
    await confirmSwitch(tester);
    await pumpRouteAnimations(tester);

    expect(kugou.switchCalls, 1);
    expect(find.text('根页面仍在'), findsOneWidget);
    expect(find.byType(UserCenterPage), findsOneWidget);
    expect(find.text('账号管理'), findsNothing);
    expect(favorites.loadCalls, 1);
    expect(toasts, contains('已切换到 目标账号'));
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('切换等待期间手动关闭面板，完成后不误弹其他路由', (
    tester,
  ) async {
    final pendingSwitch = Completer<SwitchAccountResult>();
    kugou.switchResult = pendingSwitch.future;
    await pumpNestedPage(tester);
    await openAccountSheet(tester);
    await confirmSwitch(tester);
    expect(find.text('账号管理'), findsOneWidget);

    // 面板挂在嵌套 Navigator；模拟用户在请求等待期间主动关闭它。
    nestedNavigatorKey.currentState!.pop();
    await pumpRouteAnimations(tester);
    expect(find.text('账号管理'), findsNothing);
    pendingSwitch.complete(SwitchAccountResult.success);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('根页面仍在'), findsOneWidget);
    expect(find.byType(UserCenterPage), findsOneWidget);
    expect(find.text('账号管理'), findsNothing);
    expect(favorites.loadCalls, 1);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('切换后 token 过期时稳定的用户中心 context 显示引导', (
    tester,
  ) async {
    kugou.switchResult = Future.value(SwitchAccountResult.tokenExpired);
    await pumpNestedPage(tester);
    await openAccountSheet(tester);
    await confirmSwitch(tester);

    expect(find.text('根页面仍在'), findsOneWidget);
    expect(find.byType(UserCenterPage), findsOneWidget);
    expect(find.text('账号管理'), findsNothing);
    expect(find.text('登录已过期'), findsOneWidget);
    expect(find.textContaining('登录状态已过期'), findsOneWidget);

    // 收尾引导，避免留下模态路由/异步动作。
    await tester.tap(find.text('删除该账号'));
    await pumpRouteAnimations(tester);
    expect(find.text('登录已过期'), findsNothing);
    expect(find.text('账号管理'), findsNothing);
  });
}

class _FakeKugouProvider extends KugouProvider {
  _FakeKugouProvider() : super(registerDeviceOnStart: false);

  final _accounts = [
    KugouAccount(userid: 'current', nickname: '测试用户', loginTime: 2),
    KugouAccount(userid: 'target', nickname: '目标账号', loginTime: 1),
  ];
  Future<SwitchAccountResult>? switchResult;
  int switchCalls = 0;

  @override
  bool get isLoggedIn => true;

  @override
  String? get userid => 'current';

  @override
  KugouUserDetail? get userInfo =>
      const KugouUserDetail(userid: 'current', nickname: '测试用户');

  @override
  List<KugouAccount> get savedAccounts => _accounts;

  @override
  Future<SwitchAccountResult> switchAccount(String userid) {
    switchCalls++;
    return switchResult ?? Future.value(SwitchAccountResult.success);
  }

  @override
  Future<void> refreshUserInfo() async {}

  @override
  Future<void> getVipDetail() async {}

  @override
  Future<void> getVipMonthRecord() async {}

  @override
  Future<bool> getGradeInfo() async => false;

  @override
  Future<void> removeAccount(String userid) async {}
}

class _FakeFavoritesProvider extends FavoritesProvider {
  _FakeFavoritesProvider() : super(syncOnStart: false);

  int loadCalls = 0;

  @override
  Future<void> loadFavorites() async {
    loadCalls++;
  }
}

List<String> _installToastMock() {
  final messages = <String>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('PonnamKarthik/fluttertoast'),
    (call) async {
      if (call.method == 'showToast') {
        messages.add(
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
  return messages;
}
