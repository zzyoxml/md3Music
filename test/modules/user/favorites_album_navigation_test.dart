import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/modules/playlist/playlist_page.dart';
import 'package:md3music/modules/user/favorites_page.dart';
import 'package:md3music/providers/playlist_collection_notifier.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';

import '../../test_helpers/fake_secure_storage.dart';

void main() {
  testWidgets('打开收藏专辑时保留原始编号，不按名称重新搜索歌手或版本', (tester) async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    final client = KugouApiClient();
    final previousAdapter = client.dio.httpClientAdapter;
    final adapter = _AlbumAdapter();
    client.dio.httpClientAdapter = adapter;
    final generation = KugouApiClient.markServerStarting();
    KugouApiClient.markServerReady(generation);
    await client.setLoginCookies('test-token', '10086');
    final notifier = PlaylistCollectionNotifier();
    final tabs = TabConfigProvider();
    final observer = _RouteObserver();

    try {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<PlaylistCollectionNotifier>.value(
              value: notifier,
            ),
            ChangeNotifierProvider<TabConfigProvider>.value(value: tabs),
          ],
          child: MaterialApp(
            navigatorObservers: [observer],
            home: const FavoritesPage(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('专辑'));
      await tester.pumpAndSettle();

      expect(find.text('On an Island'), findsOneWidget);
      expect(adapter.albumSearchRequests, 0);
      await tester.tap(find.text('On an Island'));

      // 检查实际导航创建的页面参数，无需启动播放器等无关依赖。
      final route = observer.latest as MaterialPageRoute;
      final page =
          route.builder(tester.element(find.byType(FavoritesPage)))
              as PlaylistPage;
      expect(page.isAlbum, isTrue);
      expect(page.albumGlobalCollectionId, '623455');
      expect(page.playlist.subscribedListId, '45');
      observer.navigator!.removeRoute(route);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      client.dio.httpClientAdapter = previousAdapter;
      notifier.dispose();
      tabs.dispose();
      uninstallFakeSecureStorage();
    }
  });
}

class _RouteObserver extends NavigatorObserver {
  Route<dynamic>? latest;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    latest = route;
  }
}

class _AlbumAdapter implements HttpClientAdapter {
  int albumSearchRequests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    Object response = {'status': 1};
    if (options.uri.path == '/search/album') {
      albumSearchRequests++;
      response = {
        'status': 1,
        'data': {
          'info': [
            {'albumid': 208239317, 'albumname': 'On an Island', 'songcount': 1},
          ],
        },
      };
    } else if (options.uri.path == '/user/playlist') {
      response = {
        'status': 1,
        'data': {
          'info': [
            {
              'type': 1,
              'source': 2,
              'name': 'On an Island',
              'listid': 45,
              'global_collection_id': 'collection_3_10086_45_0',
              'musiclib_id': 623455,
              'list_create_listid': 623455,
              'count': 10,
            },
          ],
        },
      };
    }
    return ResponseBody.fromString(
      jsonEncode(response),
      200,
      headers: const {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
