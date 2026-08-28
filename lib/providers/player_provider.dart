import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:just_audio/just_audio.dart' as just_audio;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/services/audio_service.dart';
import '../core/services/audio_service_io.dart' hide AudioService, createAudioSource;
import '../core/services/desktop_lyric_service.dart';
import '../core/services/home_widget_service.dart';
import '../core/services/lyricon_provider_service.dart';
import '../core/services/listening_grade_service.dart';
import '../core/services/media_notification_service.dart';
import '../core/services/wakelock_service.dart';
import '../core/services/media_store_service.dart';
import '../core/services/usb_audio_service.dart';
import '../data/models/song.dart';
import '../modules/player/comments_view.dart';
import '../modules/player/mv_player_page.dart';
import '../core/utils/audio_scanner.dart';
import '../data/repositories/history_repository.dart';
import '../data/repositories/player_state_repository.dart';
import '../data/repositories/settings_repository.dart';
import '../main.dart';
import '../services/kugou_server.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import '../widgets/apple_lyrics/parsers/lyric_parser_chain.dart';
import 'favorites_provider.dart';
import 'kugou_provider.dart';
import '../services/kugou_api/kugou_api_client.dart';
import '../services/kugou_api/kugou_models.dart';

enum AppLoopMode { off, one, all }

enum AudioQuality {
  standard('128', '标准音质'),
  high('320', '高音质'),
  flac('flac', '无损音质'),
  hires('high', 'Hi-Res 无损');

  const AudioQuality(this.value, this.label);
  final String value;
  final String label;
}

/// 旧版本 SharedPreferences 中存储的音质值 → 当前 AudioQuality.value 映射。
/// 升级后首次读取时自动转换，避免遗留值导致回退到标准音质。
/// 注意：高音质的 API 码是 '320'（KuGou SongQuality 合法值），
/// 早期版本误用 'hq'，这里把遗留的 'hq' 映射到 '320'。
const _legacyQualityMap = <String, String>{
  'hq': '320',
  'sq': 'flac',
  'standard': '128',
  'hires': 'high',
};

class PlayerProvider extends ChangeNotifier with WidgetsBindingObserver {
  // 播放源开始/停止时的旁路回调。公开构建不注入，均为空操作。
  static Future<String?> Function(String hash, String quality)?
      resolveLocalAudioPath;
  static Future<String?> Function(String hash)? resolveLocalArtworkPath;
  static void Function(Song song, String quality, String url)?
      onPlaybackSourceStarted;
  static void Function(String hash)? onPlaybackSourceStopped;
  static Future<String?> Function(String hash, String audioUrl)?
      extractEmbeddedArtwork;

  Song? _currentSong;
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration? _duration;
  List<Song> _playlist = [];
  List<Song> _originalPlaylist = [];
  int _currentIndex = -1;
  AppLoopMode _loopMode = AppLoopMode.off;
  bool _shuffleEnabled = false;
  double _volume = 1.0;
  double _speed = 1.0;
  bool _isResolvingUrl = false;
  String? _resolveError;
  AudioQuality _audioQuality = AudioQuality.standard;
  // 当前网络是否为 WiFi（移动数据等非 Wi-Fi 视为 false）。默认 true：
  // 启动瞬间网络未就绪/桌面开发环境等无蜂窝网时按 WiFi 音质取，随后由
  // 网络探测/监听刷新。
  bool _isWifiNetwork = true;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  // 当前在线歌曲实际播放的音质标签（降级后可能与用户设置不同）。
  // 每次成功获取播放链接时由 result.quality 更新；切歌或切换音质时重置。
  String? _actualPlayingQuality;

  // —— 睡眠定时（到点自动暂停） ——
  // 用 wall clock（DateTime.now()）计算剩余时间，避免 Timer 漂移；
  // App 被杀后失效（无后台服务），符合"不持久化"决策。
  DateTime? _sleepTimerEndTime;
  Timer? _sleepTimerTicker;

  // —— 在线歌曲异常结束重试限制 ——
  // 当在线歌曲播放不足 80% 就触发 completed 时（URL 过期 / 流中断），
  // 最多重试 _maxAbnormalRetries 次；超过后跳过该歌曲，避免死循环。
  static const int _maxAbnormalRetries = 3;
  int _abnormalEndRetries = 0;
  // 记录正在重试的歌曲 ID，切歌后自动重置计数器
  String? _retryingSongId;

  // —— 交叉淡化（crossfade）——
  // 自然播完前 _crossfadeDuration 秒开始：本首等功率渐出、下一首等功率渐入，
  // 两路音频由 AudioService 的主/辅播放器真实叠加。
  // 设置值缓存在字段里：判定发生在 positionStream（~200ms）这样的高频路径上，
  // 不能每次都 await SharedPreferences。
  bool _crossfadeEnabled = false;
  Duration _crossfadeDuration = const Duration(
    seconds: SettingsRepository.kCrossfadeDefaultSeconds,
  );

  /// 正在解析/预加载下一首（避免同一时间重入）。
  bool _crossfadePreparing = false;

  /// 正在执行淡化启动流程（账目切换期间不再触发新的判定）。
  bool _crossfadeStarting = false;

  /// 预加载完成、等待起播的下一首。索引为 null 表示没有可用的预加载。
  int? _crossfadePreparedIndex;
  Song? _crossfadePreparedSong;
  String? _crossfadePreparedQuality;

  /// 预加载时的"当前歌曲"id：起播前校验，列表/当前歌曲已变化则丢弃。
  String? _crossfadeFromSongId;

  bool get crossfadeEnabled => _crossfadeEnabled;
  Duration get crossfadeDuration => _crossfadeDuration;

  Song? get currentSong => _currentSong;
  bool get isPlaying => _isPlaying;

  /// audio_service 实例（歌曲信息页读取源格式用）。
  dynamic get audioService => _audioService;

  /// P0: position 独立通知通道。positionStream 每 ~200ms 触发一次，
  /// 之前每次都全量 notifyListeners() 导致所有 `Consumer<PlayerProvider>` 重建。
  /// 现在高频更新只通知 [positionNotifier]，进度条/歌词等高频 UI 订阅它，
  /// 其它 widget 仅在 currentSong/isPlaying/duration 等低频字段变化时重建。
  final ValueNotifier<Duration> positionNotifier = ValueNotifier(Duration.zero);

  Duration get position => _position;
  Duration? get duration => _duration;
  List<Song> get playlist => _playlist;
  int get currentIndex => _currentIndex;
  AppLoopMode get loopMode => _loopMode;
  bool get shuffleEnabled => _shuffleEnabled;
  double get volume => _volume;

  /// 更新播放位置并同步到 [positionNotifier]。
  /// 高频路径（positionStream ~200ms）只通知 positionNotifier，不触发全量 notifyListeners。
  void _updatePosition(Duration value) {
    if (_position == value) return;
    _position = value;
    positionNotifier.value = value;
  }
  double get speed => _speed;
  bool get isResolvingUrl => _isResolvingUrl;
  String? get resolveError => _resolveError;

  /// 播放链接解析失败时的提示文案。
  /// 听书章节付费边界在列表接口不可靠，能点上播放、但无免费部分的付费章节
  /// 解析必然失败——用更明确的文案提示用户，而不是通用的"无法获取播放链接"。
  String _resolveErrorText(Song? song) {
    if (song?.isLongAudio ?? false) return '该章节为 听书VIP单独付费内容';
    return '无法获取播放链接';
  }

  AudioQuality get audioQuality => _audioQuality;
  String get audioQualityLabel => _audioQuality.label;

  /// 睡眠定时剩余时间（null = 未启用）。
  Duration? get sleepTimerRemaining {
    final end = _sleepTimerEndTime;
    if (end == null) return null;
    final left = end.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  /// 是否启用了睡眠定时。
  bool get isSleepTimerActive => _sleepTimerEndTime != null;

  /// 当前歌曲的实际音质标签。
  /// 本地歌曲优先使用 song.quality 推断的标签；
  /// 在线歌曲优先显示实际播放音质（降级后可能与用户设置不同），
  /// 若尚无实际音质则回退到用户设置的全局音质偏好。
  String get currentQualityLabel {
    final song = _currentSong;
    if (song != null && !song.isOnline && song.quality != null) {
      switch (song.quality) {
        case '128':
          return '标准音质';
        case '320':
          return '高音质';
        case 'flac':
          return '无损音质';
        case 'high':
          return 'Hi-Res 无损';
        default:
          return song.quality!;
      }
    }
    // 在线歌曲：优先显示实际播放音质（可能因降级而与设置不同）
    if (_actualPlayingQuality != null) {
      return KugouQuality.labelOf(_actualPlayingQuality!);
    }
    return _audioQuality.label;
  }

  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration?>? _durationSubscription;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<just_audio.PlayerState>? _playerStateSubscription;
  StreamSubscription<just_audio.SequenceState?>? _sequenceStateSubscription;
  StreamSubscription<double>? _speedSubscription;

  dynamic _audioService;
  bool _audioInitialized = false;
  Future<void> Function()? onPlaylistEnd;
  // 未登录时尝试播放需联网歌曲,通知 UI 弹窗
  void Function()? onLoginRequired;

  // —— Lyricon 钩子字段 ——
  // 记录上次推送给 Lyricon 的歌曲，用于在 notifyListeners 回调中检测切歌
  // （PlayerProvider 没有专门的切歌回调，用 addListener 监听自身是最小侵入方式）
  Song? _lastLyriconSong;
  // 歌词异步拉取的竞态 token：每次切歌自增，过期结果被丢弃
  int _lyriconFetchToken = 0;

  // —— 播放状态持久化 ——
  final _stateRepo = PlayerStateRepository();
  bool _stateRestored = false;
  // 保存防抖计时器：避免 positionStream 每 200ms 都写磁盘
  Timer? _saveDebounce;

  PlayerProvider() {
    WidgetsBinding.instance.addObserver(this);
    _initAudioService();
    // 监听自身变化检测切歌 → 推送 Lyricon（仅 enabled 时实际推送）
    addListener(_handleLyriconSongChange);
    // 同步「是否正在播放在线歌曲」到听歌等级服务（累计本地听歌时长用）
    addListener(_syncListeningGradeOnline);
    // 监听 Lyricon 连接状态：headless 唤醒等场景下 auto_restored/connected
    // 事件到达时可能晚于状态恢复的 notifyListeners，这里补推当前歌曲，
    // 否则词幕不会自动连接显示（PlayerProvider 自己监听自己无法感知 Lyricon 启用）。
    LyriconProviderService.instance.addListener(_handleLyriconEnabledChanged);
  }

  /// 推送当前「在线歌曲播放中」状态到听歌等级服务。
  /// notifyListeners 在播放/暂停/切歌时触发（高频位置更新走 positionNotifier，
  /// 不触发全量通知），此方法开销极小。
  void _syncListeningGradeOnline() {
    final playingOnline = (_currentSong?.isOnline ?? false) && _isPlaying;
    ListeningGradeService.instance.setListeningOnline(playingOnline);
    // 真实播放上报：在线歌曲开始播放时上传一次播放历史（mxid=album_audio_id）。
    // 背景：听歌等级/时长对部分账号按"真实播放统计"记账，/user/grade/info 的
    // diff 差量上报不被服务器记账（实测 status=1/error_code=0 但服务器值不动）。
    // 上传播放历史即是真实播放信号，让这类账号也能累计听歌时长。按 song.id 去重，
    // 同一首歌只在重新开始播放时上报一次；best-effort，失败不影响播放。
    if (playingOnline) {
      _maybeUploadPlayHistory(_currentSong);
    }
  }

  /// 最近一次已上报播放历史的歌曲 id（避免同一首歌重复上报）。
  String? _lastUploadedPlaySongId;

  /// 最佳努力上报一次该在线歌曲的播放历史（需要 album_audio_id 作为 mxid）。
  void _maybeUploadPlayHistory(Song? song) {
    if (song == null || _lastUploadedPlaySongId == song.id) return;
    final audioId = song.albumAudioId;
    if (audioId == null || audioId.isEmpty) return;
    _lastUploadedPlaySongId = song.id;
    // ignore: discarded_futures
    KugouApiClient().uploadPlayHistory(audioId).catchError((_) => null);
    // ignore: avoid_print
    print('[PlayUpload] online 歌曲上报播放历史 song=${song.id} mxid=$audioId');
  }

  Future<void> _initAudioService() async {
    try {
      MediaNotificationService.initCallbacks();
      MediaNotificationService.onPrevious = () => previous();
      MediaNotificationService.onNext = () => next();
      MediaNotificationService.onTogglePlayPause = () {
        if (_isPlaying) {
          pause();
        } else {
          resume();
        }
      };
      MediaNotificationService.onPlay = () => resume();
      MediaNotificationService.onPause = () => pause();
      MediaNotificationService.onSeekTo = (pos) {
        seek(Duration(milliseconds: pos));
      };
      final audioServiceModule = await _loadAudioService();
      _audioService = audioServiceModule;
      _audioInitialized = true;
      await _audioService.init();
      _initStreams();
      await _loadDefaultQuality();
      await _syncIgnoreAudioFocus();
      // 恢复「音频焦点中断策略」设置（重启后保留用户选择）
      await _syncAudioFocusMode();
      // 恢复持久化的应用内音量（重启后保留）
      await _restoreVolume();
      // 读取交叉淡化设置到字段缓存（判定在 positionStream 高频路径上）
      await _loadCrossfadeSettings();
      // 恢复上次播放状态
      await _restoreState();
    } catch (e) {}
    // 无论初始化是否成功都通知原生端：状态恢复流程已结束。
    // 进程被杀场景下 AudioPlaybackService 等待该信号后才派发线控耳机命令
    //（唤醒播放），避免对尚未就绪的播放器派发命令导致空操作。
    try {
      await MediaNotificationService.notifyPlayerReady();
    } catch (_) {}
  }

  /// 恢复持久化的应用内音量（App 关闭重启后音量设置保留）。
  Future<void> _restoreVolume() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getDouble('player_volume');
      if (saved != null) {
        _volume = saved.clamp(0.0, 1.0);
        await _audioService?.setVolume(_volume);
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> _loadDefaultQuality() async {
    try {
      _isWifiNetwork = await _detectIsWifi();
      await _loadQualityForNetwork();
      await _initNetworkWatch();
    } catch (e) {}
  }

  /// 探测当前是否 WiFi：移动数据/蓝牙等一律按移动网络处理；无连接或探测
  /// 失败时按 WiFi（桌面开发等场景无蜂窝网，WiFi 分支作为默认回退）。
  Future<bool> _detectIsWifi() async {
    try {
      final results = await Connectivity().checkConnectivity();
      return _resultsAreWifi(results);
    } catch (_) {
      return true;
    }
  }

  /// connectivity_plus 返回的是连接类型列表：只要不含移动数据即按 WiFi 处理
  /// （覆盖 wifi / ethernet / vpn / other / none）。
  static bool _resultsAreWifi(List<ConnectivityResult> results) =>
      !results.contains(ConnectivityResult.mobile);

  /// 监听网络类型切换：仅刷新 [AudioQuality]，不重新解析当前歌曲，
  /// 新音质在下一首播放时生效（切歌走 _resolveAndPlayCurrentSong 用新值）。
  Future<void> _initNetworkWatch() async {
    try {
      _connectivitySub ??= Connectivity().onConnectivityChanged.listen(
            (results) => _onNetworkChanged(_resultsAreWifi(results)),
          );
    } catch (_) {}
  }

  void _onNetworkChanged(bool isWifi) {
    if (_isWifiNetwork == isWifi) return;
    _isWifiNetwork = isWifi;
    _loadQualityForNetwork();
  }

  /// 按当前网络类型从仓库读取对应音质并更新 [AudioQuality]。
  Future<void> _loadQualityForNetwork() async {
    final settings = SettingsRepository();
    final qualityValue = await settings.getQualityForNetwork(_isWifiNetwork);
    // 兼容旧版本存储的遗留值：hq→320, sq→flac, standard→128, hires→high
    final mapped = _legacyQualityMap[qualityValue] ?? qualityValue;
    final quality = AudioQuality.values.firstWhere(
      (q) => q.value == mapped,
      orElse: () {
        return AudioQuality.standard;
      },
    );
    if (_audioQuality != quality) {
      _audioQuality = quality;
      notifyListeners();
    }
  }

  /// 设置页修改任一网络音质后调用：按当前网络重新读取音质，下一首播放生效。
  /// 不打断正在播放的歌曲。
  Future<void> refreshQualityForNetwork() async {
    try {
      _isWifiNetwork = await _detectIsWifi();
      await _loadQualityForNetwork();
    } catch (_) {}
  }

  /// 把「忽略音频焦点」设置同步到 AudioService，使播放器中断处理即时生效。
  Future<void> _syncIgnoreAudioFocus() async {
    try {
      final ignore = await SettingsRepository().getIgnoreAudioFocus();
      // 注意：必须调 setIgnoreAudioFocus 方法（内部会同步 native Media3 的
      // ignore 标志）。AudioService 只有 getter ignoreAudioFocus、没有属性
      // setter——属性赋值 `ignoreAudioFocus = ignore` 在 dynamic 上抛
      // NoSuchMethodError 被 catch 吞掉，导致重启后开关状态从不恢复。
      // ignore: avoid_dynamic_calls
      await _audioService?.setIgnoreAudioFocus(ignore);
    } catch (_) {}
  }

  /// 设置「忽略音频焦点」开关：持久化 + 即时同步到播放器中断处理。
  /// 通过 AudioService 的重激活让系统立即按新开关评估中断派发，无需重启。
  Future<void> setIgnoreAudioFocus(bool value) async {
    try {
      await SettingsRepository().setIgnoreAudioFocus(value);
      // ignore: avoid_dynamic_calls
      await _audioService?.setIgnoreAudioFocus(value);
    } catch (_) {}
  }

  /// 把「音频焦点中断策略」设置同步到 AudioService，使策略即时生效。
  Future<void> _syncAudioFocusMode() async {
    try {
      final mode = await SettingsRepository().getAudioFocusInterruptionMode();
      // ignore: avoid_dynamic_calls
      _audioService?.setInterruptionMode(mode);
    } catch (_) {}
  }

  /// 设置「音频焦点中断策略」：持久化 + 即时同步到播放器中断处理。
  Future<void> setAudioFocusInterruptionMode(
      AudioFocusInterruptionMode mode) async {
    try {
      await SettingsRepository().setAudioFocusInterruptionMode(mode);
      // ignore: avoid_dynamic_calls
      _audioService?.setInterruptionMode(mode);
    } catch (_) {}
  }

  Future<dynamic> _loadAudioService() async {
    return AudioServiceLoader.load();
  }

  /// 冷启动恢复上次播放状态：加载歌曲、播放列表、恢复位置。
  Future<void> _restoreState() async {
    if (_stateRestored) return;
    _stateRestored = true;
    try {
      final state = await _stateRepo.restoreState();
      if (state == null) return;

      _currentSong = state.currentSong;
      _playlist = List.from(state.playlist);
      _originalPlaylist = List.from(state.playlist);
      _currentIndex = state.currentIndex;
      _loopMode = AppLoopMode.values.firstWhere(
        (m) => m.name == state.loopMode,
        orElse: () => AppLoopMode.off,
      );
      _shuffleEnabled = state.shuffleEnabled;
      _updatePosition(Duration.zero); // 先置零，等 setUrl 成功后 seek 到目标位置

      // 冷启动时清除在线歌曲的旧 URL（酷狗播放链接有时效性，上次会话的 URL 大概率已过期）
      // 强制 _resolveAndPlayCurrentSong 重新通过 API 获取有效链接
      if (_currentSong != null && _currentSong!.isOnline) {
        _currentSong = _currentSong!.copyWith(url: null);
      }
      for (int i = 0; i < _playlist.length; i++) {
        if (_playlist[i].isOnline) {
          _playlist[i] = _playlist[i].copyWith(url: null);
        }
      }

      // just_audio 的 LoopMode 始终设 off：项目通过 setUrl 加载单一 AudioSource，
      // LoopMode.one/all 在单 source 下会自动循环且不触发 completed 事件，
      // 导致应用层 _handlePlaybackCompleted 无法接管切歌。循环逻辑完全由
      // 应用层 _loopMode + _handlePlaybackCompleted 控制。
      if (_audioService != null) {
        await _audioService.setLoopMode(just_audio.LoopMode.off);
        await _audioService.setShuffleModeEnabled(false);
      }

      // 构建播放源并 seek 到保存的位置（不自动播放，等用户手动触发）
      final ok = await _resolveAndPlayCurrentSong(seekTo: state.position, play: false);
      if (ok) {
        _updatePosition(state.position);
      }
      notifyListeners();
    } catch (e) {}
  }

  /// 防抖保存播放状态：positionStream 每 200ms 触发一次，
  /// 用 3 秒防抖避免频繁写磁盘，仅保存关键字段。
  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(seconds: 3), _saveState);
  }

