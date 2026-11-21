import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/modules/player/playlist_swipe_driver.dart';

/// 记录 driver 输出、并能像真实 pager 那样做补间的宿主。
class _FakePager {
  _FakePager({required TickerProvider vsync})
    : _ticker = AnimationController(
        vsync: vsync,
        duration: const Duration(milliseconds: 300),
      ) {
    _ticker.addListener(() {
      final t = Curves.easeOutCubic.transform(_ticker.value);
      _page = _settleFrom + (_settleTo - _settleFrom) * t;
    });
  }

  double _page = 0;
  final AnimationController _ticker;

  double _settleFrom = 0;
  double _settleTo = 0;

  double get page => _page;

  /// 记录补间终点，供断言「最终落到哪一页」。
  double? settleTarget;

  void jumpTo(double page) => _page = page;

  void animateTo(double target, Duration duration, Curve curve) {
    _ticker.duration = duration;
    settleTarget = target;
    _settleFrom = _page;
    _settleTo = target;
    _ticker.forward(from: 0);
  }

  void dispose() => _ticker.dispose();
}

/// 带 TickerProvider 的测试壳：driver 需要能起补间时钟。
class _Host extends StatefulWidget {
  const _Host();

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with TickerProviderStateMixin {
  late final _FakePager pager = _FakePager(vsync: this);
  late final PlaylistSwipeDriver driver = PlaylistSwipeDriver(
    readPage: () => pager.page,
    jumpToPage: pager.jumpTo,
    animateToPage: pager.animateTo,
  );

  @override
  void dispose() {
    pager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

void main() {
  group('PlaylistSwipeDriver', () {
    testWidgets('update：逐帧把页位置写成「起点 + 进度」', (tester) async {
      await tester.pumpWidget(const _Host());
      final host = tester.state<_HostState>(find.byType(_Host));

      host.driver.start();
      host.driver.update(0.3);
      await tester.pump();
      expect(host.pager.page, closeTo(0.3, 1e-9));

      host.driver.update(0.6);
      await tester.pump();
      expect(host.pager.page, closeTo(0.6, 1e-9));
    });

    testWidgets('update：进度钳制在 0~1 页', (tester) async {
      await tester.pumpWidget(const _Host());
      final host = tester.state<_HostState>(find.byType(_Host));

      host.driver.start();
      host.driver.update(2.5);
      expect(host.pager.page, 1.0);

      host.driver.update(-3.0);
      expect(host.pager.page, 0.0);
    });

    testWidgets('松手滑过一半 → 补间到第 1 页', (tester) async {
      await tester.pumpWidget(const _Host());
      final host = tester.state<_HostState>(find.byType(_Host));

      host.driver.start();
      host.driver.update(0.7);
      host.driver.settle(velocityPxPerSec: 0, panelWidth: 400);
      expect(host.pager.settleTarget, 1.0);

      await tester.pumpAndSettle();
      expect(host.pager.page, closeTo(1.0, 1e-9));
    });

    testWidgets('松手不足一半 → 补间回弹到第 0 页，绝不卡在半路', (tester) async {
      await tester.pumpWidget(const _Host());
      final host = tester.state<_HostState>(find.byType(_Host));

      host.driver.start();
      host.driver.update(0.2);
      host.driver.settle(velocityPxPerSec: 0, panelWidth: 400);
      expect(host.pager.settleTarget, 0.0);

      await tester.pumpAndSettle();
      expect(host.pager.page, closeTo(0.0, 1e-9));
    });

    testWidgets('快速轻扫：位移不足半页也翻到第 1 页', (tester) async {
      await tester.pumpWidget(const _Host());
      final host = tester.state<_HostState>(find.byType(_Host));

      host.driver.start();
      host.driver.update(0.2);
      host.driver.settle(velocityPxPerSec: -3000, panelWidth: 400);
      expect(host.pager.settleTarget, 1.0);
    });

    test('settleDuration：距离越短动画越短，且落在 120~300ms', () {
      expect(PlaylistSwipeDriver.settleDuration(0.0, 1.0).inMilliseconds, 300);
      expect(PlaylistSwipeDriver.settleDuration(0.5, 0.0).inMilliseconds, 210);
      expect(PlaylistSwipeDriver.settleDuration(1.0, 1.0).inMilliseconds, 120);
    });
  });
}