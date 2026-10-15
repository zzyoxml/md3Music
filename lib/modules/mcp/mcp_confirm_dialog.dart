import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'mcp_confirmation.dart';
import 'mcp_service.dart';

/// 挂在 MaterialApp.builder 下的确认弹窗宿主。
///
/// 走 Stack 覆盖而不是 showDialog：MCP 确认与应用导航解耦，
/// 任何页面上都能弹出，且 pending 归零（超时/拒绝/批准）时自动消失。
class McpConfirmationDialogHost extends StatelessWidget {
  const McpConfirmationDialogHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // McpService.confirmations 恒非空（requireConfirm=false 时只是不把它
    // 注入注册表），弹窗是否出现完全由 broker.pending 驱动。
    final broker = context.watch<McpService>().confirmations;
    return ValueListenableBuilder<McpConfirmationRequest?>(
      valueListenable: broker.pending,
      builder: (context, request, _) {
        if (request == null) return child;
        return Stack(
          children: <Widget>[
            child,
            const ModalBarrier(dismissible: false),
            Center(
              child: Material(
                type: MaterialType.transparency,
                child: AlertDialog(
                  title: Text('AI 请求执行「${request.tool}」'),
                  content: Text(
                    request.summary.isEmpty
                        ? '外部 AI 客户端请求执行该写操作，是否允许？'
                        : request.summary,
                  ),
                  actions: <Widget>[
                    TextButton(
                      onPressed: () => broker.resolve(request.id, false),
                      child: const Text('拒绝'),
                    ),
                    FilledButton(
                      onPressed: () => broker.resolve(request.id, true),
                      child: const Text('允许'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
