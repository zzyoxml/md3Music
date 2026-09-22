import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';

/// MV 弹幕发送输入条。
///
/// 提交后由调用方负责清空输入并收起键盘；本 widget 不持有业务状态。
class MvDanmakuInputBar extends StatefulWidget {
  final ValueChanged<String> onSubmit;

  /// 弹幕关闭时禁用输入并给出提示。
  final bool enabled;

  /// 远端发送在途中：置 true 时禁用输入框与发送按钮，**用于防连点**。
  /// 仅反映发送状态，不影响已上屏的本地弹幕。
  final bool sending;

  /// 弹幕关闭时点击「开启弹幕」的回调。
  ///
  /// 官方 App 的 MV 弹幕**默认关闭**，因此关闭态必须给出可点击的开启入口；
  /// 只把输入框置灰会让用户找不到开启方式。
  final VoidCallback? onEnable;

  const MvDanmakuInputBar({
    super.key,
    required this.onSubmit,
    this.enabled = true,
    this.sending = false,
    this.onEnable,
  });

  @override
  State<MvDanmakuInputBar> createState() => _MvDanmakuInputBarState();
}

class _MvDanmakuInputBarState extends State<MvDanmakuInputBar> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (widget.sending) return;
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    widget.onSubmit(text);
    _controller.clear();
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    // 关闭态：给出可点击的开启入口，而不是只把输入框置灰。
    if (!widget.enabled && !widget.sending) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: widget.onEnable,
            icon: const Icon(Icons.subtitles_off_outlined, size: 18),
            label: const Text('弹幕已关闭，点击开启'),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              enabled: !widget.sending,
              maxLength: 50,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                isDense: true,
                counterText: '',
                hintText: widget.sending ? '发送中…' : '发条弹幕…',
                border: const OutlineInputBorder(),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
          ),
          const SizedBox(width: 8),
          M3EFilledButton(
            onPressed: widget.sending ? null : _submit,
            tooltip: '发送弹幕',
            // 纯图标按钮：去掉内部水平内边距 + 固定正方形尺寸，
            // 配合 M3EButtonShape.round（默认，圆角 = 高度/2）得到正圆。
            decoration: const M3EButtonDecoration(
              padding: EdgeInsets.zero,
              fixedSize: Size.square(40),
              haptic: M3EHapticFeedback.light,
            ),
            child: const Icon(Icons.send, size: 20),
          ),
        ],
      ),
    );
  }
}
