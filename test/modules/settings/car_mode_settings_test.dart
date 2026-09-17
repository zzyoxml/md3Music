import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/data/repositories/settings_repository.dart';
import 'package:md3music/modules/player/car_mode_layout.dart';
import 'package:md3music/providers/car_mode_provider.dart';

void main() {
  test('未设置过时的默认值：关闭 / 30% / 左侧', () async {
    SharedPreferences.setMockInitialValues({});
    final repo = SettingsRepository();
    expect(await repo.getCarModeEnabled(), isFalse);
    expect(await repo.getCarModePanelRatio(), kCarModePanelDefaultRatio);
    expect(await repo.getCarModePanelSide(), CarModePanelSide.left);
  });

  test('写入后可读回', () async {
    SharedPreferences.setMockInitialValues({});
    final repo = SettingsRepository();
    await repo.setCarModeEnabled(true);
    await repo.setCarModePanelRatio(0.45);
    await repo.setCarModePanelSide(CarModePanelSide.right);
    expect(await repo.getCarModeEnabled(), isTrue);
    expect(await repo.getCarModePanelRatio(), closeTo(0.45, 0.001));
    expect(await repo.getCarModePanelSide(), CarModePanelSide.right);
  });

  testWidgets('provider 越界输入被夹回合法区间并落盘', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final carMode = CarModeProvider();
    try {
      await carMode.setPanelRatio(0.95);
      expect(carMode.panelRatio, kCarModePanelMaxRatio);
      expect(
        await SettingsRepository().getCarModePanelRatio(),
        kCarModePanelMaxRatio,
      );
    } finally {
      carMode.dispose();
      await tester.pump(const Duration(seconds: 5));
    }
  });

  testWidgets('拖动预览（persist: false）只改内存不落盘', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final carMode = CarModeProvider();
    try {
      await carMode.setPanelRatio(0.42, persist: false);
      expect(carMode.panelRatio, closeTo(0.42, 0.001));
      expect(
        await SettingsRepository().getCarModePanelRatio(),
        kCarModePanelDefaultRatio,
        reason: '拖动过程中不得高频写 SharedPreferences',
      );
      await carMode.setPanelRatio(0.42);
      expect(
        await SettingsRepository().getCarModePanelRatio(),
        closeTo(0.42, 0.001),
      );
    } finally {
      carMode.dispose();
      await tester.pump(const Duration(seconds: 5));
    }
  });

  testWidgets('车机模式关闭时面板不可见', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final carMode = CarModeProvider();
    try {
      expect(carMode.enabled, isFalse);
      expect(carMode.panelVisible, isFalse);
    } finally {
      carMode.dispose();
      await tester.pump(const Duration(seconds: 5));
    }
  });

  testWidgets('抑制计数：声明后面板不可见，成对释放后恢复', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final carMode = CarModeProvider();
    try {
      await carMode.setEnabled(true);
      expect(carMode.panelVisible, isTrue);

      carMode.suppressPanel();
      expect(carMode.panelVisible, isFalse);

      // 两个抑制方同时存活（如设置页里再 push 登录页）
      carMode.suppressPanel();
      carMode.releasePanel();
      expect(carMode.panelVisible, isFalse, reason: '还有一处未释放');

      carMode.releasePanel();
      expect(carMode.panelVisible, isTrue);

      // 重复释放不得把计数打到负数而错误显示面板
      carMode.releasePanel();
      expect(carMode.panelVisible, isTrue);
      expect(carMode.panelSuppressCount, 0);
    } finally {
      carMode.dispose();
      await tester.pump(const Duration(seconds: 5));
    }
  });
}
