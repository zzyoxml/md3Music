import 'dart:convert';

/// 已保存的酷狗账号摘要（用于账号管理列表展示）。
///
/// 凭证本体（token / vip_token）存于按 userid 隔离的 SharedPreferences 键中，
/// 此处仅保存展示用信息 + 最近登录时间（用于排序，最近登录靠前）。
class KugouAccount {
  final String userid;

  /// 昵称/头像可变：登录或刷新用户信息后回填。
  String? nickname;
  String? avatar;

  /// 最近登录时间（epoch 秒）。
  final int loginTime;

  /// 该账号的登录态是否已过期（切换时校验 token 发现失效）。
  /// 过期账号在账号管理列表显示「登录已过期」，重新登录成功后被清除。
  final bool expired;

  KugouAccount({
    required this.userid,
    this.nickname,
    this.avatar,
    required this.loginTime,
    this.expired = false,
  });

  factory KugouAccount.fromJson(Map<String, dynamic> json) {
    return KugouAccount(
      userid: json['userid']?.toString() ?? '',
      nickname: json['nickname']?.toString(),
      avatar: json['avatar']?.toString(),
      loginTime: json['loginTime'] is int ? json['loginTime'] as int : 0,
      expired: json['expired'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
        'userid': userid,
        'nickname': nickname,
        'avatar': avatar,
        'loginTime': loginTime,
        'expired': expired,
      };

  KugouAccount copyWith({
    String? nickname,
    String? avatar,
    int? loginTime,
    bool? expired,
  }) {
    return KugouAccount(
      userid: userid,
      nickname: nickname ?? this.nickname,
      avatar: avatar ?? this.avatar,
      loginTime: loginTime ?? this.loginTime,
      expired: expired ?? this.expired,
    );
  }

  /// 序列化整个账号列表。
  static String encodeList(List<KugouAccount> accounts) =>
      jsonEncode(accounts.map((a) => a.toJson()).toList());

  /// 反序列化账号列表；解析失败返回空列表（容错）。
  static List<KugouAccount> decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(KugouAccount.fromJson)
          .where((a) => a.userid.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }
}
