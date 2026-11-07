import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// TV「退出 App」的播放侧契约：停止音频输出并移除媒体通知/前台播放服务，
/// 但不清空播放队列（区别于 `clearPlaylist`）。停音频失败也不能把退出流程带崩。
class _FakeAudioService {
  _FakeAudioService({this.stopError});

  final Object? stopError;
  int stopCalls = 0;

  Future<void> init() async {}

  Future<void> stop() async {
    stopCalls++;
    final error = stopError;
    if (error != null) throw error;
  }

  // ignore: annotate_overrides
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '_FakeAudioService: 未实现的方法 ${invocation.memberName}',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.md3music.md3music/floating_lyric');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    AudioServiceLoader.setTestOverride(null);
  });

  /// 注入 fake 音频服务跑一次退出流程，并确保 dispose 与 override 清理。
  Future<void> runAppExit(
    _FakeAudioService fake,
    Future<void> Function(PlayerProvider player) action,
  ) async {
    SharedPreferences.setMockInitialValues({});
    AudioServiceLoader.setTestOverride(() async => fake);
    final player = PlayerProvider();
    try {
      await player.audioReady.timeout(const Duration(seconds: 10));
      await action(player);
    } finally {
      player.dispose();
      // 让初始化期间派生的后台异步任务（均为 try/catch 包裹）跑完
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  test('stopForAppExit 停止音频输出并移除媒体通知', () async {
    final fake = _FakeAudioService();
    await runAppExit(fake, (player) async {
      await player.stopForAppExit();
    });

    expect(fake.stopCalls, 1);
    expect(
      calls.map((call) => call.method),
      contains('hideNotification'),
      reason: '退出 App 必须移除媒体通知，否则前台播放服务残留在后台',
    );
  });

  test('停音频抛错时 stopForAppExit 仍完成并移除通知', () async {
    final fake = _FakeAudioService(stopError: StateError('audio stop failed'));
    await runAppExit(fake, (player) async {
      await expectLater(player.stopForAppExit(), completes);
    });

    expect(fake.stopCalls, 1);
    expect(calls.map((call) => call.method), contains('hideNotification'));
  });
}
