import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/core/theme/app_dimens.dart';
import 'package:md3music/data/models/album.dart';
import 'package:md3music/modules/album/album_detail_page.dart';
import 'package:md3music/providers/car_mode_provider.dart';
import 'package:md3music/providers/device_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/playlist_collection_notifier.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/widgets/playlist_cover_hero.dart';

import '../../test_helpers/fake_secure_storage.dart';

/// 专辑详情页是封面连贯过渡的**终点**：页头必须在进场转场期间就存在，飞行才有落点
/// （原实现整页加载闸门，页头等接口返回才构建，观感变成「先看加载、再看到动画」）。
///
/// 断言全部落在**转场期间**（`pump` 两帧、不 pumpAndSettle）：此时
/// `_startLoadingAfterEntry` 还在让路，数据未达，正是真机上动画进行中的那一帧。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const album = Album(
    id: '777',
    name: '魔杰座',
    artist: '周杰伦',
    artworkUri: null,
    songCount: 11,
  );

  late PlayerProvider player;
  late CarModeProvider carMode;
  late ThemeProvider theme;
  late PlaylistCollectionNotifier collectionNotifier;
  late KugouApiClient client;
  late HttpClientAdapter previousAdapter;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    installFakeSecureStorage();
    // 空响应适配器：转场收敛后 `_fetchAlbum` 会真的发起请求，测试环境不能碰网络。
    client = KugouApiClient();
    previousAdapter = client.dio.httpClientAdapter;
    client.dio.httpClientAdapter = _EmptyAdapter();
    final generation = KugouApiClient.markServerStarting();
    KugouApiClient.markServerReady(generation);
    player = PlayerProvider();
    carMode = CarModeProvider();
    theme = ThemeProvider();
    collectionNotifier = PlaylistCollectionNotifier();
  });

  tearDown(() {
    player.dispose();
    carMode.dispose();
    theme.dispose();
    collectionNotifier.dispose();
    client.dio.httpClientAdapter = previousAdapter;
    uninstallFakeSecureStorage();
  });

  Future<void> openAlbumPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlayerProvider>.value(value: player),
          ChangeNotifierProvider<CarModeProvider>.value(value: carMode),
          ChangeNotifierProvider<DeviceProvider>(create: (_) => DeviceProvider()),
          ChangeNotifierProvider<ThemeProvider>.value(value: theme),
          ChangeNotifierProvider<PlaylistCollectionNotifier>.value(
            value: collectionNotifier,
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => AlbumDetailPage(album: album),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    // 第一帧只把新路由挂进 Navigator，第二帧才真正构建页面（转场进度 10ms）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
  }

  /// 收干转场与让路后的加载：`waitUntilEntrySettled` 的 900ms 兜底 Timer 在动画
  /// 收敛时才被取消，dio 每次请求还会挂一个 0 时长定时器；不把这些帧排干净，用例
  /// 结束时会撞上「A Timer is still pending」。
  Future<void> drainEntryAndLoad(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 400)); // 转场 completed
    await tester.pump(const Duration(milliseconds: 1200)); // 让路 + 请求发起
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50)); // 排干 dio 的 0 时长定时器
    }
  }

  testWidgets('转场期间页头封面 Hero 已存在，tag 取 widget.album.id', (tester) async {
    await openAlbumPage(tester);

    expect(find.byType(AlbumDetailPage), findsOneWidget);
    final hero = tester.widget<PlaylistCoverHero>(
      find.descendant(
        of: find.byType(AlbumDetailPage),
        matching: find.byType(PlaylistCoverHero),
      ),
    );
    // 专辑命名空间，不是歌单那条（同一数字 id 在两个命名空间下互不相干）。
    expect(hero.tag, albumCoverHeroTag('777'));
    expect(hero.radius, AppRadius.mdAll);
    // 落位保持到真实封面出图为止的信号必须挂上，否则交接瞬间露兜底占位。
    expect(hero.destReady, isNotNull);
    expect(hero.destReady!.value, isFalse);

    await drainEntryAndLoad(tester);
  });

  testWidgets('转场期间页头在、数据区只挂占位', (tester) async {
    await openAlbumPage(tester);

    // 页头标题转场期间即渲染（终点实体存在，飞行才有着落）。
    expect(find.text('魔杰座'), findsWidgets);
    // 歌曲区仍在加载：只挂占位，播放按钮与列表都不出现。
    expect(find.text('播放全部'), findsNothing);
    expect(tester.takeException(), isNull);

    await drainEntryAndLoad(tester);
  });
}

class _EmptyAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      '{}',
      200,
      headers: const {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
