import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/build_flags.dart';
import 'package:md3music/core/services/stem_separation_service.dart';

/// 端侧分离服务的通道语义。
///
/// 重点不是「能调通」（那要真机），而是：
/// - 编译期闸门：lite 包（默认构建）整块不编入，`init()` 不建通道调用；
/// - 非 Android 全空实现，**不建通道调用**（否则测试环境 MissingPluginException）；
/// - 模型不可用时 `available=false` 且 setEnabled 拒绝；
/// - 延迟补偿常量只在启用时生效。
///
/// 涉及「模型可用 / 原生接受」的用例只在 full 构建下有意义（`kStemSeparationAvailable`），
/// 默认（lite）构建下跳过；跑 full 语义：
///   flutter test --dart-define=MD3_FULL=true test/core/services/stem_separation_service_test.dart
///
/// 服务是单例且带 `_inited` 幂等缓存，因此每个用例都必须**重建**——
/// 否则前一个用例把 `_inited` 置位后，后面的用例永远拿不到新结果。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;
  late Map<String, dynamic> responses;
  late StemSeparationService service;

  setUp(() {
    calls = [];
    responses = {};
    // 单例构造是私有的，这里通过访问同一实例并重置其内部标志来隔离用例。
    service = StemSeparationService.instance;
    service.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.md3music.md3music/stem_separation'),
          (call) async {
            calls.add(call);
            return responses[call.method];
          },
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.md3music.md3music/stem_separation'),
          null,
        );
  });

  test('延迟补偿常量与原生端一致（2×WIN = 9216 帧 @44.1k ≈ 209ms）', () {
    // 原生 StemSeparateSession.LATENCY_MS = (2*WIN*1000 + SR/2) / SR
    // 2*WIN = 9216, SR = 44100 → 208.98 四舍五入 = 209
    //
    // 为什么是 2×WIN：引擎内部 inQ 要攒满 2*WIN 才推理一块，若按 1×WIN 放出，
    // 前 5120 帧必然全是原音（块 0 到 9216 才算得出来）。
    expect(StemSeparationService.kStemSeparateLatencyMs, 209);
  });

  test('未启用时不做延迟补偿', () {
    expect(service.latencyCompensationMs, 0);
  });

  test('模型缺失时 available=false 且拒绝开启', () async {
    responses['isAvailable'] = false;
    final ok = await service.init();
    expect(ok, isFalse);
    expect(service.available, isFalse);

    final enabled = await service.setEnabled(true);
    expect(enabled, isFalse);
    // 模型缺失时不应该再去调 setEnabled
    expect(calls.where((c) => c.method == 'setEnabled'), isEmpty);
  });

  test('lite 构建：init 直接返回 false 且不建通道调用', () async {
    if (kStemSeparationAvailable) return; // full 构建下该分支不成立
    responses['isAvailable'] = true;
    responses['init'] = <String, dynamic>{'available': true};
    final ok = await service.init();
    expect(ok, isFalse, reason: 'lite 包不编入分离，init 必须早退');
    expect(service.available, isFalse);
    expect(calls, isEmpty, reason: 'lite 下连通道都不该建');
  });

  test('模型可用时 init 拿到 latencyMs 并允许开启', () async {
    responses['isAvailable'] = true;
    responses['init'] = <String, dynamic>{
      'available': true,
      'latencyMs': 104,
    };
    final ok = await service.init();
    expect(ok, isTrue);
    expect(service.available, isTrue);

    responses['setEnabled'] = <String, dynamic>{'enabled': true};
    final enabled = await service.setEnabled(true);
    expect(enabled, isTrue);
    expect(service.enabled, isTrue);
    expect(
      service.latencyCompensationMs,
      StemSeparationService.kStemSeparateLatencyMs,
    );

    // 关闭后补偿应立即归零
    responses['setEnabled'] = <String, dynamic>{'enabled': false};
    await service.setEnabled(false);
    expect(service.enabled, isFalse);
    expect(service.latencyCompensationMs, 0);
  }, skip: !kStemSeparationAvailable);

  test('原生拒绝开启时 setEnabled 返回 false 且不置 enabled', () async {
    service.resetForTest();
    // 绕过 init：直接让 setEnabled 走通道
    responses['setEnabled'] = <String, dynamic>{
      'enabled': false,
      'reason': 'model-unavailable',
    };
    // available=false 时 setEnabled 直接短路，这里先构造可用态
    responses['isAvailable'] = true;
    responses['init'] = <String, dynamic>{'available': true};
    await service.init();
    final enabled = await service.setEnabled(true);
    expect(enabled, isFalse);
    expect(service.enabled, isFalse);
  }, skip: !kStemSeparationAvailable);

  test('模型未就绪时 setMix 不下发', () async {
    await service.setMix(1.5);
    expect(calls.where((c) => c.method == 'setMix'), isEmpty);
  });
}
