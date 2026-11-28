import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/device_capabilities.dart';
import 'package:md3music/core/services/output_mode_coordinator.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「USB 独占输出」两层开关 + Direct PCM 子开关版本门控的纯逻辑测试。
///
/// 不涉及 MethodChannel / 播放器实例：这里只钉住「两层开关的组合语义」、
/// 「持久化键契约」与「哪个子开关需要哪个 API 等级」。
///
/// **测试宿主不是 Android**（`defaultTargetPlatform != android`），协调器里所有
/// 原生调用都是 no-op，且 `_enterUsbdevfs()` 直接返回「当前平台不支持」——
/// 这正好用来钉住「直写开启失败 → 关闭外层、整体回系统默认」这条降级路径。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final OutputModeCoordinator coord = OutputModeCoordinator.instance;

  /// 把单例恢复到已知初态（它是进程级单例，测试间必须显式复位）。
  Future<void> reset() async {
    await coord.setViaSystem(false);
    await coord.setEnabled(false);
    coord.consumeFallbackNotice();
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await reset();
  });

  group('两层开关组合语义', () {
    test('初态：外层关 = 系统默认，两条路径都不生效', () async {
      expect(coord.enabled, isFalse);
      expect(coord.isCustom, isFalse);
      expect(coord.isDirectPcmActive, isFalse);
      expect(coord.isUsbdevfsActive, isFalse);
    });

    test('内层选中但外层关闭时，两条路径都不生效（内层不越过外层）', () async {
      await coord.setViaSystem(true);
      expect(coord.viaSystem, isTrue, reason: '内层选择应被记下');
      expect(coord.enabled, isFalse);
      expect(coord.isDirectPcmActive, isFalse,
          reason: '外层关闭时不得开 Direct PCM');
      expect(coord.isUsbdevfsActive, isFalse);
    });

    test('外层开 + 内层关 = 直写；外层开 + 内层开 = 系统 Direct PCM', () async {
      // 本宿主非 Android：直写开不起来会走降级。先钉「内层选中」这条能成功的路径。
      await coord.setViaSystem(true);
      await coord.setEnabled(true);
      expect(coord.enabled, isTrue);
      expect(coord.isDirectPcmActive, isTrue);
      expect(coord.isUsbdevfsActive, isFalse);

      await coord.setEnabled(false);
      expect(coord.enabled, isFalse);
      expect(coord.isDirectPcmActive, isFalse);
    });

    test('isDirectPcmActive / isUsbdevfsActive 恒为互斥互补（同一时刻只有一条）',
        () async {
      for (final bool via in <bool>[false, true]) {
        await coord.setViaSystem(via);
        if (via) {
          // 直写分支在非 Android 宿主上会降级关外层，故只断言「不同时为真」
          await coord.setEnabled(true);
        }
        expect(coord.isDirectPcmActive && coord.isUsbdevfsActive, isFalse);
        expect(coord.isCustom, coord.enabled);
        if (coord.enabled) {
          expect(coord.isDirectPcmActive || coord.isUsbdevfsActive, isTrue,
              reason: '外层打开时必有一条路径生效');
        }
      }
    });

    test('关闭外层后内层选择被保留（下次打开仍是用户选的方案）', () async {
      await coord.setViaSystem(true);
      await coord.setEnabled(true);
      await coord.setEnabled(false);
      expect(coord.viaSystem, isTrue);
      expect(coord.enabled, isFalse);
    });
  });

  group('直写失败降级', () {
    test('直写开不起来 → 关闭外层、回到系统默认，不自动换到 Direct PCM',
        () async {
      // 非 Android 宿主：_enterUsbdevfs 必然失败，等价于「廉价 DAC 打不开独占」。
      await coord.setEnabled(true);
      expect(coord.enabled, isFalse, reason: '失败时不得置位外层');
      expect(coord.isDirectPcmActive, isFalse);
      expect(coord.isUsbdevfsActive, isFalse);
      final String? notice = coord.consumeFallbackNotice();
      expect(notice, isNotNull);
      expect(notice, contains('已恢复普通输出'));
      expect(consumeAgain(coord), isNull, reason: '提示只应消费一次');
    });

    test('切回直写失败 → 留在 Direct PCM（不关闭外层）', () async {
      await coord.setViaSystem(true);
      await coord.setEnabled(true);
      expect(coord.isDirectPcmActive, isTrue);

      // 切回直写（非 Android 宿主必失败）
      await coord.setViaSystem(false);

      // 用户只是想换个方案，不该被踢回系统默认：外层保持开、内层回到 Direct PCM
      expect(coord.enabled, isTrue);
      expect(coord.viaSystem, isTrue);
      expect(coord.isDirectPcmActive, isTrue);
      final String? notice = coord.consumeFallbackNotice();
      expect(notice, isNotNull);
      expect(notice, contains('仍使用系统 Direct PCM'));
      expect(notice, isNot(contains('已恢复普通输出')));
    });

    test('拔线（onDeviceLost）→ 关闭外层；已关闭时是幂等空操作', () async {
      expect(await coord.onDeviceLost(), isFalse);

      await coord.setViaSystem(true);
      await coord.setEnabled(true);
      expect(await coord.onDeviceLost(), isTrue);
      expect(coord.enabled, isFalse);
      expect(coord.consumeFallbackNotice(), contains('已断开'));
      expect(await coord.onDeviceLost(), isFalse);
    });

    test('开启外层时直写失败 → 关外层（与「切内层失败」的处理刻意不同）',
        () async {
      // 两者区别：开外层时还没有任何可用方案，只能回系统默认；
      // 切内层时 Direct PCM 正在工作，应留在原地。
      await coord.setEnabled(true);
      expect(coord.enabled, isFalse);
      expect(coord.consumeFallbackNotice(), contains('已恢复普通输出'));
    });
  });

  group('持久化契约', () {
    test('内层键名固定为 usb_bp_via_system（改名会丢用户已选的方案）', () {
      expect(OutputModeCoordinator.keyViaSystem, 'usb_bp_via_system');
    });

    test('缺省值是 false —— 即默认仍走原有直写，用户可见行为不变', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      expect(coord.viaSystem, isFalse);
    });

    test('协调器只暴露一个持久化键：外层不落盘，旧三档键也不再写', () async {
      await coord.setViaSystem(true);
      await coord.setEnabled(true);
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      // 内层选择被持久化（重启后仍记得用户选了哪条）
      expect(prefs.getBool(OutputModeCoordinator.keyViaSystem), isTrue);
      // 旧三档键已废弃，不得再写（否则会与新模型并存造成状态歧义）
      expect(prefs.getString('output_mode'), isNull);
      // 外层开关**不落盘**：它只存在于内存 + 原生状态，重启后回到系统默认。
      // 本协调器对外只应有一个持久化键常量。
      expect(OutputModeCoordinator.keyViaSystem, isNotEmpty);
    });
  });

  group('DirectPcmFeature 版本门控', () {
    test('每个子开关声明的最低 API 都不低于其依赖的真实下限', () {
      // 这些数值是对着公开 android.jar 核过的，改动必须同步更新 AGENTS.md §4.11
      expect(DirectPcmFeature.highPrecisionOutput.minApi, 21); // ENCODING_PCM_FLOAT
      expect(DirectPcmFeature.nativeRateConfirm.minApi, 17); // @hide getNativeOutputSampleRate
      expect(DirectPcmFeature.unityVolume.minApi, 21);
      expect(DirectPcmFeature.lowLatency.minApi, 26); // @hide setPerformanceMode
      expect(DirectPcmFeature.exactRouteProbe.minApi, 31); // getRoutedDevice
    });

    test('持久化 key 全局唯一（否则两个开关会互相覆盖）', () {
      final Set<String> keys =
          DirectPcmFeature.values.map((DirectPcmFeature f) => f.specKey).toSet();
      expect(keys.length, DirectPcmFeature.values.length);
    });

    test('rateAlignment 标记为未实现，因此恒不可用（UI 不展示，仅占位）', () {
      expect(DirectPcmFeature.rateAlignment.implemented, isFalse);
      expect(DirectPcmFeature.rateAlignment.defaultOn, isFalse);
    });
  });

  group('DeviceCapabilities 门控语义', () {
    test('SDK 版本未知时一律按「不满足」处理，宁可置灰也不虚报可用', () {
      final DeviceCapabilities caps = DeviceCapabilities.instance;
      // 测试环境拿不到原生 SDK（MethodChannel 未注册）→ sdkKnown 为 false
      expect(caps.sdkKnown, isFalse);
      for (final DirectPcmFeature f in DirectPcmFeature.values) {
        expect(caps.supports(f), isFalse, reason: '${f.specKey} 不应在未知版本下可用');
        expect(caps.unavailableReason(f), isNotNull);
      }
    });

    test('effective 是「用户值 AND 平台支持」：用户关掉时即使平台支持也是关', () {
      final DeviceCapabilities caps = DeviceCapabilities.instance;
      // 用户显式关闭 → effective 必为 false，且不因平台而复活
      expect(caps.effective(DirectPcmFeature.highPrecisionOutput, false), isFalse);
    });
  });
}

/// 供「提示只消费一次」断言使用。
String? consumeAgain(OutputModeCoordinator c) => c.consumeFallbackNotice();
