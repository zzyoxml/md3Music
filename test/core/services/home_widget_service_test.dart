import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/home_widget_service.dart';

/// 桌面小组件通道载荷测试：确认新增字段不破坏旧字段集合，且旧调用方行为不变。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.md3music.md3music/home_widget');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Map<Object?, Object?>? lastArguments;
  MethodCall? lastCall;

  setUp(() {
    lastArguments = null;
    lastCall = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      lastCall = call;
      lastArguments = call.arguments as Map<Object?, Object?>?;
      return true;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('未显式传模式/收藏时仍下发旧五键，且新键取默认值', () async {
    await HomeWidgetService.updateWidget(
      title: '心墙',
      artist: '郭静',
      isPlaying: true,
      position: const Duration(seconds: 12),
      duration: const Duration(minutes: 3),
    );

    expect(lastCall?.method, 'updateWidget');
    final args = lastArguments!;
    expect(args['title'], '心墙');
    expect(args['artist'], '郭静');
    expect(args['isPlaying'], true);
    expect(args['position'], 12000);
    expect(args['duration'], 180000);
    // 默认值必须与旧行为一致：不循环、不随机、未收藏
    expect(args['loopMode'], 'off');
    expect(args['shuffleEnabled'], false);
    expect(args['isFavorited'], false);
  });

  test('显式传入播放模式/收藏时按原值下发', () async {
    await HomeWidgetService.updateWidget(
      title: '因为你',
      artist: '方大同',
      isPlaying: false,
      position: Duration.zero,
      duration: const Duration(minutes: 4),
      loopMode: 'one',
      shuffleEnabled: true,
      isFavorited: true,
    );

    final args = lastArguments!;
    expect(args['loopMode'], 'one');
    expect(args['shuffleEnabled'], true);
    expect(args['isFavorited'], true);
  });

  test('通道异常时静默吞掉，不向调用方抛出', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'unavailable');
    });

    await expectLater(
      HomeWidgetService.updateWidget(
        title: 'x',
        artist: 'y',
        isPlaying: false,
        position: Duration.zero,
        duration: Duration.zero,
      ),
      completes,
    );
  });
}
