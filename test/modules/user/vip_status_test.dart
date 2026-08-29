import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/user/vip_status.dart';

/// 构造一条 busi_vip 记录
Map<String, dynamic> _vipItem(String type, int isVip) => {
  'product_type': type,
  'is_vip': isVip,
  'vip_begin_time': '2026-08-01 00:00:00',
  'vip_end_time': '2026-08-30 00:00:00',
};

/// 时间 → "yyyy-MM-dd HH:mm:ss"（与接口返回格式一致）
String _fmt(DateTime t) {
  String pad(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${pad(t.month)}-${pad(t.day)} '
      '${pad(t.hour)}:${pad(t.minute)}:${pad(t.second)}';
}

void main() {
  group('findActiveBusiVip', () {
    test('null 列表返回 null', () {
      expect(findActiveBusiVip(null, 'tvip'), isNull);
    });

    test('空列表返回 null', () {
      expect(findActiveBusiVip(const [], 'tvip'), isNull);
    });

    test('tvip/svip 都开通时分别命中各自项', () {
      final tvip = _vipItem('tvip', 1);
      final svip = _vipItem('svip', 1);
      final list = [tvip, svip];
      expect(findActiveBusiVip(list, 'tvip'), same(tvip));
      expect(findActiveBusiVip(list, 'svip'), same(svip));
    });

    test('仅开通 tvip 时查 svip 返回 null', () {
      final list = [_vipItem('tvip', 1)];
      expect(findActiveBusiVip(list, 'svip'), isNull);
    });

    test('仅开通 svip 时查 tvip 返回 null', () {
      final list = [_vipItem('svip', 1)];
      expect(findActiveBusiVip(list, 'tvip'), isNull);
    });

    test('is_vip=0 视为未开通', () {
      final list = [_vipItem('tvip', 0), _vipItem('svip', 0)];
      expect(findActiveBusiVip(list, 'tvip'), isNull);
      expect(findActiveBusiVip(list, 'svip'), isNull);
    });

    test('未知 product_type 不命中', () {
      final list = [_vipItem('dvip', 1)];
      expect(findActiveBusiVip(list, 'tvip'), isNull);
      expect(findActiveBusiVip(list, 'svip'), isNull);
    });
  });

  group('formatVipExpireText', () {
    test('null / 空串 / 非法串返回 null', () {
      expect(formatVipExpireText(null), isNull);
      expect(formatVipExpireText(''), isNull);
      expect(formatVipExpireText('not-a-date'), isNull);
    });

    test('已过期返回"已过期"', () {
      final past = _fmt(DateTime.now().subtract(const Duration(days: 1)));
      expect(formatVipExpireText(past), '已过期');
    });

    // 注意：实现用带毫秒的 DateTime.now() 计算差值，构造"恰好整数"的边界会因
    // 毫秒截断而少 1 个单元，故各用例额外加小时/分钟/秒缓冲以稳定落在目标取整档。
    test('X 天后到期', () {
      final t = _fmt(DateTime.now().add(const Duration(days: 5, hours: 6)));
      expect(formatVipExpireText(t), '5天后到期');
    });

    test('X 个月后到期（>30 天按 30 天取整）', () {
      final t = _fmt(DateTime.now().add(const Duration(days: 40)));
      expect(formatVipExpireText(t), '1个月后到期');
    });

    test('X 年后到期（>365 天按 365 天取整）', () {
      final t = _fmt(DateTime.now().add(const Duration(days: 400)));
      expect(formatVipExpireText(t), '1年后到期');
    });

    test('X 小时后到期', () {
      final t = _fmt(DateTime.now().add(const Duration(hours: 3, minutes: 10)));
      expect(formatVipExpireText(t), '3小时后到期');
    });

    test('X 分钟后到期', () {
      final t = _fmt(DateTime.now().add(const Duration(minutes: 30, seconds: 20)));
      expect(formatVipExpireText(t), '30分钟后到期');
    });

    test('不足 1 分钟返回"即将到期"', () {
      final t = _fmt(DateTime.now().add(const Duration(seconds: 30)));
      expect(formatVipExpireText(t), '即将到期');
    });
  });

  group('formatVipDateTime', () {
    test('DateTime 对象格式化为 yyyy-MM-dd HH:mm', () {
      final d = DateTime(2026, 8, 15, 10, 30);
      expect(formatVipDateTime(d), '2026-08-15 10:30');
    });

    test('日期字符串（空格分隔）解析', () {
      expect(formatVipDateTime('2026-08-15 10:30:00'), '2026-08-15 10:30');
    });

    test('null / 空串返回 --', () {
      expect(formatVipDateTime(null), '--');
      expect(formatVipDateTime(''), '--');
    });

    test('非法输入原样返回', () {
      expect(formatVipDateTime('非法'), '非法');
    });
  });
}
