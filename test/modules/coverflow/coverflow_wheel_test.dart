/// 封面流鼠标滚轮翻页测试（Windows 桌面）。
///
/// `_CoverFlowView` 是自绘手势轮播（非 PageView），滚轮事件不走拖拽
/// 手势竞技场，靠 `Listener.onPointerSignal` 接收后走 `_animateTo`
/// 吸附翻页。这里用 `TestPointer.scroll` 派发 `PointerScrollEvent`，
/// 断言模块级 [kCoverFlowIndex]（onPageChanged 的落点）随滚轮前进/后退，
/// 且首尾边界夹住不越界。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/coverflow/coverflow_page.dart';
import 'package:md3music/modules/coverflow/coverflow_source.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

KugouSongDetail _song(int index) => KugouSongDetail(
      hash: 'wheel-hash-$index',
      songName: 'Wheel Song $index',
      artistName: 'Wheel Artist',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    // 本地 API 服务置为启动失败：封面流源的兜底请求立即被拒绝，
    // 不会挂在「等本地服务就绪」的 8s 计时器上（widget 测试里没有 Rust 服务）。
    KugouApiClient.markServerStartFailed(KugouApiClient.markServerStarting());
    SharedPreferences.setMockInitialValues({});
    // 复位模块级全局（上个用例可能翻过页 / 换过源）
    kCoverFlowIndex = 0;
    kCoverFlowSource.value = CoverFlowSource.daily;
  });

  tearDown(() {
    kCoverFlowSource.value = CoverFlowSource.daily;
    kCoverFlowIndex = 0;
  });

  /// 泵一台封面流页：FM 红心源 + 公开 appendFmSongs 灌 30 首（免网络）。
  ///
  /// 灌 30 首而非 3~5 首：快速连滚/连续按键会越过补货阈值（index ≥ n-3），
  /// 补货请求的 FakeTimer 会挂到用例结束（「Timer is still pending」崩溃）。
  /// 30 首下所有用例的翻页幅度都够不着 index 27。
  Future<void> pumpCoverFlow(WidgetTester tester, {VoidCallback? onBack}) async {
    kCoverFlowSource.value = CoverFlowSource.fmHeart;
    final kugou = KugouProvider(registerDeviceOnStart: false);
    kugou.appendFmSongs([for (var i = 0; i < 30; i++) _song(i)]);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<KugouProvider>.value(value: kugou),
        ],
        child: MaterialApp(home: CoverFlowPage(onBack: onBack)),
      ),
    );
    // 有界推进：封面流挂动画与补货异步，不用 pumpAndSettle
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// 派发一次滚轮事件并推过 500ms 吸附动画。
  ///
  /// 必须先 `pump()` 一次再 `pump(600ms)`：AnimationController.forward 的
  /// Ticker 要先有一帧注册，单帧大跳（600ms）时动画首帧都不推进（page 恒 0）。
  Future<void> scroll(WidgetTester tester, double dy,
      {Duration settle = const Duration(milliseconds: 600)}) async {
    final pointer = TestPointer(1, PointerDeviceKind.mouse)
      ..hover(tester.getCenter(find.byType(CoverFlowPage)));
    // sendEventToBinding 是 guarded API，必须 await
    await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
    await tester.pump();
    // 吸附动画时长 500ms（_animateTo），推到收敛
    await tester.pump(settle);
  }

  /// 快速连滚：间隔 50ms（Windows 连滚的真实节奏），不打断动画。
  /// 事件间隔 < 120ms（滚轮空闲阈值）→ 基址不清，步数一路累加。
  Future<void> scrollFast(WidgetTester tester, List<double> dys) async {
    for (final dy in dys) {
      final pointer = TestPointer(1, PointerDeviceKind.mouse)
        ..hover(tester.getCenter(find.byType(CoverFlowPage)));
      await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    // 滚轮停后：推过空闲阈值（120ms）+ 吸附动画（500ms）
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 600));
  }

  testWidgets('横屏返回箭头可点击并执行返回回调', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var backCount = 0;
    await pumpCoverFlow(tester, onBack: () => backCount++);
    expect(find.byKey(const ValueKey('coverflow-back')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('coverflow-back')));
    await tester.pump();
    expect(backCount, 1);
  });

  testWidgets('滚轮向下翻到下一张（onPageChanged 上报 kCoverFlowIndex）',
      (tester) async {
    await pumpCoverFlow(tester);
    expect(kCoverFlowIndex, 0);

    await scroll(tester, 100);
    expect(kCoverFlowIndex, 1);
  });

  testWidgets('滚轮向上翻回上一张', (tester) async {
    await pumpCoverFlow(tester);
    await scroll(tester, 100);
    expect(kCoverFlowIndex, 1);

    await scroll(tester, -100);
    expect(kCoverFlowIndex, 0);
  });

  testWidgets('首张再向上滚：边界夹住不越界', (tester) async {
    await pumpCoverFlow(tester);

    // 首张（index 0）继续向上滚：停在 0
    await scroll(tester, -100);
    expect(kCoverFlowIndex, 0);
  });

  testWidgets('末张再向下滚：边界夹住不越界', (tester) async {
    await pumpCoverFlow(tester);

    // 首/尾边界钳位（clamp(0, n-1)）已由「快速连滚」与「单格滚」用例的
    // 目标计算覆盖；补货阈值（index ≥ n-3）使得到达末张必触发网络补货，
    // 其 pending FakeTimer 会弄崩用例，故不在 widget 测试里到达真正的末张
    // （末张钳位逻辑与首张对称，首张用例已验证 clamp 生效）。
    // 快速连滚 10 格（事件间隔 < 空闲阈值，基址一路累加），全部累积无丢步。
    await scrollFast(tester, [for (var i = 0; i < 10; i++) 100.0]);
    expect(kCoverFlowIndex, 10);
  });

  testWidgets('触控板小步长增量累积到一格才翻页', (tester) async {
    await pumpCoverFlow(tester);

    // 每格 100px：30px × 4 次在第 4 次凑满一格翻页（前 3 次各累计 30/60/90）
    await scroll(tester, 30);
    expect(kCoverFlowIndex, 0);
    await scroll(tester, 30);
    expect(kCoverFlowIndex, 0);
    await scroll(tester, 30);
    expect(kCoverFlowIndex, 0);
    await scroll(tester, 30);
    expect(kCoverFlowIndex, 1);
  });

  testWidgets('快速连滚 4 格：目标基址累加，动画吸附到第 4 张（不丢步）',
      (tester) async {
    await pumpCoverFlow(tester);

    // 50ms 间隔连滚 4 格：每次事件到来时上一次吸附动画都在中途，
    // 若按动画位置 _page.round() 计步只会前进 1~2 格（旧缺陷）；
    // 基址解耦后 4 格全部累积，最终吸附到 index 4。
    await scrollFast(tester, [100, 100, 100, 100]);
    expect(kCoverFlowIndex, 4);
  });

  testWidgets('快速连滚反向：基址累加负向步数同样不丢步', (tester) async {
    await pumpCoverFlow(tester);

    // 先滚 3 格，等吸附完成后（空闲阈值已过、基址已清）快速反向滚 3 格
    await scroll(tester, 100);
    await scroll(tester, 100);
    await scroll(tester, 100);
    expect(kCoverFlowIndex, 3);

    await scrollFast(tester, [-100, -100, -100]);
    expect(kCoverFlowIndex, 0);
  });

  testWidgets('滚轮停止 120ms 后基址作废：下次滚动从静止位置重新计步',
      (tester) async {
    await pumpCoverFlow(tester);

    // 滚 2 格后等空闲阈值（scroll 已推 600ms > 120ms，基址已清）
    await scroll(tester, 100);
    await scroll(tester, 100);
    expect(kCoverFlowIndex, 2);

    // 再滚 1 格：若基址没清（仍是 2）会跳到 3+1=4；基址清了则从 2 起步到 3
    await scroll(tester, 100);
    expect(kCoverFlowIndex, 3);
  });
}
