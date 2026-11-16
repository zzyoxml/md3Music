import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/modules/user/favorites_page.dart';
import 'package:md3music/providers/playlist_collection_notifier.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';

import '../../test_helpers/fake_secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('收藏页卸载时不从失效context读取Provider', (tester) async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    final client = KugouApiClient();
    final previousAdapter = client.dio.httpClientAdapter;
    final adapter = _FavoritesPageAdapter();
    client.dio.httpClientAdapter = adapter;
    _markLocalServerReady();
    final notifier = PlaylistCollectionNotifier();
    final tabConfigProvider = TabConfigProvider();

    try {
      await tester.pumpWidget(
        _favoritesApp(notifier, tabConfigProvider),
      );
      await _pushFavoritesPage(tester);
      await _settleInitialProbe(tester);
      await _popFavoritesPage(tester);

      expect(tester.takeException(), isNull);
    } finally {
      notifier.dispose();
      tabConfigProvider.dispose();
      client.dio.httpClientAdapter = previousAdapter;
      uninstallFakeSecureStorage();
    }
  });

  testWidgets('收藏页卸载后会取消周期网络探测', (tester) async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    final client = KugouApiClient();
    final previousAdapter = client.dio.httpClientAdapter;
    final adapter = _FavoritesPageAdapter();
    client.dio.httpClientAdapter = adapter;
    _markLocalServerReady();
    final notifier = PlaylistCollectionNotifier();
    final tabConfigProvider = TabConfigProvider();

    try {
      await tester.pumpWidget(
        _favoritesApp(notifier, tabConfigProvider),
      );
      await _pushFavoritesPage(tester);
      await _settleInitialProbe(tester);
      await _popFavoritesPage(tester);
      expect(find.byType(FavoritesPage), findsNothing);
      final requestsAtDispose = adapter.serverNowRequests;
      await tester.pump(const Duration(seconds: 31));

      expect(adapter.serverNowRequests, requestsAtDispose);
      expect(tester.takeException(), isNull);
    } finally {
      notifier.dispose();
      tabConfigProvider.dispose();
      client.dio.httpClientAdapter = previousAdapter;
      uninstallFakeSecureStorage();
    }
  });
}

void _markLocalServerReady() {
  final generation = KugouApiClient.markServerStarting();
  KugouApiClient.markServerReady(generation);
}

Future<void> _pushFavoritesPage(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('open-favorites')));
  await tester.pump();
}

Future<void> _settleInitialProbe(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 16));
}

Future<void> _popFavoritesPage(WidgetTester tester) async {
  tester.state<_FavoritesRouteHostState>(find.byType(_FavoritesRouteHost))
      .closeFavorites();
  await tester.pump();
}

Widget _favoritesApp(
  PlaylistCollectionNotifier notifier,
  TabConfigProvider tabConfigProvider,
) => MultiProvider(
  providers: [
    ChangeNotifierProvider<PlaylistCollectionNotifier>.value(value: notifier),
    ChangeNotifierProvider<TabConfigProvider>.value(value: tabConfigProvider),
  ],
  child: MaterialApp(home: const _FavoritesRouteHost()),
);

class _FavoritesRouteHost extends StatefulWidget {
  const _FavoritesRouteHost();

  @override
  State<_FavoritesRouteHost> createState() => _FavoritesRouteHostState();
}

class _FavoritesRouteHostState extends State<_FavoritesRouteHost> {
  bool _showFavorites = false;

  void closeFavorites() => setState(() => _showFavorites = false);

  @override
  Widget build(BuildContext context) => _showFavorites
      ? const FavoritesPage()
      : Scaffold(
          body: Center(
            child: ElevatedButton(
              key: const ValueKey('open-favorites'),
              onPressed: () => setState(() => _showFavorites = true),
              child: const Text('打开收藏'),
            ),
          ),
        );
}

class _FavoritesPageAdapter implements HttpClientAdapter {
  int serverNowRequests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/server/now') {
      serverNowRequests++;
    }
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
