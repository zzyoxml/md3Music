import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/core/theme/app_dimens.dart';
import 'package:md3music/modules/settings/settings_two_pane.dart';

void main() {
  group('SettingsTwoPaneBody', () {
    testWidgets('左列固定宽度、分隔线 1dp、右列占据剩余宽度', (tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const keyMaster = Key('master');
      const keyDetail = Key('detail');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsTwoPaneBody(
              master: Container(key: keyMaster),
              detail: Container(key: keyDetail),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final masterRect = tester.getRect(find.byKey(keyMaster));
      final detailRect = tester.getRect(find.byKey(keyDetail));
      expect(masterRect.width, AppLayout.twoPaneMasterWidth);
      // 右列起点 = 左列宽 + 1dp 分隔线
      expect(detailRect.left, masterRect.right + 1);
      // 右列宽 = 剩余宽度（699 < 720，未触及最大宽约束）
      expect(detailRect.width, 1000 - AppLayout.twoPaneMasterWidth - 1);
    });

    testWidgets('右列可用宽度超过上限时内容约束到 twoPaneDetailMaxWidth 居中', (tester) async {
      tester.view.physicalSize = const Size(1400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const keyDetail = Key('detail');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsTwoPaneBody(
              master: const SizedBox(),
              detail: Container(key: keyDetail),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final detailRect = tester.getRect(find.byKey(keyDetail));
      expect(detailRect.width, AppLayout.twoPaneDetailMaxWidth);
      // 居中：左右留白均等
      final expectedLeft =
          (1400 - AppLayout.twoPaneMasterWidth - 1 - AppLayout.twoPaneDetailMaxWidth) / 2 +
              AppLayout.twoPaneMasterWidth +
              1;
      expect(detailRect.left, expectedLeft);
    });
  });
}
