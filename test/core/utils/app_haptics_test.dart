import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/core/utils/app_haptics.dart';

/// 「震动反馈」总开关、七类开关与七类震动类型的闸门行为。
///
/// 判定以真实通道调用为准（AGENTS.md 0.1）：关开关时必须原生震动通道和
/// flutter/platform（HapticFeedback 走的就是它）都一个调用也收不到；选类型时必须
/// 真的按所选类型下发。光看设置页的勾选/下拉状态不构成证据。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const hapticsChannel = MethodChannel('md3music/haptics');
  final nativeCalls = <MethodCall>[];
  final platformCalls = <MethodCall>[];

  Future<Object?> handleNative(MethodCall call) async {
    nativeCalls.add(call);
    // vibrate 一律回 true：模拟「原生已处理」，避免 _fire 的 300ms 超时回落
    return call.method == 'vibrate' ? true : null;
  }

  Future<Object?> handlePlatform(MethodCall call) async {
    platformCalls.add(call);
    return null;
  }

  /// 等过 _fire 的 300ms 超时回落窗口，此时若有震动必然已经发出。
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 350));

  /// 实际发出去的震动 type 序列（setSliderEnabled 是状态同步，不算震动）。
  List<String> vibratedTypes() => nativeCalls
      .where((call) => call.method == 'vibrate')
      .map((call) => (call.arguments as Map<Object?, Object?>)['type'] as String)
      .toList();

  List<MethodCall> sliderGateCalls() =>
      nativeCalls.where((call) => call.method == 'setSliderEnabled').toList();

  setUp(() {
    nativeCalls.clear();
    platformCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(hapticsChannel, handleNative);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, handlePlatform);
  });

  test('默认全开：无偏好时 load 后每一类都允许震动', () async {
    SharedPreferences.setMockInitialValues({});
    await AppHaptics.load();

    expect(AppHaptics.enabled, isTrue);
    for (final category in HapticCategory.values) {
      expect(AppHaptics.allows(category), isTrue, reason: '$category 默认应开');
      expect(AppHaptics.typeFor(category), isNull, reason: '$category 默认无类型');
    }
  });

  test('闸门开着时震动照常下发，且不重复回落', () async {
    SharedPreferences.setMockInitialValues({});
    await AppHaptics.load();
    nativeCalls.clear();

    AppHaptics.click(HapticCategory.transport);
    await settle();

    expect(vibratedTypes(), ['click']);
    // 原生成功 → 不再走 HapticFeedback，避免一次操作震两下
    expect(platformCalls, isEmpty);
  });

  test('总开关关闭：原生通道与 flutter/platform 都收不到震动', () async {
    SharedPreferences.setMockInitialValues({});
    await AppHaptics.load();
    await AppHaptics.setEnabled(false);
    nativeCalls.clear();
    platformCalls.clear();

    AppHaptics.click(HapticCategory.transport);
    AppHaptics.lightImpact(HapticCategory.control);
    AppHaptics.heavyImpact(HapticCategory.listItem);
    AppHaptics.selectionClick(HapticCategory.navigation);
    await settle();

    expect(nativeCalls, isEmpty);
    expect(platformCalls, isEmpty);
  });

  test('类别独立：关掉滑块不影响播放控制', () async {
    SharedPreferences.setMockInitialValues({'settings_haptics_slider': false});
    await AppHaptics.load();

    expect(AppHaptics.allows(HapticCategory.slider), isFalse);
    expect(AppHaptics.allows(HapticCategory.transport), isTrue);

    platformCalls.clear();
    AppHaptics.lightImpact(HapticCategory.slider);
    AppHaptics.lightImpact(HapticCategory.transport);
    await settle();

    expect(platformCalls, hasLength(1));
  });

  test('偏好持久化：类别关掉后重新 load 仍然是关', () async {
    SharedPreferences.setMockInitialValues({});
    await AppHaptics.load();
    await AppHaptics.setCategoryEnabled(HapticCategory.gesture, false);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('settings_haptics_gesture'), isFalse);
    // 只关类别时不该把总开关也写进去
    expect(prefs.getBool('settings_haptics_enabled'), isNull);

    await AppHaptics.load();
    expect(AppHaptics.isCategoryEnabled(HapticCategory.gesture), isFalse);
    expect(AppHaptics.allows(HapticCategory.gesture), isFalse);
  });

  test('悬浮播放器拖拽：默认发原生 longPress，关掉该类别后两通道都静默', () async {
    SharedPreferences.setMockInitialValues({});
    await AppHaptics.load();
    nativeCalls.clear();

    AppHaptics.longPress(HapticCategory.floatingPlayer);
    await settle();
    // 持久化键名由枚举 name 拼出（settings_haptics_floatingPlayer）：改名会静默丢掉
    // 用户已有偏好，编译期发现不了，故在这里钉住。
    expect(vibratedTypes(), ['longPress']);

    await AppHaptics.setCategoryEnabled(HapticCategory.floatingPlayer, false);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('settings_haptics_floatingPlayer'), isFalse);

    nativeCalls.clear();
    platformCalls.clear();
    AppHaptics.longPress(HapticCategory.floatingPlayer);
    await settle();
    expect(nativeCalls, isEmpty);
    expect(platformCalls, isEmpty);
  });

  test('滑块开关与类型下发原生闸门（m3e 滑条不经 Dart 封装，只能原生拦）', () async {
    SharedPreferences.setMockInitialValues({'settings_haptics_slider': false});
    await AppHaptics.load();
    expect(sliderGateCalls().last.arguments['enabled'], isFalse);

    await AppHaptics.setCategoryEnabled(HapticCategory.slider, true);
    expect(sliderGateCalls().last.arguments['enabled'], isTrue);

    await AppHaptics.setCategoryType(HapticCategory.slider, HapticType.heavy);
    expect(sliderGateCalls().last.arguments['type'], 'heavy');

    await AppHaptics.setCategoryType(HapticCategory.slider, null);
    expect(sliderGateCalls().last.arguments['type'], isNull);

    // 总开关关掉时闸门必须一起关，否则 m3e 滑条会绕过总开关继续震动
    await AppHaptics.setEnabled(false);
    expect(sliderGateCalls().last.arguments['enabled'], isFalse);
  });

  group('类别震动类型', () {
    test('默认类型下，Flutter 类触点仍只走 flutter/platform', () async {
      SharedPreferences.setMockInitialValues({});
      await AppHaptics.load();
      nativeCalls.clear();
      platformCalls.clear();

      AppHaptics.lightImpact(HapticCategory.control);
      await settle();

      expect(vibratedTypes(), isEmpty);
      expect(platformCalls, hasLength(1));
    });

    test('选定类型后，Flutter 类触点升级为原生下发', () async {
      SharedPreferences.setMockInitialValues({});
      await AppHaptics.load();
      await AppHaptics.setCategoryType(HapticCategory.control, HapticType.heavy);
      nativeCalls.clear();
      platformCalls.clear();

      AppHaptics.lightImpact(HapticCategory.control);
      await settle();

      expect(vibratedTypes(), ['heavy']);
      // 原生成功 → 不再叠加原本的 lightImpact
      expect(platformCalls, isEmpty);
    });

    test('选定类型覆盖原生类触点自己的强度', () async {
      SharedPreferences.setMockInitialValues({});
      await AppHaptics.load();
      await AppHaptics.setCategoryType(
        HapticCategory.transport,
        HapticType.longPress,
      );
      nativeCalls.clear();

      AppHaptics.click(HapticCategory.transport);
      await settle();

      expect(vibratedTypes(), ['longPress']);
    });

    test('类型互不串味：只影响所选类别', () async {
      SharedPreferences.setMockInitialValues({});
      await AppHaptics.load();
      await AppHaptics.setCategoryType(HapticCategory.listItem, HapticType.tick);
      nativeCalls.clear();

      AppHaptics.lightImpact(HapticCategory.listItem);
      AppHaptics.lightImpact(HapticCategory.navigation);
      await settle();

      // navigation 未选类型 → 走 flutter/platform，不占原生通道
      expect(vibratedTypes(), ['tick']);
      expect(platformCalls, hasLength(1));
    });

    test('类别关掉后即使选了类型也不震动', () async {
      SharedPreferences.setMockInitialValues({});
      await AppHaptics.load();
      await AppHaptics.setCategoryEnabled(HapticCategory.gesture, false);
      await AppHaptics.setCategoryType(
        HapticCategory.gesture,
        HapticType.doubleTap,
      );
      nativeCalls.clear();
      platformCalls.clear();

      AppHaptics.click(HapticCategory.gesture);
      AppHaptics.heavyImpact(HapticCategory.gesture);
      await settle();

      expect(nativeCalls.where((call) => call.method == 'vibrate'), isEmpty);
      expect(platformCalls, isEmpty);
    });

    test('类型持久化；回到默认会清掉键', () async {
      SharedPreferences.setMockInitialValues({});
      await AppHaptics.load();
      await AppHaptics.setCategoryType(HapticCategory.listItem, HapticType.tick);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('settings_haptics_type_listItem'), 'tick');

      await AppHaptics.load();
      expect(AppHaptics.typeFor(HapticCategory.listItem), HapticType.tick);

      await AppHaptics.setCategoryType(HapticCategory.listItem, null);
      expect(prefs.getString('settings_haptics_type_listItem'), isNull);
      await AppHaptics.load();
      expect(AppHaptics.typeFor(HapticCategory.listItem), isNull);
    });

    test('HapticType 的 nativeName 与原生 knownTypes 对齐', () {
      // 原生 handleHapticVibrate 只认这批 type，拼错会被判未知而回退 Flutter
      expect(
        HapticType.values.map((type) => type.nativeName).toList(),
        ['click', 'tick', 'heavy', 'double', 'longPress'],
      );
      expect(HapticType.fromNativeName('double'), HapticType.doubleTap);
      expect(HapticType.fromNativeName(''), isNull);
      expect(HapticType.fromNativeName('nope'), isNull);
    });
  });
}
