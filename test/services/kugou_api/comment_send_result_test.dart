import 'package:flutter_test/flutter_test.dart';

import '../../../lib/services/kugou_api/comment_send_result.dart';

/// 评论发送结果解析：只看 body 字段，不看 HTTP 状态码
/// （Rust 服务端把入参错误映射为 400、上游失败映射为 502，body 始终是 JSON）。
void main() {
  test('真实评论风控 60045 提取嵌套事件并保留失败状态', () {
    final result = CommentSendResult.fromJson({
      'res_status': 0, 'status': 0, 'err_code': 60045,
      'msg': '验证失败',
      'data': {'event_id': 'gz_tx_event_test', 'level': 1},
    });
    expect(result.ok, isFalse);
    expect(result.errorCode, 60045);
    expect(result.needsVerification, isTrue);
    expect(result.verificationEventId, 'gz_tx_event_test');
  });

  test('20028 兼容通用 SSA 验证事件', () {
    final result = CommentSendResult.fromJson({
      'status': 0, 'error_code': '20028', 'ssaCode': 'gz_tx_event_test',
    });
    expect(result.needsVerification, isTrue);
  });

  test('没有事件不能拉起验证，非风控错误不能误判', () {
    expect(CommentSendResult.fromJson({
      'status': 0, 'err_code': 60045,
    }).needsVerification, isFalse);
    expect(CommentSendResult.fromJson({
      'status': 0, 'err_code': 30012,
      'data': {'event_id': 'gz_tx_event_test'},
    }).needsVerification, isFalse);
    expect(CommentSendResult.fromJson({
      'status': 1, 'err_code': 60045,
      'data': {'event_id': 'gz_tx_event_test'},
    }).ok, isFalse);
  });

  test('status=1 且 error_code 缺失或为 0 → 成功', () {
    expect(CommentSendResult.fromJson({'status': 1}).ok, isTrue);
    expect(CommentSendResult.fromJson({'status': 1, 'error_code': 0}).ok, isTrue);
  });

  test('入参错误（HTTP 400 包装）→ 透传 msg', () {
    final r = CommentSendResult.fromJson({
      'status': 0,
      'error_code': 400,
      'msg': 'content 不能为空',
    });
    expect(r.ok, isFalse);
    expect(r.message, 'content 不能为空');
    expect(r.errorCode, 400);
  });

  test('上游业务错误 → 透传 msg 与错误码', () {
    final r = CommentSendResult.fromJson({
      'status': 0,
      'error_code': 30012,
      'msg': '评论内容包含敏感词',
    });
    expect(r.ok, isFalse);
    expect(r.errorCode, 30012);
    expect(r.message, '评论内容包含敏感词');
  });

  test('msg 为对象（transport_error）→ 走"未送达"文案', () {
    final r = CommentSendResult.fromJson({'status': 0, 'msg': <String, dynamic>{}});
    expect(r.ok, isFalse);
    expect(r.message, '请求未送达或上游无响应，请稍后重试');
  });

  test('有错误码但无文案 → 带错误码的兜底文案', () {
    final r = CommentSendResult.fromJson({'status': 0, 'error_code': 30001});
    expect(r.ok, isFalse);
    expect(r.errorCode, 30001);
    expect(r.message, '发布失败（错误码 30001）');
  });

  test('null / 完全无字段 → 兜底失败，不抛异常', () {
    expect(CommentSendResult.fromJson(null).ok, isFalse);
    expect(CommentSendResult.fromJson(null).message, '网络异常，请稍后重试');
    expect(CommentSendResult.fromJson(<String, dynamic>{}).ok, isFalse);
  });

  test('错误码为字符串数字也能解析', () {
    final r = CommentSendResult.fromJson({'status': '0', 'error_code': '30012', 'msg': 'x'});
    expect(r.ok, isFalse);
    expect(r.errorCode, 30012);
  });

  test('compactQueryParams 丢弃 null 与空白串', () {
    final out = compactQueryParams({
      'content': '  ',
      'mixsongid': null,
      'special_id': '100285259',
      'tid': '',
      'is_t': 1,
    });
    expect(out.keys.toSet(), {'special_id', 'is_t'});
  });
}
