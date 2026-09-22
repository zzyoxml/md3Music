import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:flutter/services.dart';

/// 评论输入框（歌曲 / 歌单 / 专辑评论页共用）。
///
/// 设计约束：
/// - **发送在途时禁用输入与按钮**：评论发布成功即产生真实公开内容，
///   连点会造成重复评论；
/// - 只有 [onSubmit] 返回 true（服务端确认成功）才清空输入框，
///   失败保留原文供用户手动重试；
/// - 回复模式下顶部显示「回复 @用户名」提示条，可取消。
class CommentComposer extends StatefulWidget {
  /// 发送中（由父级控制，避免父级刷新与在途请求竞争）。
  final bool sending;

  /// 非空表示处于回复模式，值为被回复用户名。
  final String? replyToName;

  /// 取消回复模式。
  final VoidCallback? onCancelReply;

  /// AM 风格（深色背景 + 白字），与 `CommentsView.isAmStyle` 保持一致。
  final bool isAmStyle;

  /// 提交回调：返回 true 表示发送成功。
  final Future<bool> Function(String text) onSubmit;

  /// 展开后是否自动聚焦（折叠模式下展开即表示要打字）。
  final bool autofocus;

  /// 是否避让软键盘。
  ///
  /// **弹层内的输入框必须为 true**：`DraggableScrollableSheet` 不会自动随键盘上移，
  /// 否则输入框会被输入法遮挡。
  final bool avoidKeyboard;

  /// 是否绘制顶部分隔线。默认 true（列表与输入框之间的分界）；
  /// 仅含输入框的托盘里应传 false——把手和输入框之间会显出一条突兀的灰白线。
  final bool showTopBorder;

  const CommentComposer({
    super.key,
    required this.onSubmit,
    this.sending = false,
    this.replyToName,
    this.onCancelReply,
    this.isAmStyle = false,
    this.autofocus = false,
    this.avoidKeyboard = false,
    this.showTopBorder = true,
  });

  @override
  State<CommentComposer> createState() => _CommentComposerState();
}

class _CommentComposerState extends State<CommentComposer> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      !widget.sending && _controller.text.trim().isNotEmpty;

  Future<void> _submit() async {
    if (!_canSubmit) return;
    final text = _controller.text.trim();
    final ok = await widget.onSubmit(text);
    if (!mounted) return;
    if (ok) {
      _controller.clear();
      _focusNode.unfocus();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final Color textColor =
        widget.isAmStyle ? Colors.white : colorScheme.onSurface;
    final Color hintColor = widget.isAmStyle
        ? const Color(0x8AFFFFFF)
        : colorScheme.onSurfaceVariant;
    final Color borderColor = widget.isAmStyle
        ? const Color(0x33FFFFFF)
        : colorScheme.outlineVariant;

    return Container(
      decoration: BoxDecoration(
        border: widget.showTopBorder
            ? Border(top: BorderSide(color: borderColor))
            : null,
        color: widget.isAmStyle ? const Color(0x1A000000) : null,
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: SafeArea(
        top: false,
        // 键盘弹出时把输入框顶到键盘之上：用 minimum 取「安全区 padding」与
        // 「键盘 viewInsets」的较大值（SafeArea 内部即 max），避免两段高度叠加。
        minimum: widget.avoidKeyboard
            ? EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom)
            : EdgeInsets.zero,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.replyToName != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '回复 @${widget.replyToName}',
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(color: hintColor),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    InkWell(
                      onTap: widget.onCancelReply,
                      child: Icon(Icons.close, size: 16, color: hintColor),
                    ),
                  ],
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    enabled: !widget.sending,
                    autofocus: widget.autofocus,
                    maxLines: 4,
                    minLines: 1,
                    maxLength: 500,
                    buildCounter: (_, {required currentLength, required isFocused, maxLength}) =>
                        null,
                    textInputAction: TextInputAction.newline,
                    onChanged: (_) => setState(() {}),
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: textColor),
                    decoration: InputDecoration(
                      hintText: '说点什么…',
                      hintStyle: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(color: hintColor),
                      isDense: true,
                      border: InputBorder.none,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                M3EFilledButton(
                  key: const ValueKey('comment_composer_send'),
                  onPressed: _canSubmit
                      ? () {
                          HapticFeedback.selectionClick();
                          _submit();
                        }
                      : null,
                  size: M3EButtonSize.sm,
                  semanticLabel: '发送',
                  child: widget.sending
                      ? M3ELoadingIndicator(
                          constraints: BoxConstraints.tightFor(width: 16, height: 16),
                          color: colorScheme.onPrimary,
                        )
                      : const Icon(Icons.send, size: 18),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
