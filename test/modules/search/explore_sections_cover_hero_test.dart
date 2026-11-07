import 'dart:convert';
import 'dart:async';
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
import 'package:md3music/modules/charts/charts_page.dart';
import 'package:md3music/modules/search/explore_sections.dart';
import 'package:md3music/modules/album/new_album_browse_page.dart';
import 'package:md3music/modules/search/search_section_header.dart';
import 'package:md3music/providers/device_provider.dart';
import 'package:md3music/providers/grid_columns_provider.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';
import 'package:md3music/widgets/album_card.dart';
import 'package:md3music/widgets/playlist_cover_hero.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../test_helpers/fake_secure_storage.dart';

/// 三组目录数据独立于主题歌单；模拟主题返回空或一直未完成的真实故障边界。
class _ExploreFixtureProvider extends KugouProvider {
  _ExploreFixtureProvider({this.populated = true, this.themeGate})
      : super(registerDeviceOnStart: false);

  final bool populated;
  final Completer<void>? themeGate;
  int playlistCalls = 0;
  int rankCalls = 0;
  int albumCalls = 0;

  @override
  List<KugouThemeInfo> get themePlaylistData => const [];
  @override
  List<KugouPlaylistBrief> get playlistList => populated
      ? const [KugouPlaylistBrief(id: 'p1', name: '推荐测试歌单')]
      : const [];
  @override
  KugouRankList? get rankList => populated
      ? const KugouRankList(ranks: [KugouRank(id: 'r1', name: '测试排行榜')])
      : null;
  @override
  List<KugouAlbumBrief> get topAlbums => populated
      ? const [KugouAlbumBrief(id: 'a1', name: '测试新碟')]
      : const [];
  @override
  Future<void> getThemePlaylist({bool forceRefresh = false}) async {
    if (themeGate != null) await themeGate!.future;
  }
  @override
  Future<void> getPlaylist({String? categoryId, int page = 1, bool forceRefresh = false}) async { playlistCalls++; }
  @override
  Future<void> getRankList({bool forceRefresh = false}) async { rankCalls++; }
  @override
  Future<void> getTopAlbum({int page = 1, bool forceRefresh = false}) async { albumCalls++; }
}

Finder _exploreAction(String label) => find.descendant(
      of: find.byType(SearchSectionAction),
      matching: find.text(label),
    );

/// 搜索空态目录恢复、主题数据故障边界，以及封面转场的既有回归点：
/// 1. [PlaylistBrowsePage] 首帧即渲染网格且卡片带歌单命名空间 Hero 端点
///    （框架 Hero 在转场首帧配对，浏览页先画一帧 loading 圈就会配对扑空）。
/// 2. 三个完整浏览入口与恢复的预览内容可达，且转场零异常。
///
/// 另一处硬约束：同一路由子树内 tag 必须唯一（重复 tag 在转场收集阶段抛
/// FlutterError），服务端列表可能出现重复 gid，卡片按首次出现挂 tag。
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
    if (path.contains('/theme/playlist')) {
      // 2 个主题歌单：让探索段横滑带渲染出来（段头「›」随之出现）。
      return _json({
        'list': [
          {
            'theme_id': 't1',
            'theme_name': '主题一',
            'img': 'https://img.example/t1.jpg',
          },
          {
            'theme_id': 't2',
            'theme_name': '主题二',
            'img': 'https://img.example/t2.jpg',
          },
        ],
      });
    }
    // 其余端点一律空数据。
    return _json(const {});
  }

  ResponseBody _json(Object body) => ResponseBody.fromString(
        jsonEncode({'status': 1, 'data': body}),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
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
      // ChartsPage 的 AppBar/页面会 read ThemeProvider（主题模式等），缺了即抛
      // ProviderNotFoundException。
      ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
    ],
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

List<Object> _heroTags(WidgetTester tester) => tester
    .widgetList<Hero>(find.byType(Hero))
    .map((h) => h.tag)
    .toList(growable: false);

