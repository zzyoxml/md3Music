import 'package:material_ui/material_ui.dart';

import '../core/theme/app_dimens.dart';
import '../providers/player_provider.dart';
import 'player_seek_bar.dart';

/// 时间行提示的显示模型：只看「缓冲中」「音频过渡中」「伴唱加载中」「伴唱中」四条。
///
/// 纯逻辑收在这里（同 `PlaybackStatusFeedbackState` 的做法），判定矩阵可以不碰
/// Provider / 音频服务直接单测。
class PlaybackHintState {
  const PlaybackHintState._({
    required this.buffering,
    required this.fading,
    required this.accompanying,
    required this.accompanyLoading,
  });

  factory PlaybackHintState.resolve({
    required bool streamBuffering,
    required bool hasError,
    required bool crossfading,
    bool accompanying = false,
    bool accompanyLoading = false,
  }) {
    return PlaybackHintState._(
      // 只看「音频数据到没到位」，刻意不看 isPlaying：拖动进度条后播放器是被
      // `pauseForSeek()` 主动暂停的，而平台仍在为落点重新缓冲，用播放态门控会把
      // 整段缓冲吞掉（表现为「不显示 / 只闪一下」）。播完与停止由
      // `PlayerProvider.isStreamBuffering` 从处理态上排除。
      buffering: streamBuffering && !hasError,
      fading: crossfading,
      // 加载阶段与「伴唱中」互斥：同一时刻只显示一条伴唱相关提示，
      // 否则会出现「伴唱加载中 + 伴唱中」并列的矛盾文案。
      accompanyLoading: accompanyLoading,
      accompanying: accompanying && !accompanyLoading,
    );
  }

  /// 音频流正在准备数据（解析地址 / 装载 / 缓冲）。
  final bool buffering;

  /// 交叉淡化（「音频过渡」）进行中。
  final bool fading;

  /// 伴唱模式开启中（伴奏轨与原曲并行播放）。
  final bool accompanying;

  /// 伴唱正在加载（匹配伴奏 / 解析地址 / 装载音频轨）。
  final bool accompanyLoading;

  bool get visible =>
      buffering || fading || accompanying || accompanyLoading;
}

/// 播放页进度条时间行中央的瞬时状态提示。
///
/// - 「缓冲中」：音频流正在准备数据（解析地址 / 装载 / 缓冲，
///   `PlayerProvider.isStreamBuffering`），或已下发播放命令但平台迟迟没出声
///   （`PlayerProvider.isWaitingForAudioStart`，桌面端起播/定位延迟的兜底口径）。
/// - 「音频过渡中」：交叉淡化（crossfade / AutoMix 的淡入斜坡）正在进行。
/// - 「伴唱加载中」：点击伴唱后匹配伴奏 / 解析地址 / 装载伴唱轨的阶段。
/// - 「伴唱中」：伴唱已就绪并出声。
///
/// 这些提示可同时出现：各包一层圆角矩形，作为一组整体居中于左右两个时间数字之间。
/// 位置与几何由调用点交给 [PlayerSeekBar.labelRowHints]，本文件只负责"显示什么、
/// 长什么样"。
///
/// 返回 null 表示当前没有提示 —— 调用点据此**不传**插槽，时间行保持改动前的
/// 14dp 定高形态（有无提示不改变进度条总高，页面 chrome 不会上下抖）。
///
/// 前置条件：调用点必须把 [PlayerProvider.crossfadeActiveNotifier]、
/// [PlayerProvider.accompanyActiveNotifier]、[PlayerProvider.accompanyLoadingNotifier]
/// 并入自己触发重建的 Listenable（进度条那一段），否则起止不会重算；
/// 「缓冲中」跟随 provider 的低频通知与位置节拍刷新，无需额外接线。
Widget? playerHintPillsFor(PlayerProvider player, {required bool amStyle}) {
  // 「缓冲中」= 平台在装数据 **或** 已下发播放命令但迟迟没出声。
  // 后者专治 Windows/WinRT：seek 与「暂停后恢复」的起步延迟里它一直是 ready，
  // 不发任何 buffering 事件（真机日志实测 1.3s 只有 ready），只靠处理态在桌面端
  // 永远看不到提示（见 PlayerProvider.isWaitingForAudioStart）。
  final streamBuffering =
      player.isStreamBuffering || player.isWaitingForAudioStart;
  final state = PlaybackHintState.resolve(
    streamBuffering: streamBuffering,
    // 有错误在展示时不报「缓冲中」：上方 PlaybackStatusFeedback 的错误条才是当时的真话。
    hasError: player.resolveErrorForDisplay != null,
    crossfading: player.crossfadeActiveNotifier.value,
    accompanying: player.accompanyActiveNotifier.value,
    accompanyLoading: player.accompanyLoadingNotifier.value,
  );
  if (!state.visible) return null;
  return PlaybackHintPills(state: state, amStyle: amStyle);
}

/// 提示胶囊组：1~3 枚圆角矩形并排（`mainAxisSize: min`），由宿主居中。
class PlaybackHintPills extends StatelessWidget {
  const PlaybackHintPills({
    super.key,
    required this.state,
    this.amStyle = false,
  });

  /// 「缓冲中」文案。
  static const String bufferingLabel = '缓冲中';

  /// 「音频过渡中」文案。
  static const String transitionLabel = '音频过渡中';

  /// 「伴唱加载中」文案。
  static const String accompanyLoadingLabel = '伴唱加载中';

  /// 「伴唱中」文案。
  static const String accompanyingLabel = '伴唱中';

  final PlaybackHintState state;

  /// AM 深色皮肤：与 `DockSkin.am` / `PlaybackStatusFeedback(amStyle: true)`
  /// 同一白色系口径。
  final bool amStyle;

  @override
  Widget build(BuildContext context) {
    final labels = <String>[
      if (state.buffering) bufferingLabel,
      if (state.fading) transitionLabel,
      if (state.accompanyLoading) accompanyLoadingLabel,
      if (state.accompanying) accompanyingLabel,
    ];
    if (labels.isEmpty) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < labels.length; i++) ...[
          if (i > 0) const Gap(AppSpacing.xs),
          _HintPill(label: labels[i], amStyle: amStyle),
        ],
      ],
    );
  }
}

/// 单枚提示胶囊：定高（= 时间行高）圆角矩形包住一行文字。
///
/// 定高取 [PlayerSeekBar.labelRowHeight] 而不是按内容撑开：时间行高度恒定，
/// 提示出现/消失不会改变进度条总高，宽屏常驻带的 40dp 预算与
/// `PlayerWidePane.seekReserve` 也不必跟着改。
class _HintPill extends StatelessWidget {
  const _HintPill({required this.label, required this.amStyle});

  final String label;
  final bool amStyle;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final background = amStyle
        ? Colors.white.withValues(alpha: 0.16)
        : colorScheme.secondaryContainer;
    final foreground = amStyle
        ? Colors.white
        : colorScheme.onSecondaryContainer;
    return Container(
      height: PlayerSeekBar.labelRowHeight,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: background,
        borderRadius: AppRadius.xsAll,
      ),
      child: Text(
        label,
        maxLines: 1,
        softWrap: false,
        // height 1.0：11sp 字只占一行字高，不被 1.45 的排版行高撑出胶囊
        //（系统字号放大到 1.3× 时由宿主的 FittedBox 兜底缩放）。
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: foreground, height: 1.0),
      ),
    );
  }
}
