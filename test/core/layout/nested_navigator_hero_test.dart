import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:md3music/core/theme/app_dimens.dart';
import 'package:md3music/widgets/playlist_cover_hero.dart';

/// 手机外壳把每个 Tab 的内容装在一个**嵌套 Navigator**里（`responsive_shell.dart`
/// 的 `_buildTab`）。flutter 的规则是：一个 HeroController 只服务一个 Navigator，
/// 且被某个 Navigator 取用后会拦住其子树里的下级 Navigator 再取用同一个
/// （`navigator.dart` 的 `_updateHeroController` 里那条 assert）。
///
/// 所以 MaterialApp 根 Navigator 那个控制器**管不到 Tab 内容栈**：Tab 栈里 push
/// 的详情页，框架 Hero 永远不会飞（真机实测：两端 tag 一致、开关为开，shuttle
/// 一次都没跑）。修法是在 Tab 栈外面套一层自带的 `HeroControllerScope`。
///
/// 本文件钉住两件事：① 带自带 scope 时确实会飞；② 不套 scope 时确实不飞
///（这条就是当年「专辑卡没效果」的现场，别再退回那个形态）。
void main() {
  const tag = 'md3/album-cover/958706';

  Widget sourceCover() => PlaylistCoverHero(
        tag: tag,
        radius: const BorderRadius.vertical(top: Radius.circular(AppRadius.md)),
        child: const SizedBox(
          width: 120,
          height: 120,
          child: ColoredBox(color: Color(0xFFFF0000)),
        ),
      );

  Widget destCover() => PlaylistCoverHero(
        tag: tag,
        radius: AppRadius.mdAll,
        child: const SizedBox(
          width: 140,
          height: 140,
          child: ColoredBox(color: Color(0xFF0000FF)),
        ),
      );

  /// 复刻 Tab 内容栈：外层是 app 的根 Navigator（MaterialApp），里层是 Tab 自己的。
  Widget shell({HeroController? ownController}) {
    final tabStack = Navigator(
      onGenerateRoute: (_) => MaterialPageRoute<void>(
        builder: (tabContext) => Scaffold(
          body: Column(
            children: [
              sourceCover(),
              TextButton(
                onPressed: () => Navigator.of(tabContext).push(
                  MaterialPageRoute<void>(
                    builder: (_) => Scaffold(body: destCover()),
                  ),
                ),
                child: const Text('open'),
              ),
            ],
          ),
        ),
      ),
    );
    return MaterialApp(
      home: ownController == null
          ? tabStack
          : HeroControllerScope(controller: ownController, child: tabStack),
    );
  }

  /// 起飞判据：飞行中 shuttle 的封面圆角在两端之间插值（下圆角 0 → 12）。
  /// 静止两端的下圆角只会是 0 或 12，出现中间值 = shuttle 真的跑了。
  Future<bool> shuttleRan(WidgetTester tester, Widget app) async {
    await tester.pumpWidget(app);
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    return tester.widgetList<ClipRRect>(find.byType(ClipRRect)).any((c) {
      final bottom = c.borderRadius.resolve(TextDirection.ltr).bottomLeft.x;
      return bottom > 0.5 && bottom < 11.5;
    });
  }

  testWidgets('Tab 内容栈自带 HeroControllerScope → 栈内 push 的封面会飞',
      (tester) async {
    final controller = MaterialApp.createMaterialHeroController();
    addTearDown(controller.dispose);

    expect(tester.takeException(), isNull);
    expect(await shuttleRan(tester, shell(ownController: controller)), isTrue);
  });

  testWidgets('不套 scope（修复前的形态）→ 同一个 Navigator 栈内也不飞',
      (tester) async {
    expect(await shuttleRan(tester, shell()), isFalse);
  });

  // 已知残留（2026-10-06 真机）：飞行途中窗口高度变化时（本 App 是
  // `windowSoftInputMode=adjustResize`，输入法收起就是这种），框架换算 shuttle
  // 四边用的 `manifest.navigatorSize` 是起飞那一刻取的一次性值（heroes.dart:1033），
  // 封面会被撑高/压扁一个键盘高（实测 140 被撑成 436）。
  //
  // 在 shuttle 内按两端实测尺寸纠正是试过的路子：入场确实干净了，但那个尺寸只能在
  // 帧末回调里量（build 阶段读别的 RenderBox 会断言失败），于是退场会先按错的尺寸画
  // 一帧再跳回正确尺寸 = 「放大缩小抽搐一下」，比原缺陷更显眼，已回退。
  // 彻底解法是让根路径也走 PlaylistCoverFlightBus 的自绘飞行（两端都实时实测，
  // 不依赖 navigatorSize），而不是继续在这个盒子上打补丁。
}