/// 区块封面是 CachedNetworkImage，其缓存管理器要 path_provider 的落盘目录；
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

  testWidgets('新碟区块已迁移到发现页，不再占用搜索探索区', (tester) async {
    final kugou = _ExploreFixtureProvider();
    addTearDown(kugou.dispose);
    await tester.pumpWidget(_host(kugou,
        const SingleChildScrollView(child: MusicExploreSections())));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    expect(find.text('测试新碟'), findsNothing);
    expect(_exploreAction('新碟上架'), findsNothing);
    expect(_exploreAction('热门歌单'), findsOneWidget);
    expect(_exploreAction('排行榜'), findsOneWidget);
    expect(kugou.albumCalls, 0);
  });

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

  /// 拉一份已含热门歌单数据的 Provider（经假适配器，不碰网络）。
  Future<KugouProvider> seed(WidgetTester tester) async {
    final provider = KugouProvider(registerDeviceOnStart: false);
    await tester.runAsync(() async {
      await provider.getPlaylist();
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

  testWidgets('探索段渲染主题横滑带，「热门歌单/排行榜」入口可达且转场零异常',
      (tester) async {
    final kugou = await seed(tester);
    addTearDown(kugou.dispose);

    await tester.pumpWidget(_host(kugou,
        const SingleChildScrollView(child: MusicExploreSections())));
    // initState 后 _ensureLoaded 补拉主题歌单，排干真实事件循环直到横滑带渲染。
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 20));
      if (find.text('主题一').evaluate().isNotEmpty) {
        break;
      }
    }
    expect(find.text('主题一'), findsOneWidget);
    expect(find.text('主题二'), findsOneWidget);

    // 段头双入口：「热门歌单」→ PlaylistBrowsePage。
    await tester.tap(_exploreAction('热门歌单'));
    await tester.pump(); // push 后一帧：转场收集扫描两端子树
    expect(tester.takeException(), isNull);

    await tester.pumpAndSettle();
    expect(find.byType(PlaylistBrowsePage), findsOneWidget);
    // 探索段仍在下层路由，同名文本两处都有，限定完整列表页范围断言。
    expect(
      find.descendant(
        of: find.byType(PlaylistBrowsePage),
        matching: find.text('歌单p1'),
      ),
      findsOneWidget,
    );

    // 返回探索段，「排行榜」入口 → ChartsPage（全 App 唯一入口，回归防护）。
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(_exploreAction('排行榜'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    expect(find.byType(ChartsPage), findsOneWidget);
  });

  testWidgets('主题歌单为空时仍展示推荐歌单和排行榜，复用已有缓存', (tester) async {
    final kugou = _ExploreFixtureProvider();
    addTearDown(kugou.dispose);
    await tester.pumpWidget(_host(kugou,
        const SingleChildScrollView(child: MusicExploreSections())));
    await tester.pumpAndSettle();

    expect(_exploreAction('热门歌单'), findsOneWidget);
    expect(_exploreAction('排行榜'), findsOneWidget);
    expect(_exploreAction('新碟上架'), findsNothing);
    expect(find.text('推荐测试歌单'), findsOneWidget);
    expect(find.text('测试排行榜'), findsOneWidget);
    expect(find.text('测试新碟'), findsNothing);
    expect([kugou.playlistCalls, kugou.rankCalls, kugou.albumCalls], [0, 0, 0]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('主题请求未完成也立即显示两个入口，并独立补拉缺失目录', (tester) async {
    final gate = Completer<void>();
    final kugou = _ExploreFixtureProvider(populated: false, themeGate: gate);
    addTearDown(kugou.dispose);
    await tester.pumpWidget(_host(kugou,
        const SingleChildScrollView(child: MusicExploreSections())));
    await tester.pump();

    expect(_exploreAction('热门歌单'), findsOneWidget);
    expect(_exploreAction('排行榜'), findsOneWidget);
    expect(_exploreAction('新碟上架'), findsNothing);
    expect([kugou.playlistCalls, kugou.rankCalls, kugou.albumCalls], [1, 1, 0]);
    gate.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('迁移后的新碟完整列表仍保留封面 Hero', (tester) async {
    final kugou = _ExploreFixtureProvider();
    addTearDown(kugou.dispose);
    await tester.pumpWidget(_host(kugou, const NewAlbumBrowsePage()));
    // 首帧即应有缓存封面，不依赖图片缓存/字体等真实 IO 的完成时序。
    await tester.pump();

    expect(find.byWidgetPredicate((w) => w.runtimeType.toString() == 'NewAlbumBrowsePage'), findsOneWidget);
    expect(find.byType(AlbumCard), findsOneWidget);
    expect(_heroTags(tester), contains(albumCoverHeroTag('a1')));
    expect(kugou.albumCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏大字号下目录入口可换行且无溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final kugou = _ExploreFixtureProvider();
    addTearDown(kugou.dispose);
    await tester.pumpWidget(_host(kugou,
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
          child: const SingleChildScrollView(child: MusicExploreSections()),
        )));
    await tester.pumpAndSettle();
    expect(_exploreAction('热门歌单'), findsOneWidget);
    expect(_exploreAction('排行榜'), findsOneWidget);
    expect(_exploreAction('新碟上架'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
