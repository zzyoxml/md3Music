import 'package:material_ui/material_ui.dart';
import '../core/utils/app_toast.dart';
import '../services/kugou_api/comment_send_result.dart';
import '../services/kugou_api/kugou_api_client.dart';
import 'verify_captcha_dialog.dart';

/// 只处理验证，不重发评论；原文由输入框保留，用户决定是否再次发送。
Future<void> handleCommentFailure(BuildContext context,
    CommentSendResult result, {
    Future<String?> Function(BuildContext, {required String txappid}) showCaptcha =
        showVerifyCaptchaDialog,
  }) async {
  if (!result.needsVerification) {
    showToast(result.message, long: true);
    return;
  }
  FocusManager.instance.primaryFocus?.unfocus();
  final api = KugouApiClient();
  final info = await api.getVerifyInfo(result.verificationEventId!);
  if (!context.mounted) return;
  final data = info?['data'];
  if (info?['status'] != 1 || data is! Map) {
    showToast('安全验证加载失败，请稍后重试', long: true);
    return;
  }
  final vType = int.tryParse('${data['v_type']}');
  final txappid = data['txappid']?.toString() ?? '';
  final url = data['url']?.toString() ?? '';
  if (vType != 23 || !url.startsWith('KGCodeTX|') || txappid.isEmpty) {
    showToast('此验证方式暂不支持，请在酷狗官方客户端完成验证', long: true);
    return;
  }
  final code = await showCaptcha(context, txappid: txappid);
  if (!context.mounted) return;
  if (code == null) {
    showToast('已取消安全验证，评论内容已保留');
    return;
  }
  final response = await api.verifyUserInfo(
    eventid: result.verificationEventId!, vType: vType!, verifycode: code);
  if (!context.mounted) return;
  final error = response?['error_code'] ?? response?['err_code'];
  final ok = response?['status'] == 1 &&
      (error == null || error.toString() == '0');
  showToast(ok ? '验证通过，请再次点击发送' : '安全验证失败，评论内容已保留',
    long: true);
}