  /// 立即保存播放状态（切歌、暂停、循环模式变更时调用）。
  void _saveState() {
    _saveDebounce?.cancel();
    try {
      _stateRepo.saveState(
        currentSong: _currentSong,
        playlist: _playlist,
        currentIndex: _currentIndex,
        position: _position,
        loopMode: _loopMode.name,
        shuffleEnabled: _shuffleEnabled,
      );
    } catch (_) {}
  }

  void _initStreams() {
    if (_audioService == null || !_audioInitialized) return;

    try {
      _positionSubscription = _audioService.positionStream.listen((position) {
        // P0: 高频位置更新只同步 positionNotifier，不再全量 notifyListeners，
        // 避免每 200ms 重建所有依赖 PlayerProvider 的 widget（MiniPlayer/封面等）
        _updatePosition(position);
        _updateNotificationPosition();
        // 防抖保存位置（3 秒）
        _scheduleSave();

        // 位置兜底：播放中 position >= duration 且 processingState 非 completed
        // 时主动触发切歌，防止 completed 事件丢失导致永不切歌（Media3 偶发）。
        // 同样受 Windows 误报防护窗口约束：setUrl 加载新源后 3s 内不兜底切歌。
        final insideLoadGuard =
            DateTime.now().difference(_lastUrlLoadStarted) <
                _urlLoadGuardWindow;
        final duration = _duration ?? Duration.zero;
        if (_isPlaying &&
            !insideLoadGuard &&
            duration > Duration.zero &&
            position >= duration &&
            _audioService?.processingState !=
                just_audio.ProcessingState.completed &&
            !_handlingCompletion) {
          print('[PlaybackCompleted] position >= duration but not completed, '
              'triggering completion manually (pos=${position.inSeconds}s '
              'dur=${duration.inSeconds}s)');
          _handlePlaybackCompleted();
        }
        // 交叉淡化调度：与位置兜底共用同一个 ~200ms tick，无需额外 Timer
        _maybeCrossfade(position);
        // 直接转发给 Lyricon，无节流。
        // positionStream 本身就是 ~200ms 周期（just_audio 默认），是天然节流。
        // MethodChannel 是异步的，不阻塞 Dart UI；setPosition 是 fire-and-forget。
        // 仅在播放中推送，暂停时跳过避免无意义 IPC。
        if (LyriconProviderService.instance.enabled && _isPlaying) {
          try {
            LyriconProviderService.instance.setPosition(
              position.inMilliseconds,
            );
          } catch (_) {}
        }
      }, onError: (e) {});

      _durationSubscription = _audioService.durationStream.listen((duration) {
        _duration = duration;
        notifyListeners();
      }, onError: (e) {});

      _playingSubscription = _audioService.playingStream.listen((isPlaying) {
        _isPlaying = isPlaying;
        WakelockService.instance.setSongPlaying(isPlaying);
        // try-catch：_updateNotification 内部（updateWidget 等）异常不应
        // 中断后续，否则暂停时 Kotlin 收不到 isPlaying=false，WakeLock 不释放
        try {
          _updateNotification();
        } catch (_) {}
        notifyListeners();
        // 播放/暂停切换时立即推 Lyricon，避免等下一个 positionStream tick
        // state 必须用 PlaybackStateCompat.STATE_PLAYING=3 / STATE_PAUSED=2
        if (LyriconProviderService.instance.enabled) {
          try {
            LyriconProviderService.instance.setPlaybackState(
              state: isPlaying ? 3 : 2,
              position: _position.inMilliseconds,
              speed: 1.0,
            );
          } catch (_) {}
        }
      }, onError: (e) {});

      _playerStateSubscription = _audioService.playerStateStream.listen((
        playerState,
      ) {
        try {
          if (playerState.processingState ==
              just_audio.ProcessingState.completed) {
            _handlePlaybackCompleted();
          }
        } catch (e) {}
      }, onError: (e) {});

      _sequenceStateSubscription = _audioService.sequenceStateStream.listen((
        sequenceState,
      ) {
        try {
          if (sequenceState != null && sequenceState.currentSource != null) {
            // 外部切歌同步：控制中心(媒体3)/耳机电线/自动播放下一首会直接推进
            // just_audio 的播放队列，这里在 currentSource 变化时把「当前歌曲」同步
            // 到 UI 与原生自定义 MediaSession/通知（否则自定义会话仍停留在上一首）。
            // 用 tag 里的 song id 反查播放列表，兼容 shuffle 下的 effective 顺序。
            final currentTag = sequenceState.currentSource!.tag;
            if (currentTag is Map && currentTag['id'] != null) {
              final newIndex = _playlist.indexWhere(
                (s) => s.id == currentTag['id'],
              );
              if (newIndex >= 0 && newIndex != _currentIndex) {
                _currentIndex = newIndex;
                _currentSong = _playlist[newIndex];
                _recordHistory(_currentSong!);
                _updateNotification();
                notifyListeners();
              }
            }
            final effectiveIndex = sequenceState.effectiveSequence.indexOf(
              sequenceState.currentSource!,
            );
            if (effectiveIndex >= _playlist.length - 2 &&
                onPlaylistEnd != null) {
              onPlaylistEnd!();
            }
          }
        } catch (e) {}
      }, onError: (e) {});

      _speedSubscription = _audioService.speedStream.listen((speed) {
        _speed = speed;
        notifyListeners();
      }, onError: (e) {});
    } catch (e) {}
  }

  bool _handlingCompletion = false;

