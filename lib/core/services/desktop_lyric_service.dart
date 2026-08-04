import 'dart:async';

import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/repositories/settings_repository.dart';
import '../../data/models/song.dart';
import '../../main.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../core/utils/audio_scanner.dart';
import '../../widgets/apple_lyrics/models/lyric_line.dart';
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
  final SettingsRepository _settings = SettingsRepository();

  bool _enabled = false;
  bool get enabled => _enabled;

  // 蓝牙歌词开关：独立于悬浮窗。开启时定时器同样运行，但只推送蓝牙歌词通道，
  // 不弹出悬浮窗。元数据替换（title→歌词，artist→「作者 - 标题」）由原生端处理。
  bool _bluetoothLyricEnabled = false;
  bool get bluetoothLyricEnabled => _bluetoothLyricEnabled;

  String? _currentSongId;
  String? _currentLrcText;
  // 解析后的歌词行列表（统一模型，KRC 含 words，LRC/纯文本 words 为空）
  List<LyricLine> _lines = const [];
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

  /// 定时器是否需要运行：悬浮窗或蓝牙歌词任一开启即需运行
  bool _shouldTick() => _enabled || _bluetoothLyricEnabled;

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
      _pushLyric('歌词加载中...', '', -1);
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
      _currentLineIndex = newIndex;
      final current = newIndex >= 0 ? _lines[newIndex].text : '';
      final next = (_doubleLine && newIndex + 1 < _lines.length)
          ? _lines[newIndex + 1].text
          : '';
      // sungCharCount 固定 -1：不启用逐字二分色，原生侧走整行渐变色（避免 100ms invalidate 卡顿）
      _pushLyric(current, next, -1);
    }
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
        // 在线歌曲用 song.id 作为 hash
        await _kugou!.getLyric(song.id, songName: song.title, fmt: 'lrc');
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
