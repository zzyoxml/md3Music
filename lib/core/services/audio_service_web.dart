import 'dart:html' as html;

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

class AudioService {
  static final AudioService _instance = AudioService._internal();

  factory AudioService() => _instance;

  AudioService._internal();

  final AudioPlayer _player = AudioPlayer();
  final ConcatenatingAudioSource _playlistSource = ConcatenatingAudioSource(children: []);

  AudioPlayer get player => _player;

  Stream<Duration> get positionStream => _player.positionStream;

  Stream<Duration?> get durationStream => _player.durationStream;

  Stream<bool> get playingStream => _player.playingStream;

  Stream<PlayerState> get playerStateStream => _player.playerStateStream;

  Stream<SequenceState?> get sequenceStateStream => _player.sequenceStateStream;

  Stream<double> get speedStream => _player.speedStream;

  bool get playing => _player.playing;

  Duration get position => _player.position;

  Duration? get duration => _player.duration;

  double get speed => _player.speed;

  Future<void> init() async {}

  Future<void> play() async {
    await _player.play();
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

  Future<void> setUrl(String url) async {
    final blobUrl = await _fetchAudioBlob(url);
    await _player.setUrl(blobUrl);
  }

  Future<void> setPlaylist(List<UriAudioSource> sources, {int startIndex = 0}) async {
    _playlistSource.clear();
    if (sources.isNotEmpty) {
      final List<AudioSource> blobSources = [];
      for (final source in sources) {
        try {
          final originalUrl = source.uri.toString();
          final blobUrl = await _fetchAudioBlob(originalUrl);
          blobSources.add(AudioSource.uri(
            Uri.parse(blobUrl),
            tag: source.tag,
          ));
        } catch (e) {
                    blobSources.add(source);
        }
      }
      _playlistSource.addAll(blobSources);
    }
    final safeStartIndex = startIndex.clamp(0, sources.isEmpty ? 0 : sources.length - 1);
    await _player.setAudioSource(
      _playlistSource,
      initialIndex: safeStartIndex,
      initialPosition: Duration.zero,
    );
  }

  Future<void> addAudioSource(UriAudioSource source) async {
    final blobUrl = await _fetchAudioBlob(source.uri.toString());
    await _playlistSource.add(AudioSource.uri(
      Uri.parse(blobUrl),
      tag: source.tag,
    ));
  }

  Future<void> addAllAudioSources(List<UriAudioSource> sources) async {
    final List<AudioSource> blobSources = [];
    for (final source in sources) {
      try {
        final blobUrl = await _fetchAudioBlob(source.uri.toString());
        blobSources.add(AudioSource.uri(
          Uri.parse(blobUrl),
          tag: source.tag,
        ));
      } catch (e) {
                blobSources.add(source);
      }
    }
    await _playlistSource.addAll(blobSources);
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
}) {
  return AudioSource.uri(
    Uri.parse(url),
    tag: <String, dynamic>{
      'id': id,
      'title': title,
      'artist': artist,
      'album': album,
      'artUri': artUri?.toString(),
    },
  );
}