  // —— Windows 误报 completed 防护 ——
  // just_audio_windows（WinRT MediaPlayer）在 setUrl() 加载新源时，旧源
  // 会异步触发一次 completed 事件（或 processingState 短暂变 completed），
  // 导致 _handlePlaybackCompleted / position 兜底被误触发 → 自动 next() 跳到
  // 下一首。Android(Media3) 无此行为。播放列表点歌"总切到下一首"即由此引起。
  // 方案：每次开始加载新源时记录时间戳；completed 兜底切歌若发生在
  // [guard 窗口]内则判定为误报并忽略。真实播完一首歌必然远超该窗口。
  static const Duration _urlLoadGuardWindow = Duration(milliseconds: 3000);
  DateTime _lastUrlLoadStarted = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> _handlePlaybackCompleted() async {
    if (_handlingCompletion) return;
    // 交叉淡化进行中：旧歌会在淡化收尾前自然播完并发出 completed，而交叉点
    // 之前对外的流仍来自旧播放器（这样界面显示的才是听到的那首）。此时切歌
    // 已由淡化流程接管，这里必须放行，否则会额外再跳一首。
    if (_crossfadeStarting || _audioService?.isCrossfading == true) {
      // ignore: avoid_print
      print('[Crossfade] 忽略 completed：淡化进行中');
      return;
    }
    // Windows 误报 completed 防护：just_audio_windows 在 setUrl() 加载新源时，
    // 旧源会异步补发一次 completed，若距上次加载源 < 窗口则判为误报并忽略，
    // 避免"播放列表点歌总自动跳到下一首"。真实播完一首歌必然远超该窗口。
    if (DateTime.now().difference(_lastUrlLoadStarted) < _urlLoadGuardWindow) {
      print('[PlaybackCompleted] ignored: within ${_urlLoadGuardWindow} of url '
          'load (likely spurious completed on Windows)');
      return;
    }
    _handlingCompletion = true;
    try {
      if (_loopMode == AppLoopMode.one) {
        // 单曲循环：检测在线歌曲是否异常结束（URL 过期 / 流中断），
        // 避免无限重播损坏的链接
        final lastPosition = _position;
        final songDuration = _currentSong?.duration ?? Duration.zero;
        final bool isAbnormal = lastPosition.inMilliseconds > 500 &&
            songDuration.inSeconds > 0 &&
            lastPosition.inSeconds < songDuration.inSeconds * 0.8;

        if (isAbnormal &&
            _currentSong != null &&
            _currentSong!.isOnline) {
          final songId = _currentSong!.id;
          if (_retryingSongId != songId) {
            _retryingSongId = songId;
            _abnormalEndRetries = 0;
          }
          _abnormalEndRetries++;
          if (_abnormalEndRetries > _maxAbnormalRetries) {
            // 重试次数耗尽，停止播放
            _abnormalEndRetries = 0;
            _retryingSongId = null;
            await _audioService?.pause();
            _resolveError = '播放失败，请检查网络';
            notifyListeners();
            return;
          }
          // 清除旧 URL，从上次位置继续
          _currentSong = _currentSong!.copyWith(url: null);
          _playlist[_currentIndex] = _currentSong!;
          final ok = await _resolveAndPlayCurrentSong(seekTo: lastPosition);
          if (ok) {
            _resolveError = null;
          } else {
            _resolveError = _resolveErrorText(_currentSong);
          }
          notifyListeners();
        } else {
          // 正常结束或本地歌曲，从头重播
          _abnormalEndRetries = 0;
          _retryingSongId = null;
          seek(Duration.zero);
          _audioService?.play();
        }
      } else if (_currentIndex >= _playlist.length - 1) {
        // 走到这里：当前是最后一首（含单首歌场景），且非 FM、非列表循环
        if (onPlaylistEnd != null) {
          await onPlaylistEnd!();
        } else {
          // 记录当前位置与歌曲实际时长，用于判断是否异常结束
          // （URL 过期 / 试听片段提前 completed 时，position 明显小于歌曲时长）
          final lastPosition = _position;
          final songDuration = _currentSong?.duration ?? Duration.zero;
          final bool isAbnormalEnd = lastPosition.inMilliseconds > 500 &&
              songDuration.inSeconds > 0 &&
              lastPosition.inSeconds < songDuration.inSeconds * 0.8;

          // 异常结束时更新重试计数
          if (isAbnormalEnd &&
              _currentSong != null &&
              _currentSong!.isOnline) {
            final songId = _currentSong!.id;
            if (_retryingSongId != songId) {
              _retryingSongId = songId;
              _abnormalEndRetries = 0;
            }
            _abnormalEndRetries++;
          }

          // 重试次数耗尽：跳过该歌曲，不回到开头
          if (isAbnormalEnd && _abnormalEndRetries > _maxAbnormalRetries) {
            _abnormalEndRetries = 0;
            _retryingSongId = null;
            if (_playlist.length > 1) {
              // 多首歌时删除当前故障歌曲，播放上一首（保持索引有效）
              _playlist.removeAt(_currentIndex);
              _currentIndex = (_currentIndex - 1).clamp(0, _playlist.length - 1);
              _currentSong = _playlist[_currentIndex];
              final ok = await _resolveAndPlayCurrentSong();
              if (!ok) {
                _resolveError = _resolveErrorText(_currentSong);
              }
            } else {
              // 仅一首歌时直接停止
              await _audioService?.pause();
              _resolveError = '播放失败，请检查网络';
            }
            notifyListeners();
            return;
          }

          // 正常结束时重置计数器
          if (!isAbnormalEnd) {
            _abnormalEndRetries = 0;
            _retryingSongId = null;
          }

          // 非 FM：最后一曲播完回到第一曲
          if (_shuffleEnabled) {
            final currentSong = _currentSong;
            final remaining = _playlist
                .where((s) => s.id != currentSong?.id)
                .toList();
            remaining.shuffle();
            // currentSong 可能为 null，使用 collection-if 条件添加
            _playlist = [if (currentSong != null) currentSong, ...remaining];
            _currentIndex = 0;
          } else {
            _currentIndex = 0;
          }
          if (_playlist.isNotEmpty) {
            _currentSong = _playlist[_currentIndex];
            _recordHistory(_currentSong!);
          }
          // 异常结束时清除旧 URL，强制重新解析（避免复用过期链接）
          if (isAbnormalEnd && _currentSong != null && _currentSong!.isOnline) {
            _currentSong = _currentSong!.copyWith(url: null);
            _playlist[_currentIndex] = _currentSong!;
          }
          // 异常结束时从上次位置继续播放；正常播完从 0 开始
          final seekTo = isAbnormalEnd ? lastPosition : null;
          final ok = await _resolveAndPlayCurrentSong(seekTo: seekTo);
          if (ok) {
            _resolveError = null;
          } else {
            _resolveError = _resolveErrorText(_currentSong);
          }
          notifyListeners();
        }
      } else {
        // 不在末尾：正常切下一首（用户切歌会重置计数器）
        await next();
      }
    } finally {
      _handlingCompletion = false;
    }
  }

  /// 重置异常结束重试计数（用户主动切歌时调用）
  void _resetAbnormalRetry() {
    _abnormalEndRetries = 0;
    _retryingSongId = null;
    _actualPlayingQuality = null;
    // 用户主动切歌：预加载的"下一首"已经不再是下一首了
    _resetCrossfadePrepared();
  }

  // ===================== 交叉淡化（crossfade） =====================

  /// 从设置读取 crossfade 开关与时长到字段缓存。
  /// 设置页改动后由 [refreshCrossfadeSettings] 重新调用。
  Future<void> _loadCrossfadeSettings() async {
    try {
      final settings = SettingsRepository();
      final enabled = await settings.getCrossfadeEnabled();
      final seconds = await settings.getCrossfadeSeconds();
      final changed =
          enabled != _crossfadeEnabled || seconds != _crossfadeDuration.inSeconds;
      _crossfadeEnabled = enabled;
      _crossfadeDuration = Duration(seconds: seconds);
      if (!enabled) _resetCrossfadePrepared();
      if (changed) {
        // ignore: avoid_print
        print('[Crossfade] 设置已加载 enabled=$enabled seconds=$seconds');
      }
    } catch (e) {
      // ignore: avoid_print
      print('[Crossfade] 读取设置失败: $e');
    }
  }

  /// 设置页修改 crossfade 设置后调用，刷新字段缓存。
  Future<void> refreshCrossfadeSettings() => _loadCrossfadeSettings();

  /// 上次已按当前歌曲刷新过设置缓存的歌曲 id。
  ///
  /// 设置页改开关时会调 [refreshCrossfadeSettings]，但那条通路依赖设置页能拿到
  /// 本 Provider；这里每首歌开头再读一次（一次 SharedPreferences 读，开销可忽略），
  /// 保证即使通知没到也最迟在下一首生效。
  String? _crossfadeSettingsSongId;

  /// 诊断日志去重键（同一首歌内同样的原因只打一次，避免 200ms 刷屏）。
  String? _lastCrossfadeDiag;

  void _crossfadeDiag(String msg) {
    final key = '${_currentSong?.id}|$msg';
    if (_lastCrossfadeDiag == key) return;
    _lastCrossfadeDiag = key;
    // ignore: avoid_print
    print('[Crossfade] $msg');
  }

  /// 丢弃已预加载的下一首（切歌 / 拖动进度条 / 关闭开关等）。
  void _resetCrossfadePrepared() {
    if (_crossfadePreparedIndex == null &&
        !_crossfadePreparing &&
        _crossfadeFromSongId == null) {
      return;
    }
    _crossfadePreparedIndex = null;
    _crossfadePreparedSong = null;
    _crossfadePreparedQuality = null;
    _crossfadeFromSongId = null;
    _crossfadePreparing = false;
    try {
      _audioService?.discardPreparedCrossfade();
    } catch (_) {}
  }

  /// crossfade 的所有前置条件。返回阻塞原因（null = 允许）。
  /// 原因字符串直接进诊断日志，排障时一眼看出卡在哪一条。
  /// 时间轴判断（是否接近尾部、曲子够不够长）在 [decideCrossfadePhase] 里。
  String? _crossfadeBlockReason() {
    if (!_crossfadeEnabled) return '开关未开启';
    // 双播放器方案依赖 Media3（共享 audioSessionId、跳过第二个 MediaSession）
    if (kIsWeb || !Platform.isAndroid) return '非 Android 平台';
    if (!_isPlaying) return '未在播放';
    if (_isResolvingUrl) return '正在解析播放链接';
    if (_handlingCompletion) return '正在处理播放结束';
    if (_crossfadeStarting) return '淡化启动中';
    if (_currentIndex < 0) return '无当前歌曲';
    if (_playlist.length < 2) return '播放列表不足 2 首';
    // 单曲循环：同一首歌尾接头不做叠加
    if (_loopMode == AppLoopMode.one) return '单曲循环';
    if (_currentIndex >= _playlist.length - 1) {
      // 最后一首且非列表循环：播完就该停，不该叠加
      if (_loopMode != AppLoopMode.all) return '最后一首且非列表循环';
      // 私人 FM 等会在末尾续列表，交给原有 onPlaylistEnd 流程
      if (onPlaylistEnd != null) return '最后一首，交给 onPlaylistEnd 续列表';
    }
    // 同专辑：尾接头属于正常曲间过渡，不做叠加（覆盖 prepare 与 start 两阶段）
    final nextIndex = _nextIndexForCrossfade();
    if (nextIndex != null) {
      final currentSong = _currentSong;
      final nextSong = _playlist[nextIndex];
      if (currentSong != null && _isSameAlbum(currentSong, nextSong)) {
        return '同专辑（同 disk 歌曲不叠加）';
      }
    }
    // USB 独占输出：所有 AudioSink 共用一条 USB 流（见 UsbAudioSinkController
    // 的 static activeStream），两个播放器会交替写入同一条流而不是混音，
    // 结果是音频错乱而非叠加。独占开启期间直接跳过。
    if (UsbAudioService.instance.lastStatus['enabled'] == true) {
      return 'USB 独占输出已开启';
    }
    return null;
  }

  /// 判断两首歌是否属于同一专辑：优先比 albumId（非空且相等），
  /// 否则比专辑名（trim 后忽略大小写相等）。
  bool _isSameAlbum(Song a, Song b) {
    final aId = a.albumId;
    final bId = b.albumId;
    if (aId != null && aId.isNotEmpty && bId != null && bId.isNotEmpty) {
      return aId == bId;
    }
    final aName = a.album.trim();
    final bName = b.album.trim();
    if (aName.isEmpty || bName.isEmpty) return false;
    return aName.toLowerCase() == bName.toLowerCase();
  }

  /// 每个 position tick 调用：决定是否预加载下一首或开始淡化。
  void _maybeCrossfade(Duration position) {
    // 每首歌开头补读一次设置，避免设置页的通知没到导致本次运行内不生效
    final songId = _currentSong?.id;
    if (songId != null && songId != _crossfadeSettingsSongId) {
      _crossfadeSettingsSongId = songId;
      // ignore: discarded_futures
      _loadCrossfadeSettings();
    }
    if (_crossfadePreparing || _crossfadeStarting) return;

    final reason = _crossfadeBlockReason();
    final total = _duration;
    // 诊断：按去重键每首歌只打一次，定位卡在哪一步
    if (reason != null) {
      _crossfadeDiag('跳过：$reason');
    } else if (total == null || total <= Duration.zero) {
      _crossfadeDiag('时长未知，无法判断尾部位置');
    } else {
      final minLength = _crossfadeDuration * 2 + kCrossfadeMinTailroom;
      if (total < minLength) {
        _crossfadeDiag('曲子过短：${total.inSeconds}s < ${minLength.inSeconds}s，不叠加');
      } else if (total - position <=
          _crossfadeDuration + kCrossfadePrepareLead) {
        _crossfadeDiag('进入窗口 pos=${position.inSeconds}s dur=${total.inSeconds}s '
            'fade=${_crossfadeDuration.inSeconds}s');
      }
    }

    final phase = decideCrossfadePhase(
      position: position,
      duration: total,
      crossfadeDuration: _crossfadeDuration,
      enabled: reason == null,
      prepared: _crossfadePreparedIndex != null,
      fading: _audioService?.isCrossfading == true,
    );
    switch (phase) {
      case CrossfadePhase.idle:
        return;
      case CrossfadePhase.prepare:
        // ignore: discarded_futures
        _prepareCrossfade();
      case CrossfadePhase.start:
        // ignore: discarded_futures
        _startCrossfade();
    }
  }

  /// 自然播完时的下一首索引（与 [next] 的推进规则一致；
  /// 随机播放已由 `_playlist` 自身的顺序体现，这里同样是 +1）。
  int? _nextIndexForCrossfade() {
    if (_playlist.isEmpty || _currentIndex < 0) return null;
    if (_currentIndex < _playlist.length - 1) return _currentIndex + 1;
    if (_loopMode == AppLoopMode.all) return 0;
    return null;
  }

  /// 解析下一首的播放地址并加载到备用播放器预缓冲（不出声）。
  Future<void> _prepareCrossfade() async {
    if (_crossfadePreparing || _crossfadePreparedIndex != null) return;
    final nextIndex = _nextIndexForCrossfade();
    if (nextIndex == null) return;
    final fromSongId = _currentSong?.id;
    _crossfadePreparing = true;
    // ignore: avoid_print
    print('[Crossfade] prepare 开始 nextIndex=$nextIndex');
    try {
      var song = _playlist[nextIndex];
      String? quality;
      if (song.isOnline && (song.url == null || song.url!.isEmpty)) {
        final result = await KugouApiClient().getSongUrlWithFallback(
          song.id,
          quality: _audioQuality.value,
          albumId: song.albumId,
          albumAudioId: song.albumAudioId,
        );
        if (result == null || result.url.isEmpty) {
          // ignore: avoid_print
          print('[Crossfade] prepare 放弃：下一首无播放链接 id=${song.id}');
          return;
        }
        quality = result.quality;
        song = song.copyWith(url: result.url);
      } else if (song.isOnline) {
        quality = _audioQuality.value;
      }
      final url = await _resolvePlaybackUrl(song);
      if (url == null || url.isEmpty) {
        // ignore: avoid_print
        print('[Crossfade] prepare 放弃：地址解析失败 id=${song.id}');
        return;
      }
      if (!song.isOnline) {
        // 回写解析后的真实路径（content:// → file://），避免起播后再解析一次
        song = song.copyWith(localPath: url);
      }
      // 解析期间用户可能已经切歌 / 换了列表：丢弃这次预加载
      if (_currentSong?.id != fromSongId ||
          nextIndex >= _playlist.length ||
          _playlist[nextIndex].id != song.id) {
        return;
      }
      _playlist[nextIndex] = song;
      final ok = await _audioService?.prepareCrossfade(url, speed: _speed);
      if (ok != true) {
        // ignore: avoid_print
        print('[Crossfade] prepare 放弃：备用播放器加载失败');
        return;
      }
      if (_currentSong?.id != fromSongId) {
        _audioService?.discardPreparedCrossfade();
        return;
      }
      _crossfadePreparedIndex = nextIndex;
      _crossfadePreparedSong = song;
      _crossfadePreparedQuality = quality;
      _crossfadeFromSongId = fromSongId;
      // ignore: avoid_print
      print('[Crossfade] prepared index=$nextIndex title=${song.title}');
    } catch (e) {
      // ignore: avoid_print
      print('[Crossfade] prepare 异常: $e');
    } finally {
      _crossfadePreparing = false;
    }
  }

