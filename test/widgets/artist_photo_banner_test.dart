// test/widgets/artist_photo_banner_test.dart
import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/modules/artist/artist_photo_banner.dart';
import 'package:md3music/modules/player/artist_photo_service.dart';

/// 按 hash 返回不同写真集的假服务（KugouEndpoints.baseUrl 有默认值，
/// 注入 fetcher 即可完全脱离网络——与 artist_photo_controller_test 手法一致）。
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

/// 合作曲响应：同一 hash 下两位歌手各一组条目（`show_authors=1` 的真实形状）。
ArtistPhotoService duetService() => ArtistPhotoService(
      fetcher: (_) async =>
          '{"status":1,"data":[['
          '{"author_id":11,"author_name":"甲","imgs":{"320":[{"sizable_portrait":"https://p/a.jpg"}]}},'
          '{"author_id":22,"author_name":"乙","imgs":{"320":[{"sizable_portrait":"https://p/b.jpg"}]}}'
          ']]}',
    );

Song song(
  String id,
  String artist, {
  String? artistId,
}) =>
    Song(
      id: id,
      title: 't$id',
      artist: artist,
      album: '',
      duration: Duration.zero,
      artistId: artistId,
    );

Widget host(Widget child) => MaterialApp(
      home: Scaffold(
        body: Center(child: SizedBox(width: 400, height: 240, child: child)),
      ),
    );

ArtistPhotoBanner banner({
  String hash = 'h1',
  required ArtistPhotoService service,
  bool active = true,
  int intervalSeconds = 60,
  double scrimOpacity = 0.55,
  bool feather = false,
  String? fallbackUrl,
  String? artistId,
  String artistName = '',
}) =>
    ArtistPhotoBanner(
      hash: hash,
      active: active,
      intervalSeconds: intervalSeconds,
      scrimOpacity: scrimOpacity,
      feather: feather,
      fallbackUrl: fallbackUrl,
      artistId: artistId,
      artistName: artistName,
      service: service,
    );

Future<void> pumpBanner(
  WidgetTester tester,
  ArtistPhotoBanner b,
) async {
  await tester.pumpWidget(host(b));
  await tester.pumpAndSettle();
}

/// 指定图片是否为当前可见页（feather 模式清晰层与 PageView 视口中心重合；
/// getRect 返回全局坐标，必须与视口中心相对比，不能写死局部值）。
bool photoCentered(WidgetTester tester, String url) {
  final finder = find.byKey(ValueKey('$url#sharp'));
  if (finder.evaluate().isEmpty) return false;
  final center = tester.getRect(find.byType(PageView)).center;
  final rect = tester.getRect(finder);
  return (rect.center.dx - center.dx).abs() < 1 &&
      (rect.center.dy - center.dy).abs() < 1;
}

