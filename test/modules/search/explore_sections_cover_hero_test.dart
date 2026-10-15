import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m3e_core/m3e_core.dart';
// 页面全部用 material_ui 的 Scaffold/AppBar，其 AppBar 校验的是 **material_ui 自家**
// 的 MaterialLocalizations 类型（与 flutter/material 同名不同型）。测试容器必须与
// 真实 app 同款（lib/app.dart 的 MaterialApp 也来自 material_ui），否则 AppBar
// 一挂载就抛「No MaterialLocalizations found」。
import 'package:material_ui/material_ui.dart';
import 'package:md3music/modules/search/explore_sections.dart';
import 'package:md3music/providers/device_provider.dart';
import 'package:md3music/providers/grid_columns_provider.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/widgets/album_card.dart';
import 'package:md3music/widgets/playlist_cover_hero.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../test_helpers/fake_secure_storage.dart';

/// 搜索页音乐探索区块 → 完整列表页（热门歌单 / 新碟上架浏览页）的封面衔接。
///
/// 衔接靠「两端同 tag」：区块 `_CompactAlbumGrid` 的小封面与浏览页 `AlbumCard`
/// 的大封面用同一套 tag（歌单 gid / 专辑 id 命名空间）。推入完整列表页时框架
/// Hero 在**转场首帧**配对两端——浏览页若先画一帧 loading 圈，配对扑空，封面就
/// 只剩页面自身的推入动画（正是真机反馈「查看完整列表没有封面衔接」的根因）。
///
/// 另一处硬约束：同一路由子树内 tag 必须唯一（重复 tag 在转场收集阶段抛
/// FlutterError），服务端列表可能出现重复 gid / 专辑 id，两端都按首次出现挂 tag。
class _ExploreApiAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    if (path.contains('/top/playlist')) {
      // 4 个歌单，其中第 4 个与第 1 个同 gid（g1）：验证首现去重。
      Map<String, Object> pl(String id, String gid) => {
            'specialid': id,
            'specialname': '歌单$id',
            'imgurl': 'https://img.example/$id.jpg',
            'songcount': 10,
            'global_collection_id': gid,
          };
      return _json({
        'special_list': [
          pl('p1', 'g1'),
          pl('p2', 'g2'),
          pl('p3', 'g3'),
          pl('p4', 'g1'),
        ],
      });
    }
    if (path.contains('/top/album')) {
      // 3 张专辑，其中第 3 张与第 2 张同 id（a2）：验证首现去重。
      Map<String, Object> al(String id) => {
            'albumid': id,
            'album_name': '专辑$id',
            'imgurl': 'https://img.example/$id.jpg',
            'singername': '歌手$id',
          };
      return _json({
        'list': [al('a1'), al('a2'), al('a2')],
      });
    }
    // 其余端点（主题歌单 / 场景 / 排行榜等 ensureLoaded 补拉）一律空数据。
    return _json(const {});
  }

  ResponseBody _json(Object body) => ResponseBody.fromString(
        jsonEncode({'status': 1, 'data': body}),
        200,
        headers: {Headers.contentTypeHeader: ['application/json']},
      );

  @override
  void close({bool force = false}) {}
}

Widget _host(KugouProvider kugou, Widget child) {
  // DeviceProvider + GridColumnsProvider：PinchableGridView 走 isPadLayout 分支
  // 会 read/watch 它们（默认测试屏 800×600 落在 Pad 判定），缺了整页 build 即抛
  // ProviderNotFoundException，网格永远渲染不出来——同库页面测试的教训。
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<DeviceProvider>(create: (_) => DeviceProvider()),
      ChangeNotifierProvider<GridColumnsProvider>(
        create: (_) => GridColumnsProvider(),
      ),
      ChangeNotifierProvider<KugouProvider>.value(value: kugou),
    ],
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

List<Object> _heroTags(WidgetTester tester) => tester
    .widgetList<Hero>(find.byType(Hero))
    .map((h) => h.tag)
    .toList(growable: false);

