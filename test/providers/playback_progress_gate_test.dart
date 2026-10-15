import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart' as services;
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/playback_progress_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../support/controlled_audio_service.dart';

void main() {
  group('PlaybackProgressGate', () {
    test('恢复时重复上报当前位置不算真实推进', () {
      final gate = PlaybackProgressGate()
        ..begin(7, baseline: const Duration(minutes: 2));

      expect(gate.observe(7, const Duration(minutes: 2)), isFalse);
      expect(gate.observe(7, const Duration(minutes: 1, seconds: 59)), isFalse);
    });

    test('只在平台位置超过请求基线后报告一次推进', () {
      final gate = PlaybackProgressGate()
        ..begin(7, baseline: const Duration(minutes: 2));

      expect(
        gate.observe(7, const Duration(minutes: 2, milliseconds: 200)),
        isTrue,
      );
      expect(
        gate.observe(7, const Duration(minutes: 2, milliseconds: 400)),
        isFalse,
      );
    });

    test('过期请求不推进当前请求，新请求会重设基线', () {
      final gate = PlaybackProgressGate()
        ..begin(7, baseline: const Duration(minutes: 2))
        ..begin(8, baseline: const Duration(seconds: 0));

      expect(gate.observe(7, const Duration(minutes: 3)), isFalse);
      expect(gate.observe(8, const Duration(milliseconds: 200)), isTrue);
    });
  });

  testWidgets('恢复播放意图不冒充当前位置已前进', (tester) async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const services.EventChannel(
            'dev.fluttercommunity.plus/connectivity_status',
          ),
          MockStreamHandler.inline(
            onListen: (_, events) => events.success(<String>['wifi']),
          ),
        );
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    late final PlayerProvider player;
    try {
      await tester.runAsync(() async {
        player = PlayerProvider();
        await player.audioReady;
      });
      const baseline = Duration(minutes: 2);
      expect(player.debugFeedPlatformPositionForTest(baseline), isFalse);

      await player.resume(notifyRoom: false);

      // 控件可立即反映用户意图，但诊断仍等待平台位置真正增加。
      expect(player.isPlaying, isTrue);
      expect(player.debugFeedPlatformPositionForTest(baseline), isFalse);
      expect(
        player.debugFeedPlatformPositionForTest(
          baseline + const Duration(milliseconds: 200),
        ),
        isTrue,
      );
      expect(
        player.debugFeedPlatformPositionForTest(
          baseline + const Duration(milliseconds: 400),
        ),
        isFalse,
      );
    } finally {
      player.dispose();
      await tester.pump();
      await tester.runAsync(audio.dispose);
      AudioServiceLoader.setTestOverride(null);
    }
  });
}
