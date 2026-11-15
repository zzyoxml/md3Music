import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/services/accompany/accompany_source.dart';

/// 伴奏来源枚举的解析与文案。
///
/// 解析必须对**损坏/未知值**稳妥回退到在线伴奏：老用户升级前 prefs 里没有这个键，
/// 或者手动改坏，都不能导致伴唱入口消失或行为突变。
void main() {
  group('AccompanySource', () {
    test('两个取值各自的稳定字符串', () {
      expect(AccompanySource.online.wireValue, 'online');
      expect(AccompanySource.onDevice.wireValue, 'on_device');
    });

    test('parse 认得自己的 wireValue', () {
      expect(AccompanySource.parse('online'), AccompanySource.online);
      expect(AccompanySource.parse('on_device'), AccompanySource.onDevice);
    });

    test('null / 未知值 / 空串都回退在线伴奏', () {
      expect(AccompanySource.parse(null), AccompanySource.online);
      expect(AccompanySource.parse(''), AccompanySource.online);
      expect(AccompanySource.parse('onDevice'), AccompanySource.online);
      expect(AccompanySource.parse('garbage'), AccompanySource.online);
    });

    test('每个取值都有非空标题与说明', () {
      for (final v in AccompanySource.values) {
        expect(v.label, isNotEmpty);
        expect(v.description, isNotEmpty);
      }
      // 标题必须互不相同，否则设置页两行一模一样
      expect(
        AccompanySource.values.map((v) => v.label).toSet().length,
        AccompanySource.values.length,
      );
    });

    test('默认来源是在线伴奏（老用户行为不变）', () {
      expect(AccompanySource.parse(null), AccompanySource.online);
    });
  });
}
