import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/build_flags.dart';
import '../core/remote/remote_slider.dart';
import '../modules/player/player_volume_state.dart';
import '../providers/player_provider.dart';
import 'player_volume_bar.dart' show PlayerVolumeUnityNotice;

/// 「播放与输出」面板里的音量行：**m3e_core 的 M3ESlider** + 三态判据。
///
/// 三态（应用音量 / USB 独占 / unity 锁定）与横屏常驻音量条、长按音质徽章的
/// 弹窗同源（[PlayerVolumeState]），只是控件换成 M3E 的标准滑杆 —— 面板是常规
/// 高度的卡片，不像横屏控制条那样缺纵向空间，用标准控件比自绘细轨道更顺手。
///
/// 交互口径与弹窗一致：拖动中只下发不落盘（`persist: false`），松手才写盘；
/// unity 档整行换成说明 + 一键关闭，避免"滑了没反应"。
class PlayerVolumeSlider extends StatefulWidget {
  const PlayerVolumeSlider({super.key});

  @override
  State<PlayerVolumeSlider> createState() => _PlayerVolumeSliderState();
}

class _PlayerVolumeSliderState extends State<PlayerVolumeSlider> {
  /// 拖动中的本地值（null = 跟随真实状态）。拖动期间的外部回写不打断手感。
  double? _dragValue;

  /// 最近一次「非零」音量：静音后再点恢复到这里。
  double _lastAudible = 1.0;

  Future<void> _toggleMute(
    PlayerProvider player,
    PlayerVolumeState state,
  ) async {
    if (!state.interactive) return;
    // 以本地显示值为准：拖动中途点静音也能得到预期结果
    final double current = _dragValue ?? state.value;
    final double target = current > 0 ? 0 : _lastAudible;
    setState(() => _dragValue = null);
    await state.apply(player, target, persist: true);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextTheme tt = Theme.of(context).textTheme;
    return ListenableBuilder(
      // 音量 / 独占开关都是低频变化；订阅 provider 即可，另两路（协调器、USB
      // 状态流）在面板这个短生命周期里作用有限，不为它们多加订阅。
      listenable: context.read<PlayerProvider>(),
      builder: (context, _) {
        final PlayerProvider player = context.read<PlayerProvider>();
        final PlayerVolumeState state = PlayerVolumeState.of(player);
        final double value = _dragValue ?? state.value;
        if (state.value > 0) _lastAudible = state.value;
        final bool muted = value <= 0;
        final int percent = (value * 100).round();
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text(
                  '音量',
                  style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                ),
                if (state.source == PlayerVolumeSource.usbExclusive) ...[
                  const SizedBox(width: 8),
                  Text(
                    state.chipLabel,
                    style: tt.labelSmall?.copyWith(color: cs.primary),
                  ),
                ],
                const Spacer(),
                Text(
                  '$percent%',
                  style: tt.labelMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
                const SizedBox(width: 2),
                // 静音/恢复：M3ESlider 本身没有静音位，用一枚裸图标补上
                // （命中框 36，够大拇指；与右侧百分数同一条基线）。
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: state.interactive
                      ? () => _toggleMute(player, state)
                      : null,
                  child: SizedBox(
                    width: 36,
                    height: 36,
                    child: Icon(
                      muted ? Icons.volume_off : Icons.volume_up,
                      size: 20,
                      color: state.interactive
                          ? cs.onSurfaceVariant
                          : cs.onSurfaceVariant.withValues(alpha: 0.38),
                    ),
                  ),
                ),
              ],
            ),
            if (state.interactive)
              // tv: TV 构建换 RemoteSlider——M3ESlider 自带 Focus 会吞四方向键。
              // 与长按音质徽章的弹窗同一门控，功能性参数不变。
              kTvBuild
                  ? RemoteSlider(
                      value: value,
                      onChanged: (double v) {
                        setState(() => _dragValue = v);
                        state.apply(player, v, persist: false);
                      },
                      onChangeEnd: (double v) {
                        setState(() => _dragValue = null);
                        state.apply(player, v, persist: true);
                      },
                    )
                  : M3ESlider(
                      value: value,
                      // 不传 divisions = 无级调节（无节点）；连续触觉按 10ms 最小
                      // 间隔震动太密，显式改成离散配置（与音量弹窗一致）。
                      decoration: const M3ESliderDecoration(
                        haptic: M3EHapticFeedback.medium,
                        hapticConfig: M3EHapticConfig.discrete(),
                      ),
                      onChanged: (double v) {
                        setState(() => _dragValue = v);
                        state.apply(player, v, persist: false);
                      },
                      onChangeEnd: (double v) {
                        setState(() => _dragValue = null);
                        state.apply(player, v, persist: true);
                      },
                    )
            else
              const PlayerVolumeUnityNotice(dense: true),
          ],
        );
      },
    );
  }
}
