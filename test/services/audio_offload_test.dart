import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/audio_offload_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 硬解决策器的**时机策略**单测（纯逻辑，不依赖播放器）。
///
/// 钉住三件最容易回归的事：
/// 1. 有效值 = 用户开关 && 无让路原因 && 平台支持；
/// 2. 让路**立即**下发，恢复在播放中**挂起到换源**（`beforeSourceLoad`），暂停态立即；
/// 3. `forceSuspend` 是「临时钉住原因」，不写持久化、不改用户开关。
///
/// 说明：`AudioOffloadService` 是进程级单例且没有测试用 reset（与仓库既有单例风格一致），
/// 故用例按顺序共用同一实例，每个用例开头用 [reset] 收敛到已知初态。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final AudioOffloadService svc = AudioOffloadService.instance;
  const MethodChannel channel = MethodChannel(AudioOffloadService.channelName);

  /// 记录下发给原生的 `setEnabled` 参数（真实下发顺序是断言依据）。
  final List<bool> pushed = <bool>[];
  int apiLevel = 33;

  Map<String, dynamic> statusMap({bool offloaded = false, bool failed = false}) {
    return <String, dynamic>{
      'effective': pushed.isNotEmpty && pushed.last,
      'offloaded': offloaded,
      'sleeping': false,
      'failed': failed,
      'apiLevel': apiLevel,
      'requestedMode': pushed.isNotEmpty && pushed.last ? 1 : 0,
      'trackFormat': offloaded ? 'MP3 44100Hz 2ch' : '',
    };
  }

  setUpAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      switch (call.method) {
        case 'setEnabled':
          final bool enabled =
              (call.arguments as Map<Object?, Object?>)['enabled'] == true;
          pushed.add(enabled);
          return statusMap(offloaded: enabled);
        case 'getStatus':
          return statusMap();
        case 'probeCapabilities':
        case 'getCachedCapabilities':
          return null;
      }
      return null;
    });
    // init 会注册 MethodCallHandler（下方 pushNativeStatus 依赖它）并拉一次 getStatus。
    await svc.init();
  });

  /// 模拟原生主动推状态（`onStatusChanged`），用于验证 apiLevel 等平台态变化。
  Future<void> pushNativeStatus(Map<String, dynamic> status) async {
    final ByteData data = const StandardMethodCodec()
        .encodeMethodCall(MethodCall('onStatusChanged', status));
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(AudioOffloadService.channelName, data, (_) {});
  }

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// 收敛到「开关关、条件全不命中、不在播放」的初态。
  Future<void> reset() async {
    pushed.clear();
    apiLevel = 33;
    svc.isPlaying = () => false;
    svc.speedIsNormal = () => true;
    svc.dspActive = () => false;
    svc.equalizerActive = () => false;
    svc.volumeNormalizationActive = () => false;
    svc.spectrumCapturing = () => false;
    svc.usbOrDirectPcmActive = () => false;
    svc.crossfadeEnabled = () => false;
    svc.rebuildRequester = null;
    await svc.setEnabled(false);
    pushed.clear();
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await reset();
  });

  test('默认关闭：不生效，也不向原生下发开启', () async {
    expect(svc.userEnabled, isFalse);
    expect(svc.effective, isFalse);
    expect(svc.yieldReason, isNull);
    expect(pushed, isNot(contains(true)));
  });

  test('打开开关且无冲突、未播放：立即下发开启', () async {
    await svc.setEnabled(true);
    expect(svc.userEnabled, isTrue);
    expect(svc.effective, isTrue);
    expect(pushed.last, isTrue);
    // 持久化键契约：下一次启动要能恢复
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(AudioOffloadService.keyEnabled), isTrue);
  });

  test('冲突条件命中：让路原因为中文文案，且立即下发关闭', () async {
    await svc.setEnabled(true);
    expect(pushed.last, isTrue);

    svc.dspActive = () => true;
    await svc.refresh();

    expect(svc.effective, isFalse);
    expect(svc.yieldReason, '蝰蛇母带已开启');
    expect(pushed.last, isFalse);
    // 让路提示是一次性可消费的
    expect(svc.consumeNotice(), contains('蝰蛇母带'));
    expect(svc.consumeNotice(), isNull);
  });

  test('优先级：蝰蛇母带先于倍速与独占输出报出', () async {
    await svc.setEnabled(true);
    svc.dspActive = () => true;
    svc.crossfadeEnabled = () => true;
    await svc.refresh();
    expect(svc.yieldReason, '蝰蛇母带已开启');
    svc.dspActive = () => false;
    await svc.refresh();
    expect(svc.yieldReason, '交叉淡化已开启');
  });

  test('播放中恢复挂起到换源：refresh 不下发，beforeSourceLoad 才下发', () async {
    await svc.setEnabled(true);
    svc.dspActive = () => true;
    await svc.refresh();
    expect(pushed.last, isFalse);

    // 冲突消失，但正在播放 → 不下发（避免打断当前歌曲）
    svc.dspActive = () => false;
    svc.isPlaying = () => true;
    await svc.refresh();
    expect(svc.effective, isTrue, reason: '决策上已恢复');
    expect(pushed.last, isFalse, reason: '但下发被挂起');

    await svc.beforeSourceLoad();
    expect(pushed.last, isTrue, reason: '换源时冲刷挂起的恢复');
  });

  test('暂停态下恢复立即下发', () async {
    await svc.setEnabled(true);
    svc.dspActive = () => true;
    await svc.refresh();
    expect(pushed.last, isFalse);

    svc.dspActive = () => false;
    svc.isPlaying = () => false;
    await svc.refresh();
    expect(pushed.last, isTrue);
  });

  test('forceSuspend 钉住临时原因：宽限内不被 refresh 冲掉，宽限后释放', () async {
    await svc.setEnabled(true);
    await svc.forceSuspend('USB 独占输出');
    expect(svc.effective, isFalse);
    expect(svc.yieldReason, 'USB 独占输出');
    expect(pushed.last, isFalse);

    // 宽限窗口内条件器还没反映（原生状态滞后）→ 不会被判为「未复现」而解除
    await svc.refresh();
    expect(svc.effective, isFalse);
    expect(svc.yieldReason, 'USB 独占输出');

    // 条件器复现 → 仍保留（此时改用条件器给出的更精确文案）
    svc.usbOrDirectPcmActive = () => true;
    await svc.refresh();
    expect(svc.yieldReason, 'USB 独占输出已开启');
    expect(pushed.last, isFalse);

    // 条件消失但仍在宽限内：继续钉住（防止切换过程中被其它 refresh 提前恢复）
    svc.usbOrDirectPcmActive = () => false;
    await svc.refresh();
    expect(svc.effective, isFalse);

    // 宽限过期后释放：暂停态立即恢复
    svc.forceSuspendGrace = Duration.zero;
    await svc.refresh();
    expect(svc.yieldReason, isNull);
    expect(svc.effective, isTrue);
    expect(pushed.last, isTrue);
    svc.forceSuspendGrace = const Duration(seconds: 3);
  });

  test('平台 API 低于 29：原生推送后即使开关打开也不生效', () async {
    await pushNativeStatus(<String, dynamic>{
      'apiLevel': 28,
      'effective': false,
      'offloaded': false,
      'sleeping': false,
      'failed': false,
    });
    await svc.setEnabled(true);

    expect(svc.platformSupported, isFalse);
    expect(svc.effective, isFalse);
    expect(pushed, isNot(contains(true)));
  });
}
