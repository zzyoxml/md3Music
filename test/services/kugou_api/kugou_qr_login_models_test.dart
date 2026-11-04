import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';

/// 微信 / QQ 扫码登录的会话模型与状态机测试。
///
/// 契约来源：`kugou_api_server/rust/src/modules/login.rs` 的
/// `handle_wx_create` / `handle_qq_qr_create` / `handle_qq_qr_check`，
/// 以及上游 KuGouMusicApi `module/login_wx_*.js` / `login_qq_qr_*.js`。
void main() {
  group('KugouWxQrSession.fromJson', () {
    test('解析上游根级响应（uuid + qrcode.qrcodebase64）', () {
      final s = KugouWxQrSession.fromJson({
        'errcode': 0,
        'uuid': '021sLGrS2acr1w3h',
        'appname': '酷狗概念版',
        'qrcode': {
          'qrcodebase64': '/9j/4AAQSkZJRg==',
          'qrcodeurl': 'https://open.weixin.qq.com/connect/confirm?uuid=021s',
        },
      });
      expect(s, isNotNull);
      expect(s!.uuid, '021sLGrS2acr1w3h');
      expect(s.imageBase64, '/9j/4AAQSkZJRg==');
      expect(s.imageUrl, 'https://open.weixin.qq.com/connect/confirm?uuid=021s');
      expect(s.hasImage, isTrue);
    });

    test('缺 uuid 返回 null（不能拿空会话去轮询）', () {
      expect(KugouWxQrSession.fromJson({'errcode': 0}), isNull);
      expect(KugouWxQrSession.fromJson({'uuid': ''}), isNull);
      expect(KugouWxQrSession.fromJson(null), isNull);
    });

    test('只有 qrcodeurl 没有 base64 时 hasImage 仍为 true', () {
      final s = KugouWxQrSession.fromJson({
        'uuid': 'u1',
        'qrcode': {'qrcodeurl': 'https://open.weixin.qq.com/connect/confirm?uuid=u1'},
      });
      expect(s!.hasImage, isTrue);
      expect(s.imageBase64, isNull);
    });

    test('无任何图片字段时 hasImage 为 false', () {
      final s = KugouWxQrSession.fromJson({'uuid': 'u1'});
      expect(s!.hasImage, isFalse);
    });
  });

  group('KugouQqQrSession.fromJson', () {
    Map<String, dynamic> validJson() => {
      'qrcode': 'BASE64JPEG',
      'qrsig': 'QRSIG',
      'ptqrtoken': 1700567251,
      'pt_login_sig': 'SIG',
      'pt_openlogin_data': 'pt_enable_pwd%3D1',
      'xlogin_url': 'https://xui.ptlogin2.qq.com/cgi-bin/xlogin?appid=716027609',
      'cookie': 'pt_login_sig=SIG; qrsig=QRSIG',
    };

    test('完整会话解析成功（根级扁平结构）', () {
      final s = KugouQqQrSession.fromJson(validJson());
      expect(s, isNotNull);
      expect(s!.qrsig, 'QRSIG');
      expect(s.ptqrtoken, 1700567251);
      expect(s.ptLoginSig, 'SIG');
      expect(s.ptOpenloginData, 'pt_enable_pwd%3D1');
      expect(s.imageBase64, 'BASE64JPEG');
    });

    test('ptqrtoken 是字符串时也能解析（上游时而字符串时而数字）', () {
      final json = validJson()..['ptqrtoken'] = '1700567251';
      final s = KugouQqQrSession.fromJson(json);
      expect(s!.ptqrtoken, 1700567251);
    });

    test('任一必需字段缺失即返回 null', () {
      for (final key in [
        'qrcode',
        'qrsig',
        'ptqrtoken',
        'pt_login_sig',
        'pt_openlogin_data',
        'xlogin_url',
        'cookie',
      ]) {
        final json = validJson()..remove(key);
        expect(
          KugouQqQrSession.fromJson(json),
          isNull,
          reason: '缺少 $key 时必须拒绝该会话',
        );
      }
      expect(KugouQqQrSession.fromJson(null), isNull);
    });

    test('toQuery 只含 6 个会话字段，不含二维码图片', () {
      final s = KugouQqQrSession.fromJson(validJson())!;
      final q = s.toQuery();
      expect(q.keys.toSet(), {
        'qrsig',
        'ptqrtoken',
        'pt_login_sig',
        'pt_openlogin_data',
        'xlogin_url',
        'cookie',
      });
      expect(q.containsKey('qrcode'), isFalse);
      // pt_openlogin_data 原样下发（Rust 侧不再二次编码）
      expect(q['pt_openlogin_data'], 'pt_enable_pwd%3D1');
      expect(q['ptqrtoken'], 1700567251);
    });
  });

  group('WxScanResult / QqScanResult 状态机', () {
    test('WxScanResult 终态判定', () {
      expect(
        const WxScanResult(WxScanKind.waiting).isTerminal,
        isFalse,
      );
      expect(const WxScanResult(WxScanKind.scanned).isTerminal, isFalse);
      for (final kind in [
        WxScanKind.success,
        WxScanKind.expired,
        WxScanKind.rejected,
        WxScanKind.error,
      ]) {
        expect(WxScanResult(kind).isTerminal, isTrue, reason: '$kind 应终止轮询');
      }
      expect(
        const WxScanResult(
          WxScanKind.success,
          token: 't',
          userid: '1',
        ).isSuccess,
        isTrue,
      );
    });

    test('QqScanResult 终态判定（blocked 也算终态，不重试）', () {
      expect(const QqScanResult(QqScanKind.waiting).isTerminal, isFalse);
      expect(const QqScanResult(QqScanKind.scanned).isTerminal, isFalse);
      for (final kind in [
        QqScanKind.success,
        QqScanKind.expired,
        QqScanKind.blocked,
        QqScanKind.error,
      ]) {
        expect(QqScanResult(kind).isTerminal, isTrue, reason: '$kind 应终止轮询');
      }
      expect(
        const QqScanResult(QqScanKind.blocked).isSuccess,
        isFalse,
        reason: 'blocked 不是登录成功',
      );
    });
  });
}