  /// 启动淡化并把"当前歌曲"账目切到新歌。
  ///
  /// [AudioService.startCrossfade] 内部先把新播放器切为活动播放器再开始斜坡，
  /// 因此旧播放器随后自然播完发出的 completed 不会被转发，
  /// [_handlePlaybackCompleted] 不会再触发一次切歌。
  Future<void> _startCrossfade() async {
    final nextIndex = _crossfadePreparedIndex;
    final nextSong = _crossfadePreparedSong;
    final fromSongId = _crossfadeFromSongId;
    final quality = _crossfadePreparedQuality;
    if (nextIndex == null || nextSong == null || _crossfadeStarting) return;
    // 起播前最后一次校验：列表/当前歌曲变了就丢弃，避免切到错误的歌
    if (_currentSong?.id != fromSongId ||
        nextIndex >= _playlist.length ||
        _playlist[nextIndex].id != nextSong.id) {
      _resetCrossfadePrepared();
      return;
    }
    _crossfadeStarting = true;
    try {
      // 复用 Windows 误报 completed 的防护窗口：新歌刚起播时不做位置兜底切歌
      _lastUrlLoadStarted = DateTime.now();
      // 作废可能仍在跑的暂停淡入/淡出循环：它们会往播放器写音量，
      // 和淡化斜坡抢同一个 setVolume 通道
      _fadeToken++;
      final prevSong = _currentSong;
      // 「当前歌曲」的账目推迟到交叉点（淡化中点）再切：一开始就切会让
      // 界面/歌词/通知栏写着下一首，而这几秒听到的主体还是正在淡出的上一首。
      final fade = _audioService?.startCrossfade(
        duration: _crossfadeDuration,
        targetVolume: _volume,
        onCrossover: () => _applyCrossfadeSwitch(nextIndex, nextSong, quality),
      );
      await fade;
      // 旧播放源到这一刻才真正停止发声
      if (prevSong != null && prevSong.isOnline) {
        // 可选扩展：播放源停止回调（默认关闭）
        PlayerProvider.onPlaybackSourceStopped?.call(prevSong.id);
      }
      // 预取下一批链接与高潮数据推迟到淡化结束后：这两件事都发网络请求，
      // 在斜坡进行中做会挤占事件循环，让音量步进变得不均匀
      if (_currentIndex == nextIndex) {
        _prefetchNextSongs(_currentIndex);
        // ignore: discarded_futures
        _fetchClimaxData();
      }
    } catch (e) {
      // ignore: avoid_print
      print('[Crossfade] 启动失败: $e');
    } finally {
      _crossfadePreparedIndex = null;
      _crossfadePreparedSong = null;
      _crossfadePreparedQuality = null;
      _crossfadeFromSongId = null;
      _crossfadeStarting = false;
    }
  }

  /// 交叉点回调：把「当前歌曲」账目切给新歌。
  ///
  /// 由 [AudioService.startCrossfade] 在淡化进度到 [kCrossfadeCrossoverProgress]
  /// 时调用 —— 此刻活动播放器刚切给新歌，两首响度相当，界面/歌词/通知栏
  /// 一起换过去在听感上最自然。
  void _applyCrossfadeSwitch(int index, Song song, String? quality) {
    if (index >= _playlist.length || _playlist[index].id != song.id) {
      // ignore: avoid_print
      print('[Crossfade] crossover 放弃：列表已变化');
      return;
    }
    _abnormalEndRetries = 0;
    _retryingSongId = null;
    _currentIndex = index;
    _currentSong = song;
    _actualPlayingQuality = quality;
    _resolveError = null;
    // 新歌此刻已经播了半个淡化时长，用它的真实进度而不是 0
    _updatePosition(_audioService?.position ?? Duration.zero);
    _recordHistory(song);
    if (song.isOnline && (song.url?.isNotEmpty ?? false)) {
      // 可选扩展：播放源开始后回调（默认关闭）
      PlayerProvider.onPlaybackSourceStarted?.call(
        song,
        quality ?? _audioQuality.value,
        song.url!,
      );
    }
    _updateNotification();
    // 用防抖保存而不是立即 _saveState()：这一帧本来就要跑 UI 重建 + 封面取色，
    // 再叠一次同步磁盘写会明显卡音
    _scheduleSave();
    notifyListeners();
  }

  Future<void> playSong(Song song) async {
    _resetAbnormalRetry();
    if (song.isOnline && song.url == null) {
      await playOnlineSong(song);
      return;
    }

    _currentSong = song;
    _playlist = [song];
    _originalPlaylist = [song];
    _currentIndex = 0;
    _resolveError = null;
    _updatePosition(Duration.zero);
    _recordHistory(song);
    _updateNotification();
    _saveState();
    notifyListeners();

    if (_audioService != null) {
      final playbackUrl = await _resolvePlaybackUrl(song);
      if (playbackUrl == null || playbackUrl.isEmpty) {
        _resolveError = _resolveErrorText(song);
        notifyListeners();
        return;
      }
      // 把解析后的真实路径回写到 song，避免下次切回时重新解析
      if (!song.isOnline) {
        _currentSong = song.copyWith(localPath: playbackUrl);
        _playlist[0] = _currentSong!;
        notifyListeners();
      }
      final source = _createAudioSource(_currentSong!);
      await _audioService.setPlaylist([source], startIndex: 0);
      await _audioService.play();
    }
  }

  Future<void> playOnlineSong(Song song) async {
    final apiClient = KugouApiClient();
    if (!apiClient.isLoggedIn) {
      onLoginRequired?.call();
      return;
    }
    _resetAbnormalRetry();

    // 可选扩展：播放前解析本地已持久化的音频（默认关闭，由私有构建注入）
    String? cachedPath;
    final localAudioResolver = PlayerProvider.resolveLocalAudioPath;
    if (localAudioResolver != null) {
      cachedPath = await localAudioResolver(song.id, _audioQuality.value);
    }

    _currentSong = song;
    _playlist = [song];
    _originalPlaylist = [song];
    _currentIndex = 0;
    _isResolvingUrl = true;
    _resolveError = null;
    _updatePosition(Duration.zero);
    _recordHistory(song);
    _updateNotification();
    _saveState();
    notifyListeners();

    try {
      // 缓存命中：直接用本地路径播放
      if (cachedPath != null) {
        _actualPlayingQuality = _audioQuality.value;
        final fileUri = Uri.file(cachedPath).toString();
        final resolvedSong = song.copyWith(url: fileUri);
        _currentSong = resolvedSong;
        _playlist = [resolvedSong];
        _isResolvingUrl = false;
        _saveState();
        notifyListeners();

        if (_audioService != null) {
          final source = _createAudioSource(resolvedSong);
          await _audioService.setPlaylist([source], startIndex: 0);
          await _audioService.play();
        }
        return;
      }

      // 确保本地 API 服务器已启动
      await _ensureApiServerReady();

      final apiClient = KugouApiClient();

      final result = await apiClient.getSongUrlWithFallback(
        song.id,
        quality: _audioQuality.value,
        albumId: song.albumId,
        albumAudioId: song.albumAudioId,
      );

      if (result != null && result.url.isNotEmpty) {
        _actualPlayingQuality = result.quality;
        final resolvedSong = song.copyWith(url: result.url);
        _currentSong = resolvedSong;
        _playlist = [resolvedSong];
        _isResolvingUrl = false;
        _saveState();
        notifyListeners();

        if (_audioService != null) {
          final source = _createAudioSource(resolvedSong);
          await _audioService.setPlaylist([source], startIndex: 0);
          await _audioService.play();
        } else {}

        // 可选扩展：播放源开始后回调（默认关闭）
        PlayerProvider.onPlaybackSourceStarted
            ?.call(resolvedSong, result.quality, result.url);
      } else {
        _isResolvingUrl = false;
        _resolveError = _resolveErrorText(song);
        notifyListeners();
      }
    } catch (e) {
      _isResolvingUrl = false;
      _resolveError = e.toString();
      notifyListeners();
    }
  }

  /// 加载歌单播放顺序：随机开启时保持点击曲目为首曲、其余打乱；
  /// 关闭时按原顺序播放。始终以原始顺序同步 [_originalPlaylist]
  /// （关闭随机时用于还原）。
  void _loadPlaylist(List<Song> songs, int startIndex) {
    // 换列表：预加载的"下一首"索引已失效
    _resetCrossfadePrepared();
    _originalPlaylist = List.from(songs);
    if (_shuffleEnabled) {
      final currentSong = songs[startIndex];
      final remaining = songs.where((s) => s.id != currentSong.id).toList();
      remaining.shuffle();
      _playlist = [currentSong, ...remaining];
      _currentIndex = 0;
    } else {
      _playlist = List.from(songs);
      _currentIndex = startIndex;
    }
  }

  Future<void> playPlaylist(List<Song> songs, int startIndex) async {
    if (songs.isEmpty) return;
    _resetAbnormalRetry();

    _loadPlaylist(songs, startIndex);
    _currentSong = _playlist[_currentIndex];
    _resolveError = null;
    _updatePosition(Duration.zero);
    _recordHistory(_currentSong!);
    _saveState();
    notifyListeners();

    if (_currentSong!.isOnline && _currentSong!.url == null) {
      _isResolvingUrl = true;
      notifyListeners();

      try {
        await _ensureApiServerReady();
        final apiClient = KugouApiClient();
        final result = await apiClient.getSongUrlWithFallback(
          _currentSong!.id,
          quality: _audioQuality.value,
          albumId: _currentSong!.albumId,
          albumAudioId: _currentSong!.albumAudioId,
        );

        if (result != null && result.url.isNotEmpty) {
          _actualPlayingQuality = result.quality;
          final resolvedSong = _currentSong!.copyWith(url: result.url);
          _currentSong = resolvedSong;
          _playlist[_currentIndex] = resolvedSong;
          _isResolvingUrl = false;
          notifyListeners();

          if (_audioService != null) {
            await _setUrlAndPlay(result.url);
          }
        } else {
          _isResolvingUrl = false;
          _resolveError = _resolveErrorText(_currentSong);
          final failedSong = _currentSong!;
          notifyListeners();
          // 先弹窗提示，随即切到下一首（不阻塞）
          _showUnplayableSongDialog(failedSong);
          // 听书付费章节失败不自动跳下一曲：整专辑大概率连续付费，
          // 自动切会疯狂刷日志且无意义，由用户手动选择。
          if (_playlist.length > 1 && !failedSong.isLongAudio) {
            await next(autoPlay: true);
          }
        }
      } catch (e) {
        _isResolvingUrl = false;
        _resolveError = e.toString();
        notifyListeners();
      }

      _prefetchNextSongs(_currentIndex);
    } else if (_audioService != null) {
      final playbackUrl = await _resolvePlaybackUrl(_currentSong!);
      if (playbackUrl == null || playbackUrl.isEmpty) {
        _resolveError = _resolveErrorText(_currentSong);
        notifyListeners();
        return;
      }
      // 把解析后的真实路径回写到 song（适用于本地 content:// URI）
      if (!_currentSong!.isOnline) {
        _currentSong = _currentSong!.copyWith(localPath: playbackUrl);
        _playlist[_currentIndex] = _currentSong!;
        notifyListeners();
      }
      await _setUrlAndPlay(playbackUrl);
    }
  }

  Future<void> playOnlinePlaylist(List<Song> songs, int startIndex) async {
    if (songs.isEmpty) return;
    _resetAbnormalRetry();

    // 可选扩展：播放前解析本地已持久化的音频（默认关闭）
    String? cachedPath;
    final localAudioResolver = PlayerProvider.resolveLocalAudioPath;
    if (localAudioResolver != null) {
      cachedPath = await localAudioResolver(
        songs[startIndex].id,
        _audioQuality.value,
      );
    }

    // 缓存未命中且未登录时才提示登录
    if (cachedPath == null && !KugouApiClient().isLoggedIn) {
      onLoginRequired?.call();
      return;
    }

    _loadPlaylist(songs, startIndex);
    _currentSong = _playlist[_currentIndex];
    _isResolvingUrl = true;
    _resolveError = null;
    _updatePosition(Duration.zero);
    _recordHistory(_currentSong!);
    _updateNotification();
    notifyListeners();

    try {
      // 缓存命中：直接播放本地文件
      if (cachedPath != null) {
        _actualPlayingQuality = _audioQuality.value;
        final fileUri = Uri.file(cachedPath).toString();
        final resolvedSong = _currentSong!.copyWith(url: fileUri);
        _currentSong = resolvedSong;
        _playlist[_currentIndex] = resolvedSong;
        _isResolvingUrl = false;
        notifyListeners();

        if (_audioService != null) {
          await _setUrlAndPlay(fileUri);
        }
      } else {
        await _ensureApiServerReady();
        final apiClient = KugouApiClient();
        final result = await apiClient.getSongUrlWithFallback(
          _currentSong!.id,
          quality: _audioQuality.value,
          albumId: _currentSong!.albumId,
          albumAudioId: _currentSong!.albumAudioId,
        );

        if (result != null && result.url.isNotEmpty) {
          _actualPlayingQuality = result.quality;
          final resolvedSong = _currentSong!.copyWith(url: result.url);
          _currentSong = resolvedSong;
          _playlist[_currentIndex] = resolvedSong;
          _isResolvingUrl = false;
          notifyListeners();

          if (_audioService != null) {
            await _setUrlAndPlay(result.url);
          }

          // 可选扩展：播放源开始后回调（默认关闭）
          PlayerProvider.onPlaybackSourceStarted
              ?.call(resolvedSong, result.quality, result.url);
        } else {
          _isResolvingUrl = false;
          _resolveError = _resolveErrorText(_currentSong);
          final failedSong = _currentSong!;
          notifyListeners();
          // 先弹窗提示，随即切到下一首（不阻塞）
          _showUnplayableSongDialog(failedSong);
          // 听书付费章节失败不自动跳下一曲：整专辑大概率连续付费，
          // 自动切会疯狂刷日志且无意义，由用户手动选择。
          if (_playlist.length > 1 && !failedSong.isLongAudio) {
            await next(autoPlay: true);
          }
        }
      }
    } catch (e) {
      _isResolvingUrl = false;
      _resolveError = e.toString();
      notifyListeners();
    }

    _prefetchNextSongs(_currentIndex);
    _fetchClimaxData();
  }

