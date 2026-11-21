import 'dart:async';

import 'package:flutter/foundation.dart';

/// 一次待裁决的写操作请求。
class McpConfirmationRequest {
  const McpConfirmationRequest({
    required this.id,
    required this.tool,
    required this.summary,
    required this.requestedAt,
  });

  final String id;
  final String tool;
  final String summary;
  final DateTime requestedAt;
}

/// 写操作二次确认中枢。
///
/// AI 触发 `requiresConfirmation` 工具时挂起等待：App 内弹窗
/// （mcp_confirm_dialog.dart 监听 [pending]）调用 [resolve] 完成裁决；
/// 超时视为拒绝——无人值守场景不能无限挂起 HTTP 请求。
class McpConfirmationBroker {
  final ValueNotifier<McpConfirmationRequest?> pending =
      ValueNotifier<McpConfirmationRequest?>(null);

  Completer<bool>? _active;
  Timer? _timeout;
  int _seq = 0;

  static const Duration defaultTimeout = Duration(seconds: 30);

  /// 发起确认。同一时刻只允许一个挂起请求，并发请求直接返回 false。
  Future<bool> confirm(
    String tool,
    String summary, {
    Duration timeout = defaultTimeout,
  }) {
    if (_active != null) return Future<bool>.value(false);
    final completer = Completer<bool>();
    final id = 'mcp-confirm-${++_seq}';
    _active = completer;
    pending.value = McpConfirmationRequest(
      id: id,
      tool: tool,
      summary: summary,
      requestedAt: DateTime.now(),
    );
    _timeout = Timer(timeout, () => resolve(id, false));
    return completer.future;
  }

  /// App 内弹窗的裁决入口。
  void resolve(String id, bool approved) {
    final req = pending.value;
    if (req == null || req.id != id) return;
    _timeout?.cancel();
    _timeout = null;
    pending.value = null;
    _active?.complete(approved);
    _active = null;
  }

  void dispose() {
    _timeout?.cancel();
    if (!(_active?.isCompleted ?? true)) _active!.complete(false);
    pending.dispose();
  }
}
