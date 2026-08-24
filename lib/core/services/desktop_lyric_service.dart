import 'dart:async';
import 'dart:convert';

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
import '../../core/utils/audio_scanner.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import '../../widgets/apple_lyrics/parsers/lyric_parser_chain.dart';
import 'media_notification_service.dart';

/// 桌面歌词服务：管理开关、解析歌词（KRC/LRC/纯文本）、按播放位置同步到原生悬浮窗。
///
/// **关键修复**：之前用 `displayLyric`（KRC 优先）+ LRC 正则解析，导致 KRC 文本
/// 解析全部失败、悬浮窗永远显示「暂无歌词」。现改用 [LyricParserChain.parse]
/// 自动识别 KRC/LRC/纯文本，输出统一 [LyricLine] 列表。
///
/// **逐字支持**：KRC 解析后每行携带 [LyricWord] 字级时间戳，本服务按当前播放
/// 位置计算已唱字数 `sungCharCount`，通过 `updateLyric` 通道传给原生悬浮窗，
/// 原生侧用 clipRect 实现已唱/未唱二分色。LRC/纯文本无字时间戳时传 -1，
/// 原生侧走整行渐变色（保持原行为）。
class DesktopLyricService {
  static final DesktopLyricService instance = DesktopLyricService._();
  DesktopLyricService._();

  PlayerProvider? _player;
  KugouProvider? _kugou;
  // 「显示大小」：悬浮窗是原生 overlay、不在 Flutter 树里，DisplayScaleScope
  // 够不到它，所以把档位随配置下发给原生，由它乘在歌词字号上。
  ThemeProvider? _theme;
  final SettingsRepository _settings = SettingsRepository();

  bool _enabled = false;
  bool get enabled => _enabled;

  // 蓝牙歌词开关：独立于悬浮窗。开启时定时器同样运行，但只推送蓝牙歌词通道，
  // 不弹出悬浮窗。元数据替换（title→歌词，artist→「作者 - 标题」）由原生端处理。
  bool _bluetoothLyricEnabled = false;
  bool get bluetoothLyricEnabled => _bluetoothLyricEnabled;

  // LyricInfo 歌词转发开关：通过 MediaSession extras.lyricInfo 发布整首歌词
  // （LRC/ELRC），供 ColorOS 桌面歌词 / LyricInfo 模块等第三方系统读取。
  // 复用本服务的定时器与歌词解析管线，歌词加载完成后构造 JSON 推送一次。
  bool _lyricInfoEnabled = false;
  bool get lyricInfoEnabled => _lyricInfoEnabled;
  // 当前歌曲是否已推送过 lyricInfo（避免每 250ms tick 重复推送）
  bool _lyricInfoPushed = false;

  // 锁屏歌词开关：独立于悬浮窗/蓝牙歌词/LyricInfo。开启时定时器运行
  // 以获取当前行逐字数据，推送原生 LockScreenLyricActivity（锁屏全屏歌词）。
  bool _lockScreenLyricEnabled = false;
  bool get lockScreenLyricEnabled => _lockScreenLyricEnabled;

