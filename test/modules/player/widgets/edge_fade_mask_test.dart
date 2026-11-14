// EdgeFadeMask（AM 横屏播放页右栏左右边缘渐隐遮罩）+ 开关测试。
//
// 回归点：
// 1) 遮罩组件：开启时包 ShaderMask（dstIn），子内容正常渲染；
//    关闭时零开销原样返回 child（无 ShaderMask 层）；
// 2) 运行时翻转 enabled → ShaderMask 出现/消失（设置开关即时生效的组件侧语义）；
// 3) 渐隐带宽度钳制：窄栏不小于 24、超宽屏不超过 36、按比例取中值；
// 4) 尺寸变化（含极端窄容器）重建 shader 不抛异常（marquee_text「无限 rect」坑：
//    本组件只应有界使用，无界宽度不在覆盖范围）；
// 5) 设置仓：amLandscapeEdgeFade 默认开启（缺失/读取失败回 true），
//    setter 先更新内存镜像（播放页即时生效）再落盘，getter 回填镜像。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/data/repositories/settings_repository.dart';
import 'package:md3music/modules/player/widgets/edge_fade_mask.dart';

Widget _host(EdgeFadeMask mask) => MaterialApp(
  home: Scaffold(body: Center(child: mask)),
);

void main() {
  setUp(() {
    // 每条用例独立的假 prefs，避免磁盘 IO；同时隔离用例间的键值。
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() {
    // 镜像是全局静态 ValueNotifier：恢复默认，避免污染其他测试文件。
    SettingsRepository.amLandscapeEdgeFade.value = true;
  });

  group('EdgeFadeMask 组件', () {
    testWidgets('开启时包 ShaderMask 且子内容正常渲染', (tester) async {
      await tester.pumpWidget(
        _host(const EdgeFadeMask(child: Text('内容'))),
      );
      expect(find.byType(ShaderMask), findsOneWidget);
      expect(find.text('内容'), findsOneWidget);
    });

    testWidgets('关闭时零开销：无 ShaderMask 层，子内容原样保留', (tester) async {
      await tester.pumpWidget(
        _host(const EdgeFadeMask(enabled: false, child: Text('内容'))),
      );
      expect(find.byType(ShaderMask), findsNothing);
      expect(find.text('内容'), findsOneWidget);
    });

    testWidgets('运行时翻转 enabled：遮罩即时出现 / 移除', (tester) async {
      EdgeFadeMask mask = const EdgeFadeMask(enabled: false, child: Text('内容'));
      await tester.pumpWidget(_host(mask));
      expect(find.byType(ShaderMask), findsNothing);

      mask = const EdgeFadeMask(enabled: true, child: Text('内容'));
      await tester.pumpWidget(_host(mask));
      expect(find.byType(ShaderMask), findsOneWidget);

      mask = const EdgeFadeMask(enabled: false, child: Text('内容'));
      await tester.pumpWidget(_host(mask));
      expect(find.byType(ShaderMask), findsNothing);
    });

    testWidgets('尺寸变化与极端窄容器：重建 shader 不抛异常', (tester) async {
      // 常规尺寸
      await tester.pumpWidget(
        _host(const EdgeFadeMask(child: SizedBox(width: 400, height: 200))),
      );
      await tester.pump();
      // 收窄到 60（两带钳制后仍 ≤ 各半宽，ratio 钳在 0.5 以内）
      await tester.pumpWidget(
        _host(const EdgeFadeMask(child: SizedBox(width: 60, height: 200))),
      );
      await tester.pump();
      // 再放宽：缓存按宽度失效重建，不应崩溃
      await tester.pumpWidget(
        _host(const EdgeFadeMask(child: SizedBox(width: 800, height: 200))),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('edgeFadeWidth 钳制', () {
    test('窄栏取下限 24', () {
      expect(edgeFadeWidth(100), 24.0);
      expect(edgeFadeWidth(300), 24.0);
    });

    test('超宽屏取上限 36', () {
      expect(edgeFadeWidth(1200), 36.0);
    });

    test('中段按比例（6%）', () {
      expect(edgeFadeWidth(500), closeTo(30.0, 0.001));
    });

    test('自定义参数生效', () {
      expect(edgeFadeWidth(200, minFade: 10, maxFade: 20, fadeRatio: 0.5), 20.0);
      expect(edgeFadeWidth(20, minFade: 10, maxFade: 20, fadeRatio: 0.5), 10.0);
      expect(edgeFadeWidth(40, minFade: 10, maxFade: 20, fadeRatio: 0.5), 20.0);
    });
  });

  group('SettingsRepository.amLandscapeEdgeFade', () {
    test('未设置时默认开启，getter 回填内存镜像', () async {
      final repo = SettingsRepository();
      expect(SettingsRepository.amLandscapeEdgeFade.value, isTrue);
      expect(await repo.getAmLandscapeEdgeFade(), isTrue);
      expect(SettingsRepository.amLandscapeEdgeFade.value, isTrue);
    });

    test('读取已保存的关闭值：getter 返回 false 并回填镜像', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'settings_am_landscape_edge_fade': false,
      });
      final repo = SettingsRepository();
      expect(await repo.getAmLandscapeEdgeFade(), isFalse);
      expect(SettingsRepository.amLandscapeEdgeFade.value, isFalse);
    });

    test('setter 先更新内存镜像（播放页即时生效）再落盘', () async {
      final repo = SettingsRepository();
      await repo.setAmLandscapeEdgeFade(false);
      // 镜像同步更新（不等读盘）
      expect(SettingsRepository.amLandscapeEdgeFade.value, isFalse);
      // 落盘可读回
      expect(await repo.getAmLandscapeEdgeFade(), isFalse);
      expect(SettingsRepository.amLandscapeEdgeFade.value, isFalse);

      await repo.setAmLandscapeEdgeFade(true);
      expect(SettingsRepository.amLandscapeEdgeFade.value, isTrue);
      expect(await repo.getAmLandscapeEdgeFade(), isTrue);
    });
  });
}
