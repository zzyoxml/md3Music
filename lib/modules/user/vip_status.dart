/// 会员状态展示辅助函数（移植自 EchoMusic Profile.vue 的会员状态查询展示）。
///
/// 酷狗 `/user/vip/detail` 响应结构：`data.busi_vip[]` 为各业务线会员，
/// 每项含 `product_type`（'tvip'=畅听 / 'svip'=概念）、`is_vip`（0/1）、
/// `vip_begin_time`、`vip_end_time`。
library;

/// 从 busi_vip 列表中找到指定 `productType` 且已开通（`is_vip == 1`）的会员项。
/// 对应 EchoMusic `busi_vip.find(v => v.product_type===X && v.is_vip===1)`；
/// 找不到返回 null。
Map<String, dynamic>? findActiveBusiVip(
  List<Map<String, dynamic>>? list,
  String productType,
) {
  if (list == null) return null;
  for (final b in list) {
    if (b['is_vip'] == 1 && b['product_type']?.toString() == productType) {
      return b;
    }
  }
  return null;
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
