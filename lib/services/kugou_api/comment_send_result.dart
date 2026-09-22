/// 评论写接口（`/comment/*/send`）的发送结果。
///
/// 上游约定（与 `/user/grade/info` 同口径）：`status == 1 && error_code == 0` 才算成功。
/// Rust 服务端对入参错误返回 HTTP 400、对上游失败返回 HTTP 502，但 body 始终是 JSON，
/// 因此这里只解析 body 字段，不看 HTTP 状态码。
class CommentSendResult {
  /// 是否成功提交。
  final bool ok;

  /// 上游业务错误码；成功时为 null。
  final int? errorCode;

  /// 面向用户的失败原因；成功时为空串。
  final String message;

  const CommentSendResult({required this.ok, this.errorCode, this.message = ''});

  static const CommentSendResult success = CommentSendResult(ok: true);

  factory CommentSendResult.failure(String message, {int? errorCode}) =>
      CommentSendResult(ok: false, errorCode: errorCode, message: message);

  /// 解析服务端响应体（null 表示请求未拿到任何响应体）。
  static CommentSendResult fromJson(Map<String, dynamic>? json) {
    if (json == null) return CommentSendResult.failure('网络异常，请稍后重试');

    final status = _asInt(json['status']);
    final errorCode = _asInt(json['error_code']);
    if (status == 1 && (errorCode == null || errorCode == 0)) {
      return CommentSendResult.success;
    }

    final msg = _messageOf(json['msg'] ?? json['error_msg'] ?? json['message']);
    if (msg.isNotEmpty) {
      return CommentSendResult.failure(msg, errorCode: errorCode);
    }
    // transport 失败时 msg 是空对象且无错误码
    if (errorCode == null || errorCode == 0) {
      return CommentSendResult.failure('请求未送达或上游无响应，请稍后重试');
    }
    return CommentSendResult.failure('发布失败（错误码 $errorCode）', errorCode: errorCode);
  }

  static int? _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  static String _messageOf(Object? v) {
    if (v is String) return v.trim();
    return '';
  }
}

/// 丢弃 null 与空白字符串的参数，避免把空值当参数发给服务端
/// （服务端对空 content 会直接返回 400）。
Map<String, dynamic> compactQueryParams(Map<String, dynamic> raw) {
  final out = <String, dynamic>{};
  raw.forEach((k, v) {
    if (v == null) return;
    if (v is String && v.trim().isEmpty) return;
    out[k] = v;
  });
  return out;
}
