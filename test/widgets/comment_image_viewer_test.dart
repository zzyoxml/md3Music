import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/services/kugou_api/kugou_models.dart';
import 'package:md3music/widgets/comment_image_viewer.dart';

/// 全屏查看器：页码、翻页、关闭、甩回小图、长按保存。
void main() {
  final images = [
    for (var i = 0; i < 3; i++)
      CommentImage(url: 'https://a/$i.jpg', width: 900, height: 900),
  ];

  Widget host({
    Rect? originRect,
    Future<bool> Function(BuildContext context, String url)? onSaveImage,
  }) =>
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showCommentImageViewer(
                  context,
                  images: images,
                  originRect: originRect,
                  onSaveImage: onSaveImage,
                  imageBuilder: (_, _) => const ColoredBox(
                    color: Color(0xFF444444),
                  ),
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

  testWidgets('点图片外的遮罩关闭', (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 400));
    await tester.pumpAndSettle();
    expect(find.byType(PageView), findsNothing);
  });

  testWidgets('上甩关闭查看器（甩回评论区）', (tester) async {
    await tester.pumpWidget(
      host(originRect: const Rect.fromLTWH(20, 500, 90, 90)),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(PageView), findsOneWidget);

    await tester.fling(find.byType(PageView), const Offset(0, -300), 1500);
    await tester.pumpAndSettle();
    expect(find.byType(PageView), findsNothing);
  });

  testWidgets('小幅下拉后松手回弹，不关闭', (tester) async {
    await tester.pumpWidget(
      host(originRect: const Rect.fromLTWH(20, 500, 90, 90)),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(PageView), const Offset(0, 40));
    await tester.pumpAndSettle();
    expect(find.byType(PageView), findsOneWidget);
  });

  testWidgets('没传 originRect 也能甩出关闭（兜底落点）', (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.fling(find.byType(PageView), const Offset(0, -300), 1500);
    await tester.pumpAndSettle();
    expect(find.byType(PageView), findsNothing);
  });

  testWidgets('长按大图触发保存回调，回传当前页 url', (tester) async {
    final saved = <String>[];
    await tester.pumpWidget(
      host(
        onSaveImage: (context, url) async {
          saved.add(url);
          return true;
        },
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.fling(find.byType(PageView), const Offset(-400, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('2/3'), findsOneWidget);

    await tester.longPress(find.byKey(const ValueKey('comment-image-viewer-image')));
    await tester.pump();
    expect(saved, ['https://a/1.jpg']);
  });
}
