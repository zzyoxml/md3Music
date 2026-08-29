import 'dart:async';

import 'package:dlna_dart/xmlParser.dart' show AudioMime, PlayType;
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../core/services/dlna_service.dart';
import '../core/services/local_http_server.dart';
import '../core/services/media_store_service.dart';
import '../data/models/song.dart';
import 'player_provider.dart';
import '../services/kugou_api/kugou_api_client.dart';

/// 投屏状态枚举。
enum DlnaCastState {
  idle,       // 空闲
  searching,  // 正在搜索设备
  connecting, // 正在连接设备
  casting,    // 正在投屏
  error,      // 出错
}

/// DLNA 投屏状态管理，app 级持久。
class DlnaProvider extends ChangeNotifier {
  final DlnaService _service = DlnaService();

  // ── 状态 ──
  DlnaCastState _state = DlnaCastState.idle;
  List<DlnaDeviceInfo> _devices = [];
  String? _castTitle;
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration? _duration;
  String? _errorMessage;
  int _volume = 100;
  // 当前投屏的媒体类型（audio/video），用于切歌时保持类型一致
  DlnaMediaType _castMediaType = DlnaMediaType.audio;

  // 投屏前本地播放状态，用于停止投屏后恢复
  bool _wasPlayingBefore = false;
  // 标记正在切歌（手动或自动），防止自动切歌重复触发
  // 注意：不拦截手动切歌，手动切歌会重置此标志
  bool _autoSkipping = false;

  StreamSubscription? _devicesSub;
  StreamSubscription? _positionSub;
  StreamSubscription? _durationSub;
  Timer? _statePollTimer;

  /// 位置心跳看门狗：位置流每 2s 推送一次；超过该时长无更新判定设备掉线。
  /// 约 6 个心跳周期，避免瞬时抖动误判。
  static const int _positionTimeoutMs = 12000;
  int _lastPositionMs = 0;

  /// 设备支持的传输动作集（从 GetCurrentTransportActions 探测）。
  /// 空集合 = 探测失败，UI 保守保留全部控制。
  Set<String> _supportedActions = {};
  bool get canPause =>
      _supportedActions.isEmpty || _supportedActions.contains('Pause');
  bool get canSeek =>
      _supportedActions.isEmpty || _supportedActions.contains('Seek');

  DlnaCastState get state => _state;
  List<DlnaDeviceInfo> get devices => _devices;
  String? get castTitle => _castTitle;
  bool get isPlaying => _isPlaying;
  Duration get position => _position;
  Duration? get duration => _duration;
  String? get errorMessage => _errorMessage;
  int get volume => _volume;
  String? get deviceName => _service.deviceName;
  bool get isCasting => _state == DlnaCastState.casting;
  DlnaMediaType get castMediaType => _castMediaType;

  DlnaProvider() {
    _devicesSub = _service.devicesStream.listen((devices) {
      _devices = devices;
      notifyListeners();
    });
    _positionSub = _service.positionStream.listen((pos) {
      // 位置心跳更新：设备存活时每 2s 推送，用于看门狗判定掉线
      _lastPositionMs = DateTime.now().millisecondsSinceEpoch;
      _position = pos;
      // 自动下一曲：position 接近 duration（差值≤3秒）时触发
      _checkAutoNext();
      notifyListeners();
    });
    _durationSub = _service.durationStream.listen((dur) {
      _duration = dur;
      notifyListeners();
    });
  }

  /// 检测投屏播放结束：position 接近 duration 时自动切下一首。
  /// 通过回调 [onAutoNext] 注入切歌逻辑，避免 Provider 持有 BuildContext。
  Future<void> Function(BuildContext)? onAutoNext;

