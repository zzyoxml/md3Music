import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/album.dart';
import 'package:md3music/widgets/album_card.dart';

void main() {
  group('AlbumCard M3 Expressive', () {
    final testAlbum = Album(
      id: '1',
      name: '测试专辑',
      artist: '测试艺术家',
      artworkUri: null,
      songCount: 0,
    );

    testWidgets('卡片外层圆角是 32dp（M3E expressive）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 200,
              height: 280,
              child: AlbumCard(album: testAlbum),
            ),
          ),
        ),
      );

      // 找到 ClipRRect，验证圆角
      final clipRRect = tester.widget<ClipRRect>(find.byType(ClipRRect));
      final borderRadius = clipRRect.borderRadius as BorderRadius;
      expect(borderRadius.topLeft.x, 32);
    });

    testWidgets('专辑名用 titleSmall 字号 14sp', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 200,
              height: 280,
              child: AlbumCard(album: testAlbum),
            ),
          ),
        ),
      );

      // 找到专辑名 Text
      final nameFinder = find.text('测试专辑');
      expect(nameFinder, findsOneWidget);
      final textWidget = tester.widget<Text>(nameFinder);
      // titleSmall 默认 14sp
      expect(textWidget.style?.fontSize, 14);
    });

    testWidgets('onTap 回调被触发', (tester) async {
      bool tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 200,
              height: 280,
              child: AlbumCard(
                album: testAlbum,
                onTap: () => tapped = true,
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byType(AlbumCard));
      await tester.pump();
      expect(tapped, isTrue);
    });
  });
}
