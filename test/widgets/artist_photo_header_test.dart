// test/widgets/artist_photo_header_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/artist/artist_photo_banner.dart';
import 'package:md3music/modules/artist/artist_photo_header.dart';
import 'package:md3music/modules/player/artist_photo_service.dart';

ArtistPhotoService fakeService(Map<String, List<String>> byHash) =>
    ArtistPhotoService(
      fetcher: (uri) async {
        final urls = byHash[uri.queryParameters['hash']] ?? const <String>[];
        if (urls.isEmpty) return '{"status":1,"data":[]}';
        return '{"status":1,"data":[[{"imgs":{"320":['
            '${urls.map((u) => '{"sizable_portrait":"$u"}').join(',')}'
            ']}}]]}';
      },
    );

void main() {
  Future<void> pump(
    WidgetTester tester, {
    String? hash,
    ArtistPhotoService? service,
    Widget? actions,
    String? fallbackUrl,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ArtistPhotoHeader(
            photoHash: hash,
            artistName: 'The Beatles',
            intervalSeconds: 15,
            fallbackUrl: fallbackUrl,
            service: service,
            actions: actions,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  test('高度函数：写真 45% 屏高钳 260~430，另加 96 按钮区', () {
    expect(artistBannerHeightFor(800), 360.0 + 96.0);
    expect(artistBannerHeightFor(500), 260.0 + 96.0);
    expect(artistBannerHeightFor(1200), 430.0 + 96.0);
  });

  testWidgets('写真态：feather banner（无 ImageFiltered）+ 名字 + actions 叠加',
      (tester) async {
    await pump(
      tester,
      hash: 'h1',
      service: fakeService({
        'h1': ['https://p/a.jpg', 'https://p/b.jpg'],
      }),
      actions: const Text('ACT'),
    );
    expect(find.text('The Beatles'), findsOneWidget);
    expect(find.byType(ArtistPhotoBanner), findsOneWidget);
    expect(find.byKey(ValueKey('https://p/a.jpg#blur')), findsOneWidget);
    expect(find.byType(ImageFiltered), findsNothing);
    expect(find.text('ACT'), findsOneWidget);
  });

  testWidgets('回落态：无 hash 时不渲染 banner，仍显示名字与渐变底',
      (tester) async {
    await pump(tester, actions: const Text('ACT'));
    expect(find.text('The Beatles'), findsOneWidget);
    expect(find.byType(ArtistPhotoBanner), findsNothing);
    expect(find.byType(ShaderMask), findsNothing);
    expect(find.text('ACT'), findsOneWidget);
  });

  testWidgets('有 hash 但写真为空：banner 自行渲染空容器，回落底仍可见',
      (tester) async {
    await pump(tester, hash: 'h1', service: fakeService({}));
    expect(find.text('The Beatles'), findsOneWidget);
    expect(find.byType(PageView), findsNothing);
  });

  testWidgets('头像作首图：写真态第 0 页是歌手头像（fallbackUrl 透传到位）',
      (tester) async {
    await pump(
      tester,
      hash: 'h1',
      fallbackUrl: 'https://p/avatar.jpg',
      service: fakeService({
        'h1': ['https://p/a.jpg', 'https://p/b.jpg'],
      }),
    );
    expect(find.byType(PageView), findsOneWidget);
    expect(
      find.byKey(const ValueKey('https://p/avatar.jpg#sharp')),
      findsOneWidget,
    );
  });
}
