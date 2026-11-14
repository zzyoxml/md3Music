import 'dart:async';

import 'package:flutter/foundation.dart';
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

  /// Windows SMTC 随机（Shuffle）按钮：系统把目标态算好后回传。
  ///
  /// 与 [onSetLoopMode] 同一套路数（系统给目标值，App 服从），差别是随机
  /// 只有两个状态，故直接传 bool。
  static void Function(bool)? onSetShuffle;

  /// Windows SMTC 倍速按钮：回传系统请求的目标倍速（double）。
  ///
  /// 只来自 `ISystemMediaTransportControls2::PlaybackRateChangeRequested`；
  /// 老系统拿不到该接口时永远不会触发。
  static void Function(double)? onSetPlaybackSpeed;

  /// 媒体键快进/快退（TV 遥控器）；由 desktop_lyric_service.registerNativeCallbacks 装配。
  static void Function()? onSeekForward;
  static void Function()? onSeekBack;
  // 线控耳机媒体键映射的独立播放 / 暂停命令（原生端唤醒播放下发）
  static void Function()? onPlay;
  static void Function()? onPause;
  // 来自通知栏桌面歌词按钮
  static void Function()? onToggleDesktopLyric;
  static void Function()? onToggleFavorite;
  // 来自概念版 4×1 小组件的播放模式键（顺序 → 列表 → 单曲 → 随机 循环）
  static void Function()? onCyclePlayMode;
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

  /// 锁屏歌词卡片里的「投屏 / 队列」按钮动作（参数为 `openCast` / `openQueue`）。
  /// 原生锁屏 Activity 只负责拉起 App 并回传动作字符串，目标面板由
  /// `LockScreenActionService` 在 Navigator 就绪后打开。
  static void Function(String)? onWidgetAction;
  // MD3Music fork v21：车机卡片点入（投屏屏判据由原生侧把控），直达全屏歌词
  static void Function()? onOpenCardLyric;

  /// MD3Music fork v66：车机语音点歌。原生把 framework
  /// `MediaController.TransportControls.playFromSearch()` 的 query 转来
  /// （media3 1.4.1 的 `MediaSession.Callback` 没有该回调，只能经 legacy stub 钩子到达）。
  static void Function(String query)? onPlayFromSearch;

  /// MD3Music fork v67：legacy browse 搜索（`MediaBrowserCompat.search`）。
  ///
  /// 返回值即原生侧收到的候选列表：**必须返回列表**，空列表表示「0 条结果」。
  /// 返回 null 会被原生兜底成空列表，但不要让这条契约依赖兜底。
  static Future<List<Map<String, Object?>>> Function(String query)?
  onBrowseSearch;

  /// MD3Music fork v67：桥接端点回候选条目（payload 含 hash/albumId/albumAudioId）。
  static void Function(Map<String, Object?> payload)? onSearchResultPlay;

  /// MD3Music fork v67：候选条目已失效（进程重启 / TTL 过期 / 无引擎）。
  static void Function()? onSearchResultExpired;
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

  /// MD3Music fork v21 车机卡片：冷启动残留深链拉取——MainActivity 在引擎
  /// 未就绪时只置 pending，这里在根导航就绪后主动取一次。
  static Future<bool> consumePendingOpenCardLyric() async {
    try {
      final r = await _channel.invokeMethod<bool>(
        'consumePendingOpenCardLyric',
      );
      return r ?? false;
    } catch (_) {
      return false;
    }
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
        // Windows SMTC 随机按钮（ISystemMediaTransportControls2）：系统把目标
        // 态算好后以 bool 回传，App 直接设定而非自行取反。
        case 'setShuffle':
          final shuffle = call.arguments;
          if (shuffle is bool) onSetShuffle?.call(shuffle);
          break;
        // Windows SMTC 倍速按钮：回传目标倍速，夹取由 setSpeed 自己负责。
        case 'setPlaybackSpeed':
          final rate = call.arguments;
          if (rate is num) onSetPlaybackSpeed?.call(rate.toDouble());
          break;
        case 'openCardLyricView':
          // MD3Music fork v30：回调未装配（首帧前送达）时不清 pending——
          // 由 _AppView postFrame 的消费兜底接住；装配后才投递并清零。
          // 否则车机冷启动的点击会被静默丢弃（v29 的"投递即清"过激）。
          debugPrint(
            '[CardLyricLink] Dart case openCardLyricView, '
            'handlerMounted=${onOpenCardLyric != null}',
          );
          if (onOpenCardLyric != null) {
            onOpenCardLyric!();
            // v33：显式 dynamic——catchError 的返回形态与 Future<dynamic?>
            // 匹配，防止日后改成强类型时 catcher 在 zone 抛 TypeError。
            unawaited(
              _channel
                  .invokeMethod<dynamic>('consumePendingOpenCardLyric')
                  .catchError((Object _) {}),
            );
          }
          break;
        // MD3Music fork v40：原子随身听列表项点播——岛按 media id 回播，原生经
        // ACTION_VIVO_MIX_PLAY 转发到引擎通道。media id 口径 `<来源>:<songId>`。
        case 'vivoMixPlay':
          final args = call.arguments as Map<dynamic, dynamic>?;
          final mediaId = args?['mediaId'] as String?;
          if (mediaId != null && mediaId.isNotEmpty)
            onVivoMixPlay?.call(mediaId);
          break;
        // MD3Music fork v45：原子随身听循环模式切换（mode 1=列表/2=单曲/3=随机）。
        case 'vivoMixPlayMode':
          final args = call.arguments as Map<dynamic, dynamic>?;
          final mode = args?['mode'] as int?;
          if (mode != null) onVivoMixPlayMode?.call(mode);
          break;
        // MD3Music fork v64：原子随身听 ❤️ 收藏（岛 setRating/HeartRating 的目标态）。
        case 'vivoMixRating':
          final args = call.arguments as Map<dynamic, dynamic>?;
          final favorite = args?['favorite'] as bool?;
          if (favorite != null) onVivoMixRating?.call(favorite);
          break;
        // MD3Music fork v66：车机语音点歌——原生把 playFromSearch 的 query 转来。
        // 暖启动直投不带 commandId，直接执行；带 commandId 时走 AckRouter 去重。
        // 注意 ack 语义是「已受理」而非「已播出」：真正的搜索/起播是异步的，
        // 原生不重试（playFromSearch 也没有标准失败回调）。
        case 'playFromSearch':
          final args = call.arguments as Map<dynamic, dynamic>?;
          final query = args?['query'] as String?;
          if (query == null || query.isEmpty) return false;
          final callback = onPlayFromSearch;
          if (callback == null) return false;
          final commandId = _commandIdFromArguments(call.arguments);
          if (commandId == null) {
            callback(query);
            return true;
          }
          return _mediaCommandAckRouter.dispatch(
            commandId,
            () => callback(query),
          );
        // MD3Music fork v67：legacy 搜索——返回值即原生侧收到的候选列表。
        // 任何失败都必须回空列表（原生据此回 emptyList，桥接端看到的是「0 条结果」
        // 而不是错误，不会因此关闭搜索入口）。
        case 'browseSearch':
          final args = call.arguments as Map<dynamic, dynamic>?;
          final query = args?['query'] as String?;
          final handler = onBrowseSearch;
          if (query == null || query.isEmpty || handler == null) {
            return <Map<String, Object?>>[];
          }
          try {
            return await handler(query);
          } catch (e) {
            debugPrint('[VoiceSearch] browseSearch 失败: $e');
            return <Map<String, Object?>>[];
          }
        // MD3Music fork v67：桥接端点回候选条目。
        case 'searchResultPlay':
          final args = call.arguments as Map<dynamic, dynamic>?;
          if (args != null && args.isNotEmpty) {
            onSearchResultPlay?.call(Map<String, Object?>.from(args));
          }
          break;
        case 'searchItemExpired':
          onSearchResultExpired?.call();
          break;
        case 'toggleDesktopLyric':
          onToggleDesktopLyric?.call();
          break;
        case 'toggleFavorite':
          onToggleFavorite?.call();
          break;
        case 'cyclePlayMode':
          onCyclePlayMode?.call();
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
        // 锁屏歌词卡片的「投屏 / 队列」按钮：App 已被拉起，这里打开目标面板
        case 'widgetAction':
          final widgetAction = call.arguments as String?;
          if (widgetAction != null) onWidgetAction?.call(widgetAction);
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
    String album = '',
    String albumArtist = '',
    double playbackRate = 1.0,
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
        // 专辑 / 专辑歌手：Windows 侧发布到 SMTC 的 AlbumTitle / AlbumArtist，
        // 是第三方任务栏歌词工具（TaskbarLyrics、AF Media Bar）的歌曲身份
        // 与歌词匹配维度之一。Android 侧现有实现忽略这两个字段。
        'album': album,
        'albumArtist': albumArtist,
        // 实际播放倍速：SMTC 不发布 PlaybackRate 时，外部工具一律按 1.0x
        // 外推时间轴，1.25x/1.5x 播放会让歌词持续漂移。
        'playbackRate': playbackRate,
      });
    } catch (_) {}
  }

  /// Windows 专用的每秒位置推进轻量路径。
  ///
  /// 只更新 SMTC 时间轴与播放状态，不重发元数据/封面。若每秒走全量
  /// [updateNotification]，原生 `DisplayUpdater.Update()` 会让系统重建媒体
  /// 卡片，播控中心封面每秒闪烁一次。Android 侧无此方法调用（30s 一次全量），
  /// MissingPluginException 已被吞掉，无副作用。
  static Future<void> updateNotificationPosition({
    required Duration position,
    required Duration duration,
    required bool isPlaying,
  }) async {
    try {
      await _channel.invokeMethod('updateNotificationPosition', {
        'position': position.inMilliseconds,
        'duration': duration.inMilliseconds,
        'isPlaying': isPlaying,
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

  /// MD3Music fork v39：把 vivo 原子随身听（vivomusicmix）的三棵列表快照推给原生。
  ///
  /// 岛在能力位放行后经 MediaBrowserServiceCompat 绑定来取列表；原生侧只读内存
  /// 快照，故由 Dart 主动推（不在 binder 回调里回拉，避免卡住岛的调用线程）。
  /// v40：失败不再静默——主通道缺 case 这类问题（第六轮审查 P0）必须当场暴露。
  static Future<void> updateVivoMixLists({
    required List<Map<String, dynamic>> current,
    required List<Map<String, dynamic>> favorites,
    required List<Map<String, dynamic>> local,
  }) async {
    try {
      await _channel.invokeMethod('updateVivoMixLists', {
        'current': current,
        'favorites': favorites,
        'local': local,
      });
    } catch (e) {
      debugPrint('[VivoMixSync] updateVivoMixLists failed: $e');
    }
  }

  /// MD3Music fork v63：点歌后强制刷新岛列表——岛的高亮只在收到列表刷新
  /// 时重渲染（列表内容不变时 notifyChildrenChanged 不会被列表指纹触发，
  /// 高亮就停在旧项，真机实测要 3~5 秒才被别的刷新带出来）。不推数据，
  /// 只让岛重新拉一次当前列表（原生侧走 childrenChangedNotifier 三树通知）。
  static Future<void> refreshVivoMixChildren() async {
    try {
      await _channel.invokeMethod('refreshVivoMixChildren');
    } catch (e) {
      debugPrint('[VivoMixSync] refreshVivoMixChildren failed: $e');
    }
  }

  /// MD3Music fork v50：岛状态回显——循环模式（1=列表/2=单曲/3=随机）与当前曲
  /// 红心。岛只在 metadata 变化时读 LOOP_MODE/RATING 来点亮按钮并计算下一次点击
  /// （岛端 c0.l0），原生收到后写 metadata 并重发。[isFav] null=尚无当前曲。
  static Future<void> updateVivoMixState({
    required int loopMode,
    required bool? isFav,
  }) async {
    try {
      await _channel.invokeMethod('updateVivoMixState', {
        'loopMode': loopMode,
        'isFav': isFav,
      });
    } catch (e) {
      debugPrint('[VivoMixSync] updateVivoMixState failed: $e');
    }
  }

  /// MD3Music fork v40：原子随身听列表项点播回调（media id = `<来源>:<songId>`）。
  static void Function(String mediaId)? onVivoMixPlay;

  /// MD3Music fork v45：原子随身听循环模式切换回调（mode 1=列表/2=单曲/3=随机）。
  static void Function(int mode)? onVivoMixPlayMode;

  /// MD3Music fork v64：原子随身听 ❤️ 收藏回调（岛 setRating/HeartRating 目标态）。
  /// true=收藏，false=取消收藏；由 VivoMixSync 按目标态落地，不做 toggle 猜测。
  static void Function(bool favorite)? onVivoMixRating;

  // 桌面歌词（悬浮窗）相关
  static Future<bool> hasOverlayPermission() async {
    try {
      final r = await _channel.invokeMethod<bool>('hasOverlayPermission');
      return r ?? false;
    } catch (e) {
      return false;
    }
  }

  /// 原生悬浮窗窗口是否真的活着（FloatingLyricService 在跑 + View 已 addView）。
  ///
  /// 用途：引擎被系统杀死后，若进程存活，原生窗口原封不动，但 Dart 侧开关
  /// 丢失；restoreFloatingFromNative 用它判断是否恢复推送。进程一起死则窗口
  /// 也没了，查询返回 false 属正常。引擎刚启动时通道可能尚未注册，异常按
  /// false 处理（此时 window 必然显示不了，恢复无人可推）。
  static Future<bool> isFloatingLyricWindowRunning() async {
    try {
      final r = await _channel.invokeMethod<bool>(
        'isFloatingLyricWindowRunning',
      );
      return r ?? false;
    } catch (_) {
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

  // CarWith 车机投屏逐句歌词：走与蓝牙歌词同一条 floating_lyric 通道，
  // 原生 MainActivity 把它转成 AudioPlaybackService 的 ACTION_UPDATE_CAR_LYRIC。
  // enabled=false 且 lyric 为空串 = 「歌词收掉」（规格 §九 第 5 条：关开关时
  // 车机不停在最后一句）。原生侧对空串做清空处理；通道异常静默吞掉，
  // 与 updateBluetoothLyric 同款（非 Android 环境没有该通道，不能让推词链路炸穿）。
  static Future<void> updateCarWithLyricLine(bool enabled, String lyric) async {
    try {
      await _channel.invokeMethod('updateCarWithLyricLine', {
        'enabled': enabled,
        'lyric': lyric,
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
    await tryUpdateLyricInfo(
      jsonString,
      songId: songId,
      sessionGeneration: sessionGeneration,
      hasTranslation: hasTranslation,
    );
  }

  /// 返回 MethodChannel 是否成功交付给原生端；失败时由调用方保留重试机会。
  static Future<bool> tryUpdateLyricInfo(
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
      return true;
    } catch (_) {
      return false;
    }
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
  /// [isFavorited] 当前歌曲收藏态，决定卡片行 2 红心是填充还是描边。
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
    required bool isFavorited,
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
        'isFavorited': isFavorited,
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

  /// 只同步锁屏卡片的收藏态（收藏翻转后调用），不重推歌词与样式。
  ///
  /// 走独立轻量通道：整包重推会重置原生侧进度外推基线，造成锁屏进度回跳。
  static Future<void> updateLockScreenFavorite({
    required bool isFavorited,
  }) async {
    try {
      await _channel.invokeMethod('updateLockScreenFavorite', {
        'isFavorited': isFavorited,
      });
    } catch (_) {}
  }

  /// 取走冷启动期间原生侧暂存的锁屏卡片动作（`openCast` / `openQueue`）。
  ///
  /// 引擎就绪前原生只能把动作存进 pending，Dart 侧首帧后主动拉取一次补投；
  /// 取走即清空。通道未注册（非 Android / 原生未实现）时异常返回 null。
  static Future<String?> takePendingWidgetAction() async {
    try {
      return await _channel.invokeMethod<String>('takePendingWidgetAction');
    } catch (_) {
      return null;
    }
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