/// 区块小封面是 CachedNetworkImage，其缓存管理器要 path_provider 的落盘目录；
/// widget test 里没有插件实现，不 mock 会以 MissingPluginException 判失败。
void _mockPathProvider() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => switch (call.method) {
      'getTemporaryDirectory' ||
      'getApplicationSupportDirectory' ||
      'getApplicationDocumentsDirectory' ||
      'getDownloadsDirectory' =>
        Directory.systemTemp.path,
      _ => null,
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpClientAdapter previous;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    _mockPathProvider();
    previous = KugouApiClient().dio.httpClientAdapter;
    KugouApiClient().dio.httpClientAdapter = _ExploreApiAdapter();
    KugouApiClient.markServerReady(KugouApiClient.markServerStarting());
  });

  tearDown(() {
    KugouApiClient().dio.httpClientAdapter = previous;
    uninstallFakeSecureStorage();
  });

  /// 拉一份已含热门歌单 + 新碟上架数据的 Provider（经假适配器，不碰网络）。
  Future<KugouProvider> seed(WidgetTester tester) async {
    final provider = KugouProvider(registerDeviceOnStart: false);
    await tester.runAsync(() async {
      await provider.getPlaylist();
      await provider.getTopAlbum();
    });
    return provider;
  }

  testWidgets('热门歌单完整列表页首帧即渲染网格，且卡片带歌单命名空间 Hero 端点',
      (tester) async {
    final kugou = await seed(tester);
    addTearDown(kugou.dispose);

    await tester.pumpWidget(_host(kugou, const PlaylistBrowsePage()));
    await tester.pump(); // 首帧：initState 按现有数据渲染网格

    // 关键回归点：首帧不能是 loading 圈（框架 Hero 在 push 后一帧内配对两端，
    // 首帧无 Hero 端点 = 推入时封面不衔接）。
    expect(find.byType(M3ELoadingIndicator), findsNothing);
    expect(find.byType(AlbumCard), findsNWidgets(4));

    // 重复 gid（p4 与 p1 同为 g1）只有首次出现挂 tag：3 个 Hero、g1 恰好一次。
    final tags = _heroTags(tester).whereType<String>().toList();
    expect(tags.where((t) => t.startsWith(kPlaylistCoverHeroTagPrefix)).length, 3);
    expect(
      tags.where((t) => t == playlistCoverHeroTag('g1')).length,
      1,
    );
    expect(tags, contains(playlistCoverHeroTag('g2')));
    expect(tags, contains(playlistCoverHeroTag('g3')));

    await tester.pumpAndSettle();
  });

  testWidgets('新碟上架完整列表页首帧即渲染网格，且卡片带专辑命名空间 Hero 端点',
      (tester) async {
    final kugou = await seed(tester);
    addTearDown(kugou.dispose);

    await tester.pumpWidget(_host(kugou, const NewAlbumBrowsePage()));
    await tester.pump();

    expect(find.byType(M3ELoadingIndicator), findsNothing);
    expect(find.byType(AlbumCard), findsNWidgets(3));

    // 重复专辑 id（a2 出现两次）只有首次出现挂 tag：a1/a2 各一次。
    expect(
      find.byWidgetPredicate(
        (w) => w is Hero && w.tag == albumCoverHeroTag('a1'),
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (w) => w is Hero && w.tag == albumCoverHeroTag('a2'),
      ),
      findsOneWidget,
    );

    await tester.pumpAndSettle();
  });

  testWidgets('搜索页区块：新碟上架小封面挂专辑命名空间 Hero，热门歌单挂歌单命名空间',
      (tester) async {
    final kugou = await seed(tester);
    addTearDown(kugou.dispose);

    await tester.pumpWidget(_host(kugou, const MusicExploreSections()));
    // ensureLoaded 会对空数据分区补拉（主题/场景/排行榜，假适配器回空数据），
    // 排干真实事件循环直到数据分区都渲染出来。
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 20));
      if (find.byWidgetPredicate(
            (w) => w is Hero && w.tag == albumCoverHeroTag('a1'),
          ).evaluate().isNotEmpty) {
        break;
      }
    }

    // 专辑小封面用 album 命名空间（与歌单互斥），且重复 id 只挂一次。
    expect(
      find.byWidgetPredicate(
        (w) => w is Hero && w.tag == albumCoverHeroTag('a1'),
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (w) => w is Hero && w.tag == albumCoverHeroTag('a2'),
      ),
      findsOneWidget,
    );
    // 歌单小封面仍是歌单命名空间（gid 口径）。
    expect(
      find.byWidgetPredicate(
        (w) => w is Hero && w.tag == playlistCoverHeroTag('g1'),
      ),
      findsOneWidget,
    );

    await tester.pumpAndSettle();
  });

  testWidgets('区块「›」推入完整列表页：转场首帧两端 Hero 成对，收集阶段零异常',
      (tester) async {
    final kugou = await seed(tester);
    addTearDown(kugou.dispose);

    await tester.pumpWidget(_host(kugou, const MusicExploreSections()));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 20));
      if (find.byWidgetPredicate(
            (w) => w is Hero && w.tag == albumCoverHeroTag('a1'),
          ).evaluate().isNotEmpty) {
        break;
      }
    }

    // 热门歌单是第一个带「›」的分区（主题/场景分区无入口）。
    await tester.tap(find.byIcon(Icons.chevron_right).first);
    await tester.pump(); // push 后一帧：转场收集扫描两端子树
    expect(tester.takeException(), isNull);

    // 转场中目标页网格已在场（首帧渲染），页面落定后可继续前进。
    await tester.pumpAndSettle();
    expect(find.byType(PlaylistBrowsePage), findsOneWidget);
    // 搜索页区块仍在下层路由，同名文本两处都有，限定完整列表页范围断言。
    expect(
      find.descendant(
        of: find.byType(PlaylistBrowsePage),
        matching: find.text('歌单p1'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('新碟上架「›」推入完整列表页：专辑端点成对，收集阶段零异常',
      (tester) async {
    final kugou = await seed(tester);
    addTearDown(kugou.dispose);

    await tester.pumpWidget(_host(kugou, const MusicExploreSections()));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 20));
      if (find.byWidgetPredicate(
            (w) => w is Hero && w.tag == albumCoverHeroTag('a1'),
          ).evaluate().isNotEmpty) {
        break;
      }
    }

    // 最后一个带「›」的分区是新碟上架（排行榜分区数据为空不渲染）。
    await tester.tap(find.byIcon(Icons.chevron_right).last);
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.pumpAndSettle();
    expect(find.byType(NewAlbumBrowsePage), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(NewAlbumBrowsePage),
        matching: find.text('专辑a1'),
      ),
      findsOneWidget,
    );
  });
}
