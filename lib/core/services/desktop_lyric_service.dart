import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/repositories/settings_repository.dart';
import '../../data/models/song.dart';
import '../../main.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/theme_provider.dart';
import '../../core/layout/ui_density.dart';
import '../../core/utils/artwork_color_extractor.dart';
import '../../core/utils/local_lyric_loader.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import '../../widgets/apple_lyrics/layout/lyric_preferences.dart';
import '../../widgets/apple_lyrics/parsers/lyric_parser_chain.dart';
import 'media_notification_service.dart';
import 'lyric_info_json_builder.dart';

/// 解析歌词文本，超过 32KB 时移入 isolate。
///
/// KRC + 翻译 + 罗马音整曲可达上百 KB，主 isolate 解析会在切歌瞬间
/// 掉帧；小文本直接解析（isolate spawn 本身有开销，不划算）。
Future<List<LyricLine>> parseLyricOffMainThread(
  String text, {
  String? translationText,
  String? romaText,
}) async {
  if (text.length <= 32 * 1024) {
    return LyricParserChain.parse(
      text,
      translationText: translationText,
      romaText: romaText,
    );
  }
  return compute(
    _parseInIsolate,
    (text, translationText, romaText),
  );
}

List<LyricLine> _parseInIsolate((String, String?, String?) input) {
  return LyricParserChain.parse(
    input.$1,
    translationText: input.$2,
    romaText: input.$3,
  );
}

/// 桌面歌词服务：管理开关、解析歌词（KRC/LRC/纯文本）、按播放位置同步到原生悬浮窗。
///
/// **关键修复**：之前用 `displayLyric`（KRC 优先）+ LRC 正则解析，导致 KRC 文本
/// 解析全部失败、悬浮窗永远显示「暂无歌词」。现改用 [LyricParserChain.parse]
/// 自动识别 KRC/LRC/纯文本，输出统一 [LyricLine] 列表。
///
/// **逐字支持**：KRC 解析后每行携带 [LyricWord] 字级时间戳，逐字时间戳随行切换
/// 整行一次下发（words + positionMs），原生按本地时钟自驱动逐字推进。
/// LRC/纯文本无字时间戳时 words 为空，原生侧走整行渐变色（保持原行为）。
class DesktopLyricService {
  static final DesktopLyricService instance = DesktopLyricService._();
  DesktopLyricService._() {
    // AM 歌词偏好变化（字号/行距/字重/字体/副行/动态取色）→ 锁屏歌词跟随重推
    LyricPreferences.instance.addListener(_onLyricPrefsChangedForLockScreen);
  }

  PlayerProvider? _player;
  KugouProvider? _kugou;
  // 「显示大小」：悬浮窗是原生 overlay、不在 Flutter 树里，DisplayScaleScope
  // 够不到它，所以把档位随配置下发给原生，由它乘在歌词字号上。
  ThemeProvider? _theme;
  final SettingsRepository _settings = SettingsRepository();

  bool _enabled = false;
  bool get enabled => _enabled;

  // 蓝牙歌词开关：独立于悬浮窗。ColorOS SystemUI 与 AVRCP 共用 MediaSession，
  // 4.0 接入后原生端必须保持稳定 title/artist，因此不再用该通道改写会话身份。
  bool _bluetoothLyricEnabled = false;
  bool get bluetoothLyricEnabled => _bluetoothLyricEnabled;

  // LyricInfo 歌词转发开关：通过 MediaSession extras.lyricInfo 发布整首歌词
  // （LRC/ELRC），供 ColorOS 桌面歌词 / LyricInfo 模块等第三方系统读取。
  // 复用本服务的定时器与歌词解析管线，歌词加载完成后构造 JSON 推送一次。
  bool _lyricInfoEnabled = false;
  bool get lyricInfoEnabled => _lyricInfoEnabled;
  // 当前歌曲是否已推送过 lyricInfo（避免每 250ms tick 重复推送）
  bool _lyricInfoPushed = false;
  // ColorOS Bridge 兼容模式：开启后 lyricInfo JSON 输出 lyric=纯 LRC +
  // rawLyric=ELRC 逐字（插件据此启用逐字高亮等增强）；关闭保持 ELRC+format 格式
  bool _lyricInfoColorOs = false;
  bool get lyricInfoColorOs => _lyricInfoColorOs;

  // 锁屏歌词开关：独立于悬浮窗/蓝牙歌词/LyricInfo。开启时定时器运行，
  // 推送整首歌词到原生 LockScreenLyricActivity（锁屏全屏滚动歌词列表，
  // 与 AM 播放页 Zen 沉浸模式视觉对齐；样式全部跟随 AM 歌词偏好）。
  bool _lockScreenLyricEnabled = false;
  bool get lockScreenLyricEnabled => _lockScreenLyricEnabled;

  // 锁屏歌词推送状态（新协议：全量数据 + 轻量进度分离）
  // - 全量脏标记：切歌 / 歌词加载完成 / AM 歌词偏好变化时置位，下个推送点整包重推
  bool _lockFullDirty = false;
  // - 无歌词列表时的占位文本（歌词加载中.../暂无歌词/歌词加载失败）
  String _lockPlaceholder = '';
  // - 进度节流：上次轻量进度推送时刻与播放态（播放态翻转时立即推）
  int _lockProgressPushMs = 0;
  bool _lockLastIsPlaying = false;
  // - 封面主色提取令牌：切歌自增，异步结果回来时校验避免串歌
  int _lockAccentToken = 0;

  // SuperLyric 歌词推送开关：基于 Binder 的系统级实时歌词 API。
  // 复用本服务的定时器与歌词解析管线，在切歌 / 歌词行变化时推送当前行
  // （text/words/翻译/副歌词 + title/artist）；播放/暂停由 SuperLyric 自动
  // 监听 App 的 MediaSession 处理（sendStop），本服务不手动发送停止事件。
  bool _superLyricEnabled = false;
  bool get superLyricEnabled => _superLyricEnabled;
  // 共用偏好（设置页三种推送协议共用一份）：
  // - 翻译歌词开关：是否推送翻译（影响 SuperLyric 与 LyricInfo）
  bool _pushTranslation = true;
  // - 罗马音歌词开关：是否推送罗马音（影响 SuperLyric）
  bool _pushRoma = false;
  // - 同时存在翻译和罗马音时是否优先推送翻译（参照 Lyricon preferTranslation）。
  //   开启：保留 translation、丢弃 roma；关闭：保留 roma、丢弃 translation。
  //   SuperLyric 接收端对同时携带两字段的数据会优先显示 secondary(roma)，故需在 Dart 侧过滤。
  bool _superLyricPreferTranslation = true;