  void _prefetchNextSongs(int startIndex) {
    final prefetchCount = 3;
    for (
      int i = startIndex + 1;
      i < _playlist.length && i <= startIndex + prefetchCount;
      i++
    ) {
      final song = _playlist[i];
      if (song.isOnline && song.url == null) {
        KugouApiClient()
            .getSongUrlWithFallback(
              song.id,
              quality: _audioQuality.value,
              albumId: song.albumId,
              albumAudioId: song.albumAudioId,
            )
            .then((result) {
              if (result != null && result.url.isNotEmpty) {
                _playlist[i] = song.copyWith(url: result.url);
              }
            });
      }
    }
  }

  /// 播放云盘歌曲列表。
  /// 与 [playOnlinePlaylist] 的区别：URL 解析优先走 /user/cloud/url，
  /// 失败再回退到 /song/url，适配用户上传到云盘的音乐。
  Future<void> playCloudPlaylist(List<Song> songs, int startIndex) async {
    if (songs.isEmpty) return;
    if (!KugouApiClient().isLoggedIn) {
      onLoginRequired?.call();
      return;
    }

    _loadPlaylist(songs, startIndex);
    _currentSong = _playlist[_currentIndex];
    _isResolvingUrl = true;
    _resolveError = null;
    _updatePosition(Duration.zero);
    _recordHistory(_currentSong!);
    _updateNotification();
    notifyListeners();

    try {
      final apiClient = KugouApiClient();
      final url = await resolveCloudUrl(apiClient, _currentSong!);
      if (url != null && url.isNotEmpty) {
        final resolvedSong = _currentSong!.copyWith(url: url);
        _currentSong = resolvedSong;
        _playlist[_currentIndex] = resolvedSong;
        _isResolvingUrl = false;
        notifyListeners();
        if (_audioService != null) {
          await _setUrlAndPlay(url);
        }
        // 云盘封面内嵌在音频文件中（API 不返回封面 URL）：
        // 播放后异步从音频提取并回填 artworkUri
        _extractCloudArtwork(resolvedSong, url);
      } else {
        _isResolvingUrl = false;
        _resolveError = '无法获取云盘播放链接';
        notifyListeners();
      }
    } catch (e) {
      _isResolvingUrl = false;
      _resolveError = e.toString();
      notifyListeners();
    }

    _prefetchCloudSongs(_currentIndex);
    _fetchClimaxData();
  }

  /// 云盘歌曲 URL 解析：先 /user/cloud/url，后 /song/url 兜底。
  /// 公开给投屏（DlnaProvider）等场景复用。
  Future<String?> resolveCloudUrl(
    KugouApiClient apiClient,
    Song song,
  ) async {
    try {
      final cloudResult = await apiClient.getUserCloudUrl(
        song.id,
        albumId: song.albumId,
        name: song.title,
        albumAudioId: song.albumAudioId,
      );
      if (cloudResult != null) {
        final data = cloudResult['data'];
        if (data is Map<String, dynamic>) {
          final rawUrl = data['url'];
          if (rawUrl is String && rawUrl.isNotEmpty) {
            return rawUrl;
          }
          if (rawUrl is List && rawUrl.isNotEmpty) {
            return rawUrl.first.toString();
          }
        }
      }
    } catch (_) {}

    // 回退到通用 /song/url
    try {
      final result = await apiClient.getSongUrlWithFallback(
        song.id,
        quality: _audioQuality.value,
        albumId: song.albumId,
        albumAudioId: song.albumAudioId,
      );
      if (result != null && result.url.isNotEmpty) {
        _actualPlayingQuality = result.quality;
        return result.url;
      }
    } catch (_) {}
    return null;
  }

  /// 云盘封面内嵌在音频文件中（API 不返回封面 URL），播放后异步提取。
  ///
  /// 本地持久化封面提取扩展点：公开版本无实现（保持调用方兼容）。
  Future<void> _extractCloudArtwork(Song song, String audioUrl) async {
    try {
      final extract = PlayerProvider.extractEmbeddedArtwork;
      final path = extract != null ? await extract(song.id, audioUrl) : null;
      if (path == null) return;
      // 回填封面路径（file://），并同步通知栏/UI
      final updated = song.copyWith(artworkUri: path);
      final idx = _playlist.indexWhere((s) => s.id == song.id);
      if (idx >= 0) _playlist[idx] = updated;
      if (_currentSong?.id == song.id) {
        _currentSong = updated;
        _updateNotification();
      }
      notifyListeners();
    } catch (_) {
      // 提取失败静默，保持无封面
    }
  }

  /// 预取云盘列表后续歌曲 URL（对齐 _prefetchNextSongs）
  void _prefetchCloudSongs(int startIndex) {
    final prefetchCount = 3;
    final apiClient = KugouApiClient();
    for (int i = startIndex + 1;
        i < _playlist.length && i <= startIndex + prefetchCount;
        i++) {
      final song = _playlist[i];
      if (song.isOnline && song.url == null) {
        resolveCloudUrl(apiClient, song).then((url) {
          if (url != null && url.isNotEmpty) {
            _playlist[i] = song.copyWith(url: url);
          }
        });
      }
    }
  }

