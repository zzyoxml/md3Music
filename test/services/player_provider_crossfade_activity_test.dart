import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/controlled_audio_service.dart';

/// 交叉淡化状态 → `crossfadeActiveNotifier`。
///
/// 播放页「音频过渡中」胶囊只认这一个 notifier；它的真值口径必须来自音频层
/// 的 `crossfadingStream`（斜坡起止 / abort 都由 `_setCrossfading` 广播），
/// 本类不另行推断。
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

  test('默认不在过渡中', () {
    expect(player.crossfadeActiveNotifier.value, isFalse);
  });

  test('音频层淡入起坡置 true、淡完或 abort 复位 false', () async {
    audio.emitCrossfading(true);
    await Future<void>.delayed(Duration.zero);
    expect(player.crossfadeActiveNotifier.value, isTrue);

    audio.emitCrossfading(false);
    await Future<void>.delayed(Duration.zero);
    expect(player.crossfadeActiveNotifier.value, isFalse);
  });
}
