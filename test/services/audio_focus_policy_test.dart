import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/audio_service_io.dart';

void main() {
  group('duck 事件', () {
    test('duckAndRestore + begin + playing → DuckVolumeAction(音量×0.5)', () {
      final a = decideInterruptionAction(
        mode: AudioFocusInterruptionMode.duckAndRestore,
        begin: true,
        type: AudioInterruptionType.duck,
        isPlaying: true,
        currentVolume: 0.8,
      );
      expect(a, isA<DuckVolumeAction>());
      expect((a as DuckVolumeAction).targetVolume, closeTo(0.4, 1e-9));
    });

    test('duckAndRestore + begin + 音量 0.3 → 0.15（相对比例，不放大）', () {
      final a = decideInterruptionAction(
        mode: AudioFocusInterruptionMode.duckAndRestore,
        begin: true,
        type: AudioInterruptionType.duck,
        isPlaying: true,
        currentVolume: 0.3,
      );
      expect((a as DuckVolumeAction).targetVolume, closeTo(0.15, 1e-9));
    });

    test('duckAndRestore + end → RestoreVolumeAction(原音量)', () {
      final a = decideInterruptionAction(
        mode: AudioFocusInterruptionMode.duckAndRestore,
        begin: false,
        type: AudioInterruptionType.duck,
        isPlaying: true,
        currentVolume: 0.4,
        volumeBeforeDuck: 0.8,
      );
      expect(a, isA<RestoreVolumeAction>());
      expect((a as RestoreVolumeAction).targetVolume, closeTo(0.8, 1e-9));
    });

    test('duckAndRestore + end + 无原音量记录 → 回退当前音量', () {
      final a = decideInterruptionAction(
        mode: AudioFocusInterruptionMode.duckAndRestore,
        begin: false,
        type: AudioInterruptionType.duck,
        isPlaying: true,
        currentVolume: 0.4,
      );
      expect((a as RestoreVolumeAction).targetVolume, closeTo(0.4, 1e-9));
    });

    test('pauseAndResume + duck begin + playing → PausePlaybackAction（暂停）', () {
      final a = decideInterruptionAction(
        mode: AudioFocusInterruptionMode.pauseAndResume,
        begin: true,
        type: AudioInterruptionType.duck,
        isPlaying: true,
        currentVolume: 0.8,
      );
      expect(a, isA<PausePlaybackAction>());
    });

    test('pauseAndResume + duck begin + 未播放 → KeepPlayingAction', () {
      final a = decideInterruptionAction(
        mode: AudioFocusInterruptionMode.pauseAndResume,
        begin: true,
        type: AudioInterruptionType.duck,
        isPlaying: false,
        currentVolume: 0.8,
      );
      expect(a, isA<KeepPlayingAction>());
    });

    test('pauseAndResume + duck end → ResumePlaybackAction（恢复）', () {
      final a = decideInterruptionAction(
        mode: AudioFocusInterruptionMode.pauseAndResume,
        begin: false,
        type: AudioInterruptionType.duck,
        isPlaying: false,
        currentVolume: 0.8,
      );
      expect(a, isA<ResumePlaybackAction>());
    });

    test('keepPlaying + duck → KeepPlayingAction', () {
      final a = decideInterruptionAction(
        mode: AudioFocusInterruptionMode.keepPlaying,
        begin: true,
        type: AudioInterruptionType.duck,
        isPlaying: true,
        currentVolume: 0.8,
      );
      expect(a, isA<KeepPlayingAction>());
    });

    test('duckAndRestore + begin + 未播放 → KeepPlayingAction', () {
      final a = decideInterruptionAction(
        mode: AudioFocusInterruptionMode.duckAndRestore,
        begin: true,
        type: AudioInterruptionType.duck,
        isPlaying: false,
        currentVolume: 0.8,
      );
      expect(a, isA<KeepPlayingAction>());
    });
  });

  group('pause / unknown 事件', () {
    for (final type in [
      AudioInterruptionType.pause,
      AudioInterruptionType.unknown,
    ]) {
      test('$type: pauseAndResume + begin + playing → PausePlaybackAction', () {
        final a = decideInterruptionAction(
          mode: AudioFocusInterruptionMode.pauseAndResume,
          begin: true,
          type: type,
          isPlaying: true,
          currentVolume: 0.8,
        );
        expect(a, isA<PausePlaybackAction>());
      });

      test('$type: pauseAndResume + begin + 未播放 → KeepPlayingAction', () {
        final a = decideInterruptionAction(
          mode: AudioFocusInterruptionMode.pauseAndResume,
          begin: true,
          type: type,
          isPlaying: false,
          currentVolume: 0.8,
        );
        expect(a, isA<KeepPlayingAction>());
      });

      test('$type: pauseAndResume + end → ResumePlaybackAction', () {
        final a = decideInterruptionAction(
          mode: AudioFocusInterruptionMode.pauseAndResume,
          begin: false,
          type: type,
          isPlaying: false,
          currentVolume: 0.8,
        );
        expect(a, isA<ResumePlaybackAction>());
      });

      test('$type: keepPlaying + begin → KeepPlayingAction（保持播放）', () {
        final a = decideInterruptionAction(
          mode: AudioFocusInterruptionMode.keepPlaying,
          begin: true,
          type: type,
          isPlaying: true,
          currentVolume: 0.8,
        );
        expect(a, isA<KeepPlayingAction>());
      });

      test('$type: duckAndRestore + begin + playing → DuckVolumeAction（降音量不暂停）', () {
        final a = decideInterruptionAction(
          mode: AudioFocusInterruptionMode.duckAndRestore,
          begin: true,
          type: type,
          isPlaying: true,
          currentVolume: 0.8,
        );
        expect(a, isA<DuckVolumeAction>());
      });

      test('$type: duckAndRestore + end → RestoreVolumeAction(原音量)', () {
        final a = decideInterruptionAction(
          mode: AudioFocusInterruptionMode.duckAndRestore,
          begin: false,
          type: type,
          isPlaying: true,
          currentVolume: 0.4,
          volumeBeforeDuck: 0.8,
        );
        expect(a, isA<RestoreVolumeAction>());
        expect((a as RestoreVolumeAction).targetVolume, closeTo(0.8, 1e-9));
      });
    }
  });
}
