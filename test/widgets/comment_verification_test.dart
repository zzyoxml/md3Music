import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/services/kugou_api/kugou_endpoints.dart';
import 'package:md3music/services/kugou_api/comment_send_result.dart';
import 'package:md3music/widgets/comment_verification.dart';
import '../test_helpers/fake_secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final requests = <RequestOptions>[];
  final messages = <String>[];
  late HttpClientAdapter original;
  late String originalUrl;
  int type = 23;
  bool verifyOk = true;
  const channel = MethodChannel('PonnamKarthik/fluttertoast');
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    KugouApiClient.markServerReady();
    final api = KugouApiClient();
    await api.clearCookies();
    original = api.dio.httpClientAdapter;
    originalUrl = KugouEndpoints.baseUrl;
    api.updateBaseUrl('http://comment-verification.invalid');
    requests.clear(); messages.clear(); type = 23; verifyOk = true;
    api.dio.httpClientAdapter = _Adapter((options) {
      requests.add(options);
      if (options.path == KugouEndpoints.getVerifyInfo) {
        return {'status': 1, 'data': {'v_type': type,
          'txappid': '12345', 'url': type == 23 ? 'KGCodeTX|test' : 'KGCodeGT|test'}};
      }
      expect(options.path, KugouEndpoints.verifyUserInfo);
      return {'status': verifyOk ? 1 : 0, 'error_code': verifyOk ? 0 : 60045};
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
        messages.add((call.arguments as Map)['msg'] as String);
        return true;
      });
  });
  tearDown(() {
    KugouApiClient().dio.httpClientAdapter = original;
    KugouApiClient().updateBaseUrl(originalUrl);
    uninstallFakeSecureStorage();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null);
  });
  final challenge = CommentSendResult.fromJson({'status': 0, 'err_code': 60045,
    'data': {'event_id': 'gz_tx_event_test'}});
  for (final scenario in ['通过', '取消', '不支持', '验证失败']) {
    testWidgets('评论安全验证$scenario，不自动重发评论', (tester) async {
      late BuildContext context;
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (ctx) {
        context = ctx; return const SizedBox();
      })));
      type = scenario == '不支持' ? 24 : 23;
      verifyOk = scenario != '验证失败';
      int dialogs = 0;
      await tester.runAsync(() => handleCommentFailure(context, challenge,
        showCaptcha: (ctx, {required txappid}) async {
          dialogs++;
          expect(txappid, '12345');
          return scenario == '取消' ? null : 'KGCodeTX|test-ticket';
        }));
      await tester.pump();
      expect(dialogs, scenario == '不支持' ? 0 : 1);
      expect(requests.length, scenario == '取消' || scenario == '不支持' ? 1 : 2);
      expect(requests.first.queryParameters['eventid'], 'gz_tx_event_test');
      if (requests.length == 2) {
        expect(requests.last.queryParameters['v_type'], 23);
        expect(requests.last.queryParameters['verifycode'], 'KGCodeTX|test-ticket');
      }
      expect(messages.last, contains(switch (scenario) {
        '通过' => '再次点击发送', '取消' => '已取消',
        '不支持' => '暂不支持', _ => '验证失败',
      }));
    });
  }
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final Map<String, dynamic> Function(RequestOptions) respond;
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream,
      Future<void>? cancel) async => ResponseBody.fromString(
    jsonEncode(respond(options)), 200,
    headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});
  @override
  void close({bool force = false}) {}
}
