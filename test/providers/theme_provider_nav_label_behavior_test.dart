import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/providers/theme_provider.dart';

/// 底栏优化批次 5b —— `navLabelBehavior` 三档读写与 L4 迁移兼容回归。
///
/// 持久化在批次 5a 已从「enum index」改为「enum name」（theme_provider.dart 的
/// `_loadNavLabelBehavior` / `setNavLabelBehavior`）：
/// - 读：用**不做类型转换**的 `prefs.get()` 读原始值——String 走 name 匹配，Int 走
///   index 迁移（命中即**就地覆写为 name**，同 key setString，类型随之变 String），
///   其余（无值 / 越界 / 无法匹配）保持默认 alwaysHide。
///   ⚠️ `getString` 对 Int 存量、`getInt` 对 String 存量都会**抛类型转换异常**（不是
///   返回 null），故本文件断言一律用 `get()` 读原始值再判型，不能指望「另一形态读回 null」。
/// - 写：`setNavLabelBehavior` 只写 name，且与当前值同值时直接返回不落盘。
///
/// ⚠️ 本仓的 `NavigationDestinationLabelBehavior` 解析到 **material_ui** 的枚举
/// （theme_provider 只 import material_ui，不 import flutter/material）；其声明顺序为
/// alwaysShow(0) / alwaysHide(1) / onlyShowSelected(2)，与 flutter/material 原生的
/// alwaysShow / onlyShowSelected / alwaysHide **不同序** —— 这正是 L4「按 index 存会
/// 静默错档」风险的实锤来源，迁移用例因此按下标逐个钉死映射。
void main() {
  // 与 theme_provider.dart 私有常量 `_navLabelBehaviorKey` 的字符串值保持一致；
  // 该常量不对外暴露，改名时本文件会以失败用例报警。
  const key = 'nav_label_behavior';

  // 构造函数触发的各 loader 均为异步（unawaited），沿用仓内 theme_provider_*_test
  // 的既有手法：等 50ms 让 SharedPreferences 读回与迁移覆写落地。
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('三档读写与默认值', () {
    test('空存量默认 alwaysHide（始终不显示），且载入不反写持久化', () async {
      final tp = ThemeProvider();
      await settle();
      expect(tp.navLabelBehavior, NavigationDestinationLabelBehavior.alwaysHide);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(key), isNull, reason: '默认值不写入存量');
      expect(prefs.getInt(key), isNull);
    });

    test('setNavLabelBehavior 以 name 落盘（String，不再是 Int），新实例读回一致', () async {
      final tp = ThemeProvider();
      await settle();

      await tp.setNavLabelBehavior(NavigationDestinationLabelBehavior.alwaysShow);
      var prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(key), 'alwaysShow');
      expect(prefs.get(key), isA<String>(), reason: '写的是 name，不残留 index 形态');

      final tp2 = ThemeProvider();
      await settle();
      expect(tp2.navLabelBehavior, NavigationDestinationLabelBehavior.alwaysShow);

      await tp2.setNavLabelBehavior(
        NavigationDestinationLabelBehavior.onlyShowSelected,
      );
      prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(key), 'onlyShowSelected');
      expect(prefs.get(key), isA<String>());

      // 切到 alwaysHide 前值不是 alwaysHide，setter 同值短路不会拦截这次写入。
      final tp3 = ThemeProvider();
      await settle();
      expect(tp3.navLabelBehavior, NavigationDestinationLabelBehavior.onlyShowSelected);
      await tp3.setNavLabelBehavior(
        NavigationDestinationLabelBehavior.alwaysHide,
      );
      prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(key), 'alwaysHide');

      final tp4 = ThemeProvider();
      await settle();
      expect(tp4.navLabelBehavior, NavigationDestinationLabelBehavior.alwaysHide);
    });

    test('同值重复 set 直接返回，不产生新的写入', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        key: 'alwaysShow',
      });
      final tp = ThemeProvider();
      await settle();
      expect(tp.navLabelBehavior, NavigationDestinationLabelBehavior.alwaysShow);
      await tp.setNavLabelBehavior(NavigationDestinationLabelBehavior.alwaysShow);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(key), 'alwaysShow', reason: '值不变，仍为原 name');
      expect(prefs.get(key), isA<String>());
    });
  });

  group('L4 迁移兼容：旧 enum index 存量', () {
    // 旧版本按 `NavigationDestinationLabelBehavior.values[index]` 写入的 Int 存量，
    // 映射按 material_ui 枚举声明顺序钉死（见文件头 ⚠️）。
    const legacyCases = <int, NavigationDestinationLabelBehavior>{
      0: NavigationDestinationLabelBehavior.alwaysShow,
      1: NavigationDestinationLabelBehavior.alwaysHide,
      2: NavigationDestinationLabelBehavior.onlyShowSelected,
    };

    for (final entry in legacyCases.entries) {
      test('存量旧 index ${entry.key} → ${entry.value.name}，载入后就地覆写为 name', () async {
        SharedPreferences.setMockInitialValues(<String, Object>{key: entry.key});
        final tp = ThemeProvider();
        await settle();

        expect(tp.navLabelBehavior, entry.value,
            reason: '旧 index 存量按当前枚举顺序解析');
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString(key), entry.value.name,
            reason: '读到旧 index 立即用 name 覆写同一 key');
        expect(prefs.get(key), isA<String>(),
            reason: '同 key 覆写后类型已变 String，不再残留 Int 存量');
      });
    }

    test('迁移是幂等的：迁移后的实例重新加载仍读回同档，且不再触发写入', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{key: 2});
      ThemeProvider();
      await settle();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(key), 'onlyShowSelected', reason: '第一次加载完成迁移');

      final tp2 = ThemeProvider();
      await settle();
      expect(tp2.navLabelBehavior, NavigationDestinationLabelBehavior.onlyShowSelected);
      expect(prefs.getString(key), 'onlyShowSelected', reason: '走 name 分支，值不变');
      expect(prefs.get(key), isA<String>());
    });

    test('越界 index（99 / -1）：保持默认 alwaysHide，不崩溃也不覆写', () async {
      for (final bad in <int>[99, -1]) {
        SharedPreferences.setMockInitialValues(<String, Object>{key: bad});
        final tp = ThemeProvider();
        await settle();
        expect(tp.navLabelBehavior, NavigationDestinationLabelBehavior.alwaysHide,
            reason: 'index 越界不解析（值域校验在 0..values.length-1）');
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getInt(key), bad, reason: '越界存量原样保留，不被误迁移覆写');
        expect(prefs.get(key), isA<int>(), reason: '越界存量仍为 Int，未被覆写成 name');
      }
    });

    test('非法 name 字符串（乱值）：保持默认 alwaysHide，不崩溃也不覆写', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        key: 'bogusBehavior',
      });
      final tp = ThemeProvider();
      await settle();
      expect(tp.navLabelBehavior, NavigationDestinationLabelBehavior.alwaysHide);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(key), 'bogusBehavior', reason: 'name 分支匹配不到即原样保留');
      expect(prefs.get(key), isA<String>());
    });
  });
}
