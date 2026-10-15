/// 会员状态展示辅助函数（移植自 EchoMusic Profile.vue 的会员状态查询展示）。
///
/// 酷狗 `/user/vip/detail` 响应结构：`data.busi_vip[]` 为各业务线会员，
/// 每项含 `product_type`（'tvip'=畅听 / 'svip'=概念）、`is_vip`（0/1）、
/// `vip_begin_time`、`vip_end_time`。
library;

/// 从 busi_vip 列表中找到指定 `productType` 且已开通（`is_vip == 1`）的会员项。
///
/// 同一业务线可能同时存在**多条**已开通记录——例如每日签到领取的 1 天畅听会员
/// 与购买的长期畅听会员会在 `busi_vip` 里各占一条。此时必须取 `vip_end_time`
/// **最晚**的一条：它才是该业务线当前生效的最终权益。旧实现取数组第一个匹配项，
/// 会把签到领的短期会员当成最终状态展示（真机案例：账号购买的畅听VIP 有效期至
/// 2027-09-22，用户中心却显示「23小时后到期」）。
///
/// 找不到返回 null；所有匹配项的 `vip_end_time` 均无法解析时，退回第一个匹配项。
Map<String, dynamic>? findActiveBusiVip(
  List<Map<String, dynamic>>? list,
  String productType,
) {
  if (list == null) return null;
  Map<String, dynamic>? best;
  DateTime? bestEnd;
  for (final b in list) {
    if (b['is_vip'] != 1) continue;
    if (b['product_type']?.toString() != productType) continue;
    final end = _parseVipEndTime(b['vip_end_time']);
    if (best == null) {
      // 首个匹配项先占位（其 vip_end_time 可能缺失或无法解析）
      best = b;
      bestEnd = end;
    } else if (end != null && (bestEnd == null || end.isAfter(bestEnd))) {
      best = b;
      bestEnd = end;
    }
  }
  return best;
}

/// 解析 `vip_end_time`（形如 "2027-09-22 00:00:00"）；空值或解析失败返回 null。
DateTime? _parseVipEndTime(Object? value) {
  if (value == null) return null;
  final s = value.toString();
  if (s.isEmpty) return null;
  return DateTime.tryParse(s.replaceFirst(' ', 'T'));
}

/// 相对到期时间文案（移植自 EchoMusic Profile.vue 的 `getVipExpireText`）。
/// `endTime` 形如 `"2026-08-16 10:30:00"`；无值或解析失败返回 null。
String? formatVipExpireText(String? endTime) {
  if (endTime == null || endTime.isEmpty) return null;
  final expireDate = DateTime.tryParse(endTime.replaceFirst(' ', 'T'));
  if (expireDate == null) return null;
  final diff = expireDate.difference(DateTime.now());
  if (diff.isNegative) return '已过期';
  final totalMinutes = diff.inMinutes;
  final totalHours = diff.inHours;
  final days = diff.inDays;
  if (days > 365) return '${days ~/ 365}年后到期';
  if (days > 30) return '${days ~/ 30}个月后到期';
  if (days > 0) return '$days天后到期';
  if (totalHours > 0) return '$totalHours小时后到期';
  if (totalMinutes > 0) return '$totalMinutes分钟后到期';
  return '即将到期';
}

/// 精确时间格式化 `yyyy-MM-dd HH:mm`（移植自 EchoMusic `formatVipDate`）。
/// 空值返回 `'--'`；非法输入原样返回字符串。
String formatVipDateTime(Object? value) {
  if (value == null) return '--';
  final s = value.toString();
  if (s.isEmpty) return '--';
  final d = DateTime.tryParse(s.replaceFirst(' ', 'T'));
  if (d == null) return s;
  String pad(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${pad(d.month)}-${pad(d.day)} ${pad(d.hour)}:${pad(d.minute)}';
}
