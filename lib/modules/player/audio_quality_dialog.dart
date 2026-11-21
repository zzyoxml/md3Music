import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';

import '../../providers/player_provider.dart' show AudioQuality;
import '../../widgets/m3e_vertical_squish_group.dart';

/// 播放页可切换的音质档位（两个播放器页共用的唯一来源）。
///
/// 与设置页「音质与输出」的五档不同：这里只列实际能一键切换的四档
/// （标准 / 高品质 / 无损 / Hi-Res），「蝰蛇母带」仍由设置页的实验开关控制。
const List<AudioQuality> kPlayerAudioQualities = <AudioQuality>[
  AudioQuality.standard,
  AudioQuality.high,
  AudioQuality.flac,
  AudioQuality.hires,
];

/// 音质简短文案：去掉码率 / 格式后缀，与设置页默认音质按钮一致。
String audioQualityShortLabel(AudioQuality quality) {
  switch (quality) {
    case AudioQuality.standard:
      return '标准';
    case AudioQuality.high:
      return '高品质';
    case AudioQuality.flac:
      return '无损';
    case AudioQuality.hires:
      return 'Hi-Res';
    case AudioQuality.viper:
      return '蝰蛇母带';
  }
}

/// 播放页音质选择弹窗：一列 [M3EVerticalSquishGroup]。
///
/// 控件与设置页「主题与配色 → 主题模式」是同一套 m3e_core 组件
/// （同一个 `M3EToggleButton` + 同样的邻居挤压），只是排成竖向——弹窗宽度只有
/// 约 280dp，五档横排必然放不下，纵排才是它本来的样子。
///
/// 与倍速弹窗同构：只收 [selected] / [onSelected] 两个纯值与回调，不收
/// `PlayerProvider`，两个播放器页共用这一份实现。
void showAudioQualityDialog({
  required BuildContext context,
  required List<AudioQuality> qualities,
  required AudioQuality selected,
  required ValueChanged<AudioQuality> onSelected,
}) {
  final int selectedIndex = qualities.indexOf(selected);
  showDialog<void>(
    context: context,
    builder: (dialogContext) {
      // 这里必须用 Dialog 而不是 AlertDialog：material_ui 的 AlertDialog 会把
      // content 塞进 IntrinsicWidth 去算固有宽度，而 M3EToggleButton 内部是
      // LayoutBuilder，一被问 intrinsic 就会 assert「LayoutBuilder does not
      // support returning intrinsic dimensions」。Dialog 只按约束布局，与倍速
      // 弹窗用的是同一个壳。
      return Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Padding(
            // 竖排按钮自带内边距，默认的 dialog padding 会显得过挤。
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '音质选择',
                  style: Theme.of(dialogContext).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                M3EVerticalSquishGroup(
                  // sm 默认 width=null → 按钮按文字内容自适应宽度，四个选项字长不同
                  // 导致奶白块宽度参差。这里用 fromBase 补上统一宽度（弹窗内容宽约
                  // 272dp，留少量边距），让四个选项等宽、文字居中。
                  size: M3EButtonSize.fromBase(M3EButtonSize.sm, width: 264),
                  actions: [
                    for (final quality in qualities)
                      M3EToggleButtonGroupAction(
                        label: Text(audioQualityShortLabel(quality)),
                      ),
                  ],
                  selectedIndex: selectedIndex < 0 ? null : selectedIndex,
                  semanticLabel: '音质选择',
                  onSelectedIndexChanged: (index) {
                    if (index == null || index < 0 || index >= qualities.length) {
                      return;
                    }
                    onSelected(qualities[index]);
                    Navigator.pop(dialogContext);
                  },
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
