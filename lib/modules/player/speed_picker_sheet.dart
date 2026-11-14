import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';

import '../../core/build_flags.dart';
import '../../core/remote/remote_slider.dart';

/// 播放速度档位（播放器与弹窗共用的唯一来源）。
///
/// 9 档固定刻度：滑块用 `divisions` 对齐成离散档，拖到哪一档就取哪一档。
const List<double> kPlaybackSpeeds = <double>[
  0.25,
  0.5,
  0.75,
  1.0,
  1.25,
  1.5,
  2.0,
  3.0,
  4.0,
];

/// 倍速文案：去掉多余的 `.0`（`1.0` → `1`），其余原样。
///
/// 弹窗中间那个大数字和更多菜单里的 `2x` 都用它——此前同一档位在弹窗里写
/// `1.0x`、在菜单里写 `1.0x`、在被删掉的节点行里写 `1x`，三处三个样。
String formatPlaybackSpeed(double speed) {
  if (speed == speed.roundToDouble()) return speed.toStringAsFixed(0);
  return speed.toString();
}

/// 播放速度弹窗：一根离散滑块 + 居中档位数字。
///
/// 滑块下方**不再逐档标注倍数**：9 个标签挤在 320dp 里，`0.25x` 与 `4x` 会被
/// 挤成省略号反而读不出，且档位位置本来就由滑块的 8 个分隔点表达。档位值
/// 由中间的大数字给出，拖动时实时更新。
///
/// 参数刻意只收 [currentSpeed] / [onSelected] 两个纯值与回调，不收
/// `PlayerProvider`：
/// - `full_player.dart` 与 `full_player_am.dart` 里原本各抄了一份逐字符相同的
///   `_showSpeedDialog`，抽出来只剩这一处；
/// - 单测不必起 `PlayerProvider`（那要连 audio_service 与 SharedPreferences）。
void showSpeedPickerDialog({
  required BuildContext context,
  required double currentSpeed,
  required ValueChanged<double> onSelected,
}) {
  int index = kPlaybackSpeeds.indexOf(currentSpeed);
  // 兜底 1.0：Provider 侧已把速度 clamp 到 [0.25, 4.0]，正常不会落到这里，
  // 但持久化被外部改坏时不能崩，也不能显示成一档空白。
  if (index < 0) index = kPlaybackSpeeds.indexOf(1.0);

  showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setState) {
          return Dialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(28),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 20,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '播放速度',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    // 居中大字：只有数字，不带 x
                    Text(
                      formatPlaybackSpeed(kPlaybackSpeeds[index]),
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    const SizedBox(height: 16),
                    // tv: TV 构建换 RemoteSlider——M3ESlider 自带 Focus 吞
                    // 四方向键，D-pad 落上去无法移出（P-C）
                    kTvBuild
                        ? RemoteSlider(
                            value: index.toDouble(),
                            min: 0,
                            max: (kPlaybackSpeeds.length - 1).toDouble(),
                            divisions: kPlaybackSpeeds.length - 1,
                            label: formatPlaybackSpeed(kPlaybackSpeeds[index]),
                            onChanged: (value) {
                              setState(() => index = value.round());
                              onSelected(kPlaybackSpeeds[index]);
                            },
                          )
                        : M3ESlider(
                            value: index.toDouble(),
                            min: 0,
                            max: (kPlaybackSpeeds.length - 1).toDouble(),
                            divisions: kPlaybackSpeeds.length - 1,
                            // 拖动气泡：与居中大字同一套写法
                            label: formatPlaybackSpeed(kPlaybackSpeeds[index]),
                            onChanged: (value) {
                              setState(() => index = value.round());
                              onSelected(kPlaybackSpeeds[index]);
                            },
                          ),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('关闭'),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    },
  );
}
