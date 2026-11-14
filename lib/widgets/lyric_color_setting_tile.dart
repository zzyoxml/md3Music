import 'package:dpad/dpad.dart';
import 'package:material_ui/material_ui.dart';

import '../core/build_flags.dart';
import 'seed_color_picker.dart';

/// 两种播放页复用选择器，但各自传入独立的偏好值和保存回调。
class LyricColorSettingTile extends StatelessWidget {
  const LyricColorSettingTile({
    super.key,
    required this.color,
    required this.onChanged,
  });

  final Color? color;
  final Future<void> Function(Color?) onChanged;

  @override
  Widget build(BuildContext context) {
    Future<void> choose() async {
      final picked = await showCustomColorPicker(
        context,
        initial: color ?? Theme.of(context).colorScheme.primary,
        title: '自定义歌词颜色',
      );
      if (picked != null) await onChanged(picked);
    }

    final tile = ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.palette_outlined),
      title: const Text('自定义歌词颜色'),
      subtitle: Text(color == null ? '跟随默认歌词配色' : '已启用 · 点击修改颜色'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (color != null) ...[
            CircleAvatar(backgroundColor: color, radius: 12),
            if (!kTvBuild)
              IconButton(
                tooltip: '恢复默认歌词配色',
                icon: const Icon(Icons.restart_alt),
                onPressed: () => onChanged(null),
              ),
          ] else
            const Icon(Icons.chevron_right, size: 18),
        ],
      ),
      onTap: choose,
    );
    return kTvBuild
        ? DpadFocusable(
            onSelect: choose,
            onLongSelect: color == null ? null : () => onChanged(null),
            child: tile,
          )
        : tile;
  }
}
