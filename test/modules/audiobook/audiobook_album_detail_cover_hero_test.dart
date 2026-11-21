import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/core/theme/app_dimens.dart';
import 'package:md3music/modules/audiobook/audiobook_album_detail_page.dart';
import 'package:md3music/providers/car_mode_provider.dart';
import 'package:md3music/providers/device_provider.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';
import 'package:md3music/widgets/playlist_cover_hero.dart';

import '../../test_helpers/fake_secure_storage.dart';

/// 听书专辑详情页是封面连贯过渡的**终点**：页头必须在进场转场期间就存在，飞行才有
/// 落点（原实现 `child: _isLoading ? Center(spinner) : Column(...)`，页头等接口返回
/// 才构建，动画只能等页面滑完再补飞）。
///
/// 断言只落在转场期间（pump 两帧、绝不 pumpAndSettle）：此时
/// `_startLoadingAfterEntry` 还在让路，数据未达，正是真机上动画进行中的那一帧。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const album = KugouLongAudioAlbum(
    id: '202415911',
    name: '北大怀沙说三国演义',
    author: '北大怀沙',
  );

  late PlayerProvider player;
  late CarModeProvider carMode;
  late ThemeProvider theme;
  late KugouProvider kugou;
  late KugouApiClient client;
  late HttpClientAdapter previousAdapter;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    installFakeSecureStorage();
    // 空响应适配器：转场收敛后 `_load` 会真的发起请求，测试环境不能碰网络。
    client = KugouApiClient();
    previousAdapter = client.dio.httpClientAdapter;
    client.dio.httpClientAdapter = _EmptyAdapter();
    final generation = KugouApiClient.markServerStarting();
    KugouApiClient.markServerReady(generation);
    player = PlayerProvider();
    carMode = CarModeProvider();
    theme = ThemeProvider();
    kugou = KugouProvider();
  });

  tearDown(() {
    player.dispose();
    carMode.dispose();
    theme.dispose();
    kugou.dispose();
    client.dio.httpClientAdapter = previousAdapter;
    uninstallFakeSecureStorage();
  });

  Future<void> openDetailPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlayerProvider>.value(value: player),
          ChangeNotifierProvider<CarModeProvider>.value(value: carMode),
          ChangeNotifierProvider<DeviceProvider>(create: (_) => DeviceProvider()),
          ChangeNotifierProvider<ThemeProvider>.value(value: theme),
          ChangeNotifierProvider<KugouProvider>.value(value: kugou),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => AudiobookAlbumDetailPage(album: album),
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
  /// 收敛时才被取消，dio 每次请求还会挂一个 0 时长定时器；不排干会撞
  /// 「A Timer is still pending」。
  Future<void> drainEntryAndLoad(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 1200));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('转场期间页头封面 Hero 已存在，tag 取 widget.album.id',
      (tester) async {
    await openDetailPage(tester);

    expect(find.byType(AudiobookAlbumDetailPage), findsOneWidget);
    final hero = tester.widget<PlaylistCoverHero>(
      find.descendant(
        of: find.byType(AudiobookAlbumDetailPage),
        matching: find.byType(PlaylistCoverHero),
      ),
    );
    // 听书命名空间（同一数字 id 与歌单/专辑互不相干）。
    expect(hero.tag, audiobookCoverHeroTag('202415911'));
    expect(hero.radius, AppRadius.lgAll);
    // 落位保持到真实封面出图为止的信号必须挂上，否则交接瞬间露兜底占位。
    expect(hero.destReady, isNotNull);
    expect(hero.destReady!.value, isFalse);

    await drainEntryAndLoad(tester);
  });

  testWidgets('转场期间页头标题在、章节区不渲染空态', (tester) async {
    await openDetailPage(tester);

    expect(find.text('北大怀沙说三国演义'), findsWidgets);
    // 加载期章节区整块被挡住：`_playableSongs` 为空时按钮文案是「暂无免费章节」，
    // 有章节时是「播放全部 (N)」，两者都不该在转场期间出现。
    expect(find.text('暂无免费章节'), findsNothing);
    expect(find.textContaining('播放全部'), findsNothing);
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