  void _checkAutoNext() {
    // 防止重复触发、非投屏状态、无时长信息时不触发
    if (_autoSkipping) return;
    if (!isCasting || !_isPlaying) return;
    final dur = _duration;
    if (dur == null || dur.inSeconds < 10) return;
    // position 距离结束 3 秒内视为播放结束
    final remaining = dur.inSeconds - _position.inSeconds;
    if (remaining <= 3 && _position.inSeconds > 0) {
      _autoSkipping = true;
      // 通过回调触发外部切歌（避免在 provider 中持有 context）
      final ctx = _autoNextContext;
      if (ctx != null && onAutoNext != null) {
        // 异步执行，不阻塞 position 监听；finally 会复位 _autoSkipping
        onAutoNext!(ctx);
      } else {
        _autoSkipping = false;
      }
    }
  }

  /// 自动切歌的 context 缓存（由 UI 层设置）。
  BuildContext? _autoNextContext;
  void setAutoNextContext(BuildContext context) {
    _autoNextContext = context;
  }

  /// 开始搜索局域网内的 DLNA 设备。
  Future<void> startSearch() async {
    _state = DlnaCastState.searching;
    _devices = [];
    _errorMessage = null;
    notifyListeners();
    try {
      await _service.startSearch();
      // ignore: avoid_print
      print('[DLNA] startSearch ok');
    } catch (e) {
      _state = DlnaCastState.error;
      _errorMessage = '搜索失败：$e';
      // ignore: avoid_print
      print('[DLNA] startSearch error: $e');
      notifyListeners();
    }
  }

  /// 停止搜索。
  Future<void> stopSearch() async {
    try {
      await _service.stopSearch();
    } catch (_) {
      // 防御性兜底：socket 关闭异常不冒泡
    }
    if (_state == DlnaCastState.searching) {
      _state = DlnaCastState.idle;
      notifyListeners();
    }
  }

  /// 投屏歌曲：在线歌曲走酷狗 URL，本地歌曲走 LocalHttpServer 暴露的 HTTP URL。
  /// [preserveWasPlaying] 为 true 时不覆盖 _wasPlayingBefore（切歌场景）。
  Future<void> castSong(BuildContext context, Song song,
      {bool preserveWasPlaying = false}) async {
    _state = DlnaCastState.connecting;
    _castTitle = song.displayName;
    _castMediaType = DlnaMediaType.audio;
    notifyListeners();

    try {
      final playerProvider = context.read<PlayerProvider>();
      String url;
      PlayType? overrideType;

      if (song.isOnline) {
        // ── 在线歌曲：通过酷狗 API 获取新鲜播放 URL ──
        final apiClient = KugouApiClient();
        if (song.isCloud) {
          // ── 云盘歌曲：URL 解析必须走 /user/cloud/url（失败回退 /song/url）──
          // 与 PlayerProvider.playCloudPlaylist 的解析路径保持一致，
          // 云盘上传歌曲用通用 /song/url 拿不到有效地址。
          final cloudUrl = await playerProvider.resolveCloudUrl(apiClient, song);
          if (cloudUrl == null || cloudUrl.isEmpty) {
            _state = DlnaCastState.error;
            _errorMessage = '无法获取云盘播放地址';
            notifyListeners();
            return;
          }
          url = cloudUrl;
        } else {
          final result = await apiClient.getSongUrlWithFallback(
            song.id,
            quality: playerProvider.audioQuality.value,
            albumId: song.albumId,
            albumAudioId: song.albumAudioId,
          );
          if (result == null || result.url.isEmpty) {
            _state = DlnaCastState.error;
            _errorMessage = '无法获取播放地址';
            notifyListeners();
            return;
          }
          url = result.url;
        }
      } else {
        // ── 本地歌曲：通过 LocalHttpServer 暴露到局域网 ──
        final rawPath = song.localPath;
        if (rawPath == null || rawPath.isEmpty) {
          _state = DlnaCastState.error;
          _errorMessage = '本地歌曲无文件路径';
          notifyListeners();
          return;
        }
        // content:// URI 走 MediaStoreService 重新解析为真实路径
        String filePath = rawPath;
        if (filePath.startsWith('content://')) {
          final resolved = await MediaStoreService.resolveLocalPath(filePath);
          if (resolved == null || resolved.isEmpty) {
            _state = DlnaCastState.error;
            _errorMessage = '无法解析本地文件路径';
            notifyListeners();
            return;
          }
          filePath = resolved;
        }
        final httpUrl = LocalHttpServer.instance.getUrlForPath(filePath);
        if (httpUrl == null) {
          _state = DlnaCastState.error;
          _errorMessage = LocalHttpServer.instance.isRunning
              ? '请确保手机已连接 WiFi'
              : '本地服务器未启动，请重启 App';
          notifyListeners();
          return;
        }
        url = httpUrl;
        overrideType = _audioPlayTypeForPath(filePath);
      }

      await _service.cast(
        url,
        title: song.displayName,
        mediaType: DlnaMediaType.audio,
        overrideType: overrideType,
      );

      // 暂停本地播放（切歌场景不覆盖 _wasPlayingBefore）
      if (!preserveWasPlaying) {
        _wasPlayingBefore = playerProvider.isPlaying;
      }
      if (playerProvider.isPlaying) {
        playerProvider.pause();
      }
      _state = DlnaCastState.casting;
      _isPlaying = true;
      // 初始化位置心跳，供看门狗判定设备掉线
      _lastPositionMs = DateTime.now().millisecondsSinceEpoch;
      _startStatePolling();
      notifyListeners();
      // 探测设备支持的传输动作（Pause/Seek），驱动 UI 隐藏/降级
      _refreshSupportedActions();
      // ignore: avoid_print
      print('[DLNA] castSong ok song=${song.displayName}');
    } catch (e) {
      _state = DlnaCastState.error;
      _errorMessage = e is DlnaServiceException ? e.message : '投屏出错：$e';
      // ignore: avoid_print
      print('[DLNA] castSong error: $e');
      notifyListeners();
    }
  }

