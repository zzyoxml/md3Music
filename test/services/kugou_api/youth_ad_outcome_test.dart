import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';

/// KugouApiClient.parseAdClaimOutcome 广告领取响应判定逻辑测试。
///
/// 说明：项目未引入 mockito / http_mock_adapter，且 `_post` 为私有方法，
/// 因此测试聚焦于抽出的静态判定函数（与 mergeLyricResponses 同一模式）。
void main() {
  group('KugouApiClient.parseAdClaimOutcome', () {
    test('status=1 → success（领取成功，可继续下一轮）', () {
      expect(
        KugouApiClient.parseAdClaimOutcome({'status': 1}),
        AdClaimOutcome.success,
      );
    });

    test('error_code=30002 → quotaDone（今日次数已用光，正常停止）', () {
      expect(
        KugouApiClient.parseAdClaimOutcome({'status': 0, 'error_code': 30002}),
        AdClaimOutcome.quotaDone,
      );
    });

    test('其他错误码（如 20018 登录过期）→ failure', () {
      expect(
        KugouApiClient.parseAdClaimOutcome({'status': 0, 'error_code': 20018}),
        AdClaimOutcome.failure,
      );
    });

    test('null 响应 → failure', () {
      expect(KugouApiClient.parseAdClaimOutcome(null), AdClaimOutcome.failure);
    });
  });
}
