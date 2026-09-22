import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/services/kugou_api/kugou_models.dart';
import 'package:md3music/widgets/comment_image_grid.dart';

/// 评论图片网格：单图自适应、多图 3 列（最多 9 张 + “+N”）、点击回调。
/// 所有断言注入 [imageBuilder] 的纯色块，避免测试里发起真实网络请求。
void main() {
  Widget buildWith(List<CommentImage> images, {void Function(int)? onTap}) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 360,
          child: CommentImageGrid(
            images: images,
            onTapImage: onTap,
            imageBuilder: (_, _) => const ColoredBox(color: Color(0xFF888888)),
          ),
        ),
      ),
    );
  }

  List<CommentImage> make(int n) => [
        for (var i = 0; i < n; i++)
          CommentImage(url: 'https://a/$i.jpg', width: 900, height: 900),
      ];

  testWidgets('单图渲染 1 个图片项', (tester) async {
    await tester.pumpWidget(buildWith(make(1)));
    expect(find.byKey(const ValueKey('comment-image-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('comment-image-1')), findsNothing);
  });

  testWidgets('多图渲染 3 列网格', (tester) async {
    await tester.pumpWidget(buildWith(make(4)));
    final grid = tester.widget<GridView>(find.byType(GridView));
    final delegate = grid.gridDelegate;
    expect(delegate, isA<SliverGridDelegateWithFixedCrossAxisCount>());
    expect((delegate as SliverGridDelegateWithFixedCrossAxisCount).crossAxisCount, 3);
    expect(find.byKey(const ValueKey('comment-image-3')), findsOneWidget);
  });

  testWidgets('超过 9 张只渲染 9 个并显示 +N', (tester) async {
    await tester.pumpWidget(buildWith(make(12)));
    expect(find.byKey(const ValueKey('comment-image-8')), findsOneWidget);
    expect(find.byKey(const ValueKey('comment-image-9')), findsNothing);
    expect(find.text('+3'), findsOneWidget);
  });

  testWidgets('点击第 2 张回传下标 1', (tester) async {
    var tapped = -1;
    await tester.pumpWidget(buildWith(make(4), onTap: (i) => tapped = i));
    await tester.tap(find.byKey(const ValueKey('comment-image-1')));
    expect(tapped, 1);
  });

  testWidgets('空列表渲染为 SizedBox.shrink', (tester) async {
    await tester.pumpWidget(buildWith(const []));
    expect(find.byType(GridView), findsNothing);
    expect(find.byType(SizedBox), findsWidgets);
  });
}
