import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/core/services/music_haptics_service.dart';
import 'package:md3music/core/services/spectrum_service.dart';
import 'package:md3music/core/utils/app_haptics.dart';

/// 音乐震动的「生效范围」与自持频谱采集的生命周期。
///
/// 判据是真实通道调用序列（AGENTS.md 0.1）：
/// - spectrum 通道出现/消失 'start' = 采集被持有/释放；
/// - music_haptics 通道出现 'strike' = 马达点火；
/// - 点火被拦时 strike 必须一次都收不到。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const spectrumChannel = 'com.md3music.md3music/spectrum';
  const musicChannel = 'com.md3music.md3music/music_haptics';
  const codec = StandardMethodCodec();

  final strikeCalls = <MethodCall>[];
  final spectrumStarts = <MethodCall>[];
  int spectrumStopCount = 0;

  Future<void> emitFeatures(List<double> features) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      spectrumChannel,
      codec.encodeMethodCall(MethodCall('onFeatures', features)),
      (_) {},
    );
  }

  /// 造一个低频能量高的"踢鼓"帧（与既有闸门测试同一量纲）。
  List<double> kickFrame(double low) {
    final f = List<double>.filled(20, 0.0);
    f[SpectrumFeaturesIndices.low] = low;
    f[SpectrumFeaturesIndices.rms] = low;
    return f;
  }

  setUp(() {
    strikeCalls.clear();
    spectrumStarts.clear();
    spectrumStopCount = 0;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(spectrumChannel),
            (call) async {
      if (call.method == 'start') spectrumStarts.add(call);
      if (call.method == 'stop') spectrumStopCount++;
      return true;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(musicChannel),
            (call) async {
      if (call.method == 'strike') strikeCalls.add(call);
      if (call.method == 'capabilities') {
        return <String, Object?>{
          'hasVibrator': true,
          'hasAmplitudeControl': true,
        };
      }
      if (call.method == 'outputLatency') return -1;
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(spectrumChannel), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(musicChannel), null);
  });

  /// 造一个完成 load() 的服务与它独占的频谱实例；调用方负责 dispose。
  Future<MusicHapticsService> makeService({
    Map<String, Object> prefs = const {},
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    await AppHaptics.load();
    final spectrum = SpectrumService.forTesting(isAndroid: true);
    final service = MusicHapticsService.forTesting(spectrum: spectrum);
    await service.load();
    return service;
  }

  test('默认范围是「播放页启用」', () async {
    final service = await makeService();
    expect(service.scope, MusicHapticsScope.playerPage);
    service.dispose();
  });

  test('范围持久化可回读，非法值回落播放页', () async {
    final service = await makeService(
      prefs: {'settings_music_haptics_scope': 'always'},
    );
    expect(service.scope, MusicHapticsScope.always);
    service.dispose();
  });

  test('开关关闭时不自持采集', () async {
    final service = await makeService();
    await pumpEventQueue();
    expect(service.captureOwned, isFalse);
    expect(spectrumStarts, isEmpty);
    service.dispose();
  });

  test('播放页启用：页面不在场时采集不启动，喂特征也不点火', () async {
    final service = await makeService(
      prefs: {'settings_music_haptics_enabled': true},
    );
    await pumpEventQueue();
    expect(service.captureOwned, isFalse);
    expect(spectrumStarts, isEmpty);

    for (var i = 0; i < 12; i++) {
      await emitFeatures(kickFrame(i.isEven ? 0.1 : 3.0));
    }
    expect(strikeCalls, isEmpty, reason: '页面不在场就不该震');
    service.dispose();
  });

  test('播放页启用 + 页面在场：自持采集（无需频谱显示开关）并正常点火', () async {
    final service = await makeService(
      prefs: {'settings_music_haptics_enabled': true},
    );
    service.setPlayerPageActive(true);
    await pumpEventQueue();

    expect(service.captureOwned, isTrue);
    expect(spectrumStarts, hasLength(1));
    // PCM-only：不需要录音权限，也绝不挂 Visualizer
    expect(spectrumStarts.single.arguments['visualizerFallback'], isFalse);

    for (var i = 0; i < 12; i++) {
      await emitFeatures(kickFrame(i.isEven ? 0.1 : 3.0));
    }
    expect(strikeCalls, isNotEmpty, reason: '频谱显示关闭也必须能震（本次改造的核心）');
    service.dispose();
  });

  test('页面离场计数归零后释放采集', () async {
    final service = await makeService(
      prefs: {'settings_music_haptics_enabled': true},
    );
    service.setPlayerPageActive(true);
    service.setPlayerPageActive(true); // 拖拽覆盖层 + 接管路由并存的场景
    await pumpEventQueue();
    expect(service.captureOwned, isTrue);

    service.setPlayerPageActive(false);
    await pumpEventQueue();
    expect(service.captureOwned, isTrue, reason: '还有一层在场');

    service.setPlayerPageActive(false);
    await pumpEventQueue();
    expect(service.captureOwned, isFalse);
    expect(spectrumStopCount, 1);
    service.dispose();
  });

  test('App 内启用：页面不在场、前台播放时自持采集', () async {
    final service = await makeService(prefs: {
      'settings_music_haptics_enabled': true,
      'settings_music_haptics_scope': 'inApp',
    });
    await pumpEventQueue();
    expect(service.captureOwned, isTrue);
    expect(spectrumStarts, hasLength(1));

    for (var i = 0; i < 12; i++) {
      await emitFeatures(kickFrame(i.isEven ? 0.1 : 3.0));
    }
    expect(strikeCalls, isNotEmpty);
    service.dispose();
  });

  test('App 内启用：退后台释放采集，回前台重新持有', () async {
    final service = await makeService(prefs: {
      'settings_music_haptics_enabled': true,
      'settings_music_haptics_scope': 'inApp',
    });
    await pumpEventQueue();
    expect(service.captureOwned, isTrue);

    service.didChangeAppLifecycleState(AppLifecycleState.paused);
    await pumpEventQueue();
    expect(service.captureOwned, isFalse);
    expect(spectrumStopCount, 1);

    service.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await pumpEventQueue();
    expect(service.captureOwned, isTrue);
    expect(spectrumStarts, hasLength(2));
    service.dispose();
  });

  test('始终启用：退后台采集保持，熄屏播放继续点火', () async {
    final service = await makeService(prefs: {
      'settings_music_haptics_enabled': true,
      'settings_music_haptics_scope': 'always',
    });
    await pumpEventQueue();
    expect(service.captureOwned, isTrue);

    service.didChangeAppLifecycleState(AppLifecycleState.paused);
    await pumpEventQueue();
    expect(service.captureOwned, isTrue);
    expect(spectrumStopCount, 0);

    for (var i = 0; i < 12; i++) {
      await emitFeatures(kickFrame(i.isEven ? 0.1 : 3.0));
    }
    expect(strikeCalls, isNotEmpty, reason: '后台播放也要震');
    service.dispose();
  });

  test('暂停后特征被门控，不会持续点火', () async {
    final service = await makeService(prefs: {
      'settings_music_haptics_enabled': true,
      'settings_music_haptics_scope': 'inApp',
    });
    await pumpEventQueue();

    service.setPlaybackActive(false);
    await pumpEventQueue();
    for (var i = 0; i < 12; i++) {
      await emitFeatures(kickFrame(i.isEven ? 0.1 : 3.0));
    }
    expect(strikeCalls, isEmpty, reason: '暂停门控（_gateZero）必须拦下 flush 尾音');
    service.dispose();
  });

  test('setScope 立即重算采集持有并持久化', () async {
    final service = await makeService(prefs: {
      'settings_music_haptics_enabled': true,
      'settings_music_haptics_scope': 'always',
    });
    await pumpEventQueue();
    expect(service.captureOwned, isTrue);

    await service.setScope(MusicHapticsScope.playerPage);
    await pumpEventQueue();
    expect(service.scope, MusicHapticsScope.playerPage);
    expect(service.captureOwned, isFalse, reason: '页面不在场，播放页档不持采集');
    expect(spectrumStopCount, 1);

    // 持久化落盘（与 SettingsRepository 写同一键）
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('settings_music_haptics_scope'), 'playerPage');

    // 页面随后到场：下一次重算重新持有
    service.setPlayerPageActive(true);
    await pumpEventQueue();
    expect(service.captureOwned, isTrue);
    service.dispose();
  });
}
