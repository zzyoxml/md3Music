import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/widgets/m3e_container_transform.dart';

void main() {
  testWidgets('壁纸模式下容器转场背景透明', (tester) async {
    late Color result;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(scaffoldBackgroundColor: Colors.transparent),
      home: Builder(
        builder: (context) {
          result = wallpaperAwareTransitionColor(context, Colors.white);
          return const SizedBox();
        },
      ),
    ));

    expect(result, Colors.transparent);
  });

  testWidgets('未开启壁纸时容器转场沿用原背景色', (tester) async {
    const fallback = Colors.white;
    late Color result;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(scaffoldBackgroundColor: Colors.black),
      home: Builder(
        builder: (context) {
          result = wallpaperAwareTransitionColor(context, fallback);
          return const SizedBox();
        },
      ),
    ));

    expect(result, fallback);
  });
}
