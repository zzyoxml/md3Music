import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';

/// 后台登录态检查的三态判定：只有「确定已过期」才返回 true，
/// 无网络/未知一律 null，避免误弹「登录已过期」弹窗。
void main() {
  group('KugouApiClient.classifyTokenExpiry', () {
    test('无网络（json=null）→ null，不弹窗', () {
      expect(KugouApiClient.classifyTokenExpiry(null), isNull);
    });

    test('error_code 20017 → true（明确过期）', () {
      expect(
        KugouApiClient.classifyTokenExpiry({'error_code': 20017}),
        isTrue,
      );
      expect(
        KugouApiClient.classifyTokenExpiry({'error_code': '20017'}),
        isTrue,
      );
    });

    test('error_code 20018 → true（明确过期）', () {
      expect(
        KugouApiClient.classifyTokenExpiry({'error_code': 20018}),
        isTrue,
      );
    });

    test('status=2 → true（明确过期）', () {
      expect(KugouApiClient.classifyTokenExpiry({'status': 2}), isTrue);
      expect(KugouApiClient.classifyTokenExpiry({'status': '2'}), isTrue);
    });

    test('正常有效响应 → false', () {
      expect(
        KugouApiClient.classifyTokenExpiry({
          'status': 1,
          'error_code': 0,
          'data': {'userid': 123},
        }),
        isFalse,
      );
    });

    test('其他业务错误码（如 20028 验证码）→ null，不误弹', () {
      expect(
        KugouApiClient.classifyTokenExpiry({'error_code': 20028}),
        isNull,
      );
    });

    test('业务成功但 data 为空/异常 → null，不误弹', () {
      expect(
        KugouApiClient.classifyTokenExpiry({'status': 1, 'data': {}}),
        isNull,
      );
      expect(KugouApiClient.classifyTokenExpiry({'status': 1}), isNull);
    });
  });
}