  String? _currentSongId;
  // 解析后的歌词行列表（统一模型，KRC 含 words，LRC/纯文本 words 为空）
  List<LyricLine> _lines = const [];
  int _currentLineIndex = -1;
  // 行切换迟滞时间戳：position 抖动时抑制行来回跳变、重复推送（蓝牙歌词高频刷新根因之一）
  DateTime? _lastLineSwitchAt;
  Timer? _ticker;
  // 播放中 250ms（行检测+逐字调度精度）；暂停后 1s（仅剩对账与切歌检测）
  static const int _tickIntervalPlayingMs = 250;
  static const int _tickIntervalPausedMs = 1000;
  int _tickIntervalMs = _tickIntervalPlayingMs;
  // 行边界预测 Timer：行提交后安排一次性触发，让切行不受 250ms 轮询相位限制
  Timer? _lineTimer;
  bool _awaitingLyric = false;
  int _lyricFetchToken = 0;
  int _sessionGeneration = 0;
  bool _lastPushedPlaying = false;
  // 歌词拉取失败退避：同一首歌连续失败按 250ms→10s 指数退避，
  // 防止无歌词歌曲在播放期间形成 250ms 间隔的无限重试风暴。
  String? _lyricFailedKey;
  int _lyricFailCount = 0;
  DateTime? _lyricNextRetryAt;
  // 屏幕亮灭（FloatingLyricService SCREEN_OFF/ON 转发）：熄屏且未开锁屏歌词时 tick 休眠
  bool _screenOn = true;

  // 当前配置缓存
  double _fontSize = 18.0;
  bool _doubleLine = false;
  int _opacity = 80;
  int _gradientStart = 0xFF00E5FF;
  int _gradientEnd = 0xFFFF00FF;
  int _unplayedColor = 0xFF666666;
  bool _locked = false;
  /// 悬浮窗是否锁定（锁定后原生端加 FLAG_NOT_TOUCHABLE 点击穿透，
  /// 悬浮窗自身无法再点击，只能从设置页/通知栏等外部入口解锁）。
  bool get locked => _locked;

  /// 解锁桌面歌词悬浮窗（锁定时悬浮窗点击穿透，需从外部解锁）。
  Future<void> unlock() async {
    if (!_locked) return;
    _locked = false;
    await _settings.setDesktopLyricLocked(false);
    _pushConfig(); // 推送原生端解除 FLAG_NOT_TOUCHABLE
    _notify();
  }

  // 通知外部状态变化（让 mini_player 等可以监听刷新）
  final List<VoidCallback> _listeners = [];
  void addListener(VoidCallback cb) => _listeners.add(cb);
  void removeListener(VoidCallback cb) => _listeners.remove(cb);
  void _notify() {
    for (final cb in List.of(_listeners)) {
      cb();
    }
  }

  /// 在 app 启动时（main 中）调用：注册原生回调
  void registerNativeCallbacks() {
    MediaNotificationService.onToggleDesktopLyric = () {
      toggle();
    };
    MediaNotificationService.onDesktopLyricAction = (action) {
      _handleFloatingAction(action);
    };
    MediaNotificationService.onPrevious = () {
      _player?.previous();
    };
    MediaNotificationService.onNext = () {
      _player?.next();
    };
    MediaNotificationService.onTogglePlayPause = () {
      if (_player == null) return;
      if (_player!.isPlaying) {
        _player!.pause();
      } else {
        _player!.resume();
      }
    };
    MediaNotificationService.onToggleFavorite = () {
      _handleToggleFavorite();
    };
    MediaNotificationService.onConfigChanged = (config) {
      _onNativeConfigChanged(config);
    };
    MediaNotificationService.onScreenStateChanged = (on) {
      _screenOn = on;
      if (on) {
        // 点亮屏幕立即补一拍：熄屏期间行提交与进度推送已暂停，需对齐漂移
        _onTick();
      }
    };
  }

