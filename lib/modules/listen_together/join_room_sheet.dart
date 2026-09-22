import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:m3e_core/m3e_core.dart';

import '../../core/utils/app_toast.dart';

/// 从粘贴文本中提取房间号：支持纯数字与分享文案（取文本中最长的 4-20 位
/// 数字串）。对齐 EchoMusic 分享链接入房的移动端替代实现。
String? extractRoomNumber(String raw) {
  final matches = RegExp(r'\d{4,20}').allMatches(raw);
  if (matches.isEmpty) return null;
  Match best = matches.first;
  for (final m in matches) {
    if (m.group(0)!.length > best.group(0)!.length) best = m;
  }
  return best.group(0);
}

/// 房间号加入托盘。
///
/// 返回输入的房间号字符串（调用方负责校验与跳转）；取消时返回 null。
/// 视觉与创建房间托盘同款：标题 + 输入框 + 错误文案，键盘弹起时避让。
class JoinRoomSheet extends StatefulWidget {
  const JoinRoomSheet({super.key});

  @override
  State<JoinRoomSheet> createState() => _JoinRoomSheetState();
}

class _JoinRoomSheetState extends State<JoinRoomSheet> {
  final _idCtrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _idCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final id = _idCtrl.text.trim();
    if (id.isEmpty) {
      setState(() => _error = '请输入房间号');
      return;
    }
    Navigator.of(context).pop(id);
  }

  /// 读取剪贴板并提取房间号：命中填入输入框，未命中轻提示。
  Future<void> _pasteFromClipboard() async {
    final text = await Clipboard.getData('text/plain');
    final roomNumber = extractRoomNumber(text?.text ?? '');
    if (roomNumber == null) {
      showToast('剪贴板中没有房间号');
      return;
    }
    _idCtrl.text = roomNumber;
    setState(() => _error = null);
    showToast('已识别房间号 $roomNumber');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // 结构与创建房间托盘一致（Column min 收缩高度）：不能包 Center，
    // 否则 isScrollControlled 全高约束下 Center 会撑满导致托盘变全屏
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Text(
                '加入房间',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: TextField(
                controller: _idCtrl,
                autofocus: true,
                keyboardType: TextInputType.number,
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: '房间号',
                  hintText: '向房主索取房间号',
                  border: const OutlineInputBorder(),
                  // 粘贴分享文案自动提取房间号
                  suffixIcon: IconButton(
                    tooltip: '粘贴房间号',
                    onPressed: _pasteFromClipboard,
                    icon: const Icon(Icons.content_paste),
                  ),
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: Text(
                  _error!,
                  style: TextStyle(color: cs.error, fontSize: 12),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: SizedBox(
                width: double.infinity,
                child: M3EFilledButton(
                  onPressed: _submit,
                  child: const Text('加入'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
