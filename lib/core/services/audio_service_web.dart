import 'dart:html' as html;

import 'package:just_audio/just_audio.dart';

import 'accompany_mix.dart';
import 'diagnostic_logger.dart';
import 'playback_command_dispatcher.dart';

class AudioService {
  static final AudioService _instance = AudioService._internal();

  factory AudioService() => _instance;

  AudioService._internal();

  final AudioPlayer _player = AudioPlayer();
  int get diagnosticPlayerCount => 1;
  String get diagnosticActiveEngine => 'main';
  final ConcatenatingAudioSource _playlistSource = ConcatenatingAudioSource(
    children: [],
  );

  AudioPlayer get player => _player;

  Stream<Duration> get positionStream => _player.positionStream;

  Stream<Duration?> get durationStream => _player.durationStream;

  Stream<bool> get playingStream => _player.playingStream;

  Stream<PlayerState> get playerStateStream => _player.playerStateStream;

  ProcessingState get processingState => _player.processingState;

  Stream<SequenceState?> get sequenceStateStream => _player.sequenceStateStream;

  Stream<double> get speedStream => _player.speedStream;

  bool get playing => _player.playing;

  Duration get position => _player.position;

  Duration? get duration => _player.duration;

  double get speed => _player.speed;

  /// Web 端没有 Android 的音量均衡（响度归一）链路，恒为关闭。
  ///
  /// 与 `audio_service_io.dart` 的同名 getter 对齐，保持条件导入两端 API 一致
  /// （「硬件解码播放」让路判定会读它，而 Web 端该功能整体不可用）。
  bool get volumeNormalizationEnabled => false;

  /// Web 端无 Android 音频会话 ID。
  int? get androidAudioSessionId => null;

  List<int> get androidAudioSessionIds => const [];

  Stream<List<int>> get androidAudioSessionIdsStream => const Stream.empty();

  // ==== 伴唱（伴奏轨）====
  //
  // Web 端不实现伴唱：浏览器同页多路音频的混音与音量比例无法在此层可靠控制
  // （且 Web 端整体功能可用性有限）。API 保持与 io 端同名同签名，
  // 使上层（PlayerProvider / UI）无需按平台分支。

  /// 伴唱模式是否已开启（Web 端恒为 false）。
  bool get accompanyActive => false;

  /// 端侧分离是否已开启（Web 端恒为 false）。
  bool get stemSeparationActive => false;

  /// 当前伴唱混音比例（Web 端恒为 null）。
  AccompanyMix? get accompanyMix => null;

  /// 原曲音量占比（Web 端恒为 1.0）。
  double get originalVolumeScale => 1.0;

  /// 开启伴唱（Web 端不支持，直接返回 false）。
  Future<bool> startAccompany(
    String url, {
    required AccompanyMix mix,
    required Duration position,
    double speed = 1.0,
  }) async => false;

  /// 关闭伴唱（Web 端无伴唱，空操作）。
  Future<void> stopAccompany() async {}

  /// 开启端侧分离（Web 端不支持，直接返回 false）。
  Future<bool> startStemSeparation({required double mix}) async => false;

  /// 关闭端侧分离（Web 端无分离，空操作）。
  Future<void> stopStemSeparation() async {}

  /// 设置端侧分离的伴奏占比（Web 端无分离，空操作）。
  Future<void> setStemMix(double mix) async {}

  Future<void> init() async {
    await _player.setLoopMode(LoopMode.off);
  }

  Future<void> play() async {
    await _player.play();
  }

  /// 派发播放命令后立即返回，并接收底层播放Future稍后抛出的错误。
  Future<void> playCommand({
    void Function(Object error, StackTrace stackTrace)? onError,
  }) async {
    await dispatchPlaybackCommand(
      _player.play(),
      onError: (error, stackTrace) {
        DiagnosticLogger.instance.e(
          '[Playback] play command future failed: ${error.runtimeType}',
        );
        try {
          onError?.call(error, stackTrace);
        } catch (callbackError) {
          DiagnosticLogger.instance.e(
            '[Playback] play error handler failed: ${callbackError.runtimeType}',
          );
        }
      },
    );
  }

  Future<void> pause() async {
    await _player.pause();
  }

  Future<void> stop() async {
    await _player.stop();
  }

  Future<void> seek(Duration position) async {
    await _player.seek(position);
  }

  Future<void> setUrl(
    String url, {
    double? loudnessLufs,
    double? loudnessPeakDb,
    Duration? initialPosition,
    dynamic tag,
  }) async {
    final blobUrl = await _fetchAudioBlob(url);
    // 与 io 端同口径：定位交给平台层，避免「加载后 seek」的竞态
    await _player.setUrl(
      blobUrl,
      initialPosition: initialPosition ?? Duration.zero,
      tag: tag,
    );
  }