  /// 本地文件按扩展名映射到 dlna_dart 的 AudioMime。
  /// 仅常见格式有专用枚举；未识别格式返回 null，由 cast() 兜底用 AudioMime.mpeg。
  static PlayType? _audioPlayTypeForPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.mp3')) return AudioMime.mp3;
    if (lower.endsWith('.flac')) return AudioMime.xFlac;
    if (lower.endsWith('.wav')) return AudioMime.wav;
    if (lower.endsWith('.m4a') || lower.endsWith('.aac')) {
      return AudioMime.mp4;
    }
    if (lower.endsWith('.ape')) return AudioMime.xApe;
    if (lower.endsWith('.wma')) return AudioMime.wma;
    return null; // ogg/opus 等无对应枚举，由 cast() 兜底用 mpeg
  }

  /// 投屏 MV：使用已解析的 MV URL。
  Future<void> castMv(String url, String title) async {
    _state = DlnaCastState.connecting;
    _castTitle = title;
    _castMediaType = DlnaMediaType.video;
    notifyListeners();

    try {
      await _service.cast(
        url,
        title: title,
        mediaType: DlnaMediaType.video,
      );

      _state = DlnaCastState.casting;
      _isPlaying = true;
      // 初始化位置心跳，供看门狗判定设备掉线
      _lastPositionMs = DateTime.now().millisecondsSinceEpoch;
      _startStatePolling();
      notifyListeners();
      // 探测设备支持的传输动作（Pause/Seek），驱动 UI 隐藏/降级
      _refreshSupportedActions();
      // ignore: avoid_print
      print('[DLNA] castMv ok title=$title');
    } catch (e) {
      _state = DlnaCastState.error;
      _errorMessage = e is DlnaServiceException ? e.message : '投屏出错：$e';
      // ignore: avoid_print
      print('[DLNA] castMv error: $e');
      notifyListeners();
    }
  }

  /// 选择设备并连接。
  void selectDevice(DlnaDeviceInfo device) {
    _service.connectDevice(device.device);
  }

  Future<void> play() async {
    try {
      await _service.play();
      _isPlaying = true;
      _errorMessage = null;
    } on DlnaServiceException catch (e) {
      // 单次操作失败仅提示，不退出投屏态；真实掉线由看门狗兜住
      _errorMessage = e.message;
      // ignore: avoid_print
      print('[DLNA] play error: ${e.message}');
    }
    notifyListeners();
  }

  Future<void> pause() async {
    try {
      await _service.pause();
      _isPlaying = false;
      _errorMessage = null;
    } on DlnaServiceException catch (e) {
      // Pause 不被支持/状态不允许 → 降级为 Stop（停止当前播放，保留投屏连接）
      await _service.stopCurrent();
      _isPlaying = false;
      _errorMessage = null;
      // ignore: avoid_print
      print('[DLNA] pause 降级 stopCurrent: ${e.message}');
    }
    notifyListeners();
  }

  /// 停止投屏并恢复本地播放。
  /// best-effort：设备失联时服务层已清理连接，此处必须重置本地状态，
  /// 保证 [restoreLocalPlayback] 一定被执行。
  Future<void> stop() async {
    try {
      await _service.stop();
    } catch (_) {
      // 设备失联时忽略异常，仅清理本地状态
    }
    _stopStatePolling();
    _state = DlnaCastState.idle;
    _isPlaying = false;
    _position = Duration.zero;
    _duration = null;
    _castTitle = null;
    _errorMessage = null;
    _supportedActions = {};
    // ignore: avoid_print
    print('[DLNA] stop -> idle wasPlayingBefore=$_wasPlayingBefore');
    notifyListeners();
  }

  Future<void> seek(Duration position) async {
    try {
      await _service.seek(position);
      _position = position;
      _errorMessage = null;
    } on DlnaServiceException catch (e) {
      _errorMessage = e.message;
    }
    notifyListeners();
  }

  Future<void> setVolume(int vol) async {
    _volume = vol;
    try {
      await _service.setVolume(vol);
    } on DlnaServiceException catch (e) {
      _errorMessage = e.message;
    }
    notifyListeners();
  }

  /// 清除当前错误提示（UI 的关闭按钮调用）。
  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  /// 探测设备支持的传输动作（Pause/Seek 等），驱动 UI 隐藏/降级。
  Future<void> _refreshSupportedActions() async {
    _supportedActions = await _service.getSupportedActions();
    // ignore: avoid_print
    print('[DLNA] supportedActions=${_supportedActions.join(',')}');
    notifyListeners();
  }

  /// 切歌后重新投屏（遥控页面上一首/下一首/自动切歌）。
  /// 根据 _castMediaType 决定投屏音频还是 MV，保持媒体类型一致。
  /// 使用 autoPlay: false 避免本地播放器实际播放，仅切换索引。
  /// 使用 preserveWasPlaying: true 保持原始 _wasPlayingBefore 不被覆盖。
  ///
  /// 防抖说明：_checkAutoNext 已在触发前检查 _autoSkipping；
  /// 此处统一设置 _autoSkipping = true 仅用于在切歌异步执行期间
  /// 阻止 _checkAutoNext 重复触发，不拦截手动切歌。
  Future<void> castNextSong(BuildContext context, {bool isAutoNext = false}) async {
    _autoSkipping = true;
    try {
      final playerProvider = context.read<PlayerProvider>();
      await playerProvider.next(autoPlay: false);
      final song = playerProvider.currentSong;
      if (song != null) {
        await _castByMediaType(context, song);
      }
    } catch (e) {
      // 切歌解析/投屏失败不冒泡为未处理异常，改为 error 状态提示
      _state = DlnaCastState.error;
      _errorMessage = e is DlnaServiceException ? e.message : '切歌投屏出错：$e';
      notifyListeners();
    } finally {
      _autoSkipping = false;
    }
  }

  Future<void> castPreviousSong(BuildContext context) async {
    _autoSkipping = true;
    try {
      final playerProvider = context.read<PlayerProvider>();
      await playerProvider.previous(autoPlay: false);
      final song = playerProvider.currentSong;
      if (song != null) {
        await _castByMediaType(context, song);
      }
    } catch (e) {
      _state = DlnaCastState.error;
      _errorMessage = e is DlnaServiceException ? e.message : '切歌投屏出错：$e';
      notifyListeners();
    } finally {
      _autoSkipping = false;
    }
  }

  /// 根据当前投屏媒体类型选择投屏方式：audio → castSong，video → castMv。
  /// MV 切歌时重新解析新歌曲的 MV URL，避免变成音频投屏。
  Future<void> _castByMediaType(BuildContext context, Song song) async {
    if (_castMediaType == DlnaMediaType.video) {
      // MV 投屏切歌：重新解析新歌曲的 MV
      final albumAudioId = song.albumAudioId;
      if (albumAudioId == null || albumAudioId.isEmpty) {
        // 新歌曲没有 MV 信息，回退到音频投屏
        await castSong(context, song, preserveWasPlaying: true);
        return;
      }
      final api = KugouApiClient();
      final mvInfo = await api.getMvByAlbumAudioId(albumAudioId);
      if (mvInfo == null || !mvInfo.hasMv) {
        // 新歌曲无 MV，回退到音频投屏
        await castSong(context, song, preserveWasPlaying: true);
        return;
      }
      // 优先用 mvId 取详情，否则直接用 hash
      String? hash = mvInfo.hash;
      final mvId = mvInfo.mvId;
      if (mvId != null && mvId.isNotEmpty) {
        final detail = await api.getVideoDetail(mvId);
        if (detail != null && detail.qualities.isNotEmpty) {
          hash = detail.qualities.last.hash;
        }
      }
      if (hash == null || hash.isEmpty) {
        await castSong(context, song, preserveWasPlaying: true);
        return;
      }
      final url = await api.getVideoUrl(hash);
      if (url == null || url.isEmpty) {
        await castSong(context, song, preserveWasPlaying: true);
        return;
      }
      await castMv(url, song.displayName);
      // MV 切歌也需要保持 _wasPlayingBefore
      _wasPlayingBefore = false;
    } else {
      // 音频投屏切歌
      await castSong(context, song, preserveWasPlaying: true);
    }
  }

  /// 停止投屏后恢复本地播放。
  Future<void> restoreLocalPlayback(BuildContext context) async {
    if (_wasPlayingBefore) {
      _wasPlayingBefore = false;
      try {
        context.read<PlayerProvider>().resume();
        // ignore: avoid_print
        print('[DLNA] restoreLocalPlayback resume ok');
      } catch (_) {
        // ignore: avoid_print
        print('[DLNA] restoreLocalPlayback resume error');
      }
    } else {
      // ignore: avoid_print
      print('[DLNA] restoreLocalPlayback skip (wasPlayingBefore=false) currentSong=${context.read<PlayerProvider>().currentSong?.id}');
    }
  }

  /// 定期轮询设备传输状态，同步播放/暂停状态。
  /// 同时作为设备断开看门狗：位置心跳超时则判定设备掉线。
  void _startStatePolling() {
    _statePollTimer?.cancel();
    _statePollTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      if (!_service.isCasting) {
        timer.cancel();
        return;
      }
      // 位置心跳超时 → 设备已掉线（如 WiFi 断开、设备关机）
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastPositionMs > _positionTimeoutMs) {
        _handleDeviceLost();
        return;
      }
      final transportState = await _service.getTransportState();
      if (transportState != null) {
        final wasPlaying = _isPlaying;
        _isPlaying = transportState == 'PLAYING';
        if (wasPlaying != _isPlaying) {
          notifyListeners();
        }
      }
    });
  }

  /// 设备断开处理：清理连接、退出投屏态并提示。
  /// 不自动恢复本地播放（无可靠 context），由用户手动恢复。
  void _handleDeviceLost() {
    _service.disconnect();
    _stopStatePolling();
    _state = DlnaCastState.error;
    _errorMessage = '投屏设备已断开连接';
    _isPlaying = false;
    _position = Duration.zero;
    _duration = null;
    _lastPositionMs = 0;
    _supportedActions = {};
    // ignore: avoid_print
    print('[DLNA] device lost -> error');
    notifyListeners();
  }

  void _stopStatePolling() {
    _statePollTimer?.cancel();
    _statePollTimer = null;
  }

  @override
  void dispose() {
    _devicesSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _statePollTimer?.cancel();
    _service.dispose();
    super.dispose();
  }
}
