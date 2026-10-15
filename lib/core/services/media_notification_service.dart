import 'package:flutter/services.dart';

/// 为原生重试提供有界的命令去重，并且只确认实际交给回调的命令。
class MediaCommandAckRouter {
  MediaCommandAckRouter({this.maxRememberedCommands = 64});

  final int maxRememberedCommands;
  final Set<int> _handledCommandIds = <int>{};
  final List<int> _handledOrder = <int>[];

  bool dispatch(int? commandId, void Function()? callback) {
    if (commandId == null || callback == null) return false;
    if (_handledCommandIds.contains(commandId)) return true;
    // 回调同步成功返回后才确认并记入去重表。若回调抛错，原生端会以同一
    // commandId 重试；提前记账会让重试被当作重复命令吞掉。
    callback();
    _handledCommandIds.add(commandId);
    _handledOrder.add(commandId);
    while (_handledOrder.length > maxRememberedCommands) {
      _handledCommandIds.remove(_handledOrder.removeAt(0));
    }
    return true;
  }
}

class MediaNotificationService {
  static const MethodChannel _channel = MethodChannel(
    'com.md3music.md3music/floating_lyric',
  );

  static void Function()? onPrevious;
  static void Function()? onNext;
  static void Function()? onTogglePlayPause;
  static void Function(int)? onSeekTo;
  /// Windows SMTC 循环（Repeat）按钮：系统算好目标循环模式后回传
  /// （'off' / 'one' / 'all'），App 直接精确设定而非自行循环切换。
  static void Function(String)? onSetLoopMode;
  /// 媒体键快进/快退（TV 遥控器）；由 desktop_lyric_service.registerNativeCallbacks 装配。
  static void Function()? onSeekForward;
  static void Function()? onSeekBack;
  // 线控耳机媒体键映射的独立播放 / 暂停命令（原生端唤醒播放下发）
  static void Function()? onPlay;
  static void Function()? onPause;
  // 来自通知栏桌面歌词按钮
  static void Function()? onToggleDesktopLyric;
  static void Function()? onToggleFavorite;
  // 来自悬浮窗内按钮：参数为 "lock" / "previous" / "play" / "next" / "settings"
  static void Function(String)? onDesktopLyricAction;
  // 来自悬浮窗内修改配置后回传
  static void Function(Map<dynamic, dynamic>)? onConfigChanged;
  // 来自私人FM桌面小部件的按钮动作
  static void Function()? onWidgetFmPlayPause;
  static void Function()? onWidgetFmToggleFavorite;
  // 参数为档位下标（0=红心 1=探索 2=小众）
  static void Function(int)? onWidgetFmSelectStation;
  // 参数为歌曲 hash（预告封面点击，后台起播）
  static void Function(String)? onWidgetFmOpenTrack;
  // 封面点击：app 已被拉起，打开播放器页
  static void Function()? onWidgetFmOpenPlayer;
  // 登录引导卡点击：MainActivity 拉起 app 后转发
  static void Function()? onWidgetFmOpenLogin;
  // 屏幕亮灭（FloatingLyricService SCREEN_OFF/ON 广播转发）
  static void Function(bool on)? onScreenStateChanged;
  static final MediaCommandAckRouter _mediaCommandAckRouter =
      MediaCommandAckRouter();

  static int? _commandIdFromArguments(Object? arguments) {
    if (arguments is! Map) return null;
    final commandId = arguments['commandId'];
    return commandId is int ? commandId : null;
  }

  static bool _dispatchMediaCommand(
    Object? arguments,
    void Function()? callback,
  ) {
    final commandId = _commandIdFromArguments(arguments);
    if (commandId != null) {
      return _mediaCommandAckRouter.dispatch(commandId, callback);
    }

    // 通知栏/桌面小组件等旧入口不携带 commandId，仍要直接执行播放回调。
    // 带 commandId 的媒体会话命令继续由 AckRouter 去重并确认。
    if (callback == null) return false;
    callback();
    return true;
  }