  // 锁屏歌词独立字体（设置页可单独调；启动时从 SettingsRepository 恢复）
  double _lockScreenFontSize = 22;
  int _lockScreenFontWeight = 400;

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
  String? _currentLrcText;
  // 解析后的歌词行列表（统一模型，KRC 含 words，LRC/纯文本 words 为空）
  List<LyricLine> _lines = const [];
  int _currentLineIndex = -1;
  // 行切换迟滞时间戳：position 抖动时抑制行来回跳变、重复推送（蓝牙歌词高频刷新根因之一）
  DateTime? _lastLineSwitchAt;
  Timer? _ticker;
  bool _awaitingLyric = false;

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
    _bindProvidersFromContext();
    if (_player == null || _kugou == null) {
      return;
    }
    _enabled = true;
    await _loadConfig();
    final ok = await MediaNotificationService.hasOverlayPermission();
    if (!ok) {
      try {
        await MediaNotificationService.startFloatingLyric(lyric: '', title: '');
      } catch (_) {}
    } else {
      try {
        await MediaNotificationService.startFloatingLyric(lyric: '', title: '');
      } catch (_) {}
    }
    await _pushConfig();
    _syncCurrentFromPlayer();
    _updateTicker();
    _notify();
  }

  Future<void> disable() async {
    if (!_enabled) return;
    _enabled = false;
    _updateTicker();
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
      _currentLrcText = null;
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
  /// 开启后定时器运行以推送当前行逐字数据到原生锁屏歌词界面
  /// （LockScreenLyricActivity，锁屏全屏显示）；关闭时关闭该界面。
  Future<void> setLockScreenLyricEnabled(bool enabled) async {
    if (_lockScreenLyricEnabled == enabled) return;
    _lockScreenLyricEnabled = enabled;
    _bindProvidersFromContext();
    _updateTicker();
    if (enabled) {
      // 启用时重置切歌检测状态，让下个 tick 立即拉取歌词并推送
      _currentSongId = null;
      _currentLrcText = null;
      _lines = const [];
      _currentLineIndex = -1;
      _awaitingLyric = false;
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

  /// 锁屏歌词字号（独立于 App 内歌词，设置页可单独调）。
  void setLockScreenLyricFontSize(double v) {
    _lockScreenFontSize = v;
  }

  /// 锁屏歌词粗细（独立于 App 内歌词，设置页可单独调）。
  void setLockScreenLyricFontWeight(int v) {
    _lockScreenFontWeight = v;
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
      _ticker?.cancel();
      _ticker = Timer.periodic(
        const Duration(milliseconds: 250),
        (_) => _onTick(),
      );
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
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
      _player = ctx.read<PlayerProvider>();
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
    // 同 _pushProgress：仅悬浮窗开启时推送
    if (!_enabled) return;
    try {
      await _channel.invokeMethod('setPlaying', {'isPlaying': playing});
    } catch (_) {}
  }

  void _onTick() {
    if (!_shouldTick()) return;
    // provider 未绑定时（如 app 启动早期 context 未就绪）尝试重新绑定，
    // 绑定成功后下个 tick 即可正常推送；仍失败则跳过本次
    if (_player == null || _kugou == null) {
      _bindProvidersFromContext();
      if (_player == null || _kugou == null) return;
    }
    final song = _player!.currentSong;
    if (song == null) {
      _currentSongId = null;
      _currentLrcText = null;
      _lines = const [];
      _currentLineIndex = -1;
      // 锁屏歌词：清空界面，避免残留上一首歌词
      if (_lockScreenLyricEnabled) {
        MediaNotificationService.updateLockScreenLyric(
          lineText: '',
          prevText: '',
          nextText: '',
          words: const [],
          wordStartTimes: const [],
          wordDurations: const [],
          currentPositionMs: 0,
          durationMs: 0,
          isPlaying: false,
          title: '',
          artist: '',
        );
      }
      return;
    }

    // 切歌检测
    if (song.id != _currentSongId) {
      _currentSongId = song.id;
      _currentLrcText = null;
      _lines = const [];
      _currentLineIndex = -1;
      _lastLineSwitchAt = null;
      _awaitingLyric = false;
      _lastPushedPosMs = null;
      _pushPlaying(_player!.isPlaying);
      _pushLyric('歌词加载中...', '', -1);
      // SuperLyric：切歌时立即更新 title/artist（清空上一首歌词）
      if (_superLyricEnabled) {
        _pushSuperLyricLine(null);
      }
      // LyricInfo：切歌时立即移除上一首的 lyricInfo，避免旧歌词短暂匹配到新歌
      if (_lyricInfoEnabled) {
        _lyricInfoPushed = false;
        MediaNotificationService.removeLyricInfo();
      }
      // 锁屏歌词：切歌时推占位文本，避免残留上一首歌词
      if (_lockScreenLyricEnabled) {
        MediaNotificationService.updateLockScreenLyric(
          lineText: '歌词加载中...',
          prevText: '',
          nextText: '',
          words: const [],
          wordStartTimes: const [],
          wordDurations: const [],
          currentPositionMs: _player!.position.inMilliseconds,
          durationMs: _player!.duration?.inMilliseconds ?? 0,
          isPlaying: _player!.isPlaying,
          title: song.displayName,
          artist: song.artist,
        );
      }
      _fetchLyricFor(song);
      return;
    }

    // 拉取/解析歌词（修复：用 LyricParserChain 自动识别 KRC/LRC/纯文本）
    if (!_awaitingLyric && _lines.isEmpty) {
      // 本地歌曲优先读取内嵌歌词
      if (song is Song && !song.isOnline) {
        final localPath = song.localPath;
        if (localPath != null && localPath.isNotEmpty) {
          String filePath = localPath;
          if (filePath.startsWith('file://')) {
            filePath = Uri.parse(filePath).toFilePath();
          }
          final embedded = readEmbeddedLyrics(filePath);
          if (embedded != null && embedded.isNotEmpty) {
            _currentLrcText = embedded;
            _lines = LyricParserChain.parse(embedded);
            if (_lines.isEmpty) {
              _pushLyric('暂无歌词', '', -1);
            }
          }
        }
      }

      // 内嵌歌词为空时从酷狗 API 获取
      if (_lines.isEmpty) {
        final lyric = _kugou!.lyric;
        if (lyric != null && lyric.displayLyric.isNotEmpty) {
          final lrc = lyric.displayLyric;
          if (lrc != _currentLrcText) {
            _currentLrcText = lrc;
            _lines = LyricParserChain.parse(
              lrc,
              translationText: lyric.translatedContent,
              romaText: lyric.romaContent,
            );
            if (_lines.isEmpty) {
              _pushLyric('暂无歌词', '', -1);
            }
          }
        } else if (song.id.isNotEmpty) {
          _fetchLyricFor(song);
          return;
        }
      }
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
        final current = newIndex >= 0 ? _lines[newIndex].text : '';
        final next = (_doubleLine && newIndex + 1 < _lines.length)
            ? _lines[newIndex + 1].text
            : '';
        // sungCharCount 固定 -1：不启用逐字二分色，原生侧走整行渐变色（避免 100ms invalidate 卡顿）
        _pushLyric(current, next, -1);
        // SuperLyric：行变化时推送当前行（含逐字 words、翻译、副歌词）
        if (_superLyricEnabled) {
          _pushSuperLyricLine(newIndex >= 0 ? _lines[newIndex] : null);
        }
      }
    }

    // 锁屏歌词：每 tick 推送当前行逐字数据（不依赖行切换，逐字连续更新）
    _pushLockScreenLyric();
  }

  Future<void> _fetchLyricFor(dynamic song) async {
    if (_awaitingLyric || song == null) return;
    _awaitingLyric = true;
    try {
      // 本地歌曲优先读取内嵌歌词
      if (song is Song && !song.isOnline) {
        final localPath = song.localPath;
        if (localPath != null && localPath.isNotEmpty) {
          String filePath = localPath;
          if (filePath.startsWith('file://')) {
            filePath = Uri.parse(filePath).toFilePath();
          }
          final embedded = readEmbeddedLyrics(filePath);
          if (embedded != null && embedded.isNotEmpty) {
            // 内嵌歌词已在 _onTick 中解析，此处仅标记不需要 API 获取
            return;
          }
        }
        // 内嵌歌词为空，用空 hash + 关键词搜索酷狗歌词
        final searchName = song.artist != '未知艺术家'
            ? '${song.title} ${song.artist}'
            : song.title;
        await _kugou!.getLyric('', songName: searchName, fmt: 'lrc');
      } else {
        // 在线歌曲用 song.id 作为 hash；搜索词与播放器页面 full_player 保持一致（歌名+歌手），
        // 确保桌面歌词与播放器页面命中同一版本歌词。
        final searchName = song.artist != '未知艺术家'
            ? '${song.title} ${song.artist}'
            : song.title;
        await _kugou!.getLyric(song.id, songName: searchName, fmt: 'lrc');
      }
    } catch (_) {
      _pushLyric('歌词加载失败', '', -1);
    } finally {
      _awaitingLyric = false;
    }
  }

  int? _lastPushedPosMs;

  /// 推送当前行文本到原生悬浮窗。
  ///
  /// - [sungCharCount] 始终传 -1（逐行模式，不启用逐字二分色）
  ///   原生侧 GradientTextView.onDraw 走 LRC/纯文本分支，整行渐变色
  ///   历史参数保留是为了不破坏 MethodChannel 协议，原生侧会忽略 -1
  Future<void> _pushLyric(String current, String next, int sungCharCount) async {
    // 悬浮窗：仅在 _enabled 时推送
    if (_enabled) {
      try {
        await _channel.invokeMethod('updateLyric', {
          'lyric': current,
          'nextLyric': next,
          'sungCharCount': sungCharCount,
        });
      } catch (_) {}
    }
    // 蓝牙歌词：仅在 _bluetoothLyricEnabled 时推送。
    // 过滤占位文本：悬浮窗显示「歌词加载中...」等提示，但蓝牙歌词应推送空串，
    // 让原生端恢复原始 title/artist，避免车机闪烁占位文本。
    if (_bluetoothLyricEnabled) {
      final btText = (current == '歌词加载中...' ||
              current == '暂无歌词' ||
              current == '歌词加载失败')
          ? ''
          : current;
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

  /// 推送当前行逐字数据到原生锁屏歌词界面（LockScreenLyricActivity）。
  ///
  /// 每 tick（250ms）调用一次，逐字连续更新；原生侧 Choreographer 帧循环
  /// 在两次推送之间按真实时间平滑推进位置。LRC/纯文本（words 为空）时
  /// 原生侧整行显示。上一行/下一行传纯文本用于上下文展示。
  void _pushLockScreenLyric() {
    if (!_lockScreenLyricEnabled) return;
    if (_player == null) return;
    final song = _player!.currentSong;
    if (song == null) return;
    final posMs = _player!.position.inMilliseconds;
    final idx = _findLineIndex(posMs);
    if (idx < 0 || idx >= _lines.length) return;
    final line = _lines[idx];
    // 上一行 / 下一行纯文本（无字级）
    final prev = idx > 0 ? _lines[idx - 1].text : '';
    final next = idx + 1 < _lines.length ? _lines[idx + 1].text : '';
    MediaNotificationService.updateLockScreenLyric(
      lineText: line.text,
      prevText: prev,
      nextText: next,
      words: line.words.map((w) => w.text).toList(),
      wordStartTimes: line.words.map((w) => w.startTime).toList(),
      wordDurations: line.words.map((w) => w.duration).toList(),
      currentPositionMs: posMs,
      durationMs: _player!.duration?.inMilliseconds ?? 0,
      isPlaying: _player!.isPlaying,
      title: song.displayName,
      artist: song.artist,
      // 锁屏背景模糊封面：在线取封面 URL，本地取音频路径（读内嵌封面）
      artUrl: song.artworkUri,
      fallbackFilePath: song.localPath,
      // 锁屏歌词独立字体（设置页可单独调，默认跟随 AM 歌词偏好）
      fontSize: _lockScreenFontSize,
      fontWeight: _lockScreenFontWeight,
    );
  }

  /// LyricInfo：歌词就绪后推送一次整首歌词（_lyricInfoPushed 去重，每首歌 1 次）。
  void _maybePushLyricInfo() {
    if (!_lyricInfoEnabled || _lyricInfoPushed) return;
    if (_lines.isEmpty) return;
    _lyricInfoPushed = true;
    _pushLyricInfo();
  }

  /// 构造并推送 lyricInfo JSON（LyricInfo 协议标准格式）。
  ///
  /// 写入 MediaSession extras.lyricInfo，供第三方系统读取。
  /// 遵循 LyricInfo 模块（HyperLyric 等）标准格式：
  /// - lyric：ELRC 逐字（[行时间]<字时间>字<字时间>字...），无逐字的行整行作一个词
  /// - format："elrc"（消费方据此启用逐字解析，否则按纯 LRC 处理）
  /// - translation："lrc"（存在翻译行时设置；翻译行为与主行相同时间戳的 LRC 行，
  ///   消费方据此把相邻同时间戳行识别为翻译）
  void _pushLyricInfo() {
    if (!_lyricInfoEnabled || _player == null) return;
    final song = _player!.currentSong;
    if (song == null) return;

    final lyricBuf = StringBuffer();
    var hasTranslation = false;
    for (final line in _lines) {
      if (line.text.isEmpty) continue;
      // 主行：ELRC 逐字（有字级时间戳用逐字，否则整行作一个词）
      lyricBuf.write(_lrcTagMs(line.startTime));
      if (line.hasWordTiming) {
        for (final w in line.words) {
          lyricBuf
            ..write(_elrcWordTag(w.startTime))
            ..write(w.text);
        }
      } else {
        lyricBuf
          ..write(_elrcWordTag(line.startTime))
          ..write(line.text);
      }
      lyricBuf.write('\n');
      // 翻译行：与主行相同时间戳的 LRC 行（HyperLyric 据此识别翻译）
      // 受共用"翻译歌词"开关 _pushTranslation 控制
      final t = _pushTranslation ? line.translation : null;
      if (t != null && t.isNotEmpty) {
        hasTranslation = true;
        lyricBuf
          ..write(_lrcTagMs(line.startTime))
          ..write(t)
          ..write('\n');
      }
    }

    if (lyricBuf.isEmpty) {
      // 无有效歌词行：不推送（保持移除状态）
      return;
    }

    final lyricOut = lyricBuf.toString().trimRight();
    final json = jsonEncode({
      'songName': song.displayName,
      'artist': song.artist,
      'songId': song.id,
      'lyric': lyricOut,
      'format': 'elrc',
      if (hasTranslation) 'translation': 'lrc',
    });
    MediaNotificationService.updateLyricInfo(json);
  }

  /// 毫秒 → LRC 行级时间标签 [mm:ss.xxx]
  static String _lrcTagMs(int ms) {
    final m = ms ~/ 60000;
    final s = (ms % 60000) ~/ 1000;
    final msPart = ms % 1000;
    return '[${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}.${msPart.toString().padLeft(3, '0')}]';
  }

  /// 毫秒 → ELRC 词级时间标签 <mm:ss.xxx>
  static String _elrcWordTag(int ms) {
    final m = ms ~/ 60000;
    final s = (ms % 60000) ~/ 1000;
    final msPart = ms % 1000;
    return '<${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}.${msPart.toString().padLeft(3, '0')}>';
  }

  /// 二分查找当前播放位置对应的歌词行 index。
  ///
  /// _lines 已按 startTime 升序排列（LyricParserChain 保证），
  /// 找到最后一个 startTime <= posMs 的行。
  int _findLineIndex(int posMs) {
    int idx = -1;
    for (int i = 0; i < _lines.length; i++) {
      if (posMs >= _lines[i].startTime) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }
}
