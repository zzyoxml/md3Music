import 'dart:async';
import 'dart:convert';
import 'package:material_ui/material_ui.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../core/theme/app_dimens.dart';

/// 签到与评论共用已有腾讯验证码页面，返回凭证；取消或超时返回 null。
Future<String?> showVerifyCaptchaDialog(BuildContext context,
    {required String txappid}) async {
  BuildContext? dialogContext;
  bool completed = false;
  bool initialized = false;
  Timer? timeout;
  void finish(String? code) {
    final ctx = dialogContext;
    if (completed || ctx == null || !ctx.mounted ||
        ModalRoute.of(ctx)?.isCurrent != true) {
      return;
    }
    completed = true;
    Navigator.of(ctx).pop(code);
  }
  final controller = WebViewController();
  void initialize() {
    if (initialized || completed) return;
    initialized = true;
    controller.runJavaScript(
      'window.initCaptcha && initCaptcha(${jsonEncode(txappid)})');
  }
  controller
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..addJavaScriptChannel('CaptchaChannel', onMessageReceived: (message) {
      final data = message.message;
      if (data == '__READY__') {
        initialize();
      } else if (data == '__CANCEL__' || data == '__ERROR__') {
        finish(null);
      } else {
        finish(data);
      }
    })
    ..setNavigationDelegate(NavigationDelegate(
      onPageFinished: (_) => initialize(),
      onWebResourceError: (error) {
        if (error.isForMainFrame == true) finish(null);
      },
    ))
    ..loadFlutterAsset('assets/web/verify_captcha.html');
  try {
    return await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        dialogContext = ctx;
        timeout ??= Timer(const Duration(minutes: 3), () => finish(null));
        return Dialog(
          clipBehavior: Clip.antiAlias,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md, vertical: AppSpacing.xs),
              child: Row(children: [
                Expanded(child: Text('安全验证',
                  style: Theme.of(ctx).textTheme.titleMedium)),
                IconButton(icon: const Icon(Icons.close), tooltip: '取消验证',
                  onPressed: () => finish(null)),
              ]),
            ),
            const Divider(height: 1),
            SizedBox(width: 360, height: 400,
              child: WebViewWidget(controller: controller)),
          ]),
        );
      },
    );
  } finally {
    completed = true;
    timeout?.cancel();
  }
}
