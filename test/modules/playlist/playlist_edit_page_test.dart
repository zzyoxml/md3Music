import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/data/models/playlist.dart';
import 'package:md3music/modules/playlist/playlist_edit_page.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';

import '../../test_helpers/fake_secure_storage.dart';

/// 编辑歌单页的单测。
///
/// 关注三件**静默损坏**风险（都不会报错，只会写错云端数据）：
/// 1. `name` / `pic` 缺省时不得下发（空串会被上游当成改名成空 / 清掉封面）；
/// 2. 无变化时不得发请求；
/// 3. 名称清空必须被拦下。
///
/// `tags` / `intro` 相反：初值非空时清空要传空串（用户意图清空），
/// 初值为空时不传（避免误清服务端已有值）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late KugouApiClient client;
  late _PlaylistApiAdapter adapter;
  late List<String> toasts;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    client = KugouApiClient();
    adapter = _PlaylistApiAdapter();
    client.dio.httpClientAdapter = adapter;
    final generation = KugouApiClient.markServerStarting();
    KugouApiClient.markServerReady(generation);
    await client.setLoginCookies('token-abc', '10086');
    toasts = _installToastMock();
  });

  tearDown(() {
    uninstallFakeSecureStorage();
  });

  Playlist buildPlaylist({
    String name = '我的歌单',
    String? description,
    String id = 'gid_1',
    String? subscribedListId = '11',
  }) {
    return Playlist(
      id: id,
      name: name,
      description: description,
      songCount: 3,
      songs: const [],
      listCreateUserid: '10086',
      listCreateListid: '11',
      subscribedListId: subscribedListId,
      artworkUri: 'https://imge.kugou.com/stdmusic/240/a.jpg',
    );
  }

  Future<void> pumpPage(
    WidgetTester tester, {
    Playlist? playlist,
    int totalVer = 9,
    int type = 0,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PlaylistEditPage(
          playlist: playlist ?? buildPlaylist(),
          totalVer: totalVer,
          type: type,
        ),
      ),
    );
    await tester.pump();
  }

  /// ListView 懒构建：视口外的孩子存在但不可点。
  ///
  /// 不能只判断 `evaluate().isNotEmpty` 就跳过——短列表会把所有孩子都建出来、
  /// 包括落在视口下方的「保存」按钮，此时 tap() 打不中任何东西（静默 warnIfMissed）。
  /// 一律先 ensureVisible。
  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    if (finder.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        finder,
        200,
        scrollable: find.byType(Scrollable).first,
      );
    }
    await tester.ensureVisible(finder);
    await tester.pump();
  }

  Future<void> tapSave(WidgetTester tester) async {
    await scrollTo(tester, find.text('保存'));
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pump();
    // fluttertoast 内部有 1s Future.delayed，不排干会报 Timer is still pending
    await tester.pump(const Duration(seconds: 2));
  }

  testWidgets('页面按入参预填歌单名称', (tester) async {
    await pumpPage(tester);
    expect(_textFieldValue(tester, 0), '我的歌单');
    expect(find.text('编辑歌单'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('只改名称：只下发 name，不下发 pic（缺省=不改封面）', (tester) async {
    await pumpPage(tester);
    await tester.enterText(find.byType(TextField).first, '新名称');
    await tapSave(tester);

    expect(adapter.updateQueries, hasLength(1));
    final q = adapter.updateQueries.single;
    expect(q['listid'], '11');
    expect(q['total_ver'], 9);
    expect(q['type'], 0);
    expect(q['name'], '新名称');
    expect(q.containsKey('pic'), isFalse, reason: 'pic 缺省时不得下发');
    expect(toasts, contains('歌单已更新'));
  });

  testWidgets('收藏歌单（type=1）原样透传 type', (tester) async {
    await pumpPage(tester, type: 1);
    await tester.enterText(find.byType(TextField).first, '新名称');
    await tapSave(tester);

    expect(adapter.updateQueries.single['type'], 1);
  });

  testWidgets('隐私歌单保存时 is_pri 原样回传（不得改成公开）', (tester) async {
    await pumpPage(
      tester,
      playlist: buildPlaylist().copyWith(isPri: true),
    );
    await tester.enterText(find.byType(TextField).first, '新名称');
    await tapSave(tester);

    expect(adapter.updateQueries.single['is_pri'], 1);
  });

  testWidgets('total_ver 原样透传（乐观锁，改错必然被上游拒）', (tester) async {
    await pumpPage(tester, totalVer: 42);
    await tester.enterText(find.byType(TextField).first, '新名称');
    await tapSave(tester);

    expect(adapter.updateQueries.single['total_ver'], 42);
  });

  testWidgets('歌单没有变化时不发请求', (tester) async {
    await pumpPage(tester);
    await tapSave(tester);

    expect(adapter.updateQueries, isEmpty);
    expect(toasts, contains('歌单没有变化'));
  });

  testWidgets('名称清空后保存被拦截', (tester) async {
    await pumpPage(tester);
    await tester.enterText(find.byType(TextField).first, '   ');
    await tapSave(tester);

    expect(adapter.updateQueries, isEmpty);
    expect(toasts, contains('歌单名称不能为空'));
  });

  testWidgets('服务端业务失败时 toast msg 且不退出页面', (tester) async {
    adapter.updateResponse = const {'status': 0, 'error_code': 1, 'msg': '歌单名称含敏感词'};
    await pumpPage(tester);

    await tester.enterText(find.byType(TextField).first, '新名称');
    await tapSave(tester);

    expect(toasts, contains('歌单名称含敏感词'));
    expect(find.byType(PlaylistEditPage), findsOneWidget);
  });

  testWidgets('业务失败无 msg 时 toast 回退显示 error 字段', (tester) async {
    // 2026-10-14 真机排查：上游业务拒绝可能不带 msg（只带 error），
    // 旧逻辑会退化成无声的「保存失败，请稍后重试」。
    adapter.updateResponse = const {
      'status': 0,
      'error_code': 40001,
      'error': '版本已过期，请刷新后重试',
    };
    await pumpPage(tester);

    await tester.enterText(find.byType(TextField).first, '新名称');
    await tapSave(tester);

    expect(toasts, contains('版本已过期，请刷新后重试'));
    expect(toasts, isNot(contains('保存失败，请稍后重试')));
    expect(find.byType(PlaylistEditPage), findsOneWidget);
  });

  testWidgets('业务失败只剩 error_code 时 toast 显示错误码', (tester) async {
    adapter.updateResponse = const {'status': 0, 'error_code': 40001};
    await pumpPage(tester);

    await tester.enterText(find.byType(TextField).first, '新名称');
    await tapSave(tester);

    expect(toasts, contains('保存失败（错误码 40001）'));
    expect(find.byType(PlaylistEditPage), findsOneWidget);
  });

  testWidgets('listid 缺失时拦下并提示', (tester) async {
    await pumpPage(
      tester,
      playlist: buildPlaylist(id: '', subscribedListId: null)
          .copyWith(listCreateListid: ''),
    );
    await tester.enterText(find.byType(TextField).first, '新名称');
    await tapSave(tester);

    expect(adapter.updateQueries, isEmpty);
    expect(toasts, contains('歌单ID无效'));
  });

  testWidgets('成功保存后 pop(true) 通知调用方刷新', (tester) async {
    var popped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              final r = await Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) => PlaylistEditPage(
                    playlist: buildPlaylist(),
                    totalVer: 9,
                  ),
                ),
              );
              popped = r == true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '新名称');
    await tapSave(tester);
    await tester.pumpAndSettle();

    expect(popped, isTrue);
  });
}

