import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart' hide Card;
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/search/hot_search_board_card.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../test_helpers/fake_secure_storage.dart';

/// 返回 boardCount 个榜、每榜 30 条可辨识词的替身。
class _BoardsAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    String kw(int board, int i) => 'b$board-w$i';
    final boards = [0, 1]
        .map((b) => '{"name":"榜$b","keywords":['
            '${List.generate(30, (i) => '{"keyword":"${kw(b, i)}"}').join(',')}'
            ']}')
        .join(',');
    return ResponseBody.fromString(
      '{"status":1,"data":{"list":[$boards]}}',
      200,
      headers: {Headers.contentTypeHeader: ['application/json']},
    );
  }

  @override
  void close({bool force = false}) {}
}

class _FailAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
        '{"status":0,"msg":"transport_error"}',
        502,
        headers: {Headers.contentTypeHeader: ['application/json']},
      );

  @override
  void close({bool force = false}) {}
}

Widget _host(KugouProvider provider, ValueChanged<String> onTap) {
  return ChangeNotifierProvider<KugouProvider>.value(
    value: provider,
    child: MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [HotSearchBoardCard(onKeywordTap: onTap)],
        ),
      ),
    ),
  );
}

/// `KugouApiClient._onRequest` 会 await 初始化 Completer（flutter_secure_storage
/// 的 MethodChannel 往返）与本地服务就绪等待，这些只有真实事件循环才放行；
/// `testWidgets` 默认跑在 FakeAsync 区里，直接 await 会死锁（实测表现为整条用例
/// did not complete、`--timeout` 也不触发），故加载必须包在 [WidgetTester.runAsync]。
/// 同理，Provider 一律用 `registerDeviceOnStart: false` 构造——构造期的 `_autoConnect`
/// 会发一次 dio 请求，在 FakeAsync 区留下未决 Timer，触发
/// 「A Timer is still pending even after the widget tree was disposed」断言。
Future<void> _load(WidgetTester tester, KugouProvider provider,
        {bool forceRefresh = false}) =>
    tester.runAsync(() => provider.loadHotSearch(forceRefresh: forceRefresh));

/// 卡片内按钮的 `onPressed` 是 fire-and-forget，请求链横跨两个区域：dio 的即时
/// Timer 归 FakeAsync 时钟（要 pump 才走），MethodChannel 与响应回包归真实事件
/// 循环（要 runAsync 才走）。交替推进两者直到热搜状态收敛。
Future<void> _settleRequest(WidgetTester tester, KugouProvider provider) async {
  for (var i = 0; i < 20; i++) {
    if (provider.hotSearchState.value.status == HotSearchStatus.ready) return;
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpClientAdapter previous;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    previous = KugouApiClient().dio.httpClientAdapter;
    KugouApiClient.markServerReady(KugouApiClient.markServerStarting());
  });

  tearDown(() {
    KugouApiClient().dio.httpClientAdapter = previous;
    uninstallFakeSecureStorage();
  });

  testWidgets('显示当前榜 Top10 与序号，不越界显示第 11 条', (tester) async {
    KugouApiClient().dio.httpClientAdapter = _BoardsAdapter();
    final provider = KugouProvider(registerDeviceOnStart: false);
    final tapped = <String>[];
    await _load(tester, provider);

    await tester.pumpWidget(_host(provider, tapped.add));
    await tester.pump();

    expect(find.text('热门搜索'), findsOneWidget);
    expect(find.text('榜0'), findsOneWidget);
    expect(find.textContaining('b0-w0'), findsOneWidget);
    expect(find.textContaining('b0-w9'), findsOneWidget);
    expect(find.textContaining('b0-w10'), findsNothing);
    expect(find.text('1'), findsWidgets); // 序号列
    provider.dispose();
  });

  testWidgets('点关键词回调带出该词', (tester) async {
    KugouApiClient().dio.httpClientAdapter = _BoardsAdapter();
    final provider = KugouProvider(registerDeviceOnStart: false);
    final tapped = <String>[];
    await _load(tester, provider);

    await tester.pumpWidget(_host(provider, tapped.add));
    await tester.pump();

    await tester.tap(find.textContaining('b0-w3').first);
    await tester.pump();

    expect(tapped, ['b0-w3']);
    provider.dispose();
  });

  testWidgets('换一批翻到第二页（11-20），第三次回第一页', (tester) async {
    KugouApiClient().dio.httpClientAdapter = _BoardsAdapter();
    final provider = KugouProvider(registerDeviceOnStart: false);
    await _load(tester, provider);

    await tester.pumpWidget(_host(provider, (_) {}));
    await tester.pump();

    await tester.tap(find.text('换一批'));
    await tester.pump();
    expect(find.textContaining('b0-w10'), findsOneWidget);
    expect(find.textContaining('b0-w0'), findsNothing);

    await tester.tap(find.text('换一批'));
    await tester.pump();
    expect(find.textContaining('b0-w20'), findsOneWidget);

    await tester.tap(find.text('换一批'));
    await tester.pump();
    expect(find.textContaining('b0-w0'), findsOneWidget);
    provider.dispose();
  });

  testWidgets('切榜 chip 更换列表内容并把页码归 0', (tester) async {
    KugouApiClient().dio.httpClientAdapter = _BoardsAdapter();
    final provider = KugouProvider(registerDeviceOnStart: false);
    await _load(tester, provider);

    await tester.pumpWidget(_host(provider, (_) {}));
    await tester.pump();

    await tester.tap(find.text('换一批'));
    await tester.pump();
    await tester.tap(find.text('榜1'));
    await tester.pump();

    expect(find.textContaining('b1-w0'), findsOneWidget);
    expect(find.textContaining('b0-w10'), findsNothing);
    provider.dispose();
  });

  testWidgets('挂在没有 Material 祖先的树上也不被全局 ErrorWidget 兜底（回归）', (tester) async {
    // 真实搜索页的卡片祖先没有 Material；InkWell 缺 Material 祖先会抛
    // 「No Material widget found」，并被 lib/main.dart 的 _FallbackErrorWidget
    // 顶成「此处内容加载出错」（2026-10-04 真机堆栈：_WordRow 的 InkWell）。
    // 因此这里刻意不包 Scaffold / Material，只给最小的 Theme + Directionality。
    KugouApiClient().dio.httpClientAdapter = _BoardsAdapter();
    final provider = KugouProvider(registerDeviceOnStart: false);
    await _load(tester, provider);

    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: ChangeNotifierProvider<KugouProvider>.value(
        value: provider,
        child: Theme(
          data: ThemeData(colorScheme: const ColorScheme.light()),
          child: MediaQuery(
            data: const MediaQueryData(),
            child: ListView(
              children: [HotSearchBoardCard(onKeywordTap: (_) {})],
            ),
          ),
        ),
      ),
    ));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('b0-w0'), findsOneWidget);
    provider.dispose();
  });

  testWidgets('失败态显示错误文案与重试按钮，点重试重新加载', (tester) async {
    KugouApiClient().dio.httpClientAdapter = _FailAdapter();
    final provider = KugouProvider(registerDeviceOnStart: false);
    await _load(tester, provider);

    await tester.pumpWidget(_host(provider, (_) {}));
    await tester.pump();

    expect(find.text('暂无热搜数据'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    KugouApiClient().dio.httpClientAdapter = _BoardsAdapter();
    await tester.tap(find.text('重试'));
    await _settleRequest(tester, provider);
    await tester.pump();

    expect(find.textContaining('b0-w0'), findsOneWidget);
    provider.dispose();
  });
}
