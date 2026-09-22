import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/services/kugou_api/kugou_models.dart';
import 'package:md3music/widgets/comment_image_viewer.dart';

/// 全屏查看器：页码、左右翻页、关闭。
void main() {
  final images = [
    for (var i = 0; i < 3; i++)
      CommentImage(url: 'https://a/$i.jpg', width: 900, height: 900),
  ];

  Widget host() => MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showCommentImageViewer(
                  context,
                  images: images,
                  imageBuilder: (_, _) =>
                      const ColoredBox(color: Color(0xFF444444)),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

  testWidgets('打开后显示页码 1/3，可翻到 2/3 并关闭', (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('1/3'), findsOneWidget);

    await tester.fling(find.byType(PageView), const Offset(-400, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('2/3'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('comment-image-viewer-close')));
    await tester.pumpAndSettle();
    expect(find.byType(PageView), findsNothing);
  });
}
