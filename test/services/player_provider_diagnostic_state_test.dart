import 'dart:io';

import 'package:flutter/services.dart' as services;
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/diagnostic_logger.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/controlled_audio_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('播放快照在位置流静止时仍采样位置、缓冲和速度', () async {
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
    final logDir = Directory.systemTemp.createTempSync('player_diag_state_');
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    PlayerProvider? player;

    try {
      await DiagnosticLogger.instance.init(dir: logDir);
      player = PlayerProvider(
        playbackDiagnosticSampleInterval: const Duration(milliseconds: 10),
      );
      await player.audioReady.timeout(const Duration(seconds: 10));
      expect(audio.hasPlayerStateListener, isTrue);

      audio.setDiagnosticSnapshot(
        position: const Duration(seconds: 156),
        bufferedPosition: const Duration(seconds: 171),
        speed: 1.0,
      );
      audio.emitPlayerState();
      await Future<void>.delayed(Duration.zero);
      await DiagnosticLogger.instance.flush();
      audio.emitSpeed(1.25);
      audio.emitPlaying(true);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      audio.emitPlaying(false);
      await Future<void>.delayed(Duration.zero);
      await DiagnosticLogger.instance.flush();
      final sampleCountBeforePause =
          (await File(
                '${logDir.path}/${DiagnosticLogger.currentFileName}',
              ).readAsLines())
              .where((line) => line.contains('platform.progress_sample'))
              .length;
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await DiagnosticLogger.instance.flush();

      final log = await File(
        '${logDir.path}/${DiagnosticLogger.currentFileName}',
      ).readAsString();
      expect(log, contains('"event":"platform.state"'));
      expect(log, contains('"positionMs":156000'));
      expect(log, contains('"bufferedPositionMs":171000'));
      expect(log, contains('"speed":1.0'));
      expect(log, contains('"event":"speed.changed"'));
      expect(log, contains('"speed":1.25'));
      expect(log, contains('"outcome":"platform_confirmed"'));
      expect(log, contains('"event":"platform.progress_sample"'));
      final sampleLines = log
          .split('\n')
          .where((line) => line.contains('platform.progress_sample'))
          .toList();
      expect(sampleLines, isNotEmpty);
      expect(sampleLines.first, contains('"positionMs":156000'));
      expect(sampleLines.first, contains('"bufferedPositionMs":171000'));
      expect(sampleLines.first, contains('"speed":1.25'));
      expect(sampleLines.length, sampleCountBeforePause);
    } finally {
      player?.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
      await DiagnosticLogger.instance.resetForTesting();
      try {
        logDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });
}
