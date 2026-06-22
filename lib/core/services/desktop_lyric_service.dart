import 'dart:async';

import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/repositories/settings_repository.dart';
import '../../main.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import 'media_notification_service.dart';

/// 桌面歌词服务：管理开关、解析 LRC、按播放位置同步到原生悬浮窗。
/// 设置面板已内嵌到原生悬浮窗，Dart 端不再弹 dialog。
class DesktopLyricService {
  static final DesktopLyricService instance = DesktopLyricService._();
  DesktopLyricService._();

  PlayerProvider? _player;
  KugouProvider? _kugou;
  final SettingsRepository _settings = SettingsRepository();

  bool _enabled = false;
  bool get enabled => _enabled;

  String? _currentSongId;
  String? _currentLrcText;
  List<_LyricLine> _lines = const [];
  int _currentLineIndex = -1;
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

  // 通知外部状态变化（让 mini_player 等可以监听刷新）
  final List<VoidCallback> _listeners = [];
  void addListener(VoidCallback cb) => _listeners.add(cb);
  void removeListener(VoidCallback cb) => _listeners.remove(cb);
  void _notify() {
    for (final cb in List.of(_listeners)) {
      cb();
    }
  }

  static final RegExp _lrcLine = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)');

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
    _ticker?.cancel();
    _ticker = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _onTick(),
    );
    _notify();
  }

  Future<void> disable() async {
    if (!_enabled) return;
    _enabled = false;
    _ticker?.cancel();
    _ticker = null;
    try {
      await MediaNotificationService.stopFloatingLyric();
    } catch (_) {}
    _notify();
  }

  void _bindProvidersFromContext() {
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null) return;
    try {
      _player = ctx.read<PlayerProvider>();
      _kugou = ctx.read<KugouProvider>();
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
    try {
      await _channel.invokeMethod('updateProgress', {
        'position': pos.inMilliseconds,
        'duration': dur.inMilliseconds,
      });
    } catch (_) {}
  }

  Future<void> _pushPlaying(bool playing) async {
    try {
      await _channel.invokeMethod('setPlaying', {'isPlaying': playing});
    } catch (_) {}
  }

  void _onTick() {
    if (!_enabled || _player == null || _kugou == null) return;
    final song = _player!.currentSong;
    if (song == null) {
      _currentSongId = null;
      _currentLrcText = null;
      _lines = const [];
      _currentLineIndex = -1;
      return;
    }

    // 切歌检测
    if (song.id != _currentSongId) {
      _currentSongId = song.id;
      _currentLrcText = null;
      _lines = const [];
      _currentLineIndex = -1;
      _awaitingLyric = false;
      _lastPushedPosMs = null;
      _pushPlaying(_player!.isPlaying);
      _pushLyric('歌词加载中...', '');
      _fetchLyricFor(song);
      return;
    }

    // 拉取/解析歌词
    if (!_awaitingLyric && _lines.isEmpty) {
      final lyric = _kugou!.lyric;
      if (lyric != null && lyric.displayLyric.isNotEmpty) {
        final lrc = lyric.displayLyric;
        if (lrc != _currentLrcText) {
          _currentLrcText = lrc;
          _lines = _parseLrc(lrc);
          if (_lines.isEmpty) {
            _pushLyric('暂无歌词', '');
          }
        }
      } else if (song.id.isNotEmpty) {
        _fetchLyricFor(song);
        return;
      }
    }

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
    final newIndex = _findLineIndex(pos);
    if (newIndex != _currentLineIndex) {
      _currentLineIndex = newIndex;
      final current = newIndex >= 0 ? _lines[newIndex].text : '';
      final next = (_doubleLine && newIndex + 1 < _lines.length)
          ? _lines[newIndex + 1].text
          : '';
      _pushLyric(current, next);
    }
  }

  Future<void> _fetchLyricFor(dynamic song) async {
    if (_awaitingLyric || song == null) return;
    _awaitingLyric = true;
    try {
      await _kugou!.getLyric(song.id, songName: song.title, fmt: 'lrc');
    } catch (_) {
      _pushLyric('歌词加载失败', '');
    } finally {
      _awaitingLyric = false;
    }
  }

  int? _lastPushedPosMs;

  Future<void> _pushLyric(String current, String next) async {
    try {
      await _channel.invokeMethod('updateLyric', {
        'lyric': current,
        'nextLyric': next,
      });
    } catch (_) {}
  }

  List<_LyricLine> _parseLrc(String lrc) {
    final result = <_LyricLine>[];
    for (final raw in lrc.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final m = _lrcLine.firstMatch(line);
      if (m == null) continue;
      final mm = int.parse(m.group(1)!);
      final ss = int.parse(m.group(2)!);
      final ff = int.parse(m.group(3)!);
      final ms = m.group(3)!.length == 2 ? ff * 10 : ff;
      final text = m.group(4)!.trim();
      if (text.isEmpty) continue;
      final ts = Duration(minutes: mm, seconds: ss, milliseconds: ms);
      result.add(_LyricLine(ts, text));
    }
    result.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return result;
  }

  int _findLineIndex(Duration position) {
    int idx = -1;
    for (int i = 0; i < _lines.length; i++) {
      if (position >= _lines[i].timestamp) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }
}

class _LyricLine {
  final Duration timestamp;
  final String text;
  _LyricLine(this.timestamp, this.text);
}
