import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/windows_system_audio_capture_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void mockChannel(Future<Object?> Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(
      WindowsSystemAudioCaptureService.channel,
      handler,
    );
  }

  tearDown(() {
    messenger.setMockMethodCallHandler(
      WindowsSystemAudioCaptureService.channel,
      null,
    );
  });

  test('start 传 maxDurationMs，stop 解析 pcm/sampleRate', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final calls = <String>[];
    mockChannel((call) async {
      calls.add(call.method);
      if (call.method == 'startCapture') {
        expect((call.arguments as Map)['maxDurationMs'], 12000);
        return true;
      }
      return <Object?, Object?>{
        'pcm': Uint8List.fromList(<int>[1, 0, 2, 0]),
        'sampleRate': 48000,
      };
    });

    expect(await WindowsSystemAudioCaptureService.start(), isTrue);
    final segment = await WindowsSystemAudioCaptureService.stop();
    expect(calls, <String>['startCapture', 'stopCapture']);
    expect(segment, isNotNull);
    expect(segment!.sampleRate, 48000);
    expect(segment.pcm.length, 4);
  });

  test('stop 返回空 pcm 时降级为 null', () async {
    mockChannel((call) async => call.method == 'startCapture'
        ? true
        : <Object?, Object?>{'pcm': Uint8List(0), 'sampleRate': 0});

    expect(await WindowsSystemAudioCaptureService.start(), isTrue);
    expect(await WindowsSystemAudioCaptureService.stop(), isNull);
  });

  test('start 返回 false 时按失败处理', () async {
    mockChannel((call) async => false);
    expect(await WindowsSystemAudioCaptureService.start(), isFalse);
  });

  test('通道缺失时 start=false / stop=null（不抛异常）', () async {
    mockChannel((call) async => throw MissingPluginException());
    expect(await WindowsSystemAudioCaptureService.start(), isFalse);
    expect(await WindowsSystemAudioCaptureService.stop(), isNull);
  });

  test('音源持久化：默认 mic，可切 system 并清除', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    expect(
      await loadRecognitionAudioSource(),
      RecognitionAudioSource.microphone,
    );

    await saveRecognitionAudioSource(RecognitionAudioSource.system);
    expect(await loadRecognitionAudioSource(), RecognitionAudioSource.system);

    await saveRecognitionAudioSource(RecognitionAudioSource.microphone);
    expect(
      await loadRecognitionAudioSource(),
      RecognitionAudioSource.microphone,
    );
  });
}
