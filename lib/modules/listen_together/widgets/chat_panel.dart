import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../../core/utils/app_toast.dart';
import '../../../providers/listen_together_provider.dart';

/// 房间聊天托盘：历史消息（含系统消息）+ 文本发送。
class ChatPanel extends StatefulWidget {
  const ChatPanel({super.key});

  @override
  State<ChatPanel> createState() => _ChatPanelState();
}

/// 消息时间标签（HH:mm，上游 timestampMs 已归一为毫秒）。
String _formatMessageTime(int timestampMs) {
  final t = DateTime.fromMillisecondsSinceEpoch(timestampMs);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}';
}

class _ChatPanelState extends State<ChatPanel> {
  final _ctrl = TextEditingController();
  // 消息列表独立滚动控制器：不挂托盘的 scrollController。reverse 列表挂在
  // DraggableScrollableSheet 的 controller 上时，滚动越界手势会把托盘整体
  // 顶起/压下，手感怪异——解耦后列表只滚内容，托盘拖拽只认头部区域。
  final _listCtrl = ScrollController();
  final _scrollCtrl = ScrollController();
  bool _sending = false;
  String? _error;

  /// 发送冷却（对齐 EchoMusic CHAT_SEND_COOLDOWN_MS=1500），防刷屏限流。
  bool _cooldown = false;
  Timer? _cooldownTimer;

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _ctrl.dispose();
    _scrollCtrl.dispose();
    _listCtrl.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _sending || _cooldown) return;
    final session = context.read<ListenTogetherProvider>().session;
    // 聊天被房主关闭时不再提交（成员端输入框已禁用，此处兜底）
    if (session == null || (!session.isOwner && !session.allowChat)) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await session.sendMessage(text);
      if (mounted) _ctrl.clear();
      // 发送成功后进入 1.5s 冷却
      if (mounted) setState(() => _cooldown = true);
      _cooldownTimer?.cancel();
      _cooldownTimer = Timer(const Duration(milliseconds: 1500), () {
        if (mounted) setState(() => _cooldown = false);
      });
    } catch (_) {
      if (mounted) setState(() => _error = '发送失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final session = context.watch<ListenTogetherProvider>().session;
    final messages = session?.messages ?? const [];
    final isOwner = session?.isOwner ?? false;
    // 房主不受开关限制（关闭聊天只约束成员）；成员按 allowChat 放行
    final canChat = isOwner || (session?.allowChat ?? true);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      minChildSize: 0.4,
      builder: (context, scrollController) => Center(
        // 横屏/平板下限宽居中，避免弹层被拉满整个屏幕宽度
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
        children: [
          // 头部（拖拽把手 + 标题行）是唯一驱动托盘缩放的区域：挂托盘的
          // scrollController，拖这里可收起/展开托盘；消息列表独立滚动。
          SingleChildScrollView(
            controller: scrollController,
            child: Column(
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: cs.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '房间聊天',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                      ),
                      // 房主开关聊天（update_chat）：成员端输入框随 allowChat 禁用
                      if (isOwner)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              (session?.allowChat ?? true) ? '聊天已开启' : '聊天已关闭',
                              style: TextStyle(
                                fontSize: 12,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Switch(
                              value: session?.allowChat ?? true,
                              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              onChanged: (v) async {
                                try {
                                  await session?.ownerSetChatEnabled(v);
                                } catch (_) {
                                  showToast('设置失败，请稍后重试');
                                }
                              },
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: messages.isEmpty
                ? ListView(
                    controller: _listCtrl,
                    children: const [
                      SizedBox(height: 80),
                      Center(child: Text('还没有消息，说点什么吧')),
                    ],
                  )
                : ListView.builder(
                    controller: _listCtrl,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    // reverse：index 0 = 最新消息，列表天然锚定底部——
                    // 打开托盘即显示最新消息，新消息到达无需手动滚动
                    reverse: true,
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final message = messages[messages.length - 1 - index];
                      // 系统消息（房主操作、进出房）以居中胶囊呈现
                      if (message.isSystem) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: cs.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                message.text,
                                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                              ),
                            ),
                          ),
                        );
                      }
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Expanded(
                              child: Text.rich(
                                TextSpan(
                                  children: [
                                    TextSpan(
                                      text: '${message.nickname}：',
                                      style: TextStyle(
                                        color: cs.primary,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    TextSpan(text: message.text),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _formatMessageTime(message.timestampMs),
                              style: TextStyle(
                                fontSize: 10,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                _error!,
                style: TextStyle(color: cs.error, fontSize: 12),
              ),
            ),
          Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _ctrl,
                        enabled: canChat,
                        decoration: InputDecoration(
                          hintText: canChat ? '发消息…' : '房主已关闭聊天',
                          isDense: true,
                          border: const OutlineInputBorder(),
                        ),
                        onSubmitted: canChat ? (_) => _send() : null,
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      onPressed:
                          (_sending || _cooldown || !canChat) ? null : _send,
                      icon: const Icon(Icons.send),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
          ),
        ),
      ),
    );
  }
}
