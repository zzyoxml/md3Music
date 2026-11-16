import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Windows 任务栏按钮的进度条与缩略图工具栏的原生门面。
///
/// ## 与 SMTC 的分工
///
/// Windows 有**两套互不相干的系统入口**，本仓库两套都接，回传的动作也共用
/// Dart 侧同一组回调（`MediaNotificationService` 的 `previous` / `next` /
/// `togglePlayPause`）：
///
/// | 入口 | 原生实现 | 面向 |
/// |---|---|---|
/// | SMTC（媒体浮层 / 锁屏 / 媒体键） | `windows/runner/media_controls.cpp` | 键盘媒体键、系统播放控制中心 |
/// | 任务栏进度条 + 悬停缩略图按钮 | `windows/runner/taskbar_controls.cpp` | 鼠标用户 |
///
/// 本类只管**下行**（把播放进度快照发给原生）；上行按钮动作走
/// `com.md3music.md3music/floating_lyric` 通道，Dart 侧无需为任务栏另写一套。
///
/// ## 平台口径
///
/// 用 `defaultTargetPlatform` 而非 `Platform.isWindows`：后者在 Windows 宿主上
/// 跑 `flutter test` 时同样为 true，会把宿主平台泄漏进本应跑 Android 语义的
/// 测试（与 [WindowsFullscreen] 同一教训）。
class WindowsTaskbar {
  WindowsTaskbar._();

  static const MethodChannel _channel = MethodChannel('md3music/window_tray');

  /// 当前是否支持任务栏集成（仅本仓库的 Windows runner 实现了它）。
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  /// 下发一次进度快照。
  ///
  /// [visible] 为 false 表示「没有可展示的进度」（无歌 / 已停止 / 时长未知），
  /// 原生侧会把整条进度收掉而不是留一条 0% 的假进度。
  ///
  /// 失败一律静默：任务栏集成不可用（老系统、受限会话、widget 测试无 runner）
  /// 不该影响播放本身。
  static Future<void> setState({
    required Duration position,
    required Duration duration,
    required bool isPlaying,
    required bool visible,
  }) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<bool>('setTaskbarState', {
        'position': position.inMilliseconds,
        'duration': duration.inMilliseconds,
        'isPlaying': isPlaying,
        'visible': visible,
      });
    } on MissingPluginException {
      // widget 测试没有原生 runner；实际运行须使用同一构建中的 Dart 与 runner。
    } on PlatformException catch (error) {
      debugPrint('WindowsTaskbar.setState failed: $error');
    }
  }
}