  Future<void> _handleToggleFavorite() async {
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null) return;
    try {
      final player = ctx.read<PlayerProvider>();
      final favorites = ctx.read<FavoritesProvider>();
      final song = player.currentSong;
      if (song != null) {
        await favorites.toggleFavorite(song);
        // Refresh notification after toggle completes to update heart icon
        player.refreshNotification();
      }
    } catch (_) {}
  }

  void _handleFloatingAction(String action) {
    switch (action) {
      case 'lock':
        _locked = !_locked;
        _settings.setDesktopLyricLocked(_locked);
        _pushConfig();
        break;
      case 'previous':
        _player?.previous();
        break;
      case 'play':
        if (_player != null) {
          if (_player!.isPlaying) {
            _player!.pause();
          } else {
            _player!.resume();
          }
        }
        break;
      case 'next':
        _player?.next();
        break;
      case 'settings':
        // 设置面板内嵌在 native 浮窗，无需 Dart 处理
        break;
    }
  }

  /// 原生浮窗内修改配置后回传，Dart 负责持久化
  Future<void> _onNativeConfigChanged(Map<dynamic, dynamic> config) async {
    final fontSize = (config['fontSize'] as num?)?.toDouble();
    final doubleLine = config['doubleLine'] as bool?;
    final opacity = config['opacity'] as int?;
    final locked = config['locked'] as bool?;
    final gradientStart = config['gradientStart'] as int?;
    final gradientEnd = config['gradientEnd'] as int?;
    final unplayedColor = config['unplayedColor'] as int?;

    if (fontSize != null) {
      _fontSize = fontSize;
      await _settings.setDesktopLyricFontSize(fontSize);
    }
    if (doubleLine != null) {
      _doubleLine = doubleLine;
      await _settings.setDesktopLyricDoubleLine(doubleLine);
    }
    if (opacity != null) {
      _opacity = opacity;
      await _settings.setDesktopLyricOpacity(opacity);
    }
    if (locked != null) {
      _locked = locked;
      await _settings.setDesktopLyricLocked(locked);
    }
    if (gradientStart != null) {
      _gradientStart = gradientStart;
      await _settings.setDesktopLyricGradientStart(gradientStart);
    }
    if (gradientEnd != null) {
      _gradientEnd = gradientEnd;
      await _settings.setDesktopLyricGradientEnd(gradientEnd);
    }
    if (unplayedColor != null) {
      _unplayedColor = unplayedColor;
      await _settings.setDesktopLyricUnplayedColor(unplayedColor);
    }
    _notify();
  }

  /// 切换桌面歌词开关（mini_player / 通知栏按钮通用）
  Future<void> toggle() async {
    if (_enabled) {
      await disable();
    } else {
      await enable();
    }
  }

  Future<void> enable() async {
    if (_enabled) return;
    // 权限是独立于 provider 的系统设置检查，放最前：无权限时也走
    // startFloatingLyric（原生 MainActivity 检测到无权限会跳系统授权页
    // 并返回 false），并保持 _enabled=false，mini_player 等开关 UI 依据
    // enabled 自动回弹，不出现"假开启"。旧实现把 provider 绑定放在
    // 权限检查之前，provider 未就绪时连授权页都不会弹出。
    final hasPermission =
        await MediaNotificationService.hasOverlayPermission();
    if (!hasPermission) {
      try {
        await MediaNotificationService.startFloatingLyric(
            lyric: '', title: '');
      } catch (_) {}
      return;
    }
    _bindProvidersFromContext();
    if (_player == null || _kugou == null) {
      return;
    }
    // startFloatingLyric 返回 false（权限竞态撤销/BadTokenException）时
    // 不点亮开关，避免悬浮窗未出现但按钮显示已开启的"假开启"状态。
    final started =
        await MediaNotificationService.startFloatingLyric(lyric: '', title: '');
    if (!started) return;
    _enabled = true;
    await _loadConfig();
    await _pushConfig();
    _syncCurrentFromPlayer();
    _updateTicker();
    _notify();
  }

  Future<void> disable() async {
    if (!_enabled) return;
    _enabled = false;
    _updateTicker();
    _cancelLineTimer();
    try {
      await MediaNotificationService.stopFloatingLyric();
    } catch (_) {}
    _notify();
  }

  /// 蓝牙歌词开关：独立于悬浮窗。开启后定时器运行以获取当前歌词行，
  /// 但不弹出悬浮窗；关闭后若悬浮窗也未开启则停止定时器。
  Future<void> setBluetoothLyricEnabled(bool enabled) async {
    if (_bluetoothLyricEnabled == enabled) return;
    _bluetoothLyricEnabled = enabled;
    _bindProvidersFromContext();
    _updateTicker();
    if (enabled) {
      // 启用时重置切歌检测状态，让下个 tick 重新拉取歌词并推送。
      // 解决 app 启动时调用本方法、但原生 service 尚未就绪导致的首次播放不推送问题。
      _currentSongId = null;
      _lines = const [];
      _currentLineIndex = -1;
      _awaitingLyric = false;
    } else {
      // 关闭时清空蓝牙歌词，让原生端恢复原始 title/artist
      await MediaNotificationService.updateBluetoothLyric('');
    }
  }

  /// LyricInfo 歌词转发开关：独立于悬浮窗/蓝牙歌词。开启后定时器运行以获取
  /// 当前歌词并构造 JSON 推送（写入 MediaSession extras）；关闭时移除 lyricInfo。
  Future<void> setLyricInfoEnabled(bool enabled) async {
    if (_lyricInfoEnabled == enabled) return;
    _lyricInfoEnabled = enabled;
    _bindProvidersFromContext();
    if (enabled) {
      _lyricInfoPushed = false;
      _updateTicker();
      // 启用时若已有歌词立即推送一次（无需等下一个 tick）
      if (_lines.isNotEmpty) {
        _maybePushLyricInfo();
      }
    } else {
      _lyricInfoPushed = false;
      _updateTicker();
      // 关闭时移除 lyricInfo，让原生端元数据不再携带
      try {
        await MediaNotificationService.removeLyricInfo();
      } catch (_) {}
    }
    _notify();
  }

  /// ColorOS Bridge 兼容模式开关：改值后若 LyricInfo 已启用，重置去重标志并
  /// 立即按新模式重推当前歌曲（与 setLyricInfoEnabled 的即时推送行为一致）。
  Future<void> setLyricInfoColorOs(bool enabled) async {
    if (_lyricInfoColorOs == enabled) return;
    _lyricInfoColorOs = enabled;
    if (_lyricInfoEnabled) {
      _lyricInfoPushed = false;
      _maybePushLyricInfo();
    }
    _notify();
  }

  /// SuperLyric 歌词推送开关：独立于悬浮窗/蓝牙歌词/LyricInfo。
  /// 开启后定时器运行以在切歌/行变化时推送当前行；关闭时推一次空歌词清空。
  Future<void> setSuperLyricEnabled(bool enabled) async {
    if (_superLyricEnabled == enabled) return;
    _superLyricEnabled = enabled;
    _bindProvidersFromContext();
    _updateTicker();
    if (enabled) {
      // 开启时若已有当前行立即推送一次（无需等下一个 tick）
      if (_currentLineIndex >= 0 && _currentLineIndex < _lines.length) {
        _pushSuperLyricLine(_lines[_currentLineIndex]);
      } else {
        _pushSuperLyricLine(null);
      }
    } else {
      // 关闭时推一次「仅 title/artist」清空当前歌词
      _pushSuperLyricLine(null);
    }
    _notify();
  }

  /// 锁屏歌词开关：独立于悬浮窗/蓝牙歌词/LyricInfo/SuperLyric。
  /// 开启后定时器运行，推送整首歌词与样式到原生锁屏歌词界面
  /// （LockScreenLyricActivity，锁屏全屏滚动歌词列表）；关闭时关闭该界面。
  Future<void> setLockScreenLyricEnabled(bool enabled) async {
    if (_lockScreenLyricEnabled == enabled) return;
    _lockScreenLyricEnabled = enabled;
    _bindProvidersFromContext();
    _updateTicker();
    if (enabled) {
      // 启用时重置切歌检测状态，让下个 tick 立即拉取歌词并推送
      _currentSongId = null;
      _lines = const [];
      _currentLineIndex = -1;
      _awaitingLyric = false;
      // 锁屏推送状态全部重置，下个 tick 整包重推
      _lockFullDirty = true;
      _lockPlaceholder = '';
      _lockProgressPushMs = 0;
      _lockAccentToken++;
      // 通知原生端开关已开启（原生端后续由 ACTION_SCREEN_OFF 广播拉起界面）
      try {
        await MediaNotificationService.showLockScreenLyric();
      } catch (_) {}
    } else {
      // 关闭时关闭锁屏歌词界面
      try {
        await MediaNotificationService.hideLockScreenLyric();
      } catch (_) {}
    }
    _notify();
  }

  /// AM 歌词偏好变化回调：锁屏歌词样式全部跟随 AM 歌词设置
  /// （字号/行距/字重/字体来源/副行模式/动态取色），偏好一变即整包重推，
  /// 锁屏显示中调整播放页歌词设置即时生效。
  void _onLyricPrefsChangedForLockScreen() {
    if (!_lockScreenLyricEnabled) return;
    _lockFullDirty = true;
    _pushLockScreenFullData();
  }

  /// 推送整首歌词 + 样式到原生锁屏界面（切歌 / 歌词就绪 / 偏好变化时调用）。
  ///
  /// 样式字段取自 [LyricPreferences]（与 AM 播放页 Zen 沉浸模式同源）；
  /// 推送后重置进度节流基线，并异步提取封面主色用于当前行混色。
  void _pushLockScreenFullData() {
    if (!_lockScreenLyricEnabled) return;
    _lockFullDirty = false;
    final prefs = LyricPreferences.instance;
    final player = _player;
    final song = player?.currentSong;
    final displayRoma = prefs.displayMode == LyricDisplayMode.roma;
    final lines = <Map<String, Object?>>[
      for (final line in _lines)
        {
          'text': line.text,
          'start': line.startTime,
          'duration': line.duration,
          'words': line.words.map((w) => w.text).toList(),
          'wordStarts': line.words.map((w) => w.startTime).toList(),
          'wordDurations': line.words.map((w) => w.duration).toList(),
          'sub': displayRoma ? line.roma : line.translation,
        },
    ];
    MediaNotificationService.updateLockScreenLyricData(
      lines: lines,
      placeholder: _lockPlaceholder,
      currentPositionMs: player?.position.inMilliseconds ?? 0,
      durationMs: player?.duration?.inMilliseconds ?? 0,
      isPlaying: player?.isPlaying ?? false,
      title: song?.displayName ?? '',
      artist: song?.artist ?? '',
      artUrl: song?.artworkUri,
      fallbackFilePath: song?.localPath,
      fontSize: prefs.fontSize,
      fontWeight: prefs.fontWeightValue,
      lineHeightMultiplier: prefs.lineHeightMultiplier,
      fontSource: prefs.fontSource.index,
      customFontPath: prefs.customFontPath,
      showTranslation: prefs.showTranslation,
      displayMode: prefs.displayMode.index,
      useDynamicColor: prefs.useDynamicLyricColor,
    );
    _lockProgressPushMs = DateTime.now().millisecondsSinceEpoch;
    _lockLastIsPlaying = player?.isPlaying ?? false;
    _pushLockScreenAccent(song?.artworkUri, prefs.useDynamicLyricColor);
  }

  /// 异步提取封面主色并推送到原生锁屏界面（当前行「85% 白 + 15% 主色」混色）。
  ///
  /// 动态取色关闭或无封面时推 0（原生侧用纯白）。提取结果带令牌校验，
  /// 切歌后回来的旧结果直接丢弃。
  void _pushLockScreenAccent(String? artUrl, bool useDynamic) {
    final token = ++_lockAccentToken;
    if (!useDynamic || artUrl == null || artUrl.isEmpty) {
      MediaNotificationService.updateLockScreenAccent(0);
      return;
    }
    ArtworkColorExtractor.extract(artUrl).then((color) {
      if (token != _lockAccentToken || !_lockScreenLyricEnabled) return;
      MediaNotificationService.updateLockScreenAccent(color?.toARGB32() ?? 0);
    }).catchError((_) {});
  }

  /// 锁屏歌词每 tick 推送入口：全量脏 → 整包重推；否则 500ms 节流轻量进度。
  void _pushLockScreenTick() {
    if (!_lockScreenLyricEnabled) return;
    if (_lockFullDirty) {
      _pushLockScreenFullData();
      return;
    }
    final player = _player;
    if (player == null) return;
    if (player.currentSong == null) return;
    final isPlaying = player.isPlaying;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (isPlaying != _lockLastIsPlaying || nowMs - _lockProgressPushMs >= 500) {
      _lockProgressPushMs = nowMs;
      _lockLastIsPlaying = isPlaying;
      MediaNotificationService.updateLockScreenProgress(
        currentPositionMs: player.position.inMilliseconds,
        durationMs: player.duration?.inMilliseconds ?? 0,
        isPlaying: isPlaying,
      );
    }
  }

  /// 设置共用的推送偏好（翻译/罗马音/优先翻译），并让过滤立即生效：
  /// - SuperLyric：重推当前行
  /// - LyricInfo：重建并重推整首歌词 JSON
  /// （参照 Lyricon repushLastSong 的做法）。
  Future<void> setLyricPushPreferences({
    required bool translation,
    required bool roma,
    required bool preferTranslation,
  }) async {
    final changed = _pushTranslation != translation ||
        _pushRoma != roma ||
        _superLyricPreferTranslation != preferTranslation;
    _pushTranslation = translation;
    _pushRoma = roma;
    _superLyricPreferTranslation = preferTranslation;
    if (!changed) return;
    if (_superLyricEnabled) {
      if (_currentLineIndex >= 0 && _currentLineIndex < _lines.length) {
        await _pushSuperLyricLine(_lines[_currentLineIndex]);
      } else {
        await _pushSuperLyricLine(null);
      }
    }
    if (_lyricInfoEnabled) {
      _lyricInfoPushed = false;
      _maybePushLyricInfo();
    }
  }

  /// 定时器是否需要运行：悬浮窗、蓝牙歌词、LyricInfo、SuperLyric 或锁屏歌词任一开启即需运行
  bool _shouldTick() =>
      _enabled ||
      _bluetoothLyricEnabled ||
      _lyricInfoEnabled ||
      _superLyricEnabled ||
      _lockScreenLyricEnabled;

  /// 根据开关状态启停定时器（250ms tick：逐行歌词足够检测切行）
  void _updateTicker() {
    if (_shouldTick()) {
      _syncTickInterval(_player?.isPlaying ?? false);
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  /// 按播放状态同步 tick 周期：周期未变化时不重建
  void _syncTickInterval(bool playing) {
    final target = playing ? _tickIntervalPlayingMs : _tickIntervalPausedMs;
    if (_ticker != null && _tickIntervalMs == target) return;
    _tickIntervalMs = target;
    _ticker?.cancel();
    _ticker = Timer.periodic(Duration(milliseconds: target), (_) => _onTick());
  }

  /// 行提交后安排一次性 Timer 在下一行起始时刻触发 _onTick，
  /// 让行切换不受 250ms 轮询相位限制。仅播放中调度（暂停时下一行
  /// 永不到来，避免空转；恢复播放后由 250ms tick 兜底提交并重新调度）。
  void _scheduleLineBoundary(int nextIndex) {
    _lineTimer?.cancel();
    _lineTimer = null;
    final player = _player;
    if (player == null || !player.isPlaying) return;
    if (nextIndex >= _lines.length) return;
    final delayMs = _lines[nextIndex].startTime - player.position.inMilliseconds;
    if (delayMs <= 0) return;
    _lineTimer = Timer(Duration(milliseconds: delayMs), _onTick);
  }

  void _cancelLineTimer() {
    _lineTimer?.cancel();
    _lineTimer = null;
  }

  // 上一次下发给原生的「显示大小」档位，用于过滤 ThemeProvider 的其他通知
  // （主题色、背景图等每次变更都会 notify，不必重推悬浮窗配置）。
  double _lastDisplayScale = kDefaultDisplayScale;

  /// 「显示大小」变更 → 重新下发配置，让已显示的悬浮窗歌词立即跟随。
  void _onThemeChanged() {
    final scale = _theme?.displayScale ?? kDefaultDisplayScale;
    if (scale == _lastDisplayScale) return;
    _lastDisplayScale = scale;
    if (!_enabled) return;
    // ignore: discarded_futures
    _pushConfig();
  }

  void _bindProvidersFromContext() {
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null) return;
    try {
      // 玩家监听：仅换实例时重绑，避免每次绑定都重复 addListener
      final player = ctx.read<PlayerProvider>();
      if (player != _player) {
        _player?.removeListener(_onPlayerChanged);
        _player = player;
        player.addListener(_onPlayerChanged);
      }
      _kugou = ctx.read<KugouProvider>();
      final theme = ctx.read<ThemeProvider>();
      if (theme != _theme) {
        _theme?.removeListener(_onThemeChanged);
        _theme = theme;
        _lastDisplayScale = theme.displayScale;
        theme.addListener(_onThemeChanged);
      }
    } catch (_) {}
  }

  // 播放状态翻转 → 推送原生（卡拉OK暂停冻结/恢复续跑的信号源）。
  // 仅翻转时推送，position 刷新触发的 notifyListeners 不受影响。
  // 基线由 _pushPlaying 成功后更新：失败时 tick 自愈会在下个周期重试。
  void _onPlayerChanged() {
    final playing = _player?.isPlaying ?? false;
    if (playing == _lastPushedPlaying) return;
    // ignore: discarded_futures
    _pushPlaying(playing);
    if (playing) {
      // 恢复播放：暂停期 tick 已降频至 1s，立即补一拍对齐当前行与预测调度
      _onTick();
    }
  }

  Future<void> _loadConfig() async {
    _fontSize = await _settings.getDesktopLyricFontSize();
    _doubleLine = await _settings.getDesktopLyricDoubleLine();
    _opacity = await _settings.getDesktopLyricOpacity();
    _gradientStart = await _settings.getDesktopLyricGradientStart();
    _gradientEnd = await _settings.getDesktopLyricGradientEnd();
    _unplayedColor = await _settings.getDesktopLyricUnplayedColor();
    _locked = await _settings.getDesktopLyricLocked();
  }

  Future<void> _pushConfig() async {
    try {
      await _channel.invokeMethod('setDesktopLyricConfig', {
        'fontSize': _fontSize,
        'displayScale': _theme?.displayScale ?? kDefaultDisplayScale,
        'doubleLine': _doubleLine,
        'opacity': _opacity,
        'locked': _locked,
        'gradientStart': _gradientStart,
        'gradientEnd': _gradientEnd,
        'unplayedColor': _unplayedColor,
      });
    } catch (_) {}
  }

  static const _channel = MethodChannel('com.md3music.md3music/floating_lyric');
  static const _superLyricChannel =
      MethodChannel('com.md3music.md3music/super_lyric');

  void _syncCurrentFromPlayer() {
    if (_player == null) return;
    final song = _player!.currentSong;
    if (song != null) {
      if (_currentSongId != song.id) {
        _sessionGeneration++;
        _lyricFetchToken++;
      }
      _currentSongId = song.id;
      _pushProgress(_player!.position, _player!.duration ?? Duration.zero);
      _pushPlaying(_player!.isPlaying);
    }
  }

  Future<void> _pushProgress(Duration pos, Duration dur) async {
    // 仅悬浮窗开启时推送：蓝牙歌词不需要 position/duration（通过 MediaSession 获取），
    // 且避免 startService 触发 FloatingLyricService.onCreate 显示悬浮窗通知
    if (!_enabled) return;
    try {
      await _channel.invokeMethod('updateProgress', {
        'position': pos.inMilliseconds,
        'duration': dur.inMilliseconds,
      });
    } catch (_) {}
  }

  Future<void> _pushPlaying(bool playing) async {
    // 同 _pushProgress：仅悬浮窗开启时推送。
    // 推送成功才更新基线：失败时基线保持旧值，让 tick 自愈机制
    // 在下个周期重试（否则失败后永远不再推送，暂停冻结失效）。
    if (!_enabled) return;
    try {
      await _channel.invokeMethod('setPlaying', {'isPlaying': playing});
      _lastPushedPlaying = playing;
    } catch (_) {}
  }

  void _onTick() {
    if (!_shouldTick()) return;
    // 熄屏且未开锁屏歌词：悬浮窗不可见，tick 纯耗电，直接休眠
    // （点亮屏幕时由 screenStateChanged 回调补一拍对齐漂移）
    if (!_screenOn && !_lockScreenLyricEnabled) {
      _cancelLineTimer();
      return;
    }
    // provider 未绑定时（如 app 启动早期 context 未就绪）尝试重新绑定，
    // 绑定成功后下个 tick 即可正常推送；仍失败则跳过本次
    if (_player == null || _kugou == null) {
      _bindProvidersFromContext();
      if (_player == null || _kugou == null) return;
    }
    // 播放状态自愈：事件驱动的 setPlaying 若曾丢失（channel 异常被吞、
    // 时序竞争），原生 isPlayingFlag 停在 true → 逐字暂停后仍狂奔。
    // 每 tick 与 PlayerProvider 对账，不一致即重推（幂等，开销可忽略）。
    final tickPlaying = _player!.isPlaying;
    if (tickPlaying != _lastPushedPlaying) {
      // ignore: discarded_futures
      _pushPlaying(tickPlaying);
    }
    // 暂停时下一行永不到来：取消预测调度；tick 周期同步降频
    if (!tickPlaying) {
      _cancelLineTimer();
    }
    _syncTickInterval(tickPlaying);
    final song = _player!.currentSong;
    if (song == null) {
      if (_currentSongId != null) _lyricFetchToken++;
      _currentSongId = null;
      _lines = const [];
      _currentLineIndex = -1;
      _cancelLineTimer();
      // 锁屏歌词：清空界面，避免残留上一首歌词
      _markLockLyricLoaded('');
      return;
    }

    // 切歌检测
    if (song.id != _currentSongId) {
      _currentSongId = song.id;
      _sessionGeneration++;
      _lyricFetchToken++;
      _lines = const [];
      _currentLineIndex = -1;
      _lastLineSwitchAt = null;
      _awaitingLyric = false;
      _lastPushedPosMs = null;
      // 新歌立即尝试拉取：清除上一首的失败退避状态
      _lyricFailedKey = null;
      _lyricFailCount = 0;
      _lyricNextRetryAt = null;
      _pushPlaying(_player!.isPlaying);
      _pushLyric('歌词加载中...', '', placeholder: '歌词加载中...');
      // SuperLyric：切歌时立即更新 title/artist（清空上一首歌词）
      if (_superLyricEnabled) {
        _pushSuperLyricLine(null);
      }
      // LyricInfo：切歌时立即移除上一首的 lyricInfo，避免旧歌词短暂匹配到新歌
      if (_lyricInfoEnabled) {
        _lyricInfoPushed = false;
        MediaNotificationService.removeLyricInfo(
          songId: song.id,
          sessionGeneration: _sessionGeneration,
        );
      }
      // 锁屏歌词：切歌时推占位全量数据，避免残留上一首歌词
      _markLockLyricLoaded('歌词加载中...');
      _cancelLineTimer();
      _fetchLyricFor(song);
      return;
    }

    // 歌词加载只由带 token 的请求提交结果，不能直接读取 KugouProvider 的共享
    // current lyric；后者可能正被播放器页或 Lyricon 的另一首请求更新。
    if (!_awaitingLyric && _lines.isEmpty) {
      // 失败退避：同一首歌上次拉取失败且尚未到退避时限时跳过本轮
      if (_lyricNextRetryAt != null &&
          _lyricFailedKey == song.id &&
          DateTime.now().isBefore(_lyricNextRetryAt!)) {
        return;
      }
      _fetchLyricFor(song);
      return;
    }

    // LyricInfo：歌词加载完成后推送一次整首歌词（_lyricInfoPushed 去重）
    _maybePushLyricInfo();

    // Sync progress (500ms throttle)
    final pos = _player!.position;
    final dur = _player!.duration ?? Duration.zero;
    final posMs = pos.inMilliseconds;
    if (_lastPushedPosMs == null || (posMs - _lastPushedPosMs!).abs() > 500) {
      _lastPushedPosMs = posMs;
      _pushProgress(pos, dur);
    }

    // Find current line
    if (_lines.isEmpty) return;
    final newIndex = _findLineIndex(posMs);

    // 行变化时推送（逐行模式：每行只在进入时推一次，不高频刷字色）
    if (newIndex != _currentLineIndex) {
      // P0: 行切换 300ms 迟滞：position 抖动（MediaSession/just_audio 位置源相位差）
      // 会导致行在相邻行间来回跳变、同一行被重复推送（日志实测同一行被推 3~16 次）。
      // 迟滞窗口内保持当前行，稳定后才切换，消除无效推送。
      final now = DateTime.now();
      if (_lastLineSwitchAt != null &&
          now.difference(_lastLineSwitchAt!).inMilliseconds < 300) {
        // 迟滞窗口内：保持当前行，下个 tick 再判定
      } else {
        _lastLineSwitchAt = now;
        _currentLineIndex = newIndex;
        final line = newIndex >= 0 ? _lines[newIndex] : null;
        final current = line?.text ?? '';
        final next = (_doubleLine && newIndex + 1 < _lines.length)
            ? _lines[newIndex + 1].text
            : '';
        // KRC 逐字：行切换时一次推送整行字级时间戳 + 当时的播放位置，
        // 原生按本地时钟自驱动逐字推进（每字边界一次 invalidate），
        // Dart 不再做 100ms 高频推送；LRC/纯文本行 words 为空走整行渐变色
        // （显式标注类型：三元分支与 const [] 的 LUB 是 List<dynamic>，需上下文类型）
        final List<Map<String, Object?>> words = (line != null && line.words.isNotEmpty)
            ? [
                for (final w in line.words)
                  {'t': w.text, 's': w.startTime, 'd': w.duration},
              ]
            : const [];
        _pushLyric(current, next, words: words, positionMs: posMs);
        // SuperLyric：行变化时推送当前行（含逐字 words、翻译、副歌词）
        if (_superLyricEnabled) {
          _pushSuperLyricLine(line);
        }
        // 预测调度：下一行起始时刻精确触发，切行延迟从最坏 250ms 降到 Timer 精度
        if (newIndex + 1 < _lines.length) {
          _scheduleLineBoundary(newIndex + 1);
        }
      }
    }

    // 锁屏歌词：每 tick 入口（全量脏 → 整包重推；否则 500ms 节流轻量进度）
    _pushLockScreenTick();
  }

  Future<void> _fetchLyricFor(Song song) async {
    if (_awaitingLyric) return;
    final requestedSongId = song.id;
    final token = ++_lyricFetchToken;
    _awaitingLyric = true;
    try {
      if (!song.isOnline) {
        final localPath = song.localPath;
        if (localPath != null && localPath.isNotEmpty) {
          String filePath = localPath;
          if (filePath.startsWith('file://')) {
            filePath = Uri.parse(filePath).toFilePath();
          }
          final embedded = LocalLyricLoader.loadForAudio(filePath);
          if (embedded != null && embedded.isNotEmpty) {
            if (!_isCurrentLyricRequest(token, requestedSongId)) return;
            final lines = await parseLyricOffMainThread(embedded);
            // isolate 解析期间可能已切歌：迟到结果直接丢弃
            if (!_isCurrentLyricRequest(token, requestedSongId)) return;
            _lines = lines;
            if (_lines.isEmpty) _pushLyric('暂无歌词', '', placeholder: '暂无歌词');
            _markLockLyricLoaded(_lines.isEmpty ? '暂无歌词' : '');
            return;
          }
        }
      }

      final searchName = song.artist != '未知艺术家'
          ? '${song.title} ${song.artist}'
          : song.title;
      final lyric = await _kugou!.getLyric(
        song.isOnline ? song.id : '',
        songName: searchName,
        fmt: 'lrc',
      );
      if (!_isCurrentLyricRequest(token, requestedSongId)) return;
      _commitFetchedLyric(lyric, token, requestedSongId);
      // 成功拿到歌词（或确认本曲可解析）：清除失败退避状态
      if (lyric != null) {
        _lyricFailedKey = null;
        _lyricFailCount = 0;
        _lyricNextRetryAt = null;
      }
    } catch (_) {
      if (_isCurrentLyricRequest(token, requestedSongId)) {
        _pushLyric('歌词加载失败', '', placeholder: '歌词加载失败');
        _markLockLyricLoaded('歌词加载失败');
        // 记录失败并指数退避（250ms→500ms→1s→2s→…→10s 封顶）
        _lyricFailCount =
            (_lyricFailedKey == requestedSongId) ? _lyricFailCount + 1 : 1;
        _lyricFailedKey = requestedSongId;
        final backoffMs = 250 * (1 << (_lyricFailCount - 1).clamp(0, 6));
        _lyricNextRetryAt =
            DateTime.now().add(Duration(milliseconds: backoffMs.clamp(250, 10000)));
      }
    } finally {
      // 旧请求完成不能把新请求的 awaiting 状态清掉。
      if (token == _lyricFetchToken) _awaitingLyric = false;
    }
  }

  bool _isCurrentLyricRequest(int token, String songId) =>
      token == _lyricFetchToken &&
      _currentSongId == songId &&
      _player?.currentSong?.id == songId;

  Future<void> _commitFetchedLyric(
      dynamic lyric, int token, String requestedSongId) async {
    if (lyric == null || lyric.displayLyric.isEmpty) {
      _pushLyric('暂无歌词', '', placeholder: '暂无歌词');
      _markLockLyricLoaded('暂无歌词');
      // 确认无歌词也进入退避（同失败路径）：否则下个 tick 会再发一次
      // 完整的歌词搜索请求，纯音乐场景形成持续网络风暴。
      _lyricFailCount =
          (_lyricFailedKey == requestedSongId) ? _lyricFailCount + 1 : 1;
      _lyricFailedKey = requestedSongId;
      final backoffMs = 250 * (1 << (_lyricFailCount - 1).clamp(0, 6));
      _lyricNextRetryAt =
          DateTime.now().add(Duration(milliseconds: backoffMs.clamp(250, 10000)));
      return;
    }
    final lines = await parseLyricOffMainThread(
      lyric.displayLyric,
      translationText: lyric.translatedContent,
      romaText: lyric.romaContent,
    );
    // isolate 解析期间可能已切歌：迟到结果直接丢弃
    if (!_isCurrentLyricRequest(token, requestedSongId)) return;
    _lines = lines;
    if (_lines.isEmpty) _pushLyric('暂无歌词', '', placeholder: '暂无歌词');
    _markLockLyricLoaded(_lines.isEmpty ? '暂无歌词' : '');
  }

  int? _lastPushedPosMs;

  /// 推送当前行文本到原生悬浮窗。
  ///
  /// - [placeholder] 非空时原生显示占位文案（歌词加载中.../暂无歌词/歌词加载失败）；
  ///   空串表示正常行：间奏期 current 为空串时原生显示空白，不再误显"加载中"。
  /// - 蓝牙歌词分支保持既有占位过滤行为不变。
  Future<void> _pushLyric(String current, String next,
      {String placeholder = '',
      List<Map<String, Object?>> words = const [],
      int positionMs = 0}) async {
    if (_enabled) {
      try {
        await _channel.invokeMethod('updateLyric', {
          'lyric': current,
          'nextLyric': next,
          'placeholder': placeholder,
          'words': words,
          'positionMs': positionMs,
        });
      } catch (_) {}
    }
    if (_bluetoothLyricEnabled) {
      final btText = (placeholder.isNotEmpty) ? '' : current;
      try {
        await MediaNotificationService.updateBluetoothLyric(btText);
      } catch (_) {}
    }
  }

  /// 推送当前歌词行到 SuperLyric（基于 Binder 的系统级实时歌词 API）。
  ///
  /// [line] 为 null 时只发 title/artist（清空当前歌词，用于切歌/关闭开关）。
  /// 核心字段映射：
  /// - title/artist：取当前歌曲的 displayName（剥后缀）与 artist
  /// - 主行：text + words（逐字）+ startTime/endTime
  /// - translation：翻译（SuperLyricData.setTranslation）
  /// - roma：副歌词（SuperLyricData.setSecondary）
  /// 播放/暂停由 SuperLyric 自动监听 App 的 MediaSession 处理，这里不推停止事件。
  Future<void> _pushSuperLyricLine(LyricLine? line) async {
    if (_player == null) return;
    final song = _player!.currentSong;
    if (song == null) return;

    final Map<String, dynamic> args = {
      'title': song.displayName,
      'artist': song.artist,
    };
    if (line != null) {
      final text = line.text.trim();
      if (text.isNotEmpty) {
        final int startTime = line.startTime;
        // endTime 兜底：LRC duration=0 时 endTime==startTime，补一个合法 end（参照 Lyricon）
        final int endTime =
            line.endTime > startTime ? line.endTime : startTime + 5000;
        // 同时存在翻译和罗马音时按偏好二选一（参照 Lyricon preferTranslation），
        // 避免 SuperLyric 接收端优先显示 secondary(roma) 导致"总是罗马音"。
        // 翻译/罗马音还受共用开关 _pushTranslation / _pushRoma 控制。
        final hasTranslation = _pushTranslation &&
            line.translation != null &&
            line.translation!.isNotEmpty;
        final hasRoma =
            _pushRoma && line.roma != null && line.roma!.isNotEmpty;
        final translationValue =
            hasTranslation && hasRoma && !_superLyricPreferTranslation
                ? null
                : line.translation;
        final romaValue =
            hasRoma && hasTranslation && _superLyricPreferTranslation
                ? null
                : line.roma;
        args.addAll({
          'text': text,
          'startTime': startTime,
          'endTime': endTime,
          'words': line.words
              .map((w) => <String, dynamic>{
                    'text': w.text,
                    'start': w.startTime,
                    'end': w.startTime + w.duration,
                  })
              .toList(),
          if (translationValue != null && translationValue.isNotEmpty)
            'translation': translationValue,
          if (romaValue != null && romaValue.isNotEmpty) 'roma': romaValue,
        });
      }
    }
    try {
      await _superLyricChannel.invokeMethod('sendLyric', args);
    } catch (_) {}
  }

  /// 歌词加载结果已落入 [_lines]：更新锁屏占位状态并立即整包重推。
  ///
  /// [placeholder] 非空时无歌词列表、锁屏居中显示占位文本
  /// （歌词加载中.../暂无歌词/歌词加载失败）；空串表示正常显示列表。
  void _markLockLyricLoaded(String placeholder) {
    if (!_lockScreenLyricEnabled) return;
    _lockPlaceholder = placeholder;
    _lockFullDirty = true;
    _pushLockScreenFullData();
  }

  /// LyricInfo：歌词就绪后推送一次整首歌词（_lyricInfoPushed 去重，每首歌 1 次）。
  /// 仅在 [_pushLyricInfo] 真正完成推送后才置位去重标志：若中途因无歌/空行等提前
  /// 返回，则保持 false 让后续 tick 重试，避免该曲 lyricInfo 永久丢失。
  void _maybePushLyricInfo() {
    if (!_lyricInfoEnabled || _lyricInfoPushed) return;
    if (_lines.isEmpty) return;
    if (_pushLyricInfo()) {
      _lyricInfoPushed = true;
    }
  }

  /// 构造并推送 lyricInfo JSON。
  ///
  /// colorOsMode=false（默认）：兼容 LyricInfo 模块（HyperLyric 等）标准格式，
  /// lyric=ELRC 逐字 + format/translation 声明；
  /// colorOsMode=true：兼容 ColorOS-Live-Lyrics-Bridge 开放协议，
  /// lyric=纯 LRC + rawLyric=ELRC 逐字，解锁插件逐字高亮等增强。
  /// 返回是否真正发起了推送（供 _maybePushLyricInfo 决定是否置位去重标志）。
  bool _pushLyricInfo() {
    if (!_lyricInfoEnabled || _player == null) return false;
    final song = _player!.currentSong;
    if (song == null) return false;

    final json = buildLyricInfoJson(
      songName: song.displayName,
      artist: song.artist,
      songId: song.id,
      album: song.album,
      trackKey:
          '${song.id}|${song.displayName}|${song.artist}|${song.duration.inSeconds}',
      sessionGeneration: _sessionGeneration,
      lines: _lines,
      includeTranslation: _pushTranslation,
      colorOsMode: _lyricInfoColorOs,
    );
    if (json.isEmpty) return false; // 无有效歌词行：不推送（保持移除状态）

    MediaNotificationService.updateLyricInfo(
      jsonEncode(json),
      songId: song.id,
      sessionGeneration: _sessionGeneration,
      hasTranslation: hasPushableTranslation(
        _lines,
        includeTranslation: _pushTranslation,
      ),
    );
    return true;
  }

  /// 二分查找当前播放位置对应的歌词行 index。
  ///
  /// _lines 已按 startTime 升序排列（LyricParserChain 保证），
  /// 找到最后一个 startTime <= posMs 的行。
  int _findLineIndex(int posMs) {
    int lo = 0;
    int hi = _lines.length - 1;
    int idx = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (_lines[mid].startTime <= posMs) {
        idx = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return idx;
  }
}
