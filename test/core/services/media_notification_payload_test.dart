// Windows SMTC 对外发布口径的 Dart 侧契约测试。
//
// 第三方任务栏歌词工具（TaskbarLyrics、AF Media Bar）只读 Windows SMTC，
// 而 SMTC 的全部输入都来自本文件的 `updateNotification` payload。这里钉住
// 三件「改错了不会报错、只会在第三方工具那边静默失效」的事：
//
// 1. **payload 必须带 album / albumArtist / playbackRate**：
//    缺 album → 歌词匹配少一维身份；缺 playbackRate → 倍速播放时外部工具
//    按 1.0x 外推时间轴，歌词持续漂移。
// 2. **老调用点不传新字段时有确定回落**（'' / 1.0），不能变成 null 让原生
//    `StringArg`/`DoubleArg` 拿到默认值之外的形态。
// 3. **入站 setShuffle / setPlaybackSpeed 能打到回调**，且回调未装配时不崩
//    —— 原生侧会无条件 InvokeMethod，Dart 侧抛异常会被引擎当未处理。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/media_notification_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.md3music.md3music/floating_lyric');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// 捕获出站 `updateNotification` 的 payload。
  late List<MethodCall> outbound;

  setUp(() {
    outbound = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      outbound.add(call);
      return true;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    MediaNotificationService.onSetShuffle = null;
    MediaNotificationService.onSetPlaybackSpeed = null;
  });

  /// 模拟原生侧入站调用。
  Future<void> sendCommand(String method, [Object? arguments]) async {
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall(method, arguments),
      ),
      (_) {},
    );
  }

  Map<Object?, Object?> lastPayload() {
    final calls = outbound
        .where((c) => c.method == 'updateNotification')
        .toList();
    expect(calls, isNotEmpty, reason: '没有捕获到 updateNotification');
    return calls.last.arguments as Map<Object?, Object?>;
  }

  group('出站 payload：第三方歌词工具依赖的字段', () {
    test('LyricInfo 通道失败会返回 false，后续成功可确认交付', () async {
      var attempts = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'updateLyricInfo') {
          attempts++;
          if (attempts == 1) {
            throw PlatformException(code: 'bridge_unavailable');
          }
        }
        return true;
      });

      expect(
        await MediaNotificationService.tryUpdateLyricInfo('[{"lyric":"x"}]'),
        isFalse,
      );
      expect(
        await MediaNotificationService.tryUpdateLyricInfo('[{"lyric":"x"}]'),
        isTrue,
      );
      expect(attempts, 2);
    });

    test('album / albumArtist / playbackRate 原样下发', () async {
      await MediaNotificationService.updateNotification(
        title: '晴天',
        artist: '周杰伦',
        album: '叶惠美',
        albumArtist: '周杰伦',
        isPlaying: true,
        playbackRate: 1.25,
      );
      final payload = lastPayload();
      expect(payload['album'], '叶惠美');
      expect(payload['albumArtist'], '周杰伦');
      expect(payload['playbackRate'], 1.25);
    });

    test('老调用点不传新字段时回落到空串 / 1.0', () async {
      await MediaNotificationService.updateNotification(
        title: '晴天',
        artist: '周杰伦',
        isPlaying: false,
      );
      final payload = lastPayload();
      expect(payload['album'], '');
      expect(payload['albumArtist'], '');
      expect(payload['playbackRate'], 1.0);
    });

    test('loopMode / shuffleEnabled 仍在同一 payload 里', () async {
      await MediaNotificationService.updateNotification(
        title: 't',
        artist: 'a',
        isPlaying: true,
        loopMode: 'one',
        shuffleEnabled: true,
      );
      final payload = lastPayload();
      expect(payload['loopMode'], 'one');
      expect(payload['shuffleEnabled'], true);
    });

    test('倍速边界值不被 Dart 侧改写（夹取由 setSpeed / 原生各负责一段）', () async {
      await MediaNotificationService.updateNotification(
        title: 't',
        artist: 'a',
        isPlaying: true,
        playbackRate: 4.0,
      );
      expect(lastPayload()['playbackRate'], 4.0);
    });
  });

  group('入站：SMTC 随机 / 倍速按钮', () {
    test('setShuffle 触发已装配的回调（系统给目标态，不自行取反）', () async {
      MediaNotificationService.initCallbacks();
      final received = <bool>[];
      MediaNotificationService.onSetShuffle = received.add;

      await sendCommand('setShuffle', true);
      await sendCommand('setShuffle', false);

      expect(received, [true, false]);
    });

    test('setPlaybackSpeed 触发已装配的回调', () async {
      MediaNotificationService.initCallbacks();
      final received = <double>[];
      MediaNotificationService.onSetPlaybackSpeed = received.add;

      await sendCommand('setPlaybackSpeed', 1.5);
      await sendCommand('setPlaybackSpeed', 0.75);

      expect(received, [1.5, 0.75]);
    });

    test('int 形态的倍速也能收（MethodCodec 的 int/double 分流）', () async {
      MediaNotificationService.initCallbacks();
      final received = <double>[];
      MediaNotificationService.onSetPlaybackSpeed = received.add;

      await sendCommand('setPlaybackSpeed', 2);

      expect(received, [2.0]);
    });

    test('回调未装配时收到命令不崩', () async {
      MediaNotificationService.initCallbacks();
      MediaNotificationService.onSetShuffle = null;
      MediaNotificationService.onSetPlaybackSpeed = null;

      await expectLater(sendCommand('setShuffle', true), completes);
      await expectLater(sendCommand('setPlaybackSpeed', 1.5), completes);
    });

    test('参数形态不对时静默忽略，不抛类型异常', () async {
      MediaNotificationService.initCallbacks();
      var calls = 0;
      MediaNotificationService.onSetShuffle = (_) => calls++;
      MediaNotificationService.onSetPlaybackSpeed = (_) => calls++;

      await sendCommand('setShuffle', 'true');
      await sendCommand('setPlaybackSpeed', 'fast');

      expect(calls, 0);
    });
  });
}
