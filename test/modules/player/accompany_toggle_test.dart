import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/modules/player/accompany_toggle.dart';

/// 伴唱按钮：尺寸、短按开关、图标状态、以及**按来源分流的比例交互**。
///
/// 组件是纯 UI（开关 / 比例回调由宿主处理），这里不依赖 Provider / 音频服务。
///
/// 两种形态是本次修复的核心差异：
/// - 在线伴奏（`adjustable: false`）：只有短按开关。两条独立解码管线，比例
///   小于 1 必然错位（历史偏移滑块与自动对齐都因此失败），故固定纯伴奏。
/// - 端侧分离（`adjustable: true`）：长按生长 + 拖动改比例。它只有一条输出
///   管线，混音在 AudioProcessor 里做，调比例不会错位。
Widget _host({
  required bool active,
  required VoidCallback onTap,
  bool adjustable = false,
  double mix = 1.0,
  ValueChanged<double>? onMixChanged,
}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: AccompanyToggle(
        active: active,
        mix: mix,
        adjustable: adjustable,
        onTap: onTap,
        onMixChanged: onMixChanged ?? (_) {},
      ),
    ),
  ),
);

/// 长按后按住拖动指定位移（负值 = 向上）。
Future<void> _longPressDrag(WidgetTester tester, double dy) async {
  final box = tester.getRect(
    find.byKey(const ValueKey('accompany-mix-track')),
  );
  final gesture = await tester.startGesture(box.center);
  await tester.pump(const Duration(milliseconds: 600));
  await gesture.moveBy(Offset(0, dy));
  await tester.pump();
  await gesture.up();
  await tester.pump();
}

void main() {
  testWidgets('图标 20、按钮 36×36', (tester) async {
    await tester.pumpWidget(_host(active: false, onTap: () {}));

    // 底层图标 + 填充层反色图标，二者叠在同一位置（折叠态填充透明度为 0
    // 但仍占位），因此恒为 2 个 —— 这是胶囊「上白下黑」切分的实现方式。
    final icons = tester.widgetList<Icon>(find.byType(Icon));
    expect(icons.length, 2);
    expect(icons.first.size, 20);

    final size = tester.getSize(
      find.byKey(const ValueKey('accompany-pill')),
    );
    expect(size.width, 36);
    expect(size.height, 36);
  });

  testWidgets('短按触发开关回调', (tester) async {
    var tapped = false;
    await tester.pumpWidget(_host(active: false, onTap: () => tapped = true));

    await tester.tap(find.byKey(const ValueKey('accompany-mix-track')));
    await tester.pump();

    expect(tapped, isTrue);
  });

  testWidgets('开启态用实心麦克风图标', (tester) async {
    await tester.pumpWidget(_host(active: true, onTap: () {}));
    expect(find.byIcon(Icons.mic), findsNWidgets(2));
    expect(find.byIcon(Icons.mic_none), findsNothing);
  });

  testWidgets('关闭态用空心麦克风图标', (tester) async {
    await tester.pumpWidget(_host(active: false, onTap: () {}));
    expect(find.byIcon(Icons.mic_none), findsNWidgets(2));
    expect(find.byIcon(Icons.mic), findsNothing);
  });

  // ── 在线伴奏：比例入口必须彻底不存在 ──

  testWidgets('不可调时（在线伴奏）长按后不生长、也不出现比例胶囊', (tester) async {
    // 回归护栏：在线来源下比例调节入口必须消失，否则用户仍能调小比例——
    // 而调小比例正是错位的直接来源。
    await tester.pumpWidget(_host(active: true, onTap: () {}));

    await tester.longPress(find.byKey(const ValueKey('accompany-pill')));
    await tester.pumpAndSettle();

    final size = tester.getSize(
      find.byKey(const ValueKey('accompany-pill')),
    );
    expect(size.height, 36, reason: '不可调时不得生长成胶囊');
    // 填充层节点恒在（透明度 0），判据是它**始终不可见** —— 比例在在线来源下
    // 既不可调也不展示，用户看不到任何「可调比例」的暗示。
    final fill = find.byKey(const ValueKey('accompany-fill'));
    expect(fill, findsOneWidget, reason: '填充层节点存在（结构固定）');
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity).first).opacity,
      0.0,
      reason: '不可调时填充必须保持不可见',
    );
  });

  testWidgets('不可调时长按不产生比例回调', (tester) async {
    final values = <double>[];
    await tester.pumpWidget(
      _host(active: true, onTap: () {}, onMixChanged: values.add),
    );

    await tester.longPress(find.byKey(const ValueKey('accompany-mix-track')));
    await tester.pumpAndSettle();

    expect(values, isEmpty, reason: '在线来源下不应有任何比例变化');
  });

  // ── 端侧分离：比例可调 ──

  testWidgets('可调时（端侧分离）长按生长成 88 高胶囊', (tester) async {
    await tester.pumpWidget(
      _host(active: true, adjustable: true, mix: 0.5, onTap: () {}),
    );

    await tester.longPress(find.byKey(const ValueKey('accompany-pill')));
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byKey(const ValueKey('accompany-pill'))).height,
      88,
      reason: '端侧分离必须能展开调比例',
    );
  });

  testWidgets('可调时向上拖动 → 伴奏占比增大', (tester) async {
    final values = <double>[];
    await tester.pumpWidget(
      _host(
        active: true,
        adjustable: true,
        mix: 0.5,
        onTap: () {},
        onMixChanged: values.add,
      ),
    );

    await _longPressDrag(tester, -60);

    expect(values, isNotEmpty, reason: '端侧分离长按拖动必须能改比例');
    expect(values.last, greaterThan(0.5));
  });

  testWidgets('可调时向下拖动 → 伴奏占比减小', (tester) async {
    final values = <double>[];
    await tester.pumpWidget(
      _host(
        active: true,
        adjustable: true,
        mix: 0.5,
        onTap: () {},
        onMixChanged: values.add,
      ),
    );

    await _longPressDrag(tester, 60);

    expect(values, isNotEmpty);
    expect(values.last, lessThan(0.5));
  });

  testWidgets('可调时填充高度反映当前比例', (tester) async {
    await tester.pumpWidget(
      _host(active: true, adjustable: true, mix: 0.5, onTap: () {}),
    );
    await tester.longPress(find.byKey(const ValueKey('accompany-pill')));
    await tester.pumpAndSettle();

    // 胶囊 88 高，比例 0.5 → 填充 44
    final fill = find.byKey(const ValueKey('accompany-fill'));
    expect(fill, findsOneWidget);
    expect(tester.getSize(fill).height, 44);
  });
}
