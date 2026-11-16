import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/car_with_service.dart';
// 与服务同源：本仓库的 ThemeMode 是 material_ui 的枚举（不是 flutter/material
// 那套同名不同类型），断言必须用同一套常量。
import 'package:material_ui/material_ui.dart' show ThemeMode;
import 'package:shared_preferences/shared_preferences.dart';

/// CarWithService 单测：全部走可注入的假读数函数 / 假平台门，不依赖真机。
///
/// 计时用 FakeAsync（心跳是 2s 常驻 Timer，真时钟等不起）；持久化用
/// shared_preferences 官方 mock（键名带插件自动加的 `flutter.` 前缀）。
/// 每个 fakeAsync 用例结尾必须 dispose：FakeAsync 在 body 返回时若仍挂
/// Timer 会报 pending-timers，这同时兜住「dispose 必须取消心跳」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  // 与跨端契约逐字一致的持久化键。shared_preferences 的 `flutter.` 前缀由
  // 插件读写两侧自动处理（setMockInitialValues 的种子也按原始键名给，
  // 本仓库既有测试同款写法），落盘才是 flutter.settings_... 。
  const followKey = 'settings_follow_carwith_dark';
  const lyricKey = 'settings_carwith_lyric_enabled';

  CarWithService makeService(
    FakeNative native, {
    bool supports = true,
  }) {
    final s = CarWithService.forTest();
    s.supportsCarWithOverride = () => supports;
    s.stateReaderOverride = native.snapshot;
    return s;
  }

  group('themeOverride 真值表（规格 §一）', () {
    test('1 没勾跟随CarWith：连着+车机深色仍为 null', () {
      fakeAsync((async) {
        final native = FakeNative(connected: true, night: 1);
        final s = makeService(native);
        s.start();
        async.flushMicrotasks();
        s.updateSystemDark(true);
        async.elapse(const Duration(seconds: 6));
        expect(s.followDarkEnabled, isFalse);
        expect(s.themeOverride, isNull);
        expect(native.reads, 0, reason: '未勾选不读原生（验收点 §九-2）');
        s.dispose();
      });
    });

    test('2 勾了但没连着车机：null（回到用户选的那档）', () {
      fakeAsync((async) {
        final native = FakeNative(connected: false, night: 0);
        final s = makeService(native);
        SharedPreferences.setMockInitialValues(<String, Object>{followKey: true});
        s.start();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 6));
        expect(s.followDarkEnabled, isTrue);
        expect(s.connected, isFalse);
        expect(s.themeOverride, isNull);
        s.dispose();
      });
    });

    test('3 连着 + 车机报深色(1) → dark', () {
      fakeAsync((async) {
        final native = FakeNative(connected: true, night: 1);
        final s = makeService(native);
        SharedPreferences.setMockInitialValues(<String, Object>{followKey: true});
        s.start();
        async.flushMicrotasks();
        expect(s.themeOverride, ThemeMode.dark);
        expect(native.reads, 1, reason: '勾着开关时 start 当场即起心跳并读一轮');
        s.dispose();
      });
    });

    test('4 连着 + 车机浅色(0) 但手机系统深色 → dark', () {
      fakeAsync((async) {
        final native = FakeNative(connected: true, night: 0);
        final s = makeService(native);
        SharedPreferences.setMockInitialValues(<String, Object>{followKey: true});
        s.start();
        async.flushMicrotasks();
        expect(s.themeOverride, ThemeMode.light);
        s.updateSystemDark(true);
        expect(s.themeOverride, ThemeMode.dark);
        s.dispose();
      });
    });

    test('5 连着 + 两边都不报深色 → light', () {
      fakeAsync((async) {
        final native = FakeNative(connected: true, night: 0);
        final s = makeService(native);
        SharedPreferences.setMockInitialValues(<String, Object>{followKey: true});
        s.start();
        async.flushMicrotasks();
        s.updateSystemDark(false);
        expect(s.themeOverride, ThemeMode.light);
        s.dispose();
      });
    });

    test('5b 连着 + 车机读不到(-1) 且系统浅色 → light（-1 属"不报深色"）', () {
      fakeAsync((async) {
        final native = FakeNative(connected: true, night: -1);
        final s = makeService(native);
        SharedPreferences.setMockInitialValues(<String, Object>{followKey: true});
        s.start();
        async.flushMicrotasks();
        s.updateSystemDark(false);
        expect(s.themeOverride, ThemeMode.light);
        s.dispose();
      });
    });

    test('6 断开时 nightMode 不采信：残留 1 不得产出 dark', () {
      fakeAsync((async) {
        final native = FakeNative(connected: true, night: 1);
        final s = makeService(native);
        SharedPreferences.setMockInitialValues(<String, Object>{followKey: true});
        s.start();
        async.flushMicrotasks();
        expect(s.themeOverride, ThemeMode.dark);
        // 车机断开：nightMode 不会清零（契约），connected=false 必须压住它
        native.connected = false;
        async.elapse(const Duration(seconds: 2));
        expect(s.connected, isFalse);
        expect(s.nightMode, 1, reason: '断开时 nightMode 保留最近读数');
        expect(s.themeOverride, isNull);
        s.dispose();
      });
    });
  });

  group('心跳（2 秒一轮）', () {
    test('7 follow 勾着且支持平台：2s 周期持续读原生', () {
      fakeAsync((async) {
        final native = FakeNative(connected: true, night: 1);
        final s = makeService(native);
        SharedPreferences.setMockInitialValues(<String, Object>{followKey: true});
        s.start();
        async.flushMicrotasks();
        expect(native.reads, 1);
        async.elapse(const Duration(seconds: 6));
        // 当场 1 次 + 2s/4s/6s 各 1 次
        expect(native.reads, 4);
        s.dispose();
      });
    });

    test('8 两把开关都没勾：不建心跳、一次原生都不读（§九-2 验收点）', () {
      fakeAsync((async) {
        final native = FakeNative(connected: true, night: 1);
        final s = makeService(native);
        s.start();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 10));
        expect(native.reads, 0);
        s.dispose();
      });
    });

    test('9 只有 lyric 勾着：不跑常驻心跳（取舍见服务内注释）', () {
      fakeAsync((async) {
        final native = FakeNative(connected: true, night: 0);
        final s = makeService(native);
        SharedPreferences.setMockInitialValues(<String, Object>{lyricKey: true});
        s.start();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 10));
        expect(native.reads, 0, reason: '歌词快照靠回前台补一轮 + 推送时原生现读');
        expect(s.lyricEnabled, isTrue);
        s.dispose();
      });
    });

    test('10 只有 lyric 勾着时 refreshNow 补读一轮', () {
      fakeAsync((async) {
        final native = FakeNative(connected: true, night: 0);
        final s = makeService(native);
        SharedPreferences.setMockInitialValues(<String, Object>{lyricKey: true});
        s.start();
        async.flushMicrotasks();
        s.refreshNow();
        async.flushMicrotasks();
        expect(native.reads, 1);
        s.dispose();
      });
    });

    test('11 两把都没勾时 refreshNow 不读原生', () {
      fakeAsync((async) {
        final native = FakeNative();
        final s = makeService(native);
        s.start();
        async.flushMicrotasks();
        s.refreshNow();
        async.flushMicrotasks();
        expect(native.reads, 0);
        s.dispose();
      });
    });

    test('12 平台不支持（桌面/TV）：勾着 follow 也不建心跳、不读原生', () {
      fakeAsync((async) {
        final native = FakeNative(connected: true, night: 1);
        final s = makeService(native, supports: false);
        SharedPreferences.setMockInitialValues(<String, Object>{followKey: true});
        s.start();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 10));
        expect(native.reads, 0);
        s.dispose();
      });
    });

    test('13 setFollowDarkEnabled(true) 当场立即读一轮', () {
      fakeAsync((async) {
        final native = FakeNative(connected: true, night: 1);
        final s = makeService(native);
        s.start();
        async.flushMicrotasks();
        expect(native.reads, 0);
        s.setFollowDarkEnabled(true);
        async.flushMicrotasks();
        expect(native.reads, 1);
        expect(s.themeOverride, ThemeMode.dark);
        s.dispose();
      });
    });

    test('14 取消勾选后停心跳：读数不再增长', () {
      fakeAsync((async) {
        final native = FakeNative(connected: true, night: 1);
        final s = makeService(native);
        SharedPreferences.setMockInitialValues(<String, Object>{followKey: true});
        s.start();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 6));
        final before = native.reads;
        expect(before, greaterThan(0));
        s.setFollowDarkEnabled(false);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 10));
        expect(native.reads, before);
        expect(s.themeOverride, isNull);
        s.dispose();
      });
    });

    test('15 dispose 取消心跳', () {
      fakeAsync((async) {
        final native = FakeNative(connected: true, night: 1);
        final s = makeService(native);
        SharedPreferences.setMockInitialValues(<String, Object>{followKey: true});
        s.start();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 2));
        final before = native.reads;
        s.dispose();
        async.elapse(const Duration(seconds: 10));
        expect(native.reads, before);
      });
    });

    test('16 start 幂等：重复调用不产生第二个心跳', () {
      fakeAsync((async) {
        final native = FakeNative(connected: true, night: 1);
        final s = makeService(native);
        SharedPreferences.setMockInitialValues(<String, Object>{followKey: true});
        s.start();
        s.start();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 6));
        expect(native.reads, 4);
        s.dispose();
      });
    });
  });

  group('翻转上报（notify 只在 themeOverride 真变化时）', () {
    test('17 连续同值心跳不重复 notify', () {
      fakeAsync((async) {
        final native = FakeNative(connected: true, night: 1);
        final s = makeService(native);
        SharedPreferences.setMockInitialValues(<String, Object>{followKey: true});
        var notifies = 0;
        s.addListener(() => notifies++);
        s.start();
        async.flushMicrotasks();
        expect(notifies, 1, reason: 'null→dark 是真翻转');
        async.elapse(const Duration(seconds: 10));
        expect(native.reads, greaterThan(3), reason: '心跳确实在跑');
        expect(notifies, 1, reason: '值没变不得再 notify（重建敏感）');
        s.dispose();
      });
    });

    test('18 车机深色→浅色翻 light：恰好一次 notify', () {
      fakeAsync((async) {
        final native = FakeNative(connected: true, night: 1);
        final s = makeService(native);
        SharedPreferences.setMockInitialValues(<String, Object>{followKey: true});
        var notifies = 0;
        s.addListener(() => notifies++);
        s.start();
        async.flushMicrotasks();
        expect(notifies, 1);
        native.night = 0;
        async.elapse(const Duration(seconds: 2));
        expect(s.themeOverride, ThemeMode.light);
        expect(notifies, 2);
        s.dispose();
      });
    });

    test('19 未连接时勾选开关：覆盖值没变（恒 null）不 notify', () {
      fakeAsync((async) {
        final native = FakeNative(connected: false, night: 0);
        final s = makeService(native);
        var notifies = 0;
        s.addListener(() => notifies++);
        s.start();
        async.flushMicrotasks();
        s.setFollowDarkEnabled(true);
        async.flushMicrotasks();
        expect(s.themeOverride, isNull);
        expect(notifies, 0);
        s.dispose();
      });
    });

    test('20 updateSystemDark 同值喂入不 notify', () {
      fakeAsync((async) {
        final native = FakeNative(connected: false, night: 0);
        final s = makeService(native);
        var notifies = 0;
        s.addListener(() => notifies++);
        s.start();
        async.flushMicrotasks();
        s.updateSystemDark(false);
        s.updateSystemDark(false);
        expect(notifies, 0);
        s.dispose();
      });
    });
  });

  group('持久化键名逐字（契约 §3）', () {
    test('21 start 从 prefs 恢复两把开关', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        followKey: true,
        lyricKey: true,
      });
      final native = FakeNative();
      final s = makeService(native, supports: false);
      await s.start();
      expect(s.followDarkEnabled, isTrue);
      expect(s.lyricEnabled, isTrue);
      s.dispose();
    });

    test('22 setter 落盘到契约键名', () async {
      final native = FakeNative();
      final s = makeService(native, supports: false);
      await s.start();
      await s.setFollowDarkEnabled(true);
      await s.setLyricEnabled(true);
      // prefs.getBool 查的是剥掉 flutter. 前缀后的缓存键 == 契约键名本身，
      // 命中即证明写入路径用的就是这两个字面量（前缀由插件自动处理）。
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(followKey), isTrue);
      expect(prefs.getBool(lyricKey), isTrue);
      s.dispose();
    });

    test('23 默认未勾选', () async {
      final native = FakeNative();
      final s = makeService(native, supports: false);
      await s.start();
      expect(s.followDarkEnabled, isFalse);
      expect(s.lyricEnabled, isFalse);
      s.dispose();
    });
  });

  group('读数异常兜底（Dart 侧 try/catch，契约 §1）', () {
    test('24 读数抛异常：按未连接处理，不崩', () {
      fakeAsync((async) {
        final native = FakeNative(connected: true, night: 1)
          ..throwOnRead = true;
        final s = makeService(native);
        SharedPreferences.setMockInitialValues(<String, Object>{followKey: true});
        s.start();
        async.flushMicrotasks();
        expect(s.connected, isFalse);
        expect(s.nightMode, -1);
        expect(s.themeOverride, isNull);
        s.dispose();
      });
    });

    test('25 脏返回一律视为未连接/读不到', () {
      fakeAsync((async) {
        // connected 非 bool → 未连接
        final s1 = CarWithService.forTest();
        s1.supportsCarWithOverride = () => true;
        s1.stateReaderOverride = () async => <Object?, Object?>{
          'connected': 1,
          'nightMode': 1,
        };
        SharedPreferences.setMockInitialValues(<String, Object>{followKey: true});
        s1.start();
        async.flushMicrotasks();
        expect(s1.connected, isFalse);
        expect(s1.themeOverride, isNull);
        s1.dispose();

        // nightMode 非 int → 按读不到处理；connected 正常
        final s2 = CarWithService.forTest();
        s2.supportsCarWithOverride = () => true;
        s2.stateReaderOverride = () async => <Object?, Object?>{
          'connected': true,
          'nightMode': 'x',
        };
        s2.start();
        async.flushMicrotasks();
        expect(s2.connected, isTrue);
        expect(s2.nightMode, -1);
        s2.updateSystemDark(false);
        expect(s2.themeOverride, ThemeMode.light);
        s2.dispose();
      });
    });

    test('26 真实通道缺失（MissingPluginException，TV/桌面/单测）按未连接', () {
      fakeAsync((async) {
        // 不注入 stateReaderOverride：走真实 MethodChannel。测试绑定下没有
        // com.md3music.md3music/car_with 的 mock handler → MissingPluginException。
        final s = CarWithService.forTest();
        s.supportsCarWithOverride = () => true;
        SharedPreferences.setMockInitialValues(<String, Object>{followKey: true});
        s.start();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 6));
        expect(s.connected, isFalse);
        expect(s.themeOverride, isNull);
        s.dispose();
      });
    });

    test('27 快照内容翻转后 nightMode getter 反映最近读数', () {
      fakeAsync((async) {
        final native = FakeNative(connected: true, night: 0);
        final s = makeService(native);
        SharedPreferences.setMockInitialValues(<String, Object>{followKey: true});
        s.start();
        async.flushMicrotasks();
        expect(s.nightMode, 0);
        native.night = 1;
        async.elapse(const Duration(seconds: 2));
        expect(s.nightMode, 1);
        s.dispose();
      });
    });
  });
}

/// 假原生读数：与跨端契约同形（`{'connected': bool, 'nightMode': int}`）。
class FakeNative {
  FakeNative({bool? connected, int? night})
    : _connected = connected ?? false,
      _night = night ?? -1;

  bool _connected;
  int _night;
  int reads = 0;
  bool throwOnRead = false;

  set connected(bool v) => _connected = v;
  set night(int v) => _night = v;

  Future<Map<Object?, Object?>?> snapshot() async {
    reads++;
    if (throwOnRead) {
      throw PlatformException(code: 'read_failed');
    }
    return <Object?, Object?>{'connected': _connected, 'nightMode': _night};
  }
}
