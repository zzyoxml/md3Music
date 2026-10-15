import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../providers/player_provider.dart';
import 'playback_status_feedback_state.dart';

/// 播放加载/失败状态的轻量提示；取消和重试始终作用于当前播放请求。
class PlaybackStatusFeedback extends StatelessWidget {
  final bool amStyle;

  const PlaybackStatusFeedback({super.key, this.amStyle = false});

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerProvider>();
    final state = context
        .select<
          PlayerProvider,
          ({bool loading, bool awaitingProgress, String? error})
        >(
          (p) => (
            loading:
                p.isManualRetryInFlight ||
                p.isResolvingUrl ||
                p.isPlaybackNotReady,
            awaitingProgress: p.isAwaitingPlaybackProgress,
            error: p.resolveErrorForDisplay,
          ),
        );
    final feedback = PlaybackStatusFeedbackState.resolve(
      loading: state.loading,
      awaitingProgress: state.awaitingProgress,
      errorMessage: state.error,
    );
    // 播放准备与等待进度阶段保留 PlayerProvider 的诊断日志即可，不展示提示条。
    if (!feedback.visible ||
        feedback.isPreparing ||
        feedback.isAwaitingProgress) {
      return const SizedBox.shrink();
    }

    final scheme = Theme.of(context).colorScheme;
    final foreground = amStyle ? Colors.white : scheme.error;
    final background = amStyle
        ? Colors.white.withValues(alpha: 0.08)
        : scheme.errorContainer;

    return Container(
      width: double.infinity,
      padding: const EdgeInsetsDirectional.only(
        start: 12,
        end: 4,
        top: 2,
        bottom: 2,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 18, color: foreground),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              feedback.message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: foreground),
            ),
          ),
          TextButton(
            onPressed: player.retryCurrentPlayback,
            child: Text(feedback.actionLabel!),
          ),
        ],
      ),
    );
  }
}
