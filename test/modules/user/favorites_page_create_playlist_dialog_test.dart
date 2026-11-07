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

  testWidgets('收藏页：新建歌单弹窗点击取消不抛异常', (tester) async {
    // 登录态：旧版全局明文键，_initFromStorage 会迁到加密存储并写入内存
    SharedPreferences.setMockInitialValues({
      'kugou_token': 'test-token',
      'kugou_userid': '123456',
    });
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
      expect(client.isLoggedIn, isTrue, reason: '前置条件：登录态应已就绪');

      // 空列表态下的「新建歌单」入口
      expect(find.text('还没有歌单'), findsOneWidget);
      await tester.tap(find.text('新建歌单'));
      await tester.pumpAndSettle();

      // 弹窗已打开
      expect(find.text('输入歌单名称'), findsOneWidget);
      expect(find.text('设为隐私歌单'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(find.text('输入歌单名称'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      notifier.dispose();
      tabConfigProvider.dispose();
      client.dio.httpClientAdapter = previousAdapter;
      uninstallFakeSecureStorage();
    }
  });

  testWidgets('收藏页：新建歌单弹窗点击创建不抛异常', (tester) async {
    // 与「取消」用例同源：退出动画期间 TextField 仍在重建，controller 若被
    // 提前 dispose，创建路径同样会抛「used after being disposed」。
    SharedPreferences.setMockInitialValues({
      'kugou_token': 'test-token',
      'kugou_userid': '123456',
    });
    installFakeSecureStorage();
    final client = KugouApiClient();
    final previousAdapter = client.dio.httpClientAdapter;
    client.dio.httpClientAdapter = _FavoritesPageAdapter();
    _markLocalServerReady();
    final notifier = PlaylistCollectionNotifier();
    final tabConfigProvider = TabConfigProvider();

    try {
      await tester.pumpWidget(
        _favoritesApp(notifier, tabConfigProvider),
      );
      await _pushFavoritesPage(tester);
      await _settleInitialProbe(tester);
      expect(client.isLoggedIn, isTrue, reason: '前置条件：登录态应已就绪');

      await tester.tap(find.text('新建歌单'));
      await tester.pumpAndSettle();
      expect(find.text('输入歌单名称'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '测试歌单');
      await tester.pumpAndSettle();
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();

      expect(find.text('输入歌单名称'), findsNothing);
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
