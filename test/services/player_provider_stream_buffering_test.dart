import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as just_audio;
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/widgets/playback_hint_pills.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/controlled_audio_service.dart';

/// `isStreamBuffering` → 播放页「缓冲中」提示的真值口径。
///
/// 背景（回归钉）：拖动进度条会走 `pauseForSeek()`，播放器处于暂停态，而平台仍会
/// 为 seek 落点重新缓冲。旧口径 `isPlaybackNotReady && isPlaying` 会把整段缓冲吞掉，
/// 表现为「拖动后不显示缓冲提示 / 只闪一下」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ControlledAudioService audio;
  late PlayerProvider player;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    player = PlayerProvider();
    await player.audioReady.timeout(const Duration(seconds: 10));
  });

  tearDown(() async {
    player.dispose();
    await audio.dispose();
    AudioServiceLoader.setTestOverride(null);
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('装载/缓冲态算在缓冲，ready 不算', () async {
    audio.emitProcessingState(just_audio.ProcessingState.loading);
    await settle();
    expect(player.isStreamBuffering, isTrue, reason: '切歌装载走 loading');

    audio.emitProcessingState(just_audio.ProcessingState.buffering);
    await settle();
    expect(player.isStreamBuffering, isTrue, reason: '播放中卡缓冲走 buffering');

    audio.emitProcessingState(just_audio.ProcessingState.ready);
    await settle();
    expect(player.isStreamBuffering, isFalse);
  });

  test('播完与停止不算缓冲（否则列表结尾会长期挂提示）', () async {
    audio.emitProcessingState(just_audio.ProcessingState.completed);
    await settle();
    // completed 仍属于「播放流未就绪」（歌词冻结语义），但提示不该出现
    expect(player.isPlaybackNotReady, isTrue);
    expect(player.isStreamBuffering, isFalse);

    audio.emitProcessingState(just_audio.ProcessingState.idle);
    await settle();
    expect(player.isStreamBuffering, isFalse);
  });

  test('拖动进度条后的暂停态：平台仍在为落点缓冲时照样提示', () async {
    // 拖动（pauseForSeek）后是暂停态：isPlaying 为 false
    expect(player.isPlaying, isFalse);
    audio.emitProcessingState(just_audio.ProcessingState.buffering);
    await settle();

    expect(player.isStreamBuffering, isTrue);
    final hint = PlaybackHintState.resolve(
      streamBuffering: player.isStreamBuffering,
      hasError: player.resolveErrorForDisplay != null,
      crossfading: player.crossfadeActiveNotifier.value,
    );
    expect(
      hint.buffering,
      isTrue,
      reason: '提示口径必须与播放态解耦，否则拖动后的整段缓冲被吞掉',
    );
  });

  // —— 桌面端起播延迟（Windows/WinRT）——
  // 真机日志实测：seek 松手到真正出声之间有 ~1.3s，期间处理态一直是 ready、
  // 也没有 buffering 事件，只有「平台还没在播」这一个可观测事实。

  test('起播宽限期内不提示，超过宽限期仍未出声才提示', () async {
    await player.resume(notifyRoom: false);
    expect(
      player.isWaitingForAudioStart,
      isFalse,
      reason: '正常恢复的位置推进通常在 200ms 内到达，不该闪一下提示',
    );

    await Future<void>.delayed(const Duration(milliseconds: 450));
    expect(player.isWaitingForAudioStart, isTrue);

    // 出声瞬间 playingStream 翻 true，提示应立刻收掉
    audio.emitPlaying(true);
    await settle();
    expect(player.isWaitingForAudioStart, isFalse);
  });

  test('用户暂停会收掉等待起播（拖动起手的 pauseForSeek 同理）', () async {
    await player.resume(notifyRoom: false);
    await Future<void>.delayed(const Duration(milliseconds: 450));
    expect(player.isWaitingForAudioStart, isTrue);

    await player.pause();
    await settle();
    expect(player.isWaitingForAudioStart, isFalse);
  });

  test('等待起播与缓冲态一样进「缓冲中」口径', () async {
    await player.resume(notifyRoom: false);
    await Future<void>.delayed(const Duration(milliseconds: 450));

    final hint = PlaybackHintState.resolve(
      streamBuffering:
          player.isStreamBuffering || player.isWaitingForAudioStart,
      hasError: player.resolveErrorForDisplay != null,
      crossfading: player.crossfadeActiveNotifier.value,
    );
    expect(hint.buffering, isTrue, reason: '桌面端只能靠这一路看到「缓冲中」');
  });
}
