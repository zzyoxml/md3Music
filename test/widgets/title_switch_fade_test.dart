import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/player/widgets/title_switch_fade.dart';

const TextStyle _titleStyle = TextStyle(
  fontSize: 20,
  fontWeight: FontWeight.w700,
);
const TextStyle _subtitleStyle = TextStyle(fontSize: 12);

Widget _host({
  required String version,
  required String title,
  required bool enabled,
}) => MaterialApp(
  // 宿主刻意不用 Scaffold：它的 FloatingActionButton 过渡固定带一个内部 Stack，
  // 会让 `find.byType(Stack), findsNothing` 这种「没有多余层」的断言在无关处落空。
  home: Material(
    child: Center(
      child: SizedBox(
        width: 300,
        child: TitleSwitchFade(
          version: version,
          align: Alignment.centerLeft,
          enabled: enabled,
          // child 就是「当前该显示的标题块」；旧标题层复用的正是上一帧的这个
          // 实例（与真实调用方 `_buildTitleBlock` 的口径一致：它只传 child，
          // 不另传一份文字去重建）。
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: _titleStyle, textAlign: TextAlign.left),
              const SizedBox(height: 2),
              Text('artist', style: _subtitleStyle, textAlign: TextAlign.left),
            ],
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('version 未变时不做任何包装（idle 零层级、零帧）', (tester) async {
    await tester.pumpWidget(
      _host(version: 'a', title: 'Song A', enabled: true),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Stack), findsNothing);
    expect(find.text('Song A'), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('version 变化时旧标题先留着，延迟到点后才淡出', (tester) async {
    await tester.pumpWidget(
      _host(version: 'a', title: 'Song A', enabled: true),
    );
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      _host(version: 'b', title: 'Song B', enabled: true),
    );
    await tester.pump(const Duration(milliseconds: 60));

    // 延迟窗口内旧标题仍在，新标题还没进来
    expect(find.text('Song A'), findsOneWidget);
    expect(find.text('Song B'), findsNothing);

    await tester.pump(const Duration(milliseconds: 320));
    expect(find.text('Song B'), findsOneWidget);
    expect(find.text('Song A'), findsOneWidget);

    await tester.pumpAndSettle();
    // 收敛后回到 idle 形态
    expect(find.text('Song B'), findsOneWidget);
    expect(find.text('Song A'), findsNothing);
    expect(find.byType(Stack), findsNothing);
  });

  testWidgets('enabled=false（频谱圆盘等场景）时完全不动，直接换文字', (tester) async {
    await tester.pumpWidget(
      _host(version: 'a', title: 'Song A', enabled: false),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      _host(version: 'b', title: 'Song B', enabled: false),
    );
    await tester.pump();

    expect(find.text('Song B'), findsOneWidget);
    expect(find.text('Song A'), findsNothing);
    expect(find.byType(Stack), findsNothing);
  });
}