  /// 设置音频源并等待就绪后播放。
  ///
  /// 不直接使用 [playerStateStream.firstWhere] 等待 ready 状态,因为
  /// `setUrl` 期间可能已经发出过 ready 事件,而 broadcast stream 的
  /// `firstWhere` 只能捕获订阅之后的事件,会一直等不到下一次 ready,
  /// 直到超时才走到 play(),表现为"暂停"。
  /// 这里采用轮询同步状态 [AudioPlayer.playerState] 的方式,避免漏掉。
  Future<void> _setUrlAndPlay(
    String url, {
    Duration? seekTo,
    bool playAfter = true,
  }) async {
    if (_audioService == null) return;
    // 记录本次加载新源时间，防护 Windows 误报 completed 导致的自动切歌
    _lastUrlLoadStarted = DateTime.now();
    // 诊断日志：setUrl
    // ignore: avoid_print
    print('[D切歌] setUrl → ${url.substring(0, url.length < 60 ? url.length : 60)}');
    await _audioService.setUrl(url);
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      final state = _audioService.player.playerState;
      if (state.processingState == just_audio.ProcessingState.ready) {
        if (seekTo != null && seekTo > Duration.zero) {
          await _audioService.seek(seekTo);
        }
        if (playAfter) {
          await _audioService.play();
        }
        return;
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
    // 超时仍尝试 seek/play,避免完全卡住
    if (seekTo != null && seekTo > Duration.zero) {
      await _audioService.seek(seekTo);
    }
    if (playAfter) {
      await _audioService.play();
    }
  }

  // 淡入淡出竞态 token：每次新的 fade 操作自增，旧 fade 循环检测到过期则中止
  int _fadeToken = 0;

  Future<void> pause() async {
    // 取消正在进行的淡入
    _fadeToken++;
    // 交叉淡化进行中被暂停：先收掉正在淡出的那一路，否则下面的暂停淡出
    // 只作用于活动播放器，旧歌会继续响
    _audioService?.abortCrossfade();
    _resetCrossfadePrepared();
    final fadeEnabled = await SettingsRepository().getPauseFadeEnabled();
    if (fadeEnabled && _audioService != null) {
      // 捕获播放器实例，不在循环里重新读 `player`。
      // `player` 返回的是「当前活动播放器」，交叉淡化会在半途换掉它；
      // 每次迭代重新取会把递减音量写到刚淡入的新歌上，收尾的
      // setVolume(_volume) 再把它猛拉回正常音量——表现正是
      // 「下一首不渐强反而减弱，到点后音量突然恢复」。
      final target = _audioService!.player;
      // 从播放器实际当前音量开始淡出（避免淡入未完成时音量跳变）
      final currentVol = target.volume;
      final token = _fadeToken;
      const steps = 10;
      const stepMs = 50; // 10步 x 50ms = 500ms
      // 淡出循环加 try-catch：若中途被切歌/清列表等竞态打断抛异常，
      // 仍要确保最终 pause 执行，否则播放器继续播放、playingStream 不发
      // false，WakeLock 无法释放（暂停后功耗降不下来）
      try {
        for (int i = steps - 1; i >= 0; i--) {
          // 被更新的 fade / 切歌抢占就停手，别再动音量
          if (token != _fadeToken) break;
          target.setVolume(currentVol * i / steps);
          await Future.delayed(const Duration(milliseconds: stepMs));
        }
      } catch (_) {}
      await _audioService?.pause();
      // 恢复音量设置（下次播放时使用）
      if (token == _fadeToken) target.setVolume(_volume);
    } else {
      await _audioService?.pause();
    }
    _saveState();
  }

  /// 拖动进度条时直接暂停（无淡入淡出），避免拖动期间音量渐变影响体验。
  Future<void> pauseForSeek() async {
    _fadeToken++;
    _audioService?.abortCrossfade();
    _resetCrossfadePrepared();
    await _audioService?.pause();
  }

  Future<void> resume() async {
    // 交叉淡化进行中：不跑淡入循环，直接 play（已在播时是 no-op）。
    // 淡入循环会以 50ms 步进与淡化斜坡抢 setVolume 通道：交叉点前写旧歌
    // 会让渐出的旧歌音量回升，交叉点后写捕获的旧实例会把刚淡入的新歌
    // 压回低位——听感正是"渐出渐入反过来"。pause() 已先 abortCrossfade，
    // 此处斜坡仍在跑，守卫必须为只读（不能 abort，否则淡化被取消）。
    if (_crossfadeStarting || _audioService?.isCrossfading == true) {
      // ignore: avoid_print
      print('[Fade] resume 跳过淡入：淡化进行中');
      await _audioService?.play();
      _saveState();
      return;
    }
    final fadeEnabled = await SettingsRepository().getPauseFadeEnabled();
    if (fadeEnabled && _audioService != null) {
      final targetVolume = _volume;
      final token = ++_fadeToken;
      // 同 pause()：捕获实例，避免循环中途活动播放器被交叉淡化换掉
      final target = _audioService!.player;
      // 先设置低音量再播放，避免突然出声
      target.setVolume(0.01);
      // 不 await play()：避免 play() 的 Future 阻塞导致淡入代码不执行
      _audioService!.play();
      // 淡入：逐步提升音量到目标值
      const steps = 10;
      const stepMs = 50; // 10步 x 50ms = 500ms
      for (int i = 1; i <= steps; i++) {
        if (token != _fadeToken) return;
        await Future.delayed(const Duration(milliseconds: stepMs));
        if (token != _fadeToken) return;
        target.setVolume(targetVolume * i / steps);
      }
    } else {
      await _audioService?.play();
    }
    _saveState();
  }

  Future<void> seek(Duration position) async {
    // 拖动进度条：中止淡化（AudioService.seek 内部也会中止，这里同步清掉
    // 预加载状态，避免拖回中段后仍按旧的"即将播完"判定起播下一首）
    _resetCrossfadePrepared();
    // 立即更新位置，让 UI（进度条、歌词行高亮、滚动）即时响应
    // 否则要等 just_audio positionStream 触发，会有一帧的滞后，
    // 导致拖动 slider 后歌词不跟随。
    if (_position != position) {
      _updatePosition(position);
      notifyListeners();
    }
    await _audioService?.seek(position);
    _saveState();
    // 同步进度到 Lyricon（仅 enabled 时推送，避免无意义 IPC；
    // seek 由用户拖动进度条或切歌/上一首/下一首触发，频率自然不高，无需额外节流）
    if (LyriconProviderService.instance.enabled) {
      try {
        LyriconProviderService.instance.seekTo(position.inMilliseconds);
      } catch (_) {}
    }
    // seek 后立即同步通知/小组件进度（频率天然低），并重置节流时间戳，
    // 使新位置立即反映到媒体通知进度条。
    _lastNotificationUpdate = null;
    _updateNotification();
  }

  Future<bool> _resolveAndPlayCurrentSong({Duration? seekTo, bool play = true}) async {
    if (_currentSong == null) return false;

    if (_currentSong!.isOnline) {
      // 可选扩展：播放前解析本地已持久化的音频（默认关闭）
      final song = _currentSong!;
      final localAudioResolver = PlayerProvider.resolveLocalAudioPath;
      String? cachedPath;
      if (localAudioResolver != null) {
        cachedPath = await localAudioResolver(song.id, _audioQuality.value);
      }
      if (cachedPath != null) {
        // 命中本地已持久化音频，直接播放本地文件
        _actualPlayingQuality = _audioQuality.value;
        await _setUrlAndPlay(
          Uri.file(cachedPath).toString(),
          seekTo: seekTo,
          playAfter: play,
        );
        // 异步获取高潮时间（不阻塞播放）
        _fetchClimaxData();
        return true;
      }

      // 缓存未命中：需要 URL 来播放
      if (song.url == null) {
        // URL 不存在，需要解析
        if (!KugouApiClient().isLoggedIn) {
          onLoginRequired?.call();
          return false;
        }

        // 确保本地 API 服务器已启动（所有酷狗 API 走本地随机端口）
        // 冷启动时 MethodChannel 可能尚未注册，导致 KugouApiServer.start() 失败，
        // 此处做二次兜底检查，避免 API 请求因服务器未就绪而全部失败
        await _ensureApiServerReady();

        _isResolvingUrl = true;
        notifyListeners();

        try {
          final result = await KugouApiClient().getSongUrlWithFallback(
            _currentSong!.id,
            quality: _audioQuality.value,
            albumId: _currentSong!.albumId,
            albumAudioId: _currentSong!.albumAudioId,
          );

          if (result != null && result.url.isNotEmpty) {
            _actualPlayingQuality = result.quality;
            final resolvedSong = _currentSong!.copyWith(url: result.url);
            _currentSong = resolvedSong;
            _playlist[_currentIndex] = resolvedSong;
            // 可选扩展：播放源开始后回调（默认关闭）
            PlayerProvider.onPlaybackSourceStarted
                ?.call(_currentSong!, result.quality, result.url);
          } else {
            _isResolvingUrl = false;
            return false;
          }
        } catch (e) {
          _isResolvingUrl = false;
          return false;
        }
      } else {
        // URL 已存在（预取过），可选扩展：播放源开始后回调（默认关闭）
        PlayerProvider.onPlaybackSourceStarted
            ?.call(song, _audioQuality.value, song.url!);
      }
    }

    _isResolvingUrl = false;
    notifyListeners();

    // 云盘歌曲封面内嵌在音频中：切歌后同样异步提取（URL 已就绪时）
    final curSong = _currentSong;
    if (curSong != null && curSong.isCloud && curSong.artworkUri == null) {
      final curUrl = curSong.url;
      if (curUrl != null && curUrl.isNotEmpty) {
        _extractCloudArtwork(curSong, curUrl);
      }
    }

    if (_audioService != null) {
      final playbackUrl = await _resolvePlaybackUrl(_currentSong!);
      if (playbackUrl != null && playbackUrl.isNotEmpty) {
        // 把解析后的真实路径回写到 song（适用于本地 content:// URI）
        if (!_currentSong!.isOnline) {
          _currentSong = _currentSong!.copyWith(localPath: playbackUrl);
          _playlist[_currentIndex] = _currentSong!;
          notifyListeners();
        }
        await _setUrlAndPlay(playbackUrl, seekTo: seekTo, playAfter: play);
      } else {
        _resolveError = _resolveErrorText(_currentSong);
        notifyListeners();
      }
    }

    // 异步获取高潮时间（不阻塞播放）
    _fetchClimaxData();

    return true;
  }

  /// 确保本地 API 服务器已就绪（随机端口，见 KugouApiServer.currentPort）。
  ///
  /// 冷启动时 main() 中的 KugouApiServer.start() 可能因 MethodChannel 尚未注册
  /// 而失败（MissingPluginException），导致后续所有 API 请求因连接被拒绝而失败。
  /// 此方法在播放流程中做二次兜底：探测端口，若不通则重新尝试启动。
  Future<void> _ensureApiServerReady() async {
    if (kIsWeb || !Platform.isAndroid) return;
    final port = KugouApiServer.currentPort;
    if (port <= 0) {
      await KugouApiServer.start();
      return;
    }
    // 快速探测端口是否可用
    try {
      final socket = await Socket.connect('127.0.0.1', port,
          timeout: const Duration(milliseconds: 500));
      await socket.close();
      return; // 服务器已就绪
    } catch (_) {
      // 端口不通，尝试重新启动
    }
    try {
      await KugouApiServer.start();
    } catch (_) {}
  }

  /// 异步获取当前歌曲的高潮时间数据。
  ///
  /// 调用酷狗 /song/climax 接口，获取高潮起止时间后更新 [_currentSong]。
  /// 不阻塞播放流程，失败时静默忽略。
  Future<void> _fetchClimaxData() async {
    final song = _currentSong;
    if (song == null || !song.isOnline) return;
    if (song.climaxStart != null) return;
    try {
      final climax = await KugouApiClient().getSongClimax(
        song.id,
        albumAudioId: song.albumAudioId,
      );
      if (climax == null) return;
      final startMs = double.tryParse(climax.startTime ?? '');
      final endMs = double.tryParse(climax.endTime ?? '');
      if (startMs == null || endMs == null) return;
      if (_currentSong?.id != song.id) return;
      // API 返回毫秒，转为秒存储
      _currentSong = song.copyWith(
        climaxStart: startMs / 1000.0,
        climaxEnd: endMs / 1000.0,
      );
      final idx = _playlist.indexWhere((s) => s.id == song.id);
      if (idx >= 0) _playlist[idx] = _currentSong!;
      notifyListeners();
    } catch (_) {
      // 静默忽略，高潮数据非必需
    }
  }

  Future<void> next({bool autoPlay = true}) async {
    if (_playlist.isEmpty) return;
    _resetAbnormalRetry();

    // 可选扩展：播放源停止回调（默认关闭）
    if (_currentSong != null && _currentSong!.isOnline) {
      PlayerProvider.onPlaybackSourceStopped?.call(_currentSong!.id);
    }

    if (_loopMode == AppLoopMode.one) {
      await seek(Duration.zero);
      if (autoPlay) await _audioService?.play();
      return;
    }

    // 已到末尾且非列表循环,停止播放(不静默跳到下一首)
    if (_currentIndex >= _playlist.length - 1 && _loopMode != AppLoopMode.all) {
      await _audioService?.pause();
      return;
    }

    final startIndex = _currentIndex;
    // 自动跳过无法获取播放链接的歌曲，直到找到可播放的或全部试过
    for (int i = 0; i < _playlist.length; i++) {
      final nextIndex = (_currentIndex + 1) % _playlist.length;
      // 绕回起点：所有歌曲都试过了
      if (nextIndex == startIndex) break;

      _currentIndex = nextIndex;
      _currentSong = _playlist[nextIndex];
      _resolveError = null;
      // 诊断日志：next 切歌
      // ignore: avoid_print
      print('[D切歌] next: _currentIndex=$_currentIndex → id=${_currentSong!.id}');
      _updatePosition(Duration.zero); // 切歌时重置位置，避免恢复时跳到上一首的进度
      _recordHistory(_currentSong!);
      _updateNotification();
      _saveState();

      final ok = await _resolveAndPlayCurrentSong(play: autoPlay);
      if (ok) {
        // 切歌后刷新通知栏：投屏场景下 play=false 不会触发 playingStream 回调刷新通知，
        // 需要在此显式刷新，避免 MediaSession 封面停留在上一首。
        _updateNotification();
        notifyListeners();
        return;
      }
      // 无法获取链接，继续尝试下一首
      _resolveError = _resolveErrorText(_currentSong);

      // 非列表循环模式下，到末尾就停止尝试
      if (_currentIndex >= _playlist.length - 1 &&
          _loopMode != AppLoopMode.all) {
        break;
      }
    }

    // 所有歌曲都试过仍失败
    _updateNotification();
    notifyListeners();
  }

  Future<void> previous({bool autoPlay = true}) async {
    if (_playlist.isEmpty) return;
    _resetAbnormalRetry();

    // 可选扩展：播放源停止回调（默认关闭）
    if (_currentSong != null && _currentSong!.isOnline) {
      PlayerProvider.onPlaybackSourceStopped?.call(_currentSong!.id);
    }

    final startIndex = _currentIndex;
    int prevIndex = _currentIndex;
    for (int i = 0; i < _playlist.length; i++) {
      prevIndex = prevIndex > 0 ? prevIndex - 1 : _playlist.length - 1;
      if (prevIndex == startIndex) {
        if (_loopMode == AppLoopMode.all) break;
        await seek(Duration.zero);
        return;
      }

      _currentIndex = prevIndex;
      _currentSong = _playlist[prevIndex];
      _resolveError = null;
      _updatePosition(Duration.zero);
      _recordHistory(_currentSong!);

      if (await _resolveAndPlayCurrentSong(play: autoPlay)) {
        // 切歌后刷新通知栏封面（投屏场景下 play=false 不会触发 playingStream 回调）
        _updateNotification();
        _saveState();
        return;
      }
      _resolveError = _resolveErrorText(_currentSong);
    }
    _saveState();
    notifyListeners();
  }

  Future<void> playSongAt(int index) async {
    if (index < 0 || index >= _playlist.length) return;
    _resetAbnormalRetry();

    // 可选扩展：播放源停止回调（默认关闭）
    if (_currentSong != null && _currentSong!.isOnline) {
      PlayerProvider.onPlaybackSourceStopped?.call(_currentSong!.id);
    }

    _currentIndex = index;
    _currentSong = _playlist[index];
    _resolveError = null;
    // 诊断日志：切歌目标
    // ignore: avoid_print
    print('[D切歌] playSongAt index=$index 实际_currentIndex=$_currentIndex → id=${_currentSong!.id}');
    _updatePosition(Duration.zero);
    _recordHistory(_currentSong!);
    _saveState();
    notifyListeners();

    final ok = await _resolveAndPlayCurrentSong();
    if (!ok) {
      _resolveError = _resolveErrorText(_currentSong);
      final failedSong = _currentSong!;
      _showUnplayableSongDialog(failedSong);
      // 听书付费章节失败不自动跳下一曲：整专辑大概率连续付费，
      // 自动切会疯狂刷日志且无意义，由用户手动选择。
      if (_playlist.length > 1 && !failedSong.isLongAudio) {
        await next(autoPlay: true);
      }
    }
  }

  Future<void> clearPlaylist() async {
    _resetCrossfadePrepared();
    // 可选扩展：播放源停止回调（默认关闭）
    if (_currentSong != null && _currentSong!.isOnline) {
      PlayerProvider.onPlaybackSourceStopped?.call(_currentSong!.id);
    }

    await _audioService?.stop();
    _playlist = [];
    _originalPlaylist = [];
    _currentIndex = -1;
    _currentSong = null;
    _isPlaying = false;
    _updatePosition(Duration.zero);
    _duration = null;
    _resolveError = null;
    _stateRepo.clearState();
    _updateNotification();
    notifyListeners();
  }

  Future<void> appendPlaylist(List<Song> songs) async {
    final newSongs = <Song>[];
    for (final song in songs) {
      if (!_playlist.any((s) => s.id == song.id)) {
        newSongs.add(song);
        _playlist.add(song);
      }
    }
    notifyListeners();

    if (newSongs.isNotEmpty) {
      if (_audioService != null) {
        // 异步把 content:// 全部解析为真实路径后建 source
        final resolvedSongs = await _resolveLocalPathsForBatch(newSongs);
        final sources = resolvedSongs
            .map((song) => _createAudioSource(song))
            .toList();
        await _audioService.addAllAudioSources(sources);
        // 回写真实路径到 _playlist
        for (final song in resolvedSongs) {
          final idx = _playlist.indexWhere((s) => s.id == song.id);
          if (idx >= 0) _playlist[idx] = song;
        }
        notifyListeners();
      }
      _prefetchNextSongs(_currentIndex);
    }
  }

  /// 更新播放列表中指定歌曲的字段（用于 NAS 按需下载后回写 localPath）。
  /// 不重建 audio_service 队列，避免打断当前播放。
  void updateSongInPlaylist(Song updatedSong) {
    final idx = _playlist.indexWhere((s) => s.id == updatedSong.id);
    if (idx < 0) return;
    _playlist[idx] = updatedSong;
    // 如果更新的是当前歌曲，同步更新 _currentSong
    if (idx == _currentIndex) {
      _currentSong = updatedSong;
    }
    notifyListeners();
  }

  /// 在当前播放歌曲之后插入歌曲（"下一首播放"功能）。
  ///
  /// - 不在播放列表中的歌曲：新增并插入到当前歌曲之后，同步 audio_service 队列。
  /// - 已在播放列表中的歌曲：移动到当前歌曲之后（不重复添加），仅调整 Dart 端
  ///   顺序，不重建 audio_service 队列（与 [reorderPlaylist] 策略一致，避免
  ///   打断当前播放；切歌走 _currentIndex/_playlist，不依赖 audio_service 队列）。
  Future<void> insertAfterCurrent(List<Song> songs) async {
    if (songs.isEmpty) return;
    if (_playlist.isEmpty || _currentIndex < 0) {
      // 播放列表为空，直接追加
      await appendPlaylist(songs);
      return;
    }

    final currentId = _playlist[_currentIndex].id;
    final newSongs = <Song>[]; // 不在列表中：需新增
    final moveSongs = <Song>[]; // 已在列表中：需移动
    for (final song in songs) {
      // 当前正在播放的歌曲本身就是"当前"，无需移动
      if (song.id == currentId) continue;
      if (_playlist.any((s) => s.id == song.id)) {
        moveSongs.add(song);
      } else {
        newSongs.add(song);
      }
    }
    if (newSongs.isEmpty && moveSongs.isEmpty) return;

    // 1. 先从 _playlist 移除待移动歌曲（稍后统一插回当前歌曲之后）
    if (moveSongs.isNotEmpty) {
      final moveIds = moveSongs.map((s) => s.id).toSet();
      _playlist.removeWhere((s) => moveIds.contains(s.id));
    }

    // 2. 重新定位当前歌曲索引（前面被移除的歌曲会使当前歌曲前移）
    int curIdx = _playlist.indexWhere((s) => s.id == currentId);
    if (curIdx < 0) curIdx = _playlist.isEmpty ? 0 : _playlist.length - 1;
    final insertIndex = curIdx + 1;

    // 3. 插入：新增歌曲在前，移动歌曲在后，保持调用顺序
    _playlist.insertAll(insertIndex, [...newSongs, ...moveSongs]);

    // 4. 当前歌曲本身未移动，但其前后增删歌曲会改变索引，按 id 重新定位
    _currentIndex = _playlist.indexWhere((s) => s.id == currentId);
    if (_currentIndex < 0) _currentIndex = 0;

    // 5. 同步 _originalPlaylist：把新增+移动的歌曲插到当前歌曲之后
    if (moveSongs.isNotEmpty) {
      final moveIds = moveSongs.map((s) => s.id).toSet();
      _originalPlaylist.removeWhere((s) => moveIds.contains(s.id));
    }
    final origCurIdx = _originalPlaylist.indexWhere((s) => s.id == currentId);
    final origInsert = origCurIdx >= 0
        ? (origCurIdx + 1).clamp(0, _originalPlaylist.length)
        : _originalPlaylist.length;
    _originalPlaylist.insertAll(origInsert, [...newSongs, ...moveSongs]);

    notifyListeners();

    // 6. audio_service 队列同步：仅对新增歌曲插入 source。
    //    移动歌曲不重建队列（Dart 端顺序已正确，切歌走 _currentIndex）。
    if (_audioService != null && _currentSong != null && newSongs.isNotEmpty) {
      final resolvedSongs = await _resolveLocalPathsForBatch(newSongs);
      // 回写真实路径到 _playlist（newSongs 占据 insertIndex 起的位置）
      for (int i = 0; i < resolvedSongs.length; i++) {
        final idx = insertIndex + i;
        if (idx < _playlist.length) {
          _playlist[idx] = resolvedSongs[i];
        }
      }
      // 逐个插入到 audio_service 队列，不打断当前播放
      for (int i = 0; i < resolvedSongs.length; i++) {
        final source = _createAudioSource(resolvedSongs[i]);
        await _audioService.insertAudioSourceAt(insertIndex + i, source);
      }
      notifyListeners();
    }
    _prefetchNextSongs(_currentIndex);
  }

  /// 从播放列表中删除指定索引的歌曲。
  ///
  /// 同步更新 _playlist / _originalPlaylist / _currentIndex。
  /// 底层 audio_service 队列的处理策略：
  /// - 删除非当前歌曲：**不重建** audio_service 队列，避免打断当前播放。
  ///   音频结束事件由 _handlePlaybackCompleted 监听，所有跳转/切歌都使用
  ///   Dart 端 _playlist + _resolveAndPlayCurrentSong，不依赖 audio_service
  ///   内部队列，因此陈旧的内部队列不会造成问题。
  /// - 删除当前歌曲：必须重建 audio_service 队列并加载新当前歌曲。
  /// - 列表清空：停止 audio_service。
  /// 边界处理：
  /// - 列表为空：清空所有播放状态
  /// - 删除的是当前播放歌曲：自动切到同索引位置的新歌
  /// - 删除的在当前歌曲之前：_currentIndex 前移
  /// - 删除的在当前歌曲之后：索引不变
  Future<void> removeFromPlaylist(int index) async {
    if (index < 0 || index >= _playlist.length) return;

    final removedSong = _playlist[index];
    final wasCurrent = index == _currentIndex;

    // 1. 维护 Dart 端列表
    _playlist.removeAt(index);

    // 同步 _originalPlaylist（shuffle 关闭时用于还原原始顺序）
    final origIndex = _originalPlaylist.indexWhere(
      (s) => s.id == removedSong.id,
    );
    if (origIndex != -1) _originalPlaylist.removeAt(origIndex);

    // 2. 维护当前播放索引
    if (_playlist.isEmpty) {
      _currentIndex = -1;
      _currentSong = null;
      _isPlaying = false;
      _updatePosition(Duration.zero);
      _duration = null;
      _resolveError = null;
    } else if (wasCurrent) {
      // 删除的就是当前播放歌曲：跳到（原 index 处的）新歌
      // index 可能在删除后越界，需要 clamp
      _currentIndex = index.clamp(0, _playlist.length - 1);
      _currentSong = _playlist[_currentIndex];
      _resolveError = null;
    } else if (index < _currentIndex) {
      // 删除的在当前歌曲之前：索引前移
      _currentIndex--;
    }

    // 3. 同步底层 audio_service 队列
    if (_audioService == null) {
      // 无 audio_service（初始化未完成），仅更新 Dart 端状态
    } else if (_playlist.isEmpty) {
      // 列表清空：停止播放
      await _audioService!.stop();
      _updateNotification();
    } else if (wasCurrent) {
      // 删除的是当前播放歌曲：先解析新当前歌曲的 URL，再重建队列播放
      if (_currentSong != null && _currentSong!.isOnline && _currentSong!.url == null) {
        try {
          final result = await KugouApiClient().getSongUrlWithFallback(
            _currentSong!.id,
            quality: _audioQuality.value,
            albumId: _currentSong!.albumId,
            albumAudioId: _currentSong!.albumAudioId,
          );
          if (result != null && result.url.isNotEmpty) {
            _actualPlayingQuality = result.quality;
            final resolvedSong = _currentSong!.copyWith(url: result.url);
            _currentSong = resolvedSong;
            _playlist[_currentIndex] = resolvedSong;
          }
        } catch (_) {}
      }
      // 重建前先批量解析本地 content://，避免 just_audio 加载失败
      final resolvedPlaylist = await _resolveLocalPathsForBatch(_playlist);
      for (int i = 0; i < resolvedPlaylist.length && i < _playlist.length; i++) {
        _playlist[i] = resolvedPlaylist[i];
      }
      if (_currentIndex >= 0 && _currentIndex < _playlist.length) {
        _currentSong = _playlist[_currentIndex];
      }
      final sources = _playlist.map(_createAudioSource).toList();
      await _audioService!.setPlaylist(
        sources,
        startIndex: _currentIndex >= 0 ? _currentIndex : 0,
      );
      await _audioService!.seek(Duration.zero);
      await _audioService!.play();
    }
    // else: 删除非当前歌曲，不动 audio_service，避免打断当前播放
    _updateNotification();

    notifyListeners();
  }

  /// 重排播放列表中的歌曲顺序。
  ///
  /// 参数遵循 Flutter ReorderableListView 的约定：当 oldIndex < newIndex
  /// 时，newIndex 需要 -1 才是实际插入位置。
  ///
  /// 只更新 Dart 端 _playlist / _originalPlaylist / _currentIndex，
  /// **不重建** audio_service 队列。
  /// 原理：项目所有切歌逻辑（_handlePlaybackCompleted → next() →
  /// _resolveAndPlayCurrentSong）都使用 Dart 端 _currentIndex 和 _currentSong
  /// 加载 URL，不依赖 audio_service 内部队列。audio_service 当前正在播放的
  /// source 不会因为 _playlist 顺序变化而失效，重建反而会打断当前播放。
  Future<void> reorderPlaylist(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= _playlist.length) return;

    // ReorderableListView 的 newIndex 在 oldIndex 之前时需 -1 的标准处理
    if (oldIndex < newIndex) newIndex -= 1;
    if (oldIndex == newIndex) return;
    if (newIndex < 0 || newIndex >= _playlist.length) return;

    // 1. 维护 Dart 端列表
    final song = _playlist.removeAt(oldIndex);
    _playlist.insert(newIndex, song);

    // 同步 _originalPlaylist：按相同偏移量调整
    final origOld = _originalPlaylist.indexWhere((s) => s.id == song.id);
    if (origOld != -1) {
      _originalPlaylist.removeAt(origOld);
      final origNew = origOld.clamp(0, _originalPlaylist.length);
      _originalPlaylist.insert(origNew, song);
    }

    // 2. 维护当前播放索引
    if (oldIndex == _currentIndex) {
      // 拖动的是当前播放歌曲：索引跟随到新位置
      _currentIndex = newIndex;
    } else if (oldIndex < _currentIndex && newIndex >= _currentIndex) {
      // 当前歌曲被「向后挤」一位
      _currentIndex--;
    } else if (oldIndex > _currentIndex && newIndex <= _currentIndex) {
      // 当前歌曲被「向前挤」一位
      _currentIndex++;
    }

    // 3. 不重建 audio_service 队列，避免打断当前播放
    _updateNotification();
    notifyListeners();
  }

