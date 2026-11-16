import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/media_notification_service.dart';

/// 锁屏歌词卡片的收藏态同步协议：
/// - `updateLockScreenFavorite` 只翻红心（独立轻量通道）；
/// - `updateLockScreenLyricData` 整包必须带 `isFavorited`（原生首帧即需要红心态）；
/// - 原生回传的 `widgetAction`（投屏 / 队列）要落到 `onWidgetAction` 回调；
/// - 车机媒体卡片深链要落到 `onOpenCardLyric` 回调。
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
    MediaNotificationService.onWidgetAction = null;
    MediaNotificationService.onOpenCardLyric = null;
  });

  Future<void> sendMethod(String method, [Object? arguments]) async {
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall(method, arguments),
      ),
      (_) {},
    );
  }

  test('updateLockScreenFavorite 只推 isFavorited=true', () async {
    await MediaNotificationService.updateLockScreenFavorite(isFavorited: true);

    expect(calls, hasLength(1));
    expect(calls.single.method, 'updateLockScreenFavorite');
    expect(calls.single.arguments, {'isFavorited': true});
  });

  test('updateLockScreenFavorite 只推 isFavorited=false', () async {
    await MediaNotificationService.updateLockScreenFavorite(isFavorited: false);

    expect(calls, hasLength(1));
    expect(calls.single.method, 'updateLockScreenFavorite');
    expect(calls.single.arguments, {'isFavorited': false});
  });

  test('updateLockScreenLyricData 整包必带 isFavorited', () async {
    await MediaNotificationService.updateLockScreenLyricData(
      lines: const <Map<String, Object?>>[],
      placeholder: '',
      currentPositionMs: 0,
      durationMs: 0,
      isPlaying: false,
      title: 't',
      artist: 'a',
      isFavorited: true,
      fontSize: 15,
      fontWeight: 600,
      lineHeightMultiplier: 1.2,
      fontSource: 0,
      showTranslation: false,
      displayMode: 0,
      useDynamicColor: false,
    );

    expect(calls, hasLength(1));
    expect(calls.single.method, 'updateLockScreenLyricData');
    final payload = calls.single.arguments as Map<Object?, Object?>;
    expect(payload['isFavorited'], isTrue);
  });

  test('收到 widgetAction 时触发已装配的回调并透传动作', () async {
    var received = '';
    MediaNotificationService.initCallbacks();
    MediaNotificationService.onWidgetAction = (action) => received = action;

    await sendMethod('widgetAction', 'openQueue');

    expect(received, 'openQueue');
  });

  test('未装配回调时收到 widgetAction 不崩溃', () async {
    MediaNotificationService.initCallbacks();
    MediaNotificationService.onWidgetAction = null;

    await expectLater(sendMethod('widgetAction', 'openCast'), completes);
  });

  test('收到 openCardLyricView 时打开全屏歌词回调', () async {
    var opened = false;
    MediaNotificationService.initCallbacks();
    MediaNotificationService.onOpenCardLyric = () => opened = true;

    await sendMethod('openCardLyricView');

    expect(opened, isTrue);
  });
}
