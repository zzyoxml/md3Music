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

import 'package:md3music/modules/channel/channel_detail_page.dart';

/// 频道详情页是 `md3/channel-cover/` 命名空间的**终点**：加载态页头照常渲染，
/// 转场期间飞行有落点；`_coverUrl` 稍后可能被详情接口替换，靠 destReady 兜交接。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = KugouYouthChannel(
    id: '9001',
    name: '电台频道',
    coverUrl: null,
    desc: null,
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

  Future<void> openChannelPage(WidgetTester tester) async {
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
                    builder: (_) => ChannelDetailPage(channel: channel),
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

  testWidgets('加载态页头封面 Hero 已存在，tag 取 widget.channel.id', (tester) async {
    await openChannelPage(tester);

    expect(find.byType(ChannelDetailPage), findsOneWidget);
    final heroes = find.descendant(
      of: find.byType(ChannelDetailPage),
      matching: find.byType(PlaylistCoverHero),
    );
    // 加载态只应有页头这一个 Hero（相似频道卡不参与飞行）。
    expect(heroes, findsOneWidget);
    final hero = tester.widget<PlaylistCoverHero>(heroes);
    expect(hero.tag, channelCoverHeroTag('9001'));
    expect(hero.radius, AppRadius.lgAll);
    expect(hero.destReady, isNotNull);
    expect(hero.destReady!.value, isFalse);

    await drainEntryAndLoad(tester);
  });

  testWidgets('转场期间页头名称在、故事区未出现', (tester) async {
    await openChannelPage(tester);

    expect(find.text('电台频道'), findsWidgets);
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