void main() {
  group('pickFirstNonEmptyHash', () {
    test('返回第一个非空 hash', () {
      expect(pickFirstNonEmptyHash(['', 'a', 'b']), 'a');
    });
    test('全空/空集合返回 null', () {
      expect(pickFirstNonEmptyHash(['', '']), isNull);
      expect(pickFirstNonEmptyHash(<String>[]), isNull);
    });
  });

  group('pickArtistPhotoHash（写真键分档优选）', () {
    test('档 1：独唱 + artistId 命中，优先于列表更靠前的合作曲', () {
      final pick = pickArtistPhotoHash([
        song('duet1', '甲、乙', artistId: '11'),
        song('solo1', '甲', artistId: '11'),
      ], artistId: '11', artistName: '甲');
      expect(pick.hash, 'solo1');
      expect(pick.isSolo, isTrue);
    });

    test('档 1：artistId 缺失时按歌手名忽略大小写命中', () {
      final pick = pickArtistPhotoHash([
        song('duet1', 'Jay Chou、A-Mei'),
        song('solo1', 'jay chou'),
      ], artistName: 'Jay Chou');
      expect(pick.hash, 'solo1');
      expect(pick.isSolo, isTrue);
    });

    test('独唱但 id 与名都对不上（脏数据/同名他人）→ 不采信，回落第一个非空', () {
      final pick = pickArtistPhotoHash([
        song('duet1', '甲、乙', artistId: '99'),
        song('solo1', '乙', artistId: '88'),
      ], artistId: '11', artistName: '甲');
      expect(pick.hash, 'duet1');
      expect(pick.isSolo, isFalse);
    });

    test('档 2：页面身份全缺时可用独唱曲（仍优于合作曲）', () {
      final pick = pickArtistPhotoHash([
        song('duet1', '甲、乙'),
        song('solo1', '丙'),
      ]);
      expect(pick.hash, 'solo1');
      expect(pick.isSolo, isTrue);
    });

    test('档 3：全是合作曲 → 回落第一个非空 hash（交给归属过滤兜底）', () {
      final pick = pickArtistPhotoHash([
        song('', '甲'),
        song('d1', '甲、乙'),
        song('d2', '丙、丁'),
      ], artistId: '11', artistName: '甲');
      expect(pick.hash, 'd1');
      expect(pick.isSolo, isFalse);
    });

    test('空列表 → hash 为 null', () {
      final pick = pickArtistPhotoHash(const <Song>[]);
      expect(pick.hash, isNull);
      expect(pick.isSolo, isFalse);
    });
  });

  group('数据加载与空态回落', () {
    testWidgets('响应非法 JSON → 不渲染 PageView', (tester) async {
      await pumpBanner(
        tester,
        banner(service: ArtistPhotoService(fetcher: (_) async => 'not-json')),
      );
      expect(find.byType(PageView), findsNothing);
    });

    testWidgets('该 hash 无写真 → 不渲染 PageView', (tester) async {
      await pumpBanner(tester, banner(service: fakeService({})));
      expect(find.byType(PageView), findsNothing);
    });

    testWidgets('加载成功 → 渲染 PageView', (tester) async {
      await pumpBanner(
        tester,
        banner(
          service: fakeService({
            'h1': ['https://p/a.jpg', 'https://p/b.jpg', 'https://p/c.jpg'],
          }),
        ),
      );
      expect(find.byType(PageView), findsOneWidget);
    });

    testWidgets('无写真但有 fallbackUrl → 渲染兜底图单页且不轮播',
        (tester) async {
      await pumpBanner(
        tester,
        banner(
            service: fakeService({}),
            fallbackUrl: 'https://p/avatar.jpg',
            intervalSeconds: 5),
      );
      expect(find.byType(PageView), findsOneWidget);
      expect(find.byType(CachedNetworkImage), findsOneWidget);
      // 单页天然不轮播：跨过 2 个间隔仍只有一张图
      await tester.pump(const Duration(seconds: 11));
      await tester.pumpAndSettle();
      expect(find.byType(CachedNetworkImage), findsOneWidget);
    });
  });

  group('头像作首图', () {
    const avatar = 'https://p/avatar.jpg';

    /// 头像 + 3 张写真（banner 有头像时无 fallback 空态）。
    Future<void> pumpWithAvatar(
      WidgetTester tester, {
      int intervalSeconds = 60,
      List<String> photos = const [
        'https://p/a.jpg',
        'https://p/b.jpg',
        'https://p/c.jpg',
      ],
      String? fallbackUrl = avatar,
    }) =>
        pumpBanner(
          tester,
          banner(
            feather: true,
            service: fakeService({'h1': photos}),
            fallbackUrl: fallbackUrl,
            intervalSeconds: intervalSeconds,
          ),
        );

    testWidgets('首图为头像，其次才是写真', (tester) async {
      await pumpWithAvatar(tester);
      expect(photoCentered(tester, avatar), isTrue);
      expect(photoCentered(tester, 'https://p/a.jpg'), isFalse);
      // 左拖一次 → 切到第 1 张写真（头像之后）
      await tester.drag(find.byType(PageView), const Offset(-200, 0));
      await tester.pumpAndSettle();
      expect(photoCentered(tester, 'https://p/a.jpg'), isTrue);
    });

    testWidgets('自动轮播从头像推进到写真', (tester) async {
      await pumpWithAvatar(tester, intervalSeconds: 5);
      expect(photoCentered(tester, avatar), isTrue);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(photoCentered(tester, 'https://p/a.jpg'), isTrue);
    });

    testWidgets('头像与写真同 URL → 不前置，页数不变（相邻页不同图）',
        (tester) async {
      // 头像 URL 恰好等于第 2 张写真：置首会让第 0、1 页放同一张图
      await pumpWithAvatar(
        tester,
        photos: const ['https://p/a.jpg', avatar, 'https://p/c.jpg'],
      );
      expect(photoCentered(tester, 'https://p/a.jpg'), isTrue);
      await tester.drag(find.byType(PageView), const Offset(-200, 0));
      await tester.pumpAndSettle();
      expect(photoCentered(tester, avatar), isTrue);
      // 总页数仍是写真数（3），头像没有多占一页
      await tester.drag(find.byType(PageView), const Offset(-200, 0));
      await tester.pumpAndSettle();
      expect(photoCentered(tester, 'https://p/c.jpg'), isTrue);
    });

    testWidgets('无头像 → 纯写真（播放页用法行为不变）', (tester) async {
      await pumpWithAvatar(tester, fallbackUrl: null);
      expect(photoCentered(tester, 'https://p/a.jpg'), isTrue);
      await tester.drag(find.byType(PageView), const Offset(-200, 0));
      await tester.pumpAndSettle();
      expect(photoCentered(tester, 'https://p/b.jpg'), isTrue);
    });
  });

  group('滑动', () {
    Future<void> pump3(WidgetTester tester) => pumpBanner(
          tester,
          banner(
            feather: true,
            service: fakeService({
              'h1': ['https://p/a.jpg', 'https://p/b.jpg', 'https://p/c.jpg'],
            }),
          ),
        );

    testWidgets('初始停在第 1 页', (tester) async {
      await pump3(tester);
      expect(photoCentered(tester, 'https://p/a.jpg'), isTrue);
      expect(photoCentered(tester, 'https://p/b.jpg'), isFalse);
    });

    testWidgets('左拖滑动切到第 2 页', (tester) async {
      await pump3(tester);
      await tester.drag(find.byType(PageView), const Offset(-200, 0));
      await tester.pumpAndSettle();
      expect(photoCentered(tester, 'https://p/b.jpg'), isTrue);
    });
  });

  group('自动轮播与 active 门控', () {
    ArtistPhotoService service3() => fakeService({
          'h1': ['https://p/a.jpg', 'https://p/b.jpg', 'https://p/c.jpg'],
        });

    testWidgets('active=true 时按间隔自动推进并循环回绕', (tester) async {
      await pumpBanner(
        tester,
        banner(feather: true, service: service3(), intervalSeconds: 5),
      );
      expect(photoCentered(tester, 'https://p/a.jpg'), isTrue);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle(); // 800ms 翻页动画
      expect(photoCentered(tester, 'https://p/b.jpg'), isTrue);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(photoCentered(tester, 'https://p/c.jpg'), isTrue);
      // 末页 → animateToPage(0) 回绕
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(photoCentered(tester, 'https://p/a.jpg'), isTrue);
    });

    testWidgets('active=false 不自动推进', (tester) async {
      await pumpBanner(
        tester,
        banner(
            feather: true,
            service: service3(),
            active: false,
            intervalSeconds: 5),
      );
      await tester.pump(const Duration(seconds: 11));
      await tester.pumpAndSettle();
      expect(photoCentered(tester, 'https://p/a.jpg'), isTrue);
    });

    testWidgets('active 转 false 后停表不再推进', (tester) async {
      await pumpBanner(
        tester,
        banner(feather: true, service: service3(), intervalSeconds: 5),
      );
      await tester.pumpWidget(
        host(banner(
            feather: true,
            service: service3(),
            active: false,
            intervalSeconds: 5)),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 11));
      await tester.pumpAndSettle();
      expect(photoCentered(tester, 'https://p/a.jpg'), isTrue);
    });
  });

  group('合作曲写真归属', () {
    testWidgets('响应含两位歌手 → 传 artistName 时只渲染本歌手写真',
        (tester) async {
      await pumpBanner(
        tester,
        banner(
          feather: true,
          service: duetService(),
          artistId: '11',
          artistName: '甲',
        ),
      );
      expect(photoCentered(tester, 'https://p/a.jpg'), isTrue);
      // 过滤后只剩 1 张 → 滑不动（他人写真连翻页都不存在）
      await tester.drag(find.byType(PageView), const Offset(-200, 0));
      await tester.pumpAndSettle();
      expect(photoCentered(tester, 'https://p/a.jpg'), isTrue);
      expect(find.byKey(ValueKey('https://p/b.jpg#sharp')), findsNothing);
    });

    testWidgets('不传归属参数（播放页用法）→ 两人写真都拿到，行为不变',
        (tester) async {
      await pumpBanner(tester, banner(feather: true, service: duetService()));
      expect(photoCentered(tester, 'https://p/a.jpg'), isTrue);
      await tester.drag(find.byType(PageView), const Offset(-200, 0));
      await tester.pumpAndSettle();
      expect(photoCentered(tester, 'https://p/b.jpg'), isTrue);
    });

    testWidgets('过滤后为空 → 回落 fallbackUrl 单页', (tester) async {
      await pumpBanner(
        tester,
        banner(
          feather: true,
          service: duetService(),
          artistId: '999',
          artistName: '查无此人',
          fallbackUrl: 'https://p/avatar.jpg',
        ),
      );
      expect(photoCentered(tester, 'https://p/avatar.jpg'), isTrue);
      expect(find.byKey(ValueKey('https://p/a.jpg#sharp')), findsNothing);
    });
  });

  group('hash 变更', () {
    bool anyImage(WidgetTester tester, String url) =>
        tester.any(find.byWidgetPredicate(
          (w) => w is CachedNetworkImage && w.imageUrl == url,
        ));

    testWidgets('迟到的旧响应被丢弃（不覆盖新 hash 的写真）', (tester) async {
      final gate = Completer<void>();
      final service = ArtistPhotoService(fetcher: (uri) async {
        final hash = uri.queryParameters['hash'];
        final url = hash == 'slow' ? 'https://p/slow.jpg' : 'https://p/fast.jpg';
        if (hash == 'slow') await gate.future;
        return '{"status":1,"data":[[{"imgs":{"320":[{"sizable_portrait":'
            '"$url"}]}}]]}';
      });
      await pumpBanner(
        tester,
        banner(hash: 'slow', service: service, feather: true),
      );
      // 切到立即返回的 hash（页面改善式换键就是这个路径）
      await tester.pumpWidget(
        host(banner(hash: 'fast', service: service, feather: true)),
      );
      await tester.pumpAndSettle();
      expect(anyImage(tester, 'https://p/fast.jpg'), isTrue);
      // 旧请求此刻才返回：不得覆盖新结果
      gate.complete();
      await tester.pumpAndSettle();
      expect(anyImage(tester, 'https://p/slow.jpg'), isFalse);
      expect(anyImage(tester, 'https://p/fast.jpg'), isTrue);
    });

    testWidgets('归属参数变化会重新拉取', (tester) async {
      final service = duetService();
      await pumpBanner(
        tester,
        banner(feather: true, service: service, artistName: '甲'),
      );
      expect(photoCentered(tester, 'https://p/a.jpg'), isTrue);
      await tester.pumpWidget(
        host(banner(feather: true, service: service, artistName: '乙')),
      );
      await tester.pumpAndSettle();
      expect(photoCentered(tester, 'https://p/b.jpg'), isTrue);
      expect(find.byKey(ValueKey('https://p/a.jpg#sharp')), findsNothing);
    });
  });

  group('底缘羽化渐变（移植 AM 三件套，只做底缘）', () {
    double alphaAt(LinearGradient g, double y) {
      final stops = g.stops!, colors = g.colors;
      if (y <= stops.first) return colors.first.a;
      if (y >= stops.last) return colors.last.a;
      for (var i = 1; i < stops.length; i++) {
        if (y <= stops[i]) {
          final span = stops[i] - stops[i - 1];
          final t = span == 0 ? 1.0 : (y - stops[i - 1]) / span;
          return colors[i - 1].a + (colors[i].a - colors[i - 1].a) * t;
        }
      }
      return 0;
    }

    test('主淡出罩：顶/中 alpha=1，底缘 alpha=0，stops 升序', () {
      final g = artistPhotoBottomFade(360);
      expect(g.colors.first.a, 1.0);
      expect(alphaAt(g, 0.5), 1.0);
      expect(g.colors.last.a, 0.0);
      final stops = g.stops!;
      for (var i = 1; i < stops.length; i++) {
        expect(stops[i], greaterThan(stops[i - 1]));
      }
    });

    test('清晰罩与主罩同源同带宽：乘积处处平滑无亮度折点（细线回归钉）', () {
      final sharp = artistPhotoSharpBottomMask(360);
      final master = artistPhotoBottomFade(360);
      // 单缘场景下两罩共用一条 smoothstep 曲线（AM 双缘 0.8 错峰会留折点，
      // 真机表现为羽化带内一条细线）
      expect(sharp.colors.map((c) => c.a).toList(),
          master.colors.map((c) => c.a).toList());
      // 带内任一点都未提前归零，仅底缘收敛到 0
      expect(alphaAt(sharp, 0.93), greaterThan(0.05));
      expect(alphaAt(sharp, 1.0), lessThan(0.01));
    });

    test('不透明标记必须为白色（modulate 用黑色会乘出纯黑）', () {
      for (final g in [
        artistPhotoBottomFade(360),
        artistPhotoSharpBottomMask(360),
      ]) {
        final opaque = g.colors.firstWhere((c) => c.a > 0.99);
        expect(opaque.r, 1.0);
        expect(opaque.g, 1.0);
        expect(opaque.b, 1.0);
      }
    });
  });

  group('feather 模式渲染', () {
    testWidgets('feather=true 每页有低分辨率模糊层（无 ImageFiltered）；默认无',
        (tester) async {
      final service = fakeService({
        'h1': ['https://p/a.jpg', 'https://p/b.jpg'],
      });
      await pumpBanner(tester, banner(service: service));
      expect(find.byKey(ValueKey('https://p/a.jpg#blur')), findsNothing);
      await pumpBanner(
        tester,
        banner(service: service, feather: true),
      );
      // 可见页一层模糊底 + 一层清晰图（PageView 只建可见页）
      expect(find.byKey(ValueKey('https://p/a.jpg#blur')), findsOneWidget);
      expect(find.byKey(ValueKey('https://p/a.jpg#sharp')), findsOneWidget);
      expect(find.byType(ImageFiltered), findsNothing);
      // 主淡出罩套整个 PageView（清晰层罩在页内，另计）
      expect(
        find.ancestor(
            of: find.byType(PageView), matching: find.byType(ShaderMask)),
        findsOneWidget,
      );
      // 滑到第 2 页：模糊层随页跟随（验证「每页」而非仅首页有）
      await tester.drag(find.byType(PageView), const Offset(-200, 0));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('https://p/b.jpg#blur')), findsOneWidget);
      expect(find.byType(ImageFiltered), findsNothing);
    });

    testWidgets('不再渲染圆点指示器', (tester) async {
      await pumpBanner(
        tester,
        banner(service: fakeService({
          'h1': ['https://p/a.jpg', 'https://p/b.jpg'],
        })),
      );
      expect(find.byKey(ValueKey('artist-photo-dot-0')), findsNothing);
    });
  });
}
