import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/core/services/lock_screen_action_service.dart';
import 'package:md3music/core/services/media_notification_service.dart';
import 'package:md3music/main.dart' show appNavigatorKey;
import 'package:md3music/modules/player/full_player_route.dart';
import 'package:md3music/providers/car_mode_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 锁屏歌词卡片「投屏 / 队列」按钮的 Dart 侧落地：
/// - `openQueue` 必须先把 [playerTabIndex] 置 0（播放列表恒为 tab 0）再打开播放页；
/// - 未知动作与「Navigator 尚未就绪」都必须静默，不能把异常抛回原生通道。
///
/// 范围说明：`openFullPlayer` 会读 `CarModeProvider` 后 push 完整播放页，
/// 本测试不构造整套 provider 树（那是播放页自己的回归测试范围）。这里让车机
/// 模式生效，使 `openFullPlayer` 按其既有语义提前返回，从而把断言限定在
/// 「tab 下标被置 0」与「不抛异常」两点，不改产品代码迁就测试。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.md3music.md3music/floating_lyric');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    playerTabIndex.value = 1;
    // attach 幂等：首次调用注册回调并拉取 pending（mock 返回 null），
    // 后续测试复用同一个已装配的回调，避免依赖用例执行顺序。
    await LockScreenActionService.instance.attach();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    playerTabIndex.value = 1;
  });

  Future<void> sendWidgetAction(String action) async {
    MediaNotificationService.initCallbacks();
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('widgetAction', action),
      ),
      (_) {},
    );
  }

  Future<void> pumpApp(WidgetTester tester, CarModeProvider carMode) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<CarModeProvider>.value(
        value: carMode,
        child: MaterialApp(
          navigatorKey: appNavigatorKey,
          home: const SizedBox.shrink(),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('openQueue 把 playerTabIndex 置 0 且不抛异常', (tester) async {
    final carMode = CarModeProvider();
    await carMode.setEnabled(true);
    addTearDown(carMode.dispose);
    await pumpApp(tester, carMode);
    expect(appNavigatorKey.currentContext, isNotNull);

    // attach 幂等：重复调用不会重复注册回调。
    await LockScreenActionService.instance.attach();
    expect(MediaNotificationService.onWidgetAction, isNotNull);

    await sendWidgetAction('openQueue');
    await tester.pump();

    expect(playerTabIndex.value, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未知动作静默丢弃且不改 tab 下标', (tester) async {
    final carMode = CarModeProvider();
    await carMode.setEnabled(true);
    addTearDown(carMode.dispose);
    await pumpApp(tester, carMode);

    await sendWidgetAction('somethingUnknown');
    await tester.pump();

    expect(playerTabIndex.value, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有 navigator 上下文时动作静默不崩溃', (tester) async {
    // 空树：appNavigatorKey 未挂载，currentContext 为 null。
    await tester.pumpWidget(const SizedBox.shrink());
    expect(appNavigatorKey.currentContext, isNull);

    await sendWidgetAction('openCast');
    await sendWidgetAction('openQueue');
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(playerTabIndex.value, 1);
  });
}
