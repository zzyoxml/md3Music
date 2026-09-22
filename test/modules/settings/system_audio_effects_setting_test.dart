import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/equalizer_service.dart';
import 'package:md3music/data/repositories/settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('禁用系统音效默认关闭并可持久化', () async {
    final repository = SettingsRepository();

    expect(await repository.getDisableSystemAudioEffects(), isFalse);

    await repository.setDisableSystemAudioEffects(true);
    expect(await repository.getDisableSystemAudioEffects(), isTrue);

    await repository.setDisableSystemAudioEffects(false);
    expect(await repository.getDisableSystemAudioEffects(), isFalse);
  });

  test('禁用期间不绑定 Android 原生均衡器会话', () async {
    final equalizer = EqualizerService.instance;

    await equalizer.setSystemEffectsDisabled(true);
    expect(equalizer.systemEffectsDisabled, isTrue);
    expect(await equalizer.tryBind(), isFalse);

    await equalizer.setSystemEffectsDisabled(false);
    expect(equalizer.systemEffectsDisabled, isFalse);
  });
}
