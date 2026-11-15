import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// TV 遥控媒体键（播放/暂停/上一首/下一首）→ 页内动作的通用包装。
///
/// 为什么必须做在**页级**：`app.dart` 的根部兜底 `_tvMediaKeyFallback` 把 5 个
/// 媒体键一律绑成 `VoidCallback`，即使当前没有音频（`currentSong == null`）也会
/// **吞掉按键**；只有比它更深的 `CallbackShortcuts` 先赢，才能把键位改道给
/// 视频页自己的播放器（刷刷竖屏流、MV 每格都是独立的 `VideoPlayerController`，
/// 不走 `PlayerProvider`）。
///
/// 与 [TvMenuKeyShortcuts] 同一惯例：组件本身**不带** `kTvBuild` 门控，
/// 由调用方在 TV 分支里使用，普通 `flutter test` 即可钉住按键行为。
///
/// 传 null 的键不登记绑定，原样穿透给上层（根部兜底/系统媒体会话）。
/// 需要「消费但不做事」（例如 MV 单视频没有切歌语义）时，调用方传一个
/// 只打日志的空实现。
class TvMediaKeyShortcuts extends StatelessWidget {
  final VoidCallback? onPlayPause;
  final VoidCallback? onPlay;
  final VoidCallback? onPause;
  final VoidCallback? onNext;
  final VoidCallback? onPrevious;

  final Widget child;

  const TvMediaKeyShortcuts({
    super.key,
    this.onPlayPause,
    this.onPlay,
    this.onPause,
    this.onNext,
    this.onPrevious,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final bindings = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.mediaPlayPause): ?onPlayPause,
      const SingleActivator(LogicalKeyboardKey.mediaPlay): ?onPlay,
      const SingleActivator(LogicalKeyboardKey.mediaPause): ?onPause,
      const SingleActivator(LogicalKeyboardKey.mediaTrackNext): ?onNext,
      const SingleActivator(LogicalKeyboardKey.mediaTrackPrevious): ?onPrevious,
    };
    if (bindings.isEmpty) return child;
    return CallbackShortcuts(bindings: bindings, child: child);
  }
}