  Future<void> toggleLoopMode() async {
    // 循环模式决定"下一首是谁"，预加载结果作废
    _resetCrossfadePrepared();
    switch (_loopMode) {
      case AppLoopMode.off:
        _loopMode = AppLoopMode.all;
        break;
      case AppLoopMode.all:
        _loopMode = AppLoopMode.one;
        break;
      case AppLoopMode.one:
        _loopMode = AppLoopMode.off;
        break;
    }
    // just_audio 的 LoopMode 始终保持 off：应用层通过 _handlePlaybackCompleted
    // 完全控制循环行为（one 从头重播、all 列表循环、off 播完即停）。
    // 若设成 one/all，单 source 下 just_audio 会自动循环且不触发 completed，
    // 导致 _handlePlaybackCompleted 不被调用，表现为单曲循环。
    if (_audioService != null) {
      await _audioService.setLoopMode(just_audio.LoopMode.off);
    }
    _saveState();
    notifyListeners();
  }

  Future<void> toggleShuffle() async {
    // 列表顺序即将改变，预加载结果作废
    _resetCrossfadePrepared();
    _shuffleEnabled = !_shuffleEnabled;
    // just_audio 的 shuffleMode 始终保持 false：应用层通过打乱 _playlist
    // （Dart List）控制播放顺序，不依赖 just_audio 的 shuffle。若开启
    // just_audio shuffle，多 source 场景下其内部 advancing 顺序与应用层
    // _currentIndex/_currentSong 不一致。
    if (_audioService != null) {
      await _audioService.setShuffleModeEnabled(false);
    }
    if (_shuffleEnabled) {
      final currentSong = _currentSong;
      final remaining = _playlist
          .where((s) => s.id != currentSong?.id)
          .toList();
      remaining.shuffle();
      // currentSong 可能为 null，使用 collection-if 条件添加
      _playlist = [if (currentSong != null) currentSong, ...remaining];
      _currentIndex = 0;
    } else {
      final currentSong = _currentSong;
      _playlist = List.from(_originalPlaylist);
      if (currentSong != null) {
        _currentIndex = _playlist.indexWhere((s) => s.id == currentSong.id);
        if (_currentIndex < 0) _currentIndex = 0;
      }
    }
    _saveState();
    notifyListeners();
  }

  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    await _audioService?.setVolume(_volume);
    // 持久化应用内音量（重启保留）
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('player_volume', _volume);
    } catch (_) {}
    notifyListeners();
  }

  Future<void> setSpeed(double speed) async {
    _speed = speed.clamp(0.25, 4.0);
    await _audioService?.setSpeed(_speed);
    notifyListeners();
  }

  void setAudioQuality(AudioQuality quality) {
    if (_audioQuality == quality) return;
    _audioQuality = quality;
    _actualPlayingQuality = null;
    // 手动切换：写入当前网络对应的音质键（设置页两套音质模型）
    SettingsRepository().setQualityForNetwork(_isWifiNetwork, quality.value);
    notifyListeners();
    _applyQualityToCurrent();
  }

  /// 设置 / 取消睡眠定时。
  /// [duration] 为 null 表示取消；非 null 表示 duration 后自动暂停播放。
  void setSleepTimer(Duration? duration) {
    _sleepTimerTicker?.cancel();
    _sleepTimerTicker = null;
    if (duration == null) {
      _sleepTimerEndTime = null;
      notifyListeners();
      return;
    }
    _sleepTimerEndTime = DateTime.now().add(duration);
    _sleepTimerTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      final end = _sleepTimerEndTime;
      if (end == null) return;
      final left = end.difference(DateTime.now());
      if (left <= Duration.zero) {
        // 到点：暂停 + 清理
        _sleepTimerTicker?.cancel();
        _sleepTimerTicker = null;
        _sleepTimerEndTime = null;
        _audioService?.pause();
        notifyListeners();
      } else {
        // 每秒刷新剩余时间，让 UI 药丸走字
        notifyListeners();
      }
    });
    notifyListeners();
  }

  Future<void> _applyQualityToCurrent() async {
    final song = _currentSong;
    if (song == null || !song.isOnline) return;
    if (_audioService == null) return;

    final wasPlaying = _audioService!.playing;
    final savedPosition = _audioService!.position;
    _isResolvingUrl = true;
    _resolveError = null;
    notifyListeners();

    try {
      final apiClient = KugouApiClient();
      final result = await apiClient.getSongUrlWithFallback(
        song.id,
        quality: _audioQuality.value,
        albumId: song.albumId,
        albumAudioId: song.albumAudioId,
      );

      if (result == null || result.url.isEmpty) {
        _isResolvingUrl = false;
        _resolveError = _resolveErrorText(song);
        notifyListeners();
        return;
      }

      _actualPlayingQuality = result.quality;
      final resolvedSong = song.copyWith(url: result.url);
      _currentSong = resolvedSong;
      if (_playlist.isNotEmpty && _currentIndex >= 0) {
        _playlist[_currentIndex] = resolvedSong;
      } else {
        _playlist
          ..clear()
          ..add(resolvedSong);
        _currentIndex = 0;
      }
      _isResolvingUrl = false;
      notifyListeners();

      if (_audioService != null) {
        // 同 playOnlinePlaylist:_playlist 中其他歌曲 url 仍为 null,
        // 用 setUrl 只切当前歌曲,避免 just_audio_web 的 null check 异常
        await _setUrlAndPlay(
          result.url,
          seekTo: savedPosition,
          playAfter: wasPlaying,
        );
      }
    } catch (e) {
      _isResolvingUrl = false;
      _resolveError = e.toString();
      notifyListeners();
    }
  }

  DateTime? _lastNotificationUpdate;

  void _updateNotificationPosition() {
    // P0: 暂停时位置不再变化，直接跳过。
    // 此前暂停时 positionStream 仍每 200ms 回调、这里每 1 秒无条件
    // updateNotification → Kotlin 每 1 秒 showNotification（封面提取、
    // startForeground、MediaSession 重建）→ 主线程/raster/binder 持续
    // 空转（暂停功耗降不下来、GPU raster 占用最高）。暂停瞬间已由
    // playingStream(false) 触发过最终状态通知，之后无需再更新。
    if (!_isPlaying) return;
    final now = DateTime.now();
    // P0: 播放中通知刷新降到 30s 一次（原 1s/次）。
    // 原因：PlaybackStateCompat 传入 STATE_PLAYING + position 后，系统会基于
    // elapsed 时间自动推进通知进度条，无需每秒上报。原每秒 enqueue 重建通知
    // 会触发 SystemUI 高频刷新媒体卡片（魅族等 ROM 实测极度卡顿）。
    // 30s 一次仅作基线校正；切歌/暂停/seek 时由对应事件单独触发更新。
    if (_lastNotificationUpdate != null &&
        now.difference(_lastNotificationUpdate!).inSeconds < 30) {
      return;
    }
    _lastNotificationUpdate = now;
    _updateNotification();
  }

  /// 手动选歌无法播放时，弹出提示对话框（提供查看 MV 和评论的入口）。
  /// 通过 [appNavigatorKey] 获取全局 context，不依赖具体 widget 重建。
  void _showUnplayableSongDialog(Song song) {
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null) return;
    showDialog(
      context: ctx,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('歌曲无法播放'),
        content: Text('「${song.displayName}」暂时无法播放，将切换到下一首'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('关闭'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogCtx);
              Navigator.push(ctx,
                MaterialPageRoute(builder: (_) => MvPlayerPage(song: song)),
              );
            },
            child: const Text('去看MV'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogCtx);
              showSongCommentsSheet(ctx, song);
            },
            child: const Text('看评论'),
          ),
        ],
      ),
    );
  }

  /// 预取队列中后续歌曲封面到原生本地缓存（方案B）。
  /// 切歌前把接下来数首的封面下载到缓存，切换时命中缓存秒显，根治封面空档。
  void _prefetchUpcomingCovers() {
    try {
      if (_playlist.isEmpty || _currentIndex < 0) return;
      final urls = <String?>[];
      // 预取接下来 3 首（含环回，贴合常见循环播放）
      for (int i = 1; i <= 3; i++) {
        if (_playlist.length <= 1) break;
        final idx = (_currentIndex + i) % _playlist.length;
        if (idx == _currentIndex) break;
        final s = _playlist[idx];
        // 仅在线歌走网络；本地歌封面本就秒读
        if (s.isOnline) urls.add(s.artworkUri);
      }
      if (urls.isNotEmpty) {
        MediaNotificationService.prefetchCover(urls);
      }
    } catch (_) {}
  }

  void _updateNotification() {
    final song = _currentSong;
    if (song == null) return;
    // 方案B：切歌后预取队列后续歌曲封面，下一首切换时命中缓存秒显
    _prefetchUpcomingCovers();
    // Check favorite status from FavoritesProvider via global context
    bool isFavorited = false;
    try {
      final ctx = appNavigatorKey.currentContext;
      if (ctx != null) {
        isFavorited = ctx.read<FavoritesProvider>().isFavorite(song.id);
      }
    } catch (_) {}
    _pushNotification(song, isFavorited);
    // 在线歌曲封面偶现失效：原生端每次临时用 HttpURLConnection 下载封面，
    // 覆盖网络波动/防泄漏链失败时 MediaSession 只剩 http ART_URI 而无 bitmap，
    // 锁屏/车机多数只读 bitmap 所以「封面没传过去」。这里优先把已本地缓存的
    // 封面 file:// 路径补发给原生，从源头规避对网络的临时依赖。
    if (song.isOnline &&
        song.artworkUri != null &&
        PlayerProvider.resolveLocalArtworkPath != null) {
      _pushNotificationWithCachedArtwork(song, isFavorited);
    }
    // 同步更新桌面小组件（封面由原生侧从 MediaSession 缓存同步，无需传路径）
    HomeWidgetService.updateWidget(
      title: song.displayName,
      artist: song.artist,
      isPlaying: _isPlaying,
      position: _position,
      duration: _duration ?? Duration.zero,
    );
  }

  /// 在线歌曲封面优先使用本地缓存路径（已由私有构建 StreamCacheManager 缓存）。
  /// 命中后原生端按 file:// 图片直接解码，不依赖网络；未缓存/失败时静默，
  /// 沿用原 artUrl。缓存封面解析是异步 IO，fire-and-forget 不阻塞播放主流程。
  void _pushNotificationWithCachedArtwork(Song song, bool isFavorited) {
    PlayerProvider.resolveLocalArtworkPath!(song.id).then((cached) {
      if (cached == null || cached.isEmpty) {
        // 封面链路日志：本地未缓存封面，沿用原 artUrl
        debugPrint('[PlayerProvider] 封面无本地缓存，沿用原 artUrl=${song.artworkUri}');
        return;
      }
      if (_currentSong?.id != song.id) {
        // 封面链路日志：缓存解析完成但已切歌，丢弃避免跨歌错配
        debugPrint('[PlayerProvider] 封面缓存解析完成但已切歌，丢弃 id=${song.id}');
        return;
      }
      final url = cached.startsWith('file://') ? cached : 'file://$cached';
      // 封面链路日志：命中本地缓存，改为下发 file:// 封面路径
      debugPrint('[PlayerProvider] 封面命中本地缓存并下发 id=${song.id} url=$url');
      _pushNotification(song, isFavorited, artUrlOverride: url);
    }).catchError((e) {
      // 封面链路日志：缓存封面解析异常，回退原逻辑
      debugPrint('[PlayerProvider] 封面缓存解析异常: $e');
    });
  }

  /// 统一下发通知/MediaSession 元数据。artUrlOverride 非空时优先用作封面源。
  void _pushNotification(Song song, bool isFavorited, {String? artUrlOverride}) {
    final artUrl = artUrlOverride ?? song.artworkUri;
    // 封面链路日志：记录最终下发给原生的封面源（便于区分是否走本地缓存/在线 URL）
    debugPrint('[PlayerProvider] 下发通知封面 artUrl=$artUrl '
        'override=${artUrlOverride != null} fallback=${song.localPath}');
    MediaNotificationService.updateNotification(
      // 使用 displayName 剥离 .mp3 等扩展名，与 _createAudioSource 行为保持一致
      title: song.displayName,
      artist: song.artist,
      artUrl: artUrl,
      // 本地歌曲传递文件路径，供原生侧提取内嵌封面
      fallbackFilePath: song.localPath,
      isPlaying: _isPlaying,
      position: _position,
      duration: _duration ?? Duration.zero,
      desktopLyricEnabled: DesktopLyricService.instance.enabled,
      isFavorited: isFavorited,
    );
  }

  /// Public method to refresh notification (called when favorite state changes)
  void refreshNotification() {
    _updateNotification();
  }

  void _recordHistory(Song song) {
    HistoryRepository().addHistory(song);
  }

  just_audio.UriAudioSource _createAudioSource(Song song) {
    final playbackUrl = song.isOnline ? song.url : song.localPath;
    // 本地歌曲的 artworkUri 是 local:// 或 content:// 格式，
    // just_audio 无法加载这些 URI 作为封面；系统通知封面由
    // AudioPlaybackService 通过 fallbackFilePath 提取内嵌封面处理
    final effectiveArtUri = song.isOnline && song.artworkUri != null
        ? Uri.parse(song.artworkUri!)
        : null;
    if (kIsWeb) {
      return createAudioSourceWeb(
        id: song.id,
        url: playbackUrl ?? '',
        // 使用 displayName 剥离 .mp3 等扩展名，避免系统通知栏/锁屏显示后缀
        title: song.displayName,
        artist: song.artist,
        album: song.album,
        artUri: effectiveArtUri,
      );
    }
    return createAudioSource(
      id: song.id,
      url: playbackUrl ?? '',
      // 使用 displayName 剥离 .mp3 等扩展名，避免系统通知栏/锁屏显示后缀
      title: song.displayName,
      artist: song.artist,
      album: song.album,
      artUri: effectiveArtUri,
    );
  }

  /// 把 [Song] 转为可播放的 `file://` 或绝对路径 URL。
  ///
  /// **关键**：本地音乐在 MediaStore 中以 `content://media/...` 形式存在，
  /// 而 `just_audio.setUrl` 不支持 `content://` 协议，会导致
  /// "播放没声音"。这里通过原生 MethodChannel 把 `content://` 解析为
  /// 真实文件路径（命中 MediaStore.DATA 字段或拷贝到 App 缓存）。
  ///
  /// 解析结果会回写到 song 的 `localPath`（去掉 `content://` 前缀后的真实路径），
  /// 后续切歌/重播时无需重新解析。
  Future<String?> _resolvePlaybackUrl(Song song) async {
    if (song.isOnline) return song.url;
    final raw = song.localPath;
    if (raw == null || raw.isEmpty) return null;
    // 非 content:// 协议：直接当本地路径用（兼容旧的绝对路径/SMB 路径等）
    if (!raw.startsWith('content://')) {
      // just_audio 的 setUrl / AudioSource.uri 需要完整的 URI，
      // 裸路径 /storage/emulated/0/... 会导致 "No host specified in URI" 错误。
      // 这里把绝对路径转换为 file:// URI。
      if (raw.startsWith('/')) {
        return Uri.file(raw).toString();
      }
      return raw;
    }
    try {
      final resolved = await MediaStoreService.resolveLocalPath(raw);
      if (resolved == null || resolved.isEmpty) {
        debugPrint('[PlayerProvider] 解析 content:// 失败: $raw');
        return null;
      }
      // resolved 是真实文件路径，同样需要转换为 file:// URI
      if (resolved.startsWith('/')) {
        final fileUri = Uri.file(resolved).toString();
        debugPrint('[PlayerProvider] content:// → $fileUri');
        return fileUri;
      }
      debugPrint('[PlayerProvider] content:// → $resolved');
      return resolved;
    } catch (e) {
      debugPrint('[PlayerProvider] resolvePlaybackUrl 异常: $e');
      return null;
    }
  }

  /// 批量解析一组本地音乐（仅对 `content://` URI 调用原生 MethodChannel）。
  ///
  /// 用于在 `appendPlaylist` / `insertAfterCurrent` / `removeFromPlaylist` 等
  /// 一次性构建多 source 的入口，避免对每首歌的 `content://` 漏解析而传给
  /// `just_audio` 导致"播放没声音"。
  ///
  /// 在线歌曲保持原样不动。解析失败的本地歌曲保留原 `content://`（让上层
  /// `setPlaylist` 静默失败，避免阻塞整体流程）。
  Future<List<Song>> _resolveLocalPathsForBatch(List<Song> songs) async {
    final result = <Song>[];
    for (final song in songs) {
      if (song.isOnline) {
        result.add(song);
        continue;
      }
      final raw = song.localPath;
      if (raw == null || raw.isEmpty) {
        result.add(song);
        continue;
      }
      // 非 content:// 的裸路径也需要转换为 file:// URI
      if (!raw.startsWith('content://')) {
        if (raw.startsWith('/') && !raw.startsWith('file://')) {
          result.add(song.copyWith(localPath: Uri.file(raw).toString()));
        } else {
          result.add(song);
        }
        continue;
      }
      final resolved = await _resolvePlaybackUrl(song);
      if (resolved != null && resolved != raw) {
        result.add(song.copyWith(localPath: resolved));
      } else {
        result.add(song);
      }
    }
    return result;
  }

  /// 监听自身 notifyListeners：检测 currentSong 变化时推送 Lyricon。
  ///
  /// PlayerProvider 没有专门的切歌回调（playSong / next / previous / playSongAt
  /// 等多处都会切歌），用 addListener 监听自身是最小侵入方式。
  /// 每次 notifyListeners（含 position tick）都会触发本方法，但首行 short-circuit
  /// 仅做一次字符串比较，开销可忽略。
  void _handleLyriconSongChange() {
    if (!LyriconProviderService.instance.enabled) return;
    final song = _currentSong;
    // id 相同（含都为 null）则不处理，避免高频 tick 触发重复推送
    if (song?.id == _lastLyriconSong?.id) return;
    _lastLyriconSong = song;
    _pushLyriconSongChange(song);
  }

  // 记录上次的 enabled 状态，只在 disabled→enabled 边界触发重推，
  // 避免断开/超时等保持 enabled 的事件反复触发歌词重推
  bool _lyriconWasEnabled = false;

  /// Lyricon 状态变化时（enabled 从 false→true，如 auto_restored / connected），
  /// 重置 _lastLyriconSong 强制重推当前歌曲。enabled=false 时无需处理，
  /// 等下次 enabled 时再推（_handleLyriconSongChange 会自然恢复）。
  void _handleLyriconEnabledChanged() {
    final enabled = LyriconProviderService.instance.enabled;
    if (enabled && !_lyriconWasEnabled) {
      _lyriconWasEnabled = true;
      _lastLyriconSong = null;
      _handleLyriconSongChange();
    } else if (!enabled) {
      _lyriconWasEnabled = false;
    }
  }

  /// 拉取歌词 → 解析 → 推送 Lyricon onSongChanged。
  ///
  /// 参考 [DesktopLyricService._onTick] / [_fetchLyricFor] 的模式：
  /// - 通过 appNavigatorKey.currentContext 拿 KugouProvider
  /// - 调 kugou.getLyric 拉 LRC（Task 15 双请求会同时拉 KRC）
  /// - 用 LyricParserChain.parse 自动识别 KRC/LRC/纯文本
  /// - 推送 LyriconProviderService.instance.onSongChanged
  ///
  /// 竞态处理：每次切歌自增 _lyriconFetchToken，异步结果过期则丢弃，
  /// 避免快速切歌时旧歌词覆盖新歌词。
  Future<void> _pushLyriconSongChange(Song? song) async {
    if (!LyriconProviderService.instance.enabled) return;
    final token = ++_lyriconFetchToken;
    try {
      List<LyricLine> lines = const [];
      if (song != null) {
        // 本地歌曲优先读取内嵌歌词
        if (!song.isOnline) {
          final localPath = song.localPath;
          if (localPath != null && localPath.isNotEmpty) {
            String filePath = localPath;
            if (filePath.startsWith('file://')) {
              filePath = Uri.parse(filePath).toFilePath();
            }
            final embedded = readEmbeddedLyrics(filePath);
            if (embedded != null && embedded.isNotEmpty) {
              lines = LyricParserChain.parse(embedded);
            }
          }
        }

        // 内嵌歌词为空时从酷狗 API 获取
        if (lines.isEmpty) {
          final ctx = appNavigatorKey.currentContext;
          if (ctx != null) {
            try {
              final kugou = ctx.read<KugouProvider>();
              // 本地歌曲传空 hash + "歌名 艺术家" 关键词搜索；搜索词与播放器页面 full_player 保持一致，
              // 确保 Lyricon 推送与播放器页面命中同一版本歌词。
              final lyricHash = song.isOnline ? song.id : '';
              final searchName = song.artist != '未知艺术家'
                  ? '${song.title} ${song.artist}'
                  : song.title;
              await kugou.getLyric(lyricHash, songName: searchName, fmt: 'lrc');
              if (token != _lyriconFetchToken) return;
              final text = kugou.lyric?.displayLyric;
              final translationText = kugou.lyric?.translatedContent;
              final romaText = kugou.lyric?.romaContent;
              if (text != null && text.isNotEmpty) {
                lines = LyricParserChain.parse(
                  text,
                  translationText: translationText,
                  romaText: romaText,
                );
              }
            } catch (_) {}
          }
        }
      }
      if (token != _lyriconFetchToken) return;
      // 传入当前播放进度和状态，让 Lyricon 能立即触发歌词渲染
      // （Lyricon 推荐调用顺序：setSong → setPosition → setPlaybackState）
      await LyriconProviderService.instance.onSongChanged(
        song,
        lines,
        positionMs: _position.inMilliseconds,
        isPlaying: _isPlaying,
      );
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      // App 进入后台或即将被杀死，立即保存播放状态
      _saveState();
      _saveDebounce?.cancel();
    }
  }

  @override
  void dispose() {
    _saveState(); // 退出时立即保存
    _saveDebounce?.cancel();
    _connectivitySub?.cancel();
    _connectivitySub = null;
    WidgetsBinding.instance.removeObserver(this);
    removeListener(_handleLyriconSongChange);
    LyriconProviderService.instance.removeListener(_handleLyriconEnabledChanged);
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _playingSubscription?.cancel();
    _playerStateSubscription?.cancel();
    _sequenceStateSubscription?.cancel();
    _speedSubscription?.cancel();
    _sleepTimerTicker?.cancel();
    _sleepTimerTicker = null;
    positionNotifier.dispose();
    super.dispose();
  }
}

class AudioServiceLoader {
  static Future<dynamic> load() async {
    return AudioService();
  }
}

just_audio.UriAudioSource createAudioSourceWeb({
  required String id,
  required String url,
  required String title,
  String? artist,
  String? album,
  Uri? artUri,
}) {
  return createAudioSource(
    id: id,
    url: url,
    title: title,
    artist: artist,
    album: album,
    artUri: artUri,
  );
}
