import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/modules/settings/settings_navigation.dart';

void main() {
  group('resolveSettingsLevel', () {
    test('两级都为空 = 总览', () {
      expect(
        resolveSettingsLevel(category: null, subpage: null),
        SettingsLevel.overview,
      );
    });

    test('有分类无子页 = 分类二级页', () {
      expect(
        resolveSettingsLevel(category: '外观', subpage: null),
        SettingsLevel.category,
      );
    });

    test('分类与子页都有 = 三级子页', () {
      expect(
        resolveSettingsLevel(category: '外观', subpage: '主题与配色'),
        SettingsLevel.subpage,
      );
    });
  });

  group('settingsBackTarget', () {
    test('三级返回二级：保留分类、清空子页', () {
      expect(
        settingsBackTarget(category: '外观', subpage: '主题与配色'),
        (category: '外观', subpage: null),
      );
    });

    test('二级返回总览', () {
      expect(
        settingsBackTarget(category: '外观', subpage: null),
        (category: null, subpage: null),
      );
    });

    test('总览页无可退目标（交还系统返回）', () {
      expect(settingsBackTarget(category: null, subpage: null), isNull);
    });
  });

  group('settingsUseTwoPaneLayout', () {
    test('Pad 竖屏（宽 853）= 双列', () {
      expect(settingsUseTwoPaneLayout(padLayout: true, width: 853), isTrue);
    });

    test('Pad 横屏（宽 1365）= 双列', () {
      expect(settingsUseTwoPaneLayout(padLayout: true, width: 1365), isTrue);
    });

    test('Pad 但视口宽度跌出 600（显示大小调大后）= 单列', () {
      expect(settingsUseTwoPaneLayout(padLayout: true, width: 599), isFalse);
    });

    test('手机横屏宽 869（非 Pad 设备）= 单列', () {
      expect(settingsUseTwoPaneLayout(padLayout: false, width: 869), isFalse);
    });

    test('桌面外壳（计划 4.4 A 类）= 单列', () {
      expect(
        settingsUseTwoPaneLayout(
          padLayout: true,
          width: 1365,
          desktopLayout: true,
        ),
        isFalse,
      );
    });
  });

  group('SettingsCategory', () {
    test('subpageNamed 命中、未命中与 null 入参', () {
      final category = SettingsCategory(
        title: '外观',
        icon: Icons.palette_outlined,
        description: '主题、字体与界面背景',
        body: (_) => const SizedBox.shrink(),
        subpages: [
          SettingsSubpage(
            title: '主题与配色',
            icon: Icons.brightness_6_outlined,
            description: '明暗模式、OLED 纯黑与主题色来源',
            builder: (_) => const SizedBox.shrink(),
          ),
        ],
      );
      expect(category.hasSubpages, isTrue);
      expect(category.subpageNamed('主题与配色')?.title, '主题与配色');
      expect(category.subpageNamed('不存在的子页'), isNull);
      expect(category.subpageNamed(null), isNull);
    });

    test('旧扩展点 record 转换后无子页、无置顶内容', () {
      final category = settingsCategoryFromLegacy(
        ('边听边存', Icons.download_outlined, (_) => const SizedBox.shrink()),
      );
      expect(category.title, '边听边存');
      expect(category.hasSubpages, isFalse);
      expect(category.leading, isNull);
      expect(category.subpageNamed('任意'), isNull);
    });
  });
}
