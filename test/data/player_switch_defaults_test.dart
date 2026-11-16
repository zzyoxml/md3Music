// 播放页三个形态开关的默认值口径。
//
// 三个开关都只影响形态，翻错方向不会崩溃，只会静默退回另一套布局 —— 所以每个都要
// 钉住三条：① 从没落过盘时拿到什么默认值；② 显式反向设置后照旧（一键回退位仍在）；
// ③ 内存镜像（ValueNotifier）的初值与持久化默认一致，否则启动载入完成前会按另一套
// 形态渲染一帧。
//
// 原先是三个逐字同构的文件（各 35 行左右，只差 key、getter 与 notifier），合成一份。
// 注意：本文件内**不要**给任何 notifier 赋值，否则后面的「初值」断言测的就不再是
// 进程启动时的状态（flutter test 每个文件独立 isolate，文件内顺序即执行顺序）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/repositories/settings_repository.dart';
import 'package:md3music/utils/landscape_immersive.dart';
import 'package:md3music/widgets/player_top_bar_actions.dart';
import 'package:md3music/widgets/player_top_bar_tab_dots.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('横屏控制面板独立页：默认关（常驻控制带）', () {
    test('从没设置过：默认走常驻控制带', () async {
      SharedPreferences.setMockInitialValues({});
      expect(
        await SettingsRepository().getLandscapeDetachedControls(),
        isFalse,
        reason: '未落过盘的用户必须拿到新默认值 false，否则改造看不见',
      );
    });

    test('用户显式开启后照旧走独立页（一键回退位仍在）', () async {
      SharedPreferences.setMockInitialValues({});
      final repo = SettingsRepository();
      await repo.setLandscapeDetachedControls(true);
      expect(await repo.getLandscapeDetachedControls(), isTrue);
    });

    test('内存镜像初值与持久化默认一致', () {
      expect(kLandscapeDetachedControlsEnabled.value, isFalse);
    });
  });

  group('胶囊按钮收缩：默认开（竖屏尾部合成图标胶囊）', () {
    test('从没设置过：默认为开', () async {
      SharedPreferences.setMockInitialValues({});
      expect(
        await SettingsRepository().getTopBarPillCollapse(),
        isTrue,
        reason: '未落过盘的用户必须拿到默认 true，否则新形态看不见',
      );
    });

    test('用户显式关闭后保持关闭', () async {
      SharedPreferences.setMockInitialValues({});
      final repo = SettingsRepository();
      await repo.setTopBarPillCollapse(false);
      expect(await repo.getTopBarPillCollapse(), isFalse);
    });

    test('内存镜像初值与持久化默认一致', () {
      expect(kTopBarPillCollapseEnabled.value, isTrue);
    });
  });

  group('顶栏页签圆点：默认关（页签条留在竖屏底部、原 icon 形态）', () {
    test('从没设置过：默认为关', () async {
      SharedPreferences.setMockInitialValues({});
      expect(
        await SettingsRepository().getTopBarTabDots(),
        isFalse,
        reason: '未落过盘的用户必须拿到默认 false，即原底部 icon 形态',
      );
    });

    test('用户显式开启后照旧上顶栏', () async {
      SharedPreferences.setMockInitialValues({});
      final repo = SettingsRepository();
      await repo.setTopBarTabDots(true);
      expect(await repo.getTopBarTabDots(), isTrue);
    });

    test('内存镜像初值与持久化默认一致', () {
      expect(kTopBarTabDotsEnabled.value, isFalse);
    });
  });
}
