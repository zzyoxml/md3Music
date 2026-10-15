import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/core/layout/responsive_layout.dart';
import 'package:md3music/data/repositories/settings_repository.dart';
import 'package:md3music/providers/device_provider.dart';

/// 底栏优化批次 5b —— 悬浮播放器折叠态停靠位（dock）的「Pad 默认分支」缺口测试。
///
/// 生产落点（app.dart 的 `_AppViewState._loadSecondaryPlayerDock`）：
/// ```dart
/// final raw = await SettingsRepository().getSecondaryPlayerDockRaw();
/// final side = SecondaryPlayerDockSide.tryParse(raw) ??
///     (isPadLayout(context) ? SecondaryPlayerDockSide.right : SecondaryPlayerDockSide.center);
/// if (kSecondaryPlayerDock.value != side) kSecondaryPlayerDock.value = side;
/// ```
/// 即：**已落盘值优先；未落盘（raw=null 或非法）时按设备形态取默认（手机 center /
/// Pad right），且默认值不回写持久化**。
///
/// 可测性边界（如实记录）：`_loadSecondaryPlayerDock` 是 app.dart 私有 State 的
/// 方法，pump 它需要整个 app 的 provider/MethodChannel 引导，widget 测试不可行。
/// 因此本文件把该式的三个**公开构件**逐个钉死，作为「可控的最小闭环」：
/// 1. `SecondaryPlayerDockSide.tryParse` —— raw 合法即短路默认分支（落盘值优先）；
/// 2. `SettingsRepository` 的 dock 原始值读写 —— 「未落盘」的可判定口径（getString 为 null）；
/// 3. `isPadLayout(context)` —— Pad 默认 right 的判定输入（auto 按最短边 ≥600 /
///    强制档直接服从用户选择）。
/// 三段合起来即 `_loadSecondaryPlayerDock` 的全部决策依赖；「Pad 下默认 right 且不
/// 落盘」这一步本身仍需真机（或生产码将来提供可注入点）才能端到端断言。
/// 等 [DeviceProvider] 构造期 fire-and-forget 的 `_load()` 落地。
///
/// **不能**写 `await Future<void>.delayed(...)`：`testWidgets` 跑在 FakeAsync 区，
/// 那里创建的 Timer 归假时钟所有、永不触发——实测表现为整条用例 did not complete，
/// 且 `--timeout` 同样不生效（假时钟连超时定时器一起冻住），会拽住整个测试套件。
/// [WidgetTester.pump] 推进的正是假时钟，同时冲刷 `_load()` 的微任务链。
Future<void> _settleDeviceLoad(WidgetTester tester) =>
    tester.pump(const Duration(milliseconds: 50));

