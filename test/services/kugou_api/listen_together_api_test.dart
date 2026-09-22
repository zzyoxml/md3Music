import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/services/kugou_api/listen_together_api.dart';

void main() {
  group('ensureSuccess', () {
    test('status==1 且 error_code==0 通过', () {
      final p = ensureSuccess({'status': 1, 'error_code': 0, 'data': <String, dynamic>{}});
      expect(p, isNotNull);
      expect(p!['status'], 1);
    });

    test('status 缺失时默认视为成功（仅看 error_code）', () {
      expect(ensureSuccess({'error_code': 0}), isNotNull);
    });

    test('status==0 或 error_code!=0 抛 ListenTogetherApiError', () {
      expect(
        () => ensureSuccess({'status': 0, 'error_code': 55006}),
        throwsA(isA<ListenTogetherApiError>()),
      );
      expect(
        () => ensureSuccess({'errcode': 20006, 'status': 1}),
        throwsA(isA<ListenTogetherApiError>()),
      );
      expect(
        () => ensureSuccess({'err_code': '51002'}),
        throwsA(isA<ListenTogetherApiError>()),
      );
    });

    test('错误码被正确带出，payload 保留原始响应', () {
      try {
        ensureSuccess({'status': 0, 'error_code': 55006, 'error_msg': '自定义'});
        fail('应当抛出');
      } on ListenTogetherApiError catch (e) {
        expect(e.code, 55006);
        expect(e.message, '自定义');
        expect(e.payload, isA<Map>());
      }
    });

    test('错误文案优先 error_msg，其次码表，最后通用兜底', () {
      expect(
        () => ensureSuccess({'status': 0, 'error_code': 55006, 'error_msg': '自定义'}),
        throwsA(predicate((e) => (e as ListenTogetherApiError).message == '自定义')),
      );
      expect(
        () => ensureSuccess({'status': 0, 'error_code': 51002}),
        throwsA(predicate(
            (e) => (e as ListenTogetherApiError).message == '请先登录后再使用一起听')),
      );
      expect(
        () => ensureSuccess({'status': 0, 'error_code': 99999}),
        throwsA(predicate(
            (e) => (e as ListenTogetherApiError).message == '一起听服务暂不可用（99999）')),
      );
    });

    test('非 Map 响应返回 null（不抛异常）', () {
      expect(ensureSuccess(null), isNull);
      expect(ensureSuccess('text'), isNull);
    });
  });

  group('listenTogetherErrorMessage 码表', () {
    test('覆盖已验证错误码', () {
      expect(listenTogetherErrorMessage(51002), '请先登录后再使用一起听');
      expect(listenTogetherErrorMessage(20003), '房间音乐配置不完整');
      expect(listenTogetherErrorMessage(20006), '账号当前已有未结束的众乐房会话');
      expect(listenTogetherErrorMessage(55004), '已达到房间创建上限，请先管理已有房间');
      expect(listenTogetherErrorMessage(55006), '房间不存在或已解散');
      expect(listenTogetherErrorMessage(0), '一起听服务暂不可用');
      expect(listenTogetherErrorMessage(12345), '一起听服务暂不可用（12345）');
    });
  });

  group('buildCacheBustingTimestamp', () {
    test('毫秒加三位序列号，同毫秒内多次生成不重复', () {
      expect(buildCacheBustingTimestamp(nowMs: 1000, seq: 1), '1000001');
      expect(buildCacheBustingTimestamp(nowMs: 1000, seq: 2), '1000002');
      expect(buildCacheBustingTimestamp(nowMs: 1000, seq: 999), '1000999');
    });

    test('序列号回绕到 0 时补零', () {
      expect(buildCacheBustingTimestamp(nowMs: 1000, seq: 0), '1000000');
    });

    test('连续调用生成的戳互不相同', () {
      final a = buildCacheBustingTimestamp();
      final b = buildCacheBustingTimestamp();
      expect(a, isNot(b));
    });
  });

  group('isDissolvedRoomError / isSessionConflictError', () {
    test('解散类错误码判定', () {
      expect(isDissolvedRoomError(const ListenTogetherApiError('x', 55006)), isTrue);
      expect(isDissolvedRoomError(const ListenTogetherApiError('x', 20005)), isTrue);
      // 20002 需 message 携带解散语义才判定（房间域「群组不存在」）
      expect(isDissolvedRoomError(const ListenTogetherApiError('群组不存在', 20002)), isTrue);
      expect(isDissolvedRoomError(const ListenTogetherApiError('房间已解散', 20002)), isTrue);
      expect(isDissolvedRoomError(const ListenTogetherApiError('其他错误', 20002)), isFalse);
      expect(isDissolvedRoomError(const ListenTogetherApiError('x', 51002)), isFalse);
      expect(isDissolvedRoomError(Exception('x')), isFalse);
    });

    test('20006 会话冲突判定', () {
      expect(isSessionConflictError(const ListenTogetherApiError('x', 20006)), isTrue);
      expect(isSessionConflictError(const ListenTogetherApiError('x', 55006)), isFalse);
      expect(isSessionConflictError(Exception('x')), isFalse);
    });
  });

  group('ListenTogetherApiError', () {
    test('toString 含错误码与文案', () {
      const e = ListenTogetherApiError('房间已解散', 55006);
      expect(e.toString(), contains('55006'));
      expect(e.toString(), contains('房间已解散'));
    });
  });
}
