import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/modules/user/favorites_page.dart';
import 'package:md3music/providers/playlist_collection_notifier.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';

import '../../test_helpers/fake_secure_storage.dart';

/// 「我的收藏」列表排序同步到云端（`/playlist/sort`）的触发时机。
///
/// 关键行为：拖拽过程中**不发请求**（拖一格发一次会把服务端打满），
/// 只在退出排序模式时发一次；没有拖过则一次都不发。
///
/// 拖动本身通过直接调用 M3E 列表的 [M3EReorderableDismissibleList.onReorder]
/// 来驱动，而不是模拟长按拖拽手势：M3E 的重排走
/// `DelayedMultiDragGestureRecognizer`（200ms 延迟）＋自定义 slot 位移，
/// 在 widget test 里起手后不提交重排（实测拖动后两行 y 坐标不变、
/// onReorder 不回调），模拟手势只会测到 M3E 的手势识别而非本页逻辑。
/// 本页真正要保证的是「回调进来后置脏 → 退出时发一次请求」这条链路。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late KugouApiClient client;
  late _FavoritesAdapter adapter;
  late HttpClientAdapter previousAdapter;
  late PlaylistCollectionNotifier notifier;
  late TabConfigProvider tabConfigProvider;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    client = KugouApiClient();
    previousAdapter = client.dio.httpClientAdapter;
    adapter = _FavoritesAdapter();
    client.dio.httpClientAdapter = adapter;
    final generation = KugouApiClient.markServerStarting();
    KugouApiClient.markServerReady(generation);
    await client.setLoginCookies('token-abc', '10086');
    client.lastKnownPlaylistTotalVer = 9;
    notifier = PlaylistCollectionNotifier();
    tabConfigProvider = TabConfigProvider();
  });

  tearDown(() {
    // 还原适配器：同步请求是 fire-and-forget 的异步调用，最后一个用例
    // 退出时可能还有在途请求，不还原就会落到下一个用例的适配器上（串测）。
    client.dio.httpClientAdapter = previousAdapter;
    notifier.dispose();
    tabConfigProvider.dispose();
    uninstallFakeSecureStorage();
  });

  Future<void> openFavorites(WidgetTester tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlaylistCollectionNotifier>.value(
            value: notifier,
          ),
          ChangeNotifierProvider<TabConfigProvider>.value(
            value: tabConfigProvider,
          ),
        ],
        child: const MaterialApp(home: FavoritesPage()),
      ),
    );
    // 歌单列表加载 + 分组动画
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// 进入「我创建的歌单」的排序模式。
  Future<void> enterSortMode(WidgetTester tester) async {
    final buttons = find.byTooltip('自由排序');
    expect(buttons, findsWidgets, reason: '排序按钮应存在');
    await tester.tap(buttons.first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.byType(M3EReorderableDismissibleList),
      findsOneWidget,
      reason: '排序模式下分组主体应换成 M3E 可拖拽列表',
    );
  }

  /// 退出排序模式（点「完成排序」）。
  Future<void> exitSortMode(WidgetTester tester) async {
    await tester.tap(find.byTooltip('完成排序').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// 触发一次拖拽重排（[from] / [to] 均为 M3E 的「移除前」插入位语义）。
  Future<void> reorder(WidgetTester tester, int from, int to) async {
    final list = tester.widget<M3EReorderableDismissibleList>(
      find.byType(M3EReorderableDismissibleList),
    );
    // M3E 把「移除前」位换算成「移除后」位后再回调本页的 _reorderGroup
    // （见 _GroupSection 里 `newIndex > oldIndex ? newIndex - 1 : newIndex`）。
    list.onReorder(from, to);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('进入又退出排序模式但没拖动 → 不发 /playlist/sort', (tester) async {
    await openFavorites(tester);
    await enterSortMode(tester);
    await exitSortMode(tester);

    expect(adapter.sortRequests, isEmpty, reason: '没有实际改动就不该打扰服务端');
    expect(tester.takeException(), isNull);
  });

  testWidgets('拖动后退出排序模式 → 发一次 /playlist/sort，data 为 listid|type|sort', (
    tester,
  ) async {
    await openFavorites(tester);
    await enterSortMode(tester);

    await reorder(tester, 0, 2);

    // 拖拽过程中不得发请求
    expect(adapter.sortRequests, isEmpty, reason: '拖拽过程不发请求');

    await exitSortMode(tester);

    expect(adapter.sortRequests, hasLength(1));
    final q = adapter.sortRequests.single;
    expect(q['total_ver'], 9);
    // 我自己创建的歌单 → type 0，sort 从 0 连续编号
    final data = q['data'] as String;
    expect(data.split(','), hasLength(2));
    for (final part in data.split(',')) {
      expect(part.split('|'), hasLength(3));
      expect(part.split('|')[1], '0', reason: '自建歌单 type=0');
    }
    expect(data.split(',').first.split('|')[2], '0');
    expect(data.split(',').last.split('|')[2], '1');
    expect(tester.takeException(), isNull);
  });

  testWidgets('重排后顺序确实写回（歌单二 排到 歌单一 之前）', (tester) async {
    await openFavorites(tester);
    await enterSortMode(tester);

    final beforeY = tester.getCenter(find.text('歌单一').first).dy;
    final beforeY2 = tester.getCenter(find.text('歌单二').first).dy;
    expect(beforeY2, greaterThan(beforeY), reason: '初始：歌单一 在上');

    await reorder(tester, 0, 2);

    final afterY = tester.getCenter(find.text('歌单一').first).dy;
    final afterY2 = tester.getCenter(find.text('歌单二').first).dy;
    expect(afterY2, lessThan(afterY), reason: '重排后：歌单二 应在上');

    await exitSortMode(tester);
    // 顺序变了 → 必须同步
    expect(adapter.sortRequests, hasLength(1));
    expect(
      (adapter.sortRequests.single['data'] as String).split(',').first,
      startsWith('22|'),
      reason: 'data 首条应是重排后位于最前的 歌单二(listid=22)',
    );
  });

  testWidgets('无变化的重复重排也被同步（脏标记在拖拽时置位）', (tester) async {
    await openFavorites(tester);
    await enterSortMode(tester);

    // 0 → 1 是「移除前」位，换算后等价于原地不动
    await reorder(tester, 0, 1);
    await exitSortMode(tester);

    // 只要拖拽回调发生过就提交一次：判定「顺序是否真的变了」需要额外快照，
    // 而上游对同一顺序重复提交是幂等的，多提一次的代价远小于漏提。
    expect(adapter.sortRequests, hasLength(1));
  });

  testWidgets('拖动后直接卸载页面 → 仍补发一次 /playlist/sort', (tester) async {
    await openFavorites(tester);
    await enterSortMode(tester);

    await reorder(tester, 0, 2);
    expect(adapter.sortRequests, isEmpty);

    // 直接卸载（模拟用户拖完就返回/切 tab）
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(adapter.sortRequests, hasLength(1),
        reason: 'dispose 时脏标记未消费，必须补发，否则云端停在旧顺序');
  });
}

/// 假适配器：返回两个自建歌单，并记录 /playlist/sort 的 query。
class _FavoritesAdapter implements HttpClientAdapter {
  final List<Map<String, dynamic>> sortRequests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    if (path == '/playlist/sort') {
      sortRequests.add(Map<String, dynamic>.from(options.queryParameters));
      return _json(const {'status': 1});
    }
    if (path == '/user/playlist') {
      return _json(const {
        'status': 1,
        'data': {
          'total_ver': 9,
          'info': [
            {
              'listid': '11',
              // specialid / global_collection_id 必须有且互不相同：
              // _playlistKey = globalCollectionId ?? id，两者都空时两行会拿到
              // 同一个 key，重排会被 M3E 当成无变化而静默丢弃。
              'specialid': '11',
              'global_collection_id': 'gid_11',
              'name': '歌单一',
              'list_create_userid': '10086',
              'type': 0,
              'source': 0,
              'songcount': 2,
            },
            {
              'listid': '22',
              'specialid': '22',
              'global_collection_id': 'gid_22',
              'name': '歌单二',
              'list_create_userid': '10086',
              'type': 0,
              'source': 0,
              'songcount': 2,
            },
          ],
        },
      });
    }
    return _json(const {'status': 1});
  }

  ResponseBody _json(Map<String, dynamic> obj) => ResponseBody.fromString(
        jsonEncode(obj),
        200,
        headers: const {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );

  @override
  void close({bool force = false}) {}
}
