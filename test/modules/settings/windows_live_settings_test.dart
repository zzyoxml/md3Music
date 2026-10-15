import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/repositories/settings_repository.dart';
import 'package:md3music/providers/car_mode_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('Windows 播放与 MV 设置写入后通知已挂载页面', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsRepository();
    final start = SettingsRepository.windowsLiveSettingsRevision.value;

    await settings.setZenCoverLongPress(false);
    await settings.setDynamicAlbumCover(false);
    await settings.setMvDanmakuEnabled(true);
    await settings.setMvDanmakuOpacity(0.4);

    final reopenedSettings = SettingsRepository();
    expect(await reopenedSettings.getZenCoverLongPress(), isFalse);
    expect(await reopenedSettings.getDynamicAlbumCover(), isFalse);
    expect(await reopenedSettings.getMvDanmakuEnabled(), isTrue);
    expect(await reopenedSettings.getMvDanmakuOpacity(), 0.4);
    expect(
      SettingsRepository.windowsLiveSettingsRevision.value,
      start + (Platform.isWindows ? 4 : 0),
    );
  });

  test('Windows 车机 Dock 预览值在松手时写盘，重开后保留', () async {
    SharedPreferences.setMockInitialValues({});
    final carMode = CarModeProvider();
    addTearDown(carMode.dispose);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final settings = SettingsRepository();

    await carMode.setDockClearance(32, persist: false);
    expect(await settings.getCarModeDockClearance(), isNot(32));
    await carMode.setDockClearance(32);
    expect(await settings.getCarModeDockClearance(), Platform.isWindows ? 32 : isNot(32));
    final reopened = CarModeProvider();
    addTearDown(reopened.dispose);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(reopened.dockClearanceDp, Platform.isWindows ? 32 : isNot(32));
  });
}