  Future<void> setPlaylist(
    List<UriAudioSource> sources, {
    int startIndex = 0,
    Duration? initialPosition,
  }) async {
    _playlistSource.clear();
    if (sources.isNotEmpty) {
      final List<AudioSource> blobSources = [];
      for (final source in sources) {
        try {
          final originalUrl = source.uri.toString();
          final blobUrl = await _fetchAudioBlob(originalUrl);
          blobSources.add(AudioSource.uri(Uri.parse(blobUrl), tag: source.tag));
        } catch (e) {
          blobSources.add(source);
        }
      }
      _playlistSource.addAll(blobSources);
    }
    final safeStartIndex = startIndex.clamp(
      0,
      sources.isEmpty ? 0 : sources.length - 1,
    );
    await _player.setAudioSource(
      _playlistSource,
      initialIndex: safeStartIndex,
      initialPosition: initialPosition ?? Duration.zero,
    );
  }

  Future<void> addAudioSource(UriAudioSource source) async {
    final blobUrl = await _fetchAudioBlob(source.uri.toString());
    await _playlistSource.add(
      AudioSource.uri(Uri.parse(blobUrl), tag: source.tag),
    );
  }

  Future<void> addAllAudioSources(List<UriAudioSource> sources) async {
    final List<AudioSource> blobSources = [];
    for (final source in sources) {
      try {
        final blobUrl = await _fetchAudioBlob(source.uri.toString());
        blobSources.add(AudioSource.uri(Uri.parse(blobUrl), tag: source.tag));
      } catch (e) {
        blobSources.add(source);
      }
    }
    await _playlistSource.addAll(blobSources);
  }

  /// 在指定位置插入音频源，不打断当前播放。
  Future<void> insertAudioSourceAt(int index, UriAudioSource source) async {
    final blobUrl = await _fetchAudioBlob(source.uri.toString());
    await _playlistSource.insert(
      index,
      AudioSource.uri(Uri.parse(blobUrl), tag: source.tag),
    );
  }

  Future<void> setSpeed(double speed) async {
    await _player.setSpeed(speed);
  }

  Future<void> seekToNext() async {
    await _player.seekToNext();
  }

  Future<void> seekToPrevious() async {
    await _player.seekToPrevious();
  }

  Future<void> setLoopMode(LoopMode mode) async {
    await _player.setLoopMode(mode);
  }

  Future<void> setShuffleModeEnabled(bool enabled) async {
    await _player.setShuffleModeEnabled(enabled);
  }

  Future<void> setVolume(double volume) async {
    await _player.setVolume(volume.clamp(0.0, 1.0));
  }

  // —— 响度归一：Web 无实现（依赖 Android 侧 LoudnessEnhancer 与
  // NormalizationGainAudioSink），保持与 io 版同样的接口，上层无需分平台判断。
  Future<void> setVolumeNormalization({bool? enabled, double? referenceLufs}) async {}

  /// AutoMix 实测响度补给（io 版用它填补上游缺失的响度）；Web 无响度通路。
  Future<void> applyMeasuredLoudness(double? measuredDbfs) async {}

  // —— 交叉淡化：Web 不支持（需要第二个播放器与 Media3 层的会话共享），
  // 保持与 io 版同样的接口，上层无需分平台判断。
  bool get isCrossfading => false;

  Stream<bool> get crossfadingStream => const Stream.empty();

  Future<bool> prepareCrossfade(
    String url, {
    double speed = 1.0,
    String? id,
    String? title,
    String? artist,
    String? artUri,
    double? loudnessLufs,
    double? loudnessPeakDb,
  }) async => false;

  void discardPreparedCrossfade() {}

  Future<void> startCrossfade({
    required Duration duration,
    required double targetVolume,
    void Function()? onCrossover,
  }) async {}

  void abortCrossfade({bool keepVolume = false}) {}

  Future<void> dispose() async {
    await _player.dispose();
  }

  /// Fetch audio as blob via XMLHttpRequest to bypass ORB (Opaque Response Blocking).
  /// ORB blocks cross-origin audio loaded directly by <audio> elements,
  /// but XMLHttpRequest uses CORS mode, so the response is not opaque.
  Future<String> _fetchAudioBlob(String url) async {
    if (url.isEmpty) return url;
    try {
      final request = await html.HttpRequest.request(
        url,
        method: 'GET',
        responseType: 'blob',
      );
      final blob = request.response as html.Blob;
      final blobUrl = html.Url.createObjectUrlFromBlob(blob);
      return blobUrl;
    } catch (e) {
      return url;
    }
  }
}

UriAudioSource createAudioSource({
  required String id,
  required String url,
  required String title,
  String? artist,
  String? album,
  Uri? artUri,
  Map<String, String>? headers,
}) {
  return AudioSource.uri(
    Uri.parse(url),
    // 与 io 端签名保持一致；Web 端请求头支持有限（仅同源 Cookie），透传即可
    headers: headers,
    tag: <String, dynamic>{
      'id': id,
      'title': title,
      'artist': artist,
      'album': album,
      'artUri': artUri?.toString(),
    },
  );
}