/// 捕获 toast 文案。
///
/// 必须同时挂两个通道：`showToast` 在 **Windows 上走原生短暂提示**
/// （`md3music/desktop_message`，见 `app_toast.dart` 的 `_useNativeToast`），
/// 只有 Android/iOS/Web 才走 fluttertoast。只挂 fluttertoast 的话，
/// 在 Windows 主机上所有 toast 断言都会得到空列表（既有
/// `profile_edit_page_test.dart` 就是这么挂的，在本机整组失败）。
List<String> _installToastMock() {
  final toasts = <String>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  messenger.setMockMethodCallHandler(
    const MethodChannel('PonnamKarthik/fluttertoast'),
    (MethodCall call) async {
      if (call.method == 'showToast') {
        toasts.add(
          (call.arguments as Map<Object?, Object?>?)?['msg'] as String? ?? '',
        );
      }
      return null;
    },
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('md3music/desktop_message'),
    (MethodCall call) async {
      if (call.method == 'show') {
        toasts.add(
          (call.arguments as Map<Object?, Object?>?)?['message'] as String? ?? '',
        );
      }
      return null;
    },
  );

  addTearDown(() {
    messenger.setMockMethodCallHandler(
      const MethodChannel('PonnamKarthik/fluttertoast'),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('md3music/desktop_message'),
      null,
    );
  });
  return toasts;
}

String _textFieldValue(WidgetTester tester, int index) {
  final widget = tester.widget<TextField>(find.byType(TextField).at(index));
  return widget.controller?.text ?? '';
}

/// 假适配器：捕获 /playlist/update 的 **query** 参数（不是 body）。
class _PlaylistApiAdapter implements HttpClientAdapter {
  final List<Map<String, dynamic>> updateQueries = [];

  Map<String, dynamic> updateResponse = const {'status': 1, 'error_code': 0};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    if (path == '/playlist/update') {
      updateQueries.add(Map<String, dynamic>.from(options.queryParameters));
      return _json(updateResponse);
    }
    return _json(const {'status': 1, 'error_code': 0});
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
