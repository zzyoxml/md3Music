import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_animation_preset_store.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 歌词动画预设仓库单测：保存 / 覆盖 / 应用 / 删除 / 导入导出 / 当前匹配。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final prefs = LyricPreferences.instance;
  final store = LyricAnimationPresetStore.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await prefs.reset();
    store.resetForTest();
    await store.load();
  });

  tearDown(() => store.resetForTest());

  group('保存当前设置', () {
    test('保存 20 项参数并落盘，重新 load 后恢复', () async {
      await prefs.setInactiveScale(0.9);
      await prefs.setAlignPosition(0.5);

      final isNew = await store.saveCurrentAsPreset('测试预设');
      expect(isNew, isTrue);
      expect(store.presets.single.name, '测试预设');
      expect(
        store.presets.single.values.keys.toSet(),
        LyricPreferences.animationValueKeys.toSet(),
      );
      expect(store.presets.single.values['inactiveScale'], 0.9);

      store.resetForTest();
      await store.load();
      expect(store.presets.single.name, '测试预设');
      expect(store.presets.single.values['alignPosition'], 0.5);
    });

    test('20 项参数含透明度，内置预设自带默认透明度', () async {
      expect(LyricPreferences.animationValueKeys, hasLength(20));
      expect(prefs.exportAnimationValues().keys.toSet(),
          LyricPreferences.animationValueKeys.toSet());
      expect(prefs.exportAnimationValues()['playedOpacity'], 1.0);
      expect(prefs.exportAnimationValues()['unplayedOpacity'], 0.4);
      for (final preset in LyricAnimationPresetStore.builtInPresets) {
        expect(preset.values['playedOpacity'], 1.0,
            reason: '${preset.name} 应显式带上默认透明度');
        expect(preset.values['unplayedOpacity'], 0.4);
      }
    });

    test('旧预设缺透明度键时保持当前值，含键时按 setter clamp 生效', () async {
      await prefs.setPlayedOpacity(0.5);
      await prefs.setUnplayedOpacity(0.8);
      expect(
        await store.importFromJsonText(
          '{"name":"旧预设","values":{"alignPosition":0.4}}',
        ),
        1,
      );
      await store.applyPreset('旧预设');
      expect(prefs.playedOpacity, 0.5,
          reason: '缺键保持当前值是 applyAnimationValues 既有契约');
      expect(prefs.unplayedOpacity, 0.8);

      expect(
        await store.importFromJsonText(
          '{"name":"新预设","values":{"playedOpacity":2.5,"unplayedOpacity":0.2}}',
        ),
        1,
      );
      await store.applyPreset('新预设');
      expect(prefs.playedOpacity,
          LyricPreferences.maxPlayedOpacityForCurrentPlatform);
      expect(prefs.unplayedOpacity, 0.2);
    });

    test('同名保存覆盖参数而不是新增', () async {
      await prefs.setInactiveScale(0.9);
      expect(await store.saveCurrentAsPreset('A'), isTrue);

      await prefs.setInactiveScale(0.95);
      expect(await store.saveCurrentAsPreset('A'), isFalse);
      expect(store.presets.length, 1);
      expect(store.presets.single.values['inactiveScale'], 0.95);
    });

    test('名称 trim 并截断到 20 字符', () async {
      final longName = List<String>.filled(30, '长').join();
      await store.saveCurrentAsPreset('  $longName  ');
      expect(store.presets.single.name.length,
          LyricAnimationPresetStore.maxNameLength);
    });
  });

  group('内置性能预设', () {
    test('allPresets 首位为性能优先，用户列表仍为空', () {
      expect(
        store.allPresets.first.name,
        LyricAnimationPresetStore.defaultPresetName,
      );
      expect(store.presets, isEmpty);
    });

    test('不可删除 / 重命名 / 占用保留名称', () async {
      final reserved = LyricAnimationPresetStore.defaultPresetName;
      expect(await store.deletePreset(reserved), isFalse);
      expect(await store.renamePreset(reserved, 'X'), isFalse);
      expect(await store.saveCurrentAsPreset(reserved), isFalse);
      expect(store.presets, isEmpty);

      await store.saveCurrentAsPreset('A');
      expect(await store.renamePreset('A', reserved), isFalse);
      expect(store.presets.single.name, 'A');
    });

    test('应用性能优先写入兜底参数并可被 activePresetName 命中', () async {
      await store.applyPreset(LyricAnimationPresetStore.defaultPresetName);
      expect(prefs.alignPosition, 0.34844447355541364);
      expect(prefs.cascadeMaxDelayMs, 990.0);
      expect(prefs.staggerFromCurrentLine, isFalse);
      expect(prefs.preStartBiasMs, 118.49028694318446);
      expect(
        prefs.glowFixedThresholdMs,
        LyricAnimationPresetStore.currentPlatformTag() == 'windows'
            ? 900.0
            : 1000.0,
      );
      expect(
        store.activePresetName(),
        LyricAnimationPresetStore.defaultPresetName,
      );
    });

    test('导入保留名称自动追加序号', () async {
      await store.importFromJsonText(
        '{"name":"性能优先","values":{"alignPosition":0.4}}',
      );
      expect(store.presets.single.name, '性能优先 2');
    });

    test('全部导出不含内置预设，单独导出可得到它', () async {
      expect(
        store.exportAllAsJson(),
        isNot(contains(LyricAnimationPresetStore.defaultPresetName)),
      );
      final json = store.exportPresetAsJson(
        LyricAnimationPresetStore.defaultPresetName,
      );
      expect(json, contains('"name": "性能优先"'));
    });
  });

  group('内置流畅优先预设', () {
    const smoothName = '流畅优先';

    test('两个内置预设按序排列，且内置项不进入用户列表', () {
      expect(store.allPresets.first.name,
          LyricAnimationPresetStore.defaultPresetName);
      expect(store.allPresets[1].name, smoothName);
      expect(store.presets, isEmpty);
      // 内置预设不随用户预设一起写盘/导出
      expect(store.exportAllAsJson(), isNot(contains(smoothName)));
    });

    test('不可删除 / 重命名 / 占用保留名称', () async {
      expect(await store.deletePreset(smoothName), isFalse);
      expect(await store.renamePreset(smoothName, 'X'), isFalse);
      expect(await store.saveCurrentAsPreset(smoothName), isFalse);
      expect(store.presets, isEmpty);
    });

    test('应用后写入错峰归零与非当前行缩放 0.60，并命中 activePresetName', () async {
      await store.applyPreset(smoothName);
      expect(prefs.inactiveScale, 0.60);
      expect(prefs.alignPosition, 0.45);
      expect(prefs.liftHeightPx, 1.7);
      expect(prefs.cascadeMaxDelayMs, 0.0);
      expect(prefs.cascadeBaseStepMs, 0.0);
      expect(prefs.cascadeDecayX, 1.0);
      expect(prefs.glowFixedThresholdMs, 500.0);
      expect(prefs.staggerFromCurrentLine, isTrue);
      expect(store.activePresetName(), smoothName);
    });

    test('单独导出可得到流畅优先', () {
      final json = store.exportPresetAsJson(smoothName);
      expect(json, contains('"name": "流畅优先"'));
      expect(json, contains('"cascadeMaxDelayMs": 0.0'));
    });

    test('导入同名时自动追加序号，不覆盖内置项', () async {
      await store.importFromJsonText(
        '{"name":"流畅优先","values":{"alignPosition":0.4}}',
      );
      expect(store.presets.single.name, '流畅优先 2');
      expect(store.allPresets[1].name, smoothName);
    });
  });

  group('应用与匹配', () {
    test('应用预设：越界值 clamp，错误类型/未知键忽略，缺失键不动', () async {
      const raw = r'''
      {
        "presets": [
          {
            "name": "越界",
            "values": {
              "inactiveScale": 5.0,
              "unknownKey": 123,
              "staggerFromCurrentLine": "yes",
              "fillMode": "bogus"
            }
          }
        ]
      }
      ''';
      expect(await store.importFromJsonText(raw), 1);

      await prefs.setBlurIntensity(1.5);
      await store.applyPreset('越界');

      expect(prefs.inactiveScale, LyricPreferences.maxInactiveScale);
      // 类型/枚举非法 → 保持默认值不变
      expect(prefs.staggerFromCurrentLine,
          LyricPreferences.defaultStaggerFromCurrentLine);
      expect(prefs.fillMode, LyricFillMode.sweep);
      // 预设中没有的键保持当前值
      expect(prefs.blurIntensity, 1.5);
    });

    test('activePresetName 应用后命中，改动后不再命中', () async {
      await prefs.setAlignPosition(0.4);
      await store.saveCurrentAsPreset('A');
      expect(store.activePresetName(), 'A');

      await prefs.setAlignPosition(0.5);
      expect(store.activePresetName(), isNull);
    });

    test('局部预设按子集匹配', () async {
      await prefs.setAlignPosition(0.5);
      await store.importFromJsonText(
        '{"name":"局部","values":{"alignPosition":0.5}}',
      );
      expect(store.activePresetName(), '局部');
      await prefs.setAlignPosition(0.6);
      expect(store.activePresetName(), isNull);
    });
  });

  group('删除', () {
    test('删除命中并落盘，重复删除返回 false', () async {
      await store.saveCurrentAsPreset('A');
      expect(await store.deletePreset('A'), isTrue);
      expect(store.presets, isEmpty);
      expect(await store.deletePreset('A'), isFalse);

      store.resetForTest();
      await store.load();
      expect(store.presets, isEmpty);
    });
  });

  group('重命名', () {
    test('重命名成功并落盘，参数保持不变', () async {
      await prefs.setAlignPosition(0.4);
      await store.saveCurrentAsPreset('旧名');
      expect(await store.renamePreset('旧名', '新名'), isTrue);
      expect(store.presets.single.name, '新名');
      expect(store.presets.single.values['alignPosition'], 0.4);

      store.resetForTest();
      await store.load();
      expect(store.presets.single.name, '新名');
    });

    test('空名 / 与其它预设重名 / 旧名不存在时失败', () async {
      await store.saveCurrentAsPreset('A');
      await store.saveCurrentAsPreset('B');
      expect(await store.renamePreset('A', '  '), isFalse);
      expect(await store.renamePreset('A', 'B'), isFalse);
      expect(await store.renamePreset('不存在', 'C'), isFalse);
      expect(store.presets.map((p) => p.name), <String>['A', 'B']);
    });

    test('改成同名视为 no-op 并返回 true', () async {
      await store.saveCurrentAsPreset('A');
      expect(await store.renamePreset('A', 'A'), isTrue);
      expect(store.presets.single.name, 'A');
    });
  });

  group('导入', () {
    test('完整文档可导入多档预设', () async {
      const raw = r'''
      {
        "app": "md3music",
        "type": "md3music.lyric_animation",
        "version": 1,
        "presets": [
          {"name": "A", "values": {"alignPosition": 0.3}},
          {"name": "B", "values": {"alignPosition": 0.6}}
        ]
      }
      ''';
      expect(await store.importFromJsonText(raw), 2);
      expect(store.presets.map((p) => p.name), <String>['A', 'B']);
    });

    test('单预设对象 / 裸参数对象 / 数组均可导入', () async {
      expect(
        await store.importFromJsonText(
          '{"name":"单个","values":{"alignPosition":0.3}}',
        ),
        1,
      );
      expect(
        await store.importFromJsonText('{"alignPosition":0.4}'),
        1,
      );
      expect(store.presets.last.name, '导入预设');
      expect(
        await store.importFromJsonText(
          '[{"name":"数组","values":{"alignPosition":0.5}}]',
        ),
        1,
      );
      expect(store.presets.map((p) => p.name),
          <String>['单个', '导入预设', '数组']);
    });

    test('同一文档多个无名预设自动编号', () async {
      const raw = r'''
      [{"values": {"alignPosition": 0.3}}, {"values": {"alignPosition": 0.4}}]
      ''';
      expect(await store.importFromJsonText(raw), 2);
      expect(store.presets.map((p) => p.name),
          <String>['导入预设', '导入预设 2']);
    });

    test('同名导入覆盖已有预设', () async {
      await store.importFromJsonText(
        '{"name":"A","values":{"alignPosition":0.3}}',
      );
      await store.importFromJsonText(
        '{"name":"A","values":{"alignPosition":0.6}}',
      );
      expect(store.presets.length, 1);
      expect(store.presets.single.values['alignPosition'], 0.6);
    });

    test('无可识别参数 / 非法 JSON 抛 FormatException', () async {
      await expectLater(
        store.importFromJsonText('{"presets":[{"name":"空","values":{}}]}'),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        store.importFromJsonText('这不是 JSON'),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        store.importFromJsonText('   '),
        throwsA(isA<FormatException>()),
      );
      expect(store.presets, isEmpty);
    });

    test('parsePresetsFromJson 只解析不落库', () async {
      final parsed = store.parsePresetsFromJson('{"alignPosition":0.5}');
      expect(parsed, hasLength(1));
      expect(store.presets, isEmpty);
    });

    test('importPresets 可用 names 覆盖导入名称', () async {
      final parsed = store.parsePresetsFromJson(
        '[{"name":"A","values":{"alignPosition":0.3}},'
        '{"values":{"alignPosition":0.4}}]',
      );
      expect(await store.importPresets(
        parsed,
        names: <String>['自定义一', '自定义二'],
      ), 2);
      expect(store.presets.map((p) => p.name),
          <String>['自定义一', '自定义二']);
    });
  });

  group('平台标签', () {
    test('保存预设记录当前平台，重命名保持平台', () async {
      final platform = LyricAnimationPresetStore.currentPlatformTag();
      await store.saveCurrentAsPreset('A');
      expect(store.presets.single.platform, platform);

      await store.renamePreset('A', 'B');
      expect(store.presets.single.platform, platform);
    });

    test('导入时文档级平台写入各预设，单条可覆盖', () async {
      const raw = r'''
      {
        "platform": "tv",
        "presets": [
          {"name": "A", "values": {"alignPosition": 0.3}},
          {"name": "B", "platform": "android", "values": {"alignPosition": 0.4}}
        ]
      }
      ''';
      expect(await store.importFromJsonText(raw), 2);
      expect(store.presets[0].platform, 'tv');
      expect(store.presets[1].platform, 'android');
    });

    test('旧预设缺平台标签时按当前平台补全', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        LyricAnimationPresetStore.storageKey:
            '{"presets":[{"name":"旧","values":{"alignPosition":0.3}}]}',
      });
      store.resetForTest();
      await store.load();
      expect(store.presets.single.platform,
          LyricAnimationPresetStore.currentPlatformTag());
    });

    test('非法平台标签归一为兜底平台', () async {
      final parsed = store.parsePresetsFromJson(
        '{"platform":"macos","name":"X","values":{"alignPosition":0.3}}',
      );
      expect(parsed.single.platform,
          LyricAnimationPresetStore.currentPlatformTag());
    });

    test('导出当前设置携带自定义名称与平台标签', () async {
      await prefs.setAlignPosition(0.33);
      final json = store.exportCurrentAsJson(name: '导出名');
      expect(json, contains('"name": "导出名"'));
      expect(
        json,
        contains(
          '"platform": "${LyricAnimationPresetStore.currentPlatformTag()}"',
        ),
      );
      expect(json, contains('"alignPosition": 0.33'));
    });
  });

  group('导出', () {
    test('exportAllAsJson 往返后名称与参数一致', () async {
      await prefs.setAlignPosition(0.4);
      await store.saveCurrentAsPreset('A');
      await prefs.setAlignPosition(0.42);
      await store.saveCurrentAsPreset('B');
      final json = store.exportAllAsJson();

      // 模拟导入到全新设备：清空存储后重新导入
      SharedPreferences.setMockInitialValues(<String, Object>{});
      store.resetForTest();
      await store.load();
      expect(store.presets, isEmpty);

      expect(await store.importFromJsonText(json), 2);
      expect(store.presets.map((p) => p.name), <String>['A', 'B']);
      expect(store.presets[1].values['alignPosition'], 0.42);
    });

    test('exportCurrentAsJson 固定名「当前设置」且不入库', () async {
      await prefs.setAlignPosition(0.33);
      final json = store.exportCurrentAsJson();
      expect(json, contains('"当前设置"'));
      expect(json, contains('"alignPosition": 0.33'));
      expect(store.presets, isEmpty);
    });
  });
}
