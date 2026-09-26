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

  test('repo 层按最宽区间夹取：0.12（底部布局合法值）不被抬高', () async {
    SharedPreferences.setMockInitialValues({});
    final repo = SettingsRepository();
    // 0.12 低于侧边下限 20% 但高于底部下限 10%：repo 层必须原样保留，
    // 精确夹取由 CarModeProvider.setPanelRatio 按布局负责。
    await repo.setCarModePanelRatio(0.12);
    expect(await repo.getCarModePanelRatio(), closeTo(0.12, 0.001));
    // 明显越界（< 10%）仍夹回
    await repo.setCarModePanelRatio(0.02);
    expect(await repo.getCarModePanelRatio(), kCarModePanelMinRatioBottom);
  });

  testWidgets('provider 按布局夹取：底部布局 0.15 合法、侧边布局夹回 0.20',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final carMode = CarModeProvider();
    try {
      // 底部布局（车机屏 + 竖屏/近方屏）
      carMode.updateScreenMetrics(isCar: true, portraitOrSquare: true);
      await carMode.setPanelRatio(0.15);
      expect(carMode.panelRatio, closeTo(0.15, 0.001));
      expect(
        await SettingsRepository().getCarModePanelRatio(),
        closeTo(0.15, 0.001),
      );

      // 同一 provider 切到侧边布局：0.15 低于 20% → 夹回
      carMode.updateScreenMetrics(isCar: true, portraitOrSquare: false);
      await carMode.setPanelRatio(0.15);
      expect(carMode.panelRatio, kCarModePanelMinRatio);
    } finally {
      carMode.dispose();
      await tester.pump(const Duration(seconds: 5));
    }
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

  testWidgets('active：强制开关 或 （自动检测开启且屏幕命中车机屏）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final carMode = CarModeProvider();
    try {
      // 默认全部关闭：不生效
      expect(carMode.active, isFalse);

      // 仅自动检测开启、屏幕未命中 → 不生效
      await carMode.setAutoScreenEnabled(true);
      expect(carMode.active, isFalse);

      // 注入命中车机屏（如方屏 880×860）→ 生效
      carMode.updateScreenMetrics(isCar: true, portraitOrSquare: true);
      expect(carMode.active, isTrue);

      // 命中失败（如普通竖屏手机长比 0.46）→ 即使开启自动检测也不生效
      await carMode.setAutoScreenEnabled(false);
      carMode.updateScreenMetrics(isCar: false, portraitOrSquare: true);
      expect(carMode.active, isFalse);

      // 强制开关开启 → 无论屏幕类型都生效
      await carMode.setEnabled(true);
      carMode.updateScreenMetrics(isCar: false, portraitOrSquare: false);
      expect(carMode.active, isTrue);
    } finally {
      carMode.dispose();
      await tester.pump(const Duration(seconds: 5));
    }
  });

  testWidgets('useBottomLayout：仅 生效 + 车机屏 + 竖屏/近方屏 三者同时成立', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final carMode = CarModeProvider();
    try {
      // 方屏 880×860（命中车机屏 + 近方屏）+ 自动检测开启 → 底部
      await carMode.setAutoScreenEnabled(true);
      carMode.updateScreenMetrics(isCar: true, portraitOrSquare: true);
      expect(carMode.useBottomLayout, isTrue);

      // 16:9 横屏车机（命中车机屏但非竖屏/方屏）→ 仍左右停靠，不走底部
      carMode.updateScreenMetrics(isCar: true, portraitOrSquare: false);
      expect(carMode.useBottomLayout, isFalse);

      // 普通竖屏手机强制开启（命中竖屏但非车机屏）→ 不走底部
      await carMode.setEnabled(true);
      carMode.updateScreenMetrics(isCar: false, portraitOrSquare: true);
      expect(carMode.useBottomLayout, isFalse);
    } finally {
      carMode.dispose();
      await tester.pump(const Duration(seconds: 5));
    }
  });

  testWidgets('自动检测开关可持久化读回', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final carMode = CarModeProvider();
    try {
      expect(carMode.autoScreenEnabled, isFalse);
      await carMode.setAutoScreenEnabled(true);
      expect(carMode.autoScreenEnabled, isTrue);
      expect(await SettingsRepository().getCarModeAutoScreenEnabled(), isTrue);
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
