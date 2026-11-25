import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers/fake_secure_storage.dart';

/// 返回固定 JSON 的假 adapter（避免真实网络/15s 超时）。
class _JsonAdapter implements HttpClientAdapter {
  _JsonAdapter(this.body);

  final Map<String, dynamic> body;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: const {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 第三方（微信 / QQ）扫码登录的 Provider 层契约测试。
///
/// 覆盖：
///  - [KugouProvider.completeThirdPartyLogin] 的凭证落盘与多账号隔离；
///  - create/check 的响应解析（用假 adapter 喂上游真实结构的 JSON）；
///  - 缺字段时的失败文案。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late KugouProvider provider;
  late _JsonAdapter adapter;
  late HttpClientAdapter original;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    final client = KugouApiClient();
    final generation = KugouApiClient.markServerStarting();
    KugouApiClient.markServerReady(generation);
    await client.clearCookies();
    original = client.dio.httpClientAdapter;
    adapter = _JsonAdapter(const {'status': 0});
    client.dio.httpClientAdapter = adapter;
    provider = KugouProvider(registerDeviceOnStart: false);
  });

  tearDown(() {
    KugouApiClient().dio.httpClientAdapter = original;
    provider.dispose();
    uninstallFakeSecureStorage();
  });

  group('completeThirdPartyLogin', () {
    test('写入凭证后 isLoggedIn 为 true 且 userid 已切换', () async {
      final ok = await provider.completeThirdPartyLogin(
        token: 'wx-token-1',
        userid: '9001',
        vipToken: 'vip-token-1',
      );

      expect(ok, isTrue);
      expect(provider.isLoggedIn, isTrue);
      expect(provider.userid, '9001');
      expect(KugouApiClient().userid, '9001');
    });

    test('同一账号重复登录不会在账号列表里产生重复条目', () async {
      await provider.completeThirdPartyLogin(token: 't1', userid: '9002');
      await provider.completeThirdPartyLogin(token: 't2', userid: '9002');

      final accounts = provider.savedAccounts.where((a) => a.userid == '9002');
      expect(accounts, hasLength(1));
    });

    test('登录第二个账号后两个账号都在列表里（多账号隔离，不互相清除）', () async {
      await provider.completeThirdPartyLogin(token: 't-a', userid: '9003');
      await provider.completeThirdPartyLogin(token: 't-b', userid: '9004');

      final ids = provider.savedAccounts.map((a) => a.userid).toSet();
      expect(ids.containsAll({'9003', '9004'}), isTrue);
      expect(provider.userid, '9004');
    });

    test('空 token / 空 userid 直接失败且不改变登录态', () async {
      expect(
        await provider.completeThirdPartyLogin(token: '', userid: '9005'),
        isFalse,
      );
      expect(
        await provider.completeThirdPartyLogin(token: 'tok', userid: ''),
        isFalse,
      );
      expect(provider.isLoggedIn, isFalse);
      expect(provider.error, isNotNull);
    });
  });

  group('createWxLoginQr', () {
    test('上游正常返回 uuid + 图片 → 解析成功', () async {
      adapter = _JsonAdapter(const {
        'errcode': 0,
        'uuid': 'wx-uuid-abc',
        'appname': '酷狗概念版',
        'qrcode': {'qrcodebase64': '/9j/4AAQ', 'qrcodeurl': 'https://x/confirm'},
      });
      KugouApiClient().dio.httpClientAdapter = adapter;

      final session = await provider.createWxLoginQr();
      expect(session, isNotNull);
      expect(session!.uuid, 'wx-uuid-abc');
      expect(session.imageBase64, '/9j/4AAQ');
    });

    test('缺 uuid → 返回 null 并写 error（不能拿空会话轮询）', () async {
      adapter = _JsonAdapter(const {'errcode': 0});
      KugouApiClient().dio.httpClientAdapter = adapter;

      expect(await provider.createWxLoginQr(), isNull);
      expect(provider.error, '生成微信二维码失败');
    });
  });

  group('createQqLoginQr', () {
    Map<String, dynamic> validSession() => const {
      'qrcode': 'BASE64JPEG',
      'qrsig': 'QRSIG',
      'ptqrtoken': 1700567251,
      'pt_login_sig': 'SIG',
      'pt_openlogin_data': 'pt_enable_pwd%3D1',
      'xlogin_url': 'https://xui.ptlogin2.qq.com/cgi-bin/xlogin?appid=1',
      'cookie': 'pt_login_sig=SIG; qrsig=QRSIG',
    };

    test('完整会话 → 解析成功', () async {
      adapter = _JsonAdapter(validSession());
      KugouApiClient().dio.httpClientAdapter = adapter;

      final session = await provider.createQqLoginQr();
      expect(session, isNotNull);
      expect(session!.qrsig, 'QRSIG');
      expect(session.ptqrtoken, 1700567251);
    });

    test('会话字段缺失 → null，且 error 带上上游 msg', () async {
      adapter = _JsonAdapter(const {
        'status': 0,
        'msg': '未获取到 qrsig',
      });
      KugouApiClient().dio.httpClientAdapter = adapter;

      expect(await provider.createQqLoginQr(), isNull);
      expect(provider.error, contains('未获取到 qrsig'));
    });
  });

  group('checkQqLogin 状态映射', () {
    const session = KugouQqQrSession(
      imageBase64: 'x',
      qrsig: 'Q',
      ptqrtoken: 1,
      ptLoginSig: 'S',
      ptOpenloginData: 'O',
      xloginUrl: 'U',
      cookie: 'c',
    );

    test('wait / scanned / expired / blocked 各自映射到对应状态', () async {
      for (final entry in {
        'wait': QqScanKind.waiting,
        'scanned': QqScanKind.scanned,
        'expired': QqScanKind.expired,
        'blocked': QqScanKind.blocked,
      }.entries) {
        adapter = _JsonAdapter({'status': entry.key, 'msg': 'm-${entry.key}'});
        KugouApiClient().dio.httpClientAdapter = adapter;

        final result = await provider.checkQqLogin(session);
        expect(result.kind, entry.value, reason: 'status=${entry.key}');
        expect(result.message, 'm-${entry.key}');
        expect(result.isSuccess, isFalse);
      }
    });

    test('status:1 + data.token → success 且带出凭证', () async {
      adapter = _JsonAdapter(const {
        'status': 1,
        'data': {'token': 'qq-tok', 'userid': 8001, 'vip_token': 'vip-x'},
      });
      KugouApiClient().dio.httpClientAdapter = adapter;

      final result = await provider.checkQqLogin(session);
      expect(result.kind, QqScanKind.success);
      expect(result.token, 'qq-tok');
      expect(result.userid, '8001');
      expect(result.vipToken, 'vip-x');
      expect(result.isSuccess, isTrue);
      expect(result.isTerminal, isTrue);
    });

    test('status:1 但缺 data.token → error（不能当成功放行）', () async {
      adapter = _JsonAdapter(const {
        'status': 1,
        'data': {'userid': 8001},
      });
      KugouApiClient().dio.httpClientAdapter = adapter;

      final result = await provider.checkQqLogin(session);
      expect(result.kind, QqScanKind.error);
      expect(result.isSuccess, isFalse);
    });
  });

  group('checkWxLogin 状态映射', () {
    test('408/404/403/402 各自映射', () async {
      for (final entry in {
        408: WxScanKind.waiting,
        404: WxScanKind.scanned,
        403: WxScanKind.rejected,
        402: WxScanKind.expired,
      }.entries) {
        adapter = _JsonAdapter({'wx_errcode': entry.key});
        KugouApiClient().dio.httpClientAdapter = adapter;

        final result = await provider.checkWxLogin('uuid-1');
        expect(result.kind, entry.value, reason: 'wx_errcode=${entry.key}');
      }
    });

    test('wx_errcode 为字符串时也能识别（上游时而字符串）', () async {
      adapter = _JsonAdapter(const {'wx_errcode': '404'});
      KugouApiClient().dio.httpClientAdapter = adapter;

      final result = await provider.checkWxLogin('uuid-1');
      expect(result.kind, WxScanKind.scanned);
    });

    test('空 uuid → error 且不发请求', () async {
      final before = adapter.calls;
      final result = await provider.checkWxLogin('');
      expect(result.kind, WxScanKind.error);
      expect(adapter.calls, before, reason: '空 uuid 不应发起网络请求');
    });
  });
}
