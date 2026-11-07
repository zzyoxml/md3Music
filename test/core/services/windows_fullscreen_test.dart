// Windows 桌面「窗口全屏 + F11 → Zen」的门面测试。
//
// 覆盖三条互不相同的语义：
// 1. F11 的**归属**：播放页接管时切 Zen、不碰窗口；没人接管时退化为窗口全屏；
// 2. **快照模型**：Zen 只恢复「自己那次」全屏改变，不吞掉用户手动开的全屏；
// 3. **平台门控**：非 Windows 一律不注册、不发通道调用（防止宿主平台泄漏进测试）。
//
// `debugDefaultTargetPlatformOverride` **必须**在测试体内复位（框架在测试体结束时
// 校验 foundation debug 变量，放在 setUp/tearDown 会直接判失败），故统一走
// [_onWindows] 包一层。
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/windows_fullscreen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('md3music/window_tray');

  final calls = <String>[];
  // 原生侧的假全屏状态：mock 处理器按它回值，并随 set/toggle 变化。
  var nativeFullscreen = false;

  setUp(() {
    calls.clear();
    nativeFullscreen = false;
    WindowsFullscreen.active.value = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          switch (call.method) {
            case 'setFullscreen':
              nativeFullscreen =
                  (call.arguments as Map)['value'] as bool? ?? false;
              return nativeFullscreen;
            case 'toggleFullscreen':
              nativeFullscreen = !nativeFullscreen;
              return nativeFullscreen;
            case 'isFullscreen':
              return nativeFullscreen;
            default:
              return false;
          }
        });
  });

  tearDown(() {
    // 清掉 Zen 快照（无快照时是 no-op），避免污染后续用例。
    WindowsFullscreen.exitZen();
    WindowsFullscreen.active.value = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// 在「桌面 Windows」平台下跑 [body]，结束时复位平台覆盖。
  Future<void> onWindows(Future<void> Function() body) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  group('F11 归属', () {
    testWidgets('播放页接管时切 Zen，不发全屏通道调用', (tester) async {
      await onWindows(() async {
        var zenToggles = 0;
        final dispose = installWindowsF11Handler(
          toggleZen: () {
            zenToggles++;
            return true;
          },
        );
        addTearDown(dispose);

        await tester.sendKeyEvent(LogicalKeyboardKey.f11);
        await tester.pump();

        expect(zenToggles, 1, reason: '播放页在场时 F11 必须交给它切 Zen');
        expect(
          calls,
          isEmpty,
          reason: 'Zen 自己会调 WindowsFullscreen.enterZen()，全局层不得再切一次',
        );
      });
    });

    testWidgets('没有播放页接管时 F11 切换窗口全屏', (tester) async {
      await onWindows(() async {
        var zenToggles = 0;
        final dispose = installWindowsF11Handler(
          toggleZen: () {
            zenToggles++;
            return false;
          },
        );
        addTearDown(dispose);

        await tester.sendKeyEvent(LogicalKeyboardKey.f11);
        await tester.pump();

        expect(zenToggles, 1);
        expect(calls, ['toggleFullscreen']);
        expect(
          WindowsFullscreen.active.value,
          isTrue,
          reason: '镜像要跟随原生返回值',
        );
      });
    });

    testWidgets('非 F11 键与 KeyRepeat 不触发（长按不连翻）', (tester) async {
      await onWindows(() async {
        var zenToggles = 0;
        final dispose = installWindowsF11Handler(
          toggleZen: () {
            zenToggles++;
            return false;
          },
        );
        addTearDown(dispose);

        await tester.sendKeyEvent(LogicalKeyboardKey.f12);
        await tester.pump();
        expect(zenToggles, 0);
        expect(calls, isEmpty);

        // 按住 F11：重复事件不得再切一次（否则按住会反复进出 Zen）。
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.f11);
        await tester.pump();
        expect(zenToggles, 0);
        expect(calls, isEmpty);
      });
    });

    testWidgets('卸载后 F11 不再触发', (tester) async {
      await onWindows(() async {
        var zenToggles = 0;
        final dispose = installWindowsF11Handler(
          toggleZen: () {
            zenToggles++;
            return false;
          },
        );
        dispose();

        await tester.sendKeyEvent(LogicalKeyboardKey.f11);
        await tester.pump();
        expect(zenToggles, 0);
        expect(calls, isEmpty);
      });
    });

    testWidgets('非 Windows 平台不注册、不发通道调用', (tester) async {
      // flutter_test 默认平台是 android：不设覆盖即为「非 Windows」。
      var zenToggles = 0;
      final dispose = installWindowsF11Handler(
        toggleZen: () {
          zenToggles++;
          return false;
        },
      );
      addTearDown(dispose);

      await tester.sendKeyEvent(LogicalKeyboardKey.f11);
      await tester.pump();
      expect(zenToggles, 0);
      expect(calls, isEmpty);
      expect(WindowsFullscreen.supported, isFalse);
    });
  });

  group('Zen 全屏快照', () {
    testWidgets('进入前非全屏：进 Zen 切全屏，退 Zen 恢复', (tester) async {
      await onWindows(() async {
        WindowsFullscreen.enterZen();
        await tester.pump();
        expect(calls, ['setFullscreen']);
        expect(WindowsFullscreen.active.value, isTrue);

        WindowsFullscreen.exitZen();
        await tester.pump();
        expect(calls, ['setFullscreen', 'setFullscreen']);
        expect(WindowsFullscreen.active.value, isFalse);
      });
    });

    testWidgets('进入前已全屏：退出 Zen 保持全屏（不吞用户手动全屏）', (tester) async {
      await onWindows(() async {
        await WindowsFullscreen.setActive(true);
        calls.clear();
        expect(WindowsFullscreen.active.value, isTrue);

        WindowsFullscreen.enterZen();
        await tester.pump();
        expect(calls, isEmpty, reason: '已经全屏，Zen 不该再发一次 setFullscreen');

        WindowsFullscreen.exitZen();
        await tester.pump();
        expect(calls, isEmpty, reason: '全屏不是 Zen 开的，退出 Zen 不得关掉它');
        expect(WindowsFullscreen.active.value, isTrue);
      });
    });

    testWidgets('重复 enterZen 只记一次快照，重复 exitZen 幂等', (tester) async {
      await onWindows(() async {
        WindowsFullscreen.enterZen();
        WindowsFullscreen.enterZen();
        await tester.pump();
        expect(calls, ['setFullscreen']);

        WindowsFullscreen.exitZen();
        WindowsFullscreen.exitZen();
        await tester.pump();
        expect(calls, ['setFullscreen', 'setFullscreen']);
        expect(WindowsFullscreen.active.value, isFalse);
      });
    });

    testWidgets('显式退出一定恢复窗口（peek 的例外由播放页控制）', (tester) async {
      // 播放页 peek 期间**不**调 exitZen（窗口保持全屏），所以这里只锁「显式退出
      // 一定恢复」，防止以后有人把 exitZen 挪到 _zenMode 守卫之后。
      await onWindows(() async {
        WindowsFullscreen.enterZen();
        await tester.pump();
        WindowsFullscreen.exitZen();
        await tester.pump();
        expect(nativeFullscreen, isFalse);
      });
    });

    testWidgets('sync 用原生真实状态校正镜像', (tester) async {
      await onWindows(() async {
        nativeFullscreen = true;
        await WindowsFullscreen.sync();
        expect(calls, ['isFullscreen']);
        expect(WindowsFullscreen.active.value, isTrue);
      });
    });

    testWidgets('非 Windows 平台 setActive/toggle/sync 均不发调用', (tester) async {
      await WindowsFullscreen.setActive(true);
      await WindowsFullscreen.toggle();
      await WindowsFullscreen.sync();
      WindowsFullscreen.enterZen();
      WindowsFullscreen.exitZen();
      await tester.pump();
      expect(calls, isEmpty);
      expect(WindowsFullscreen.active.value, isFalse);
    });
  });
}