void main() {
  // 进程启动瞬间取初值：本文件是该 notifier 在本测试进程里的首个触碰方。
  final SecondaryPlayerDockSide dockInitial = kSecondaryPlayerDock.value;

  // dock 原始值的持久化 key（与 SettingsRepository 私有常量 `_keySecondaryPlayerDock`
  // 一致；该常量不对外暴露，改名时以失败用例报警）。
  const dockRawKey = 'settings_secondary_player_dock';

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('落盘值优先（tryParse 短路默认分支）', () {
    test('三个合法 name 均能解析为对应档位', () {
      expect(SecondaryPlayerDockSide.tryParse('left'), SecondaryPlayerDockSide.left);
      expect(
        SecondaryPlayerDockSide.tryParse('center'),
        SecondaryPlayerDockSide.center,
      );
      expect(SecondaryPlayerDockSide.tryParse('right'), SecondaryPlayerDockSide.right);
    });
  });

  group('未落盘口径（默认分支的触发条件）', () {
    test('未持久化过时 raw 为 null，tryParse(null) 返回 null → 调用方取设备默认', () async {
      final raw = await SettingsRepository().getSecondaryPlayerDockRaw();
      expect(raw, isNull, reason: 'getString 未命中 = 「从没设置过」的判定口径');
      expect(SecondaryPlayerDockSide.tryParse(raw), isNull,
          reason: 'null 时 ?? 右侧生效，落到 Pad/Phone 默认');
    });

    test('落盘往返：setSecondaryPlayerDockRaw(name) 后读回同名并可解析', () async {
      await SettingsRepository().setSecondaryPlayerDockRaw(
        SecondaryPlayerDockSide.right.name,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(dockRawKey), 'right');
      final raw = await SettingsRepository().getSecondaryPlayerDockRaw();
      expect(SecondaryPlayerDockSide.tryParse(raw), SecondaryPlayerDockSide.right,
          reason: '已落盘的 right 优先于任何设备默认');

      // 手机上落盘 left：读回仍是 left（默认分支被 ?? 左侧短路）。
      await SettingsRepository().setSecondaryPlayerDockRaw(
        SecondaryPlayerDockSide.left.name,
      );
      expect(
        SecondaryPlayerDockSide.tryParse(
          await SettingsRepository().getSecondaryPlayerDockRaw(),
        ),
        SecondaryPlayerDockSide.left,
      );
    });

    test('非法字符串（大小写不符 / 乱值 / 空串）解析为 null，回落默认而不崩溃', () {
      expect(SecondaryPlayerDockSide.tryParse('CENTER'), isNull, reason: '按 name 精确匹配，大小写敏感');
      expect(SecondaryPlayerDockSide.tryParse('up'), isNull);
      expect(SecondaryPlayerDockSide.tryParse(''), isNull);
    });

    test('kSecondaryPlayerDock 启动初值为 center（与手机默认同值；Pad 默认靠装载覆写，不落盘）', () {
      expect(dockInitial, SecondaryPlayerDockSide.center,
          reason: '未落盘且未装载时，UI 按初值（手机默认）渲染；'
              'Pad 的 right 默认由 _loadSecondaryPlayerDock 覆写 notifier，'
              '不写回持久化（见该方法的 ?? 默认分支）。');
    });
  });

  group('Pad 默认分支的判定输入（isPadLayout）', () {
    // 在真实 widget 树里取 context 调 isPadLayout（它经 `context.read<DeviceProvider>`
    // + `MediaQuery.sizeOf` 判定，不能在树外伪造）。
    //
    // 用显式 MediaQuery 注入逻辑视口（size 即「有效视口」，与「显示大小」调整后
    // 的口径同型），比操纵 tester.view 更贴近 isPadLayout 实际读取的数据源。
    Future<bool> probe(
      WidgetTester tester, {
      required Size logical,
      required DeviceProvider device,
    }) async {
      bool? result;
      await tester.pumpWidget(
        ChangeNotifierProvider<DeviceProvider>.value(
          value: device,
          child: MediaQuery(
            data: MediaQueryData(size: logical),
            child: Builder(
              builder: (context) {
                result = isPadLayout(context);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      return result!;
    }

    testWidgets('auto + 400×800（最短边 400 < 600）→ 手机布局，默认 center', (tester) async {
      final device = DeviceProvider();
      expect(await probe(tester, logical: const Size(400, 800), device: device), isFalse);
    });

    testWidgets('auto + 700×800（最短边 700 ≥ 600）→ Pad 布局，默认 right 的触发条件成立', (tester) async {
      final device = DeviceProvider();
      expect(await probe(tester, logical: const Size(700, 800), device: device), isTrue);
    });

    testWidgets('auto + 横置手机 800×400 → 仍按手机（判定量是最短边，不是当前宽）', (tester) async {
      final device = DeviceProvider();
      expect(await probe(tester, logical: const Size(800, 400), device: device), isFalse);
    });

    testWidgets('用户强制选 Pad：窄视口也判 Pad（默认分支同样取 right）', (tester) async {
      // 经持久化预置 device_type=pad（index 2），避免与 DeviceProvider 构造期的
      // 异步 _load 竞态。
      SharedPreferences.setMockInitialValues(<String, Object>{
        'device_type': DeviceType.pad.index,
      });
      final device = DeviceProvider();
      await _settleDeviceLoad(tester);
      expect(device.deviceType, DeviceType.pad, reason: '_load 已落地，不会再覆回 auto');
      expect(await probe(tester, logical: const Size(400, 800), device: device), isTrue);
    });

    testWidgets('用户强制选手机：大屏视口也判手机（默认分支取 center）', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'device_type': DeviceType.phone.index,
      });
      final device = DeviceProvider();
      await _settleDeviceLoad(tester);
      expect(device.deviceType, DeviceType.phone);
      expect(await probe(tester, logical: const Size(900, 1200), device: device), isFalse);
    });
  });
}