  static void initCallbacks() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'previous':
          return _dispatchMediaCommand(call.arguments, onPrevious);
        case 'next':
          return _dispatchMediaCommand(call.arguments, onNext);
        case 'togglePlayPause':
          return _dispatchMediaCommand(call.arguments, onTogglePlayPause);
        case 'play':
          return _mediaCommandAckRouter.dispatch(
            _commandIdFromArguments(call.arguments),
            onPlay,
          );
        case 'pause':
          // just_audio fork 从 Media3 onPlayerCommandRequest 转来的同步暂停没有
          // commandId；它与原生队列重试不同，直接交给 Provider 使在途换源失效。
          final commandId = _commandIdFromArguments(call.arguments);
          if (commandId == null) {
            final callback = onPause;
            if (callback == null) return false;
            callback();
            return true;
          }
          return _mediaCommandAckRouter.dispatch(commandId, onPause);
        case 'seekForward':
          return _dispatchMediaCommand(call.arguments, onSeekForward);
        case 'seekBack':
          return _dispatchMediaCommand(call.arguments, onSeekBack);
        case 'seekTo':
          final pos = call.arguments as int?;
          if (pos != null) onSeekTo?.call(pos);
          break;
        case 'setLoopMode':
          final mode = call.arguments as String?;
          if (mode != null) onSetLoopMode?.call(mode);
          break;
        case 'toggleDesktopLyric':
          onToggleDesktopLyric?.call();
          break;
        case 'toggleFavorite':
          onToggleFavorite?.call();
          break;
        case 'desktopLyricAction':
          final action = call.arguments as String?;
          if (action != null) onDesktopLyricAction?.call(action);
          break;
        case 'desktopLyricConfigChanged':
          final config = call.arguments as Map<dynamic, dynamic>?;
          if (config != null) onConfigChanged?.call(config);
          break;
        // 悬浮窗服务转发的屏幕亮灭（熄屏时 Dart tick 门控休眠用）
        case 'screenStateChanged':
          final on = call.arguments is Map
              ? (call.arguments as Map<dynamic, dynamic>)['on'] == true
              : false;
          onScreenStateChanged?.call(on);
          break;
        // 私人FM桌面小部件按钮动作
        case 'widgetFmPlayPause':
          onWidgetFmPlayPause?.call();
          break;
        case 'widgetFmToggleFavorite':
          onWidgetFmToggleFavorite?.call();
          break;
        case 'widgetFmSelectStation':
          final index = call.arguments as int?;
          if (index != null) onWidgetFmSelectStation?.call(index);
          break;
        case 'widgetFmOpenTrack':
          final hash = call.arguments as String?;
          if (hash != null) onWidgetFmOpenTrack?.call(hash);
          break;
        case 'widgetFmOpenPlayer':
          onWidgetFmOpenPlayer?.call();
          break;
        case 'widgetFmOpenLogin':
          onWidgetFmOpenLogin?.call();
          break;
      }
      return null;
    });
  }

  static Future<void> updateNotification({
    String songId = '',
    required String title,
    required String artist,
    String? artUrl,
    String? fallbackFilePath,
    required bool isPlaying,
    Duration position = Duration.zero,
    Duration duration = Duration.zero,
    bool desktopLyricEnabled = false,
    bool isFavorited = false,
    String loopMode = 'off',
    bool shuffleEnabled = false,
  }) async {
    try {
      await _channel.invokeMethod('updateNotification', {
        'songId': songId,
        'title': title,
        'artist': artist,
        'artUrl': artUrl,
        'fallbackFilePath': fallbackFilePath,
        'isPlaying': isPlaying,
        'position': position.inMilliseconds,
        'duration': duration.inMilliseconds,
        'desktopLyricEnabled': desktopLyricEnabled,
        'isFavorited': isFavorited,
        'loopMode': loopMode,
        'shuffleEnabled': shuffleEnabled,
      });
    } catch (_) {}
  }

  static Future<void> hideNotification() async {
    try {
      await _channel.invokeMethod('hideNotification');
    } catch (_) {}
  }

  /// 预取封面到原生本地缓存（方案B：切歌前下载后续歌曲封面，切歌时秒显，根治空档）。
  static Future<void> prefetchCover(List<String?> artUrls) async {
    try {
      final urls = artUrls
          .whereType<String>()
          .where((u) => u.isNotEmpty)
          .toList();
      if (urls.isEmpty) return;
      await _channel.invokeMethod('prefetchCover', {'urls': urls});
    } catch (_) {}
  }

  /// 通知原生端：播放状态已恢复完成，可安全派发线控耳机命令（唤醒播放）。
  /// 原生端 AudioPlaybackService 进程被杀后创建后台 FlutterEngine 并等待该信号
  /// 后才派发 play/next 等命令，确保 PlayerProvider 已完成状态恢复。
  static Future<void> notifyPlayerReady() async {
    try {
      await _channel.invokeMethod('playerReady');
    } catch (_) {}
  }

  // 桌面歌词（悬浮窗）相关
  static Future<bool> hasOverlayPermission() async {
    try {
      final r = await _channel.invokeMethod<bool>('hasOverlayPermission');
      return r ?? false;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> startFloatingLyric({
    required String lyric,
    required String title,
  }) async {
    try {
      final r = await _channel.invokeMethod<bool>('startFloatingLyric', {
        'lyric': lyric,
        'title': title,
      });
      return r ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> updateLyric(String lyric, {String nextLyric = ''}) async {
    try {
      final r = await _channel.invokeMethod<bool>('updateLyric', {
        'lyric': lyric,
        'nextLyric': nextLyric,
      });
      return r ?? false;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> updateTitle(String title) async {
    try {
      final r = await _channel.invokeMethod<bool>('updateTitle', {
        'title': title,
      });
      return r ?? false;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> stopFloatingLyric() async {
    try {
      final r = await _channel.invokeMethod<bool>('stopFloatingLyric');
      return r ?? false;
    } catch (e) {
      return false;
    }
  }

  // 蓝牙歌词兼容通道仍保留，但原生端不再改写共享 MediaSession 的 TITLE/ARTIST，
  // 避免 ColorOS 锁屏把歌词行误判为歌曲身份。
  static Future<void> updateBluetoothLyric(String lyric) async {
    try {
      await _channel.invokeMethod('updateBluetoothLyric', {'lyric': lyric});
    } catch (_) {}
  }

  static Future<void> setBluetoothLyricEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod('setBluetoothLyricEnabled', {
        'enabled': enabled,
      });
    } catch (_) {}
  }

  // LyricInfo 歌词转发：把整首歌词（LRC/ELRC JSON）写入 MediaSession extras，
  // 供 ColorOS 桌面歌词 / LyricInfo 模块等第三方系统读取。
  // 传入空字符串表示移除 lyricInfo（切歌/功能关闭时调用）。
  static Future<void> updateLyricInfo(
    String jsonString, {
    String songId = '',
    int sessionGeneration = 0,
    bool hasTranslation = false,
  }) async {
    try {
      await _channel.invokeMethod('updateLyricInfo', {
        'lyricInfo': jsonString,
        'songId': songId,
        'sessionGeneration': sessionGeneration,
        'hasTranslation': hasTranslation,
      });
    } catch (_) {}
  }

  static Future<void> removeLyricInfo({
    String songId = '',
    int sessionGeneration = 0,
  }) async {
    await updateLyricInfo(
      '',
      songId: songId,
      sessionGeneration: sessionGeneration,
      hasTranslation: false,
    );
  }

  // ================= 锁屏歌词 =================
  // 原生侧 LockScreenLyricActivity 覆盖在锁屏上方显示全屏滚动歌词列表
  // （与 AM 播放页 Zen 沉浸模式视觉对齐）。
  // 协议：整首歌词 + 样式一次推送（updateLockScreenLyricData），
  // 播放进度 500ms 节流轻量推送（updateLockScreenProgress），
  // 封面主色异步提取完成后单独推送（updateLockScreenAccent）。

  static Future<void> showLockScreenLyric() async {
    try {
      await _channel.invokeMethod('showLockScreenLyric');
    } catch (_) {}
  }

  static Future<void> hideLockScreenLyric() async {
    try {
      await _channel.invokeMethod('hideLockScreenLyric');
    } catch (_) {}
  }

  /// 推送整首歌词与样式到原生锁屏歌词界面（切歌 / 歌词加载完成 / 样式变化时调用）。
  ///
  /// [lines] 每项为 `{'text', 'start', 'duration', 'words', 'wordStarts',
  /// 'wordDurations', 'sub'}`；LRC/纯文本行 words 为空数组，原生侧整行渲染。
  /// [placeholder] 非空时无歌词列表、居中显示占位文本（如「歌词加载中...」）。
  /// 样式字段全部来自 AM 歌词偏好（LyricPreferences），保证锁屏与 Zen 模式一致：
  /// [lineHeightMultiplier] = (fontSize / 15) * lineSpacing；
  /// [fontSource] 0=system 1=bundled（已废弃，等同 system）2=custom（[customFontPath]）；
  /// [showTranslation] + [displayMode]（0=翻译 1=罗马音）决定当前行副行。
  static Future<void> updateLockScreenLyricData({
    required List<Map<String, Object?>> lines,
    required String placeholder,
    required int currentPositionMs,
    required int durationMs,
    required bool isPlaying,
    required String title,
    required String artist,
    String? artUrl,
    String? fallbackFilePath,
    required double fontSize,
    required int fontWeight,
    required double lineHeightMultiplier,
    required int fontSource,
    String? customFontPath,
    required bool showTranslation,
    required int displayMode,
    required bool useDynamicColor,
  }) async {
    try {
      await _channel.invokeMethod('updateLockScreenLyricData', {
        'lines': lines,
        'placeholder': placeholder,
        'currentPositionMs': currentPositionMs,
        'durationMs': durationMs,
        'isPlaying': isPlaying,
        'title': title,
        'artist': artist,
        'artUrl': artUrl,
        'fallbackFilePath': fallbackFilePath,
        'fontSize': fontSize,
        'fontWeight': fontWeight,
        'lineHeightMultiplier': lineHeightMultiplier,
        'fontSource': fontSource,
        'customFontPath': customFontPath,
        'showTranslation': showTranslation,
        'displayMode': displayMode,
        'useDynamicColor': useDynamicColor,
      });
    } catch (_) {}
  }

  /// 轻量进度更新：仅位置/时长/播放态（500ms 节流 + 播放状态翻转时立即推）。
  ///
  /// 原生帧循环按真实时间 1:1 外推 + 指数平滑校正，低频权威位置足够平滑。
  static Future<void> updateLockScreenProgress({
    required int currentPositionMs,
    required int durationMs,
    required bool isPlaying,
  }) async {
    try {
      await _channel.invokeMethod('updateLockScreenProgress', {
        'currentPositionMs': currentPositionMs,
        'durationMs': durationMs,
        'isPlaying': isPlaying,
      });
    } catch (_) {}
  }

  /// 封面主色异步提取完成后推送：当前行歌词按「85% 白 + 15% 主色」混色
  /// （与 AM 歌词动态取色一致）。[colorValue] 为 0 表示无主色（纯白）。
  static Future<void> updateLockScreenAccent(int colorValue) async {
    try {
      await _channel.invokeMethod('updateLockScreenAccent', {
        'accentColor': colorValue,
      });
    } catch (_) {}
  }
}
