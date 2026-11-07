import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/core/theme/app_dimens.dart';
import 'package:md3music/providers/car_mode_provider.dart';
import 'package:md3music/providers/device_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/playlist_collection_notifier.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';
import 'package:md3music/widgets/playlist_cover_hero.dart';

import '../../test_helpers/fake_secure_storage.dart';

import 'package:md3music/modules/scene/scene_detail_page.dart';

/// 场景详情页是 `md3/scene-cover/` 命名空间的**终点**：页头必须在进场转场
/// 期间就存在（已去整页加载闸门），飞行才有落点。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const scene = KugouSceneInfo(
    id: '8001',
    name: '深夜 headphone',
    coverUrl: null,
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

  Future<void> openScenePage(WidgetTester tester) async {
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
                    builder: (_) => SceneDetailPage(scene: scene),
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
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
  }

  Future<void> drainEntryAndLoad(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 1200));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('转场期间页头封面 Hero 已存在，tag 取 widget.scene.id', (tester) async {
    await openScenePage(tester);

    expect(find.byType(SceneDetailPage), findsOneWidget);
    final hero = tester.widget<PlaylistCoverHero>(
      find.descendant(
        of: find.byType(SceneDetailPage),
        matching: find.byType(PlaylistCoverHero),
      ),
    );
    expect(hero.tag, sceneCoverHeroTag('8001'));
    expect(hero.radius, AppRadius.lgAll);
    expect(hero.destReady, isNotNull);
    expect(hero.destReady!.value, isFalse);

    await drainEntryAndLoad(tester);
  });

  testWidgets('转场期间页头在、数据区只挂占位', (tester) async {
    await openScenePage(tester);

    expect(find.text('深夜 headphone'), findsWidgets);
    expect(find.text('音乐'), findsNothing);
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
