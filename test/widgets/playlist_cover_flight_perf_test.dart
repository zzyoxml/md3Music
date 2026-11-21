import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/layout/adaptive_navigator.dart';
import 'package:md3music/core/layout/responsive_layout.dart';
import 'package:md3music/core/theme/app_dimens.dart';
import 'package:md3music/widgets/playlist_cover_hero.dart';

/// 歌单封面连贯过渡的**常驻成本**回归测试。
///
/// 飞行本身只活 300ms + 尾巴 120ms；真正会伤到 120Hz 帧率的是「转场之外还在付费」
/// 的部分：每次封面绘制的几何实测、每次来源登记/注销引起的整层重建。
/// 这些一律用计数器 `coverFlightDebugMeasureCalls` / `bus.revision` 断言为 0。
///
/// 来源登记只发生在 pane 自绘路径（真双栏/面板内），harness 统一包一层桌面语义
/// `DetailPaneScope`（twoPane 默认 true）让封面照常登记；单栏框架 Hero 路径
/// 不登记，另有分派测试钉住。
void main() {
  setUp(coverFlightDebugResetMeasureCalls);
  tearDown(PlaylistCoverFlightBus.instance.debugReset);

  Future<void> pumpCoverList(WidgetTester tester, {int count = 30}) async {
    await tester.pumpWidget(MaterialApp(
      home: DetailPaneScope(
        detailKey: GlobalKey<NavigatorState>(),
        child: Scaffold(
          body: ListView(
            children: [
              for (var i = 0; i < count; i++)
                SizedBox(
                  height: 60,
                  child: SizedBox(
                    width: 52,
                    height: 52,
                    child: PlaylistCoverHero(
                      tag: playlistCoverHeroTag('$i'),
                      radius: AppRadius.smAll,
                      child: ColoredBox(color: Color(0xFF000000 + i * 0x10101)),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('长列表滚动不触发封面几何实测', (tester) async {
    await pumpCoverList(tester);
    expect(
      coverFlightDebugMeasureCalls,
      0,
      reason: '首帧绘制不应产生任何几何实测：矩形只在起飞时按需算',
    );

    final list = find.byType(ListView);
    for (var i = 0; i < 12; i++) {
      await tester.drag(list, const Offset(0, -120));
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(
      coverFlightDebugMeasureCalls,
      0,
      reason: '滚动期每次封面绘制都实测 = 常驻成本，必须为 0',
    );
  });

  testWidgets('来源登记/注销不通知飞行层重建', (tester) async {
    final bus = PlaylistCoverFlightBus.instance;
    bus.debugReset();
    // debugReset 自己会通知一次；先让那次微任务落地，再取基线。
    await tester.pumpAndSettle();
    final revision = bus.revision.value;

    // 登记：整棵新树挂载，每个封面各注册一条来源。
    await pumpCoverList(tester);
    expect(bus.debugSourceCount(playlistCoverHeroTag('3')), 1);

    // 注销：必须把封面整棵拆掉。只换 ListView 的 children 是假绿——无 key 的
    // 同类型 Element 只会被 update，既没有 dispose 也没有新挂载，
    // register/unregister 一次都不发生，断言等于没测。
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Center(child: Text('空')))),
    );
    await tester.pumpAndSettle();
    expect(bus.debugSourceCount(playlistCoverHeroTag('3')), 0);

    expect(
      bus.revision.value,
      revision,
      reason: '来源集合变化不改变画面；只有航班起止才需要重建飞行层',
    );
  });

  testWidgets('武装 pane push 只实测最近画过的来源，陈旧条目走缓存', (tester) async {
    final bus = PlaylistCoverFlightBus.instance;
    coverFlightDebugResetMeasureCalls();

    // 一个"最近还在画"的来源：给它真实渲染树（探针会把 RenderBox 交给登记簿）。
    await tester.pumpWidget(MaterialApp(
      home: DetailPaneScope(
        detailKey: GlobalKey<NavigatorState>(),
        child: Scaffold(
          body: SizedBox(
            width: 52,
            height: 52,
            child: PlaylistCoverHero(
              tag: playlistCoverHeroTag('fresh'),
              radius: AppRadius.smAll,
              child: const ColoredBox(color: Colors.red),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    coverFlightDebugResetMeasureCalls();

    // 一个早就停在屏外的陈旧条目：没有渲染树，只有缓存矩形。
    final stale = bus.registerSource(
      playlistCoverHeroTag('stale'),
      Object(),
      BorderRadius.zero,
      const SizedBox.shrink(),
    );
    stale.rect = const Rect.fromLTWH(-9999, 0, 52, 52);

    bus.armPanePush(MaterialPageRoute<void>(builder: (_) => const SizedBox.shrink()));

    // 新鲜条目被实测（拿到点击那一刻的真实位置），陈旧条目只读缓存 → 恰好 1 次。
    expect(coverFlightDebugMeasureCalls, 1);
    expect(stale.restRect, const Rect.fromLTWH(-9999, 0, 52, 52));
  });

  testWidgets('开关关闭时不登记来源', (tester) async {
    final bus = PlaylistCoverFlightBus.instance;
    kPlaylistCoverTransitionEnabled.value = false;
    addTearDown(() => kPlaylistCoverTransitionEnabled.value = true);

    await tester.pumpWidget(MaterialApp(
      home: DetailPaneScope(
        detailKey: GlobalKey<NavigatorState>(),
        child: Scaffold(
          body: SizedBox(
            width: 52,
            height: 52,
            child: PlaylistCoverHero(
              tag: playlistCoverHeroTag('off'),
              radius: AppRadius.smAll,
              child: const ColoredBox(color: Colors.red),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();

    expect(bus.debugSourceCount(playlistCoverHeroTag('off')), 0);
    expect(coverFlightDebugMeasureCalls, 0);
  });
}
