import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/core/layout/page_layout.dart';
import 'package:md3music/core/theme/app_dimens.dart';

void main() {
  test('大屏宽度随窗口变化，窄面板及手机原限宽不变', () {
    expect(AppLayout.contentWidthFor(390), 390);
    expect(AppLayout.contentWidthFor(840), 840);
    expect(AppLayout.contentWidthFor(900), 840);
    expect(AppLayout.contentWidthFor(1280), 1088);
    expect(AppLayout.contentWidthFor(1920), 1632);
    expect(AppLayout.contentWidthFor(3840), 3264);
    expect(AppLayout.contentWidthFor(1920, adaptive: false), 840);
  });
  for (final scenario in [
    (size: const Size(1280, 800), platform: TargetPlatform.android, width: 1088.0),
    (size: const Size(1600, 400), platform: TargetPlatform.android, width: 840.0),
    (size: const Size(1600, 400), platform: TargetPlatform.windows, width: 1360.0),
    (size: const Size(390, 800), platform: TargetPlatform.android, width: 390.0),
  ]) {
    testWidgets('${scenario.platform} ${scenario.size}：占比及嵌套不重复缩窄', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = scenario.size;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(theme: ThemeData(platform: scenario.platform),
        home: const ContentWidth(child: ContentWidth(
          child: SizedBox.expand(key: Key('adaptive-body')),
        )),
      ));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byKey(const Key('adaptive-body'))).width, scenario.width);
      expect(tester.getTopLeft(find.byKey(const Key('adaptive-body'))).dx,
          (scenario.size.width - scenario.width) / 2);
      expect(tester.takeException(), isNull);
    });
  }
}
