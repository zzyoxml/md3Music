import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import '../test_helpers/fake_secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('凭证保存失败必须返回失败且保留原账号的内存登录状态', () async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    addTearDown(uninstallFakeSecureStorage);
    final api = KugouApiClient();
    await api.setLoginCookies('old-token', 'old-user');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => throw PlatformException(code: 'keystore-unavailable'),
        );
    await expectLater(
      api.setLoginCookies('new-token', 'new-user'),
      throwsStateError,
    );
    expect(api.userid, 'old-user');
    expect(api.isLoggedIn, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('kugou_current_userid'), 'old-user');
  });
}
