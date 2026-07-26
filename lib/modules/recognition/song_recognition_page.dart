import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';

import '../../data/models/song.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';

class SongRecognitionPage extends StatefulWidget {
  const SongRecognitionPage({super.key});

  @override
  State<SongRecognitionPage> createState() => _SongRecognitionPageState();
}

class _SongRecognitionPageState extends State<SongRecognitionPage>
    with SingleTickerProviderStateMixin {
  final AudioRecorder _recorder = AudioRecorder();
  bool _isRecording = false;
  bool _isRecognizing = false;
  bool _isLooping = false;
  int _attemptCount = 0;
  String? _error;
  Map<String, dynamic>? _result;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  /// 录音采样率（44100Hz，安卓原生支持率）
  static const int _recordSampleRate = 44100;
  /// 目标采样率（酷狗指纹接口要求 8000Hz）
  static const int _targetSampleRate = 8000;
  /// 每段录制时长（秒）
  static const int _segmentDuration = 8;
  /// 最大总录制时长（秒），56s = 7 轮（每轮 8s）
  static const int _maxTotalDuration = 56;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _toggleRecording() async {
    if (_isLooping) {
      await _stopLoop();
    } else {
      await _startRecognitionLoop();
    }
  }

  Future<void> _startRecognitionLoop() async {
    if (!await _recorder.hasPermission()) {
      try {
        final status = await Permission.microphone.request();
        if (!status.isGranted) {
          setState(() => _error = '需要麦克风权限才能使用听歌识曲');
          return;
        }
      } catch (_) {
        setState(() => _error = '需要麦克风权限才能使用听歌识曲');
        return;
      }
    }

    setState(() {
      _error = null;
      _result = null;
      _isLooping = true;
      _attemptCount = 0;
    });

    // 切换音频会话为录音模式
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
        avAudioSessionMode: AVAudioSessionMode.defaultMode,
        androidAudioAttributes: AndroidAudioAttributes(
          contentType: AndroidAudioContentType.music,
          usage: AndroidAudioUsage.media,
        ),
        androidWillPauseWhenDucked: false,
      ));
    } catch (_) {}

    await _recordAndRecognizeSegment();
  }

  Future<void> _recordAndRecognizeSegment() async {
    if (!_isLooping) return;

    final elapsed = _attemptCount * _segmentDuration;
    if (elapsed >= _maxTotalDuration) {
      await _stopLoop();
      if (_result == null && _error == null) {
        setState(() => _error = '未能识别出歌曲，请换个环境重试');
      }
      return;
    }

    _attemptCount++;
    print('[SongRecognition] === 第 $_attemptCount 轮，已用 ${elapsed}s / ${_maxTotalDuration}s ===');

    final dir = await getTemporaryDirectory();
    final filePath = '${dir.path}/recording_${DateTime.now().millisecondsSinceEpoch}.wav';
    try {
      await _recorder.start(
        RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: _recordSampleRate,
          numChannels: 1,
          autoGain: false,
          echoCancel: false,
          noiseSuppress: false,
          androidConfig: const AndroidRecordConfig(
            // 使用 unprocessed 源获取原始麦克风信号，不经过系统降噪/增益处理
            audioSource: AndroidAudioSource.unprocessed,
            audioManagerMode: AudioManagerMode.modeNormal,
          ),
        ),
        path: filePath,
      );
    } catch (e) {
      // unprocessed 可能在部分设备不支持，回退到 mic
      try {
        await _recorder.start(
          RecordConfig(
            encoder: AudioEncoder.wav,
            sampleRate: _recordSampleRate,
            numChannels: 1,
            autoGain: false,
            echoCancel: false,
            noiseSuppress: false,
            androidConfig: const AndroidRecordConfig(
              audioSource: AndroidAudioSource.mic,
              audioManagerMode: AudioManagerMode.modeNormal,
            ),
          ),
          path: filePath,
        );
      } catch (e2) {
        setState(() {
          _isLooping = false;
          _error = '录音启动失败: $e2';
        });
        return;
      }
    }

    setState(() {
      _isRecording = true;
      _isRecognizing = false;
      _error = null;
    });
    _pulseController.repeat(reverse: true);

    await Future.delayed(const Duration(seconds: _segmentDuration));

    if (!_isLooping) return;

    String? path;
    try {
      path = await _recorder.stop();
    } catch (e) {
      print('[SongRecognition] stop recorder error: $e');
    }

    _pulseController.stop();
    setState(() {
      _isRecording = false;
      _isRecognizing = true;
    });

    if (path == null || path.isEmpty) {
      await _recordAndRecognizeSegment();
      return;
    }

    final recognized = await _processAndRecognize(path);

    if (!_isLooping) return;

    if (recognized) {
      await _stopLoop();
    } else {
      await _recordAndRecognizeSegment();
    }
  }

  Future<bool> _processAndRecognize(String path) async {
    try {
      final file = File(path);
      final exists = await file.exists();
      if (!exists) return false;

      final fileBytes = await file.readAsBytes();
      await file.delete().catchError((_) {});

      if (fileBytes.isEmpty) return false;

      // 提取原始 PCM 数据（44100Hz）
      final rawPcm = _extractPcmFromWav(fileBytes);
      print('[SongRecognition] fileBytes=${fileBytes.length}, rawPcm=${rawPcm.length} (${_recordSampleRate}Hz)');

      // 降采样到 8000Hz
      final pcmData = _downsample(rawPcm, _recordSampleRate, _targetSampleRate);
      print('[SongRecognition] downsampled: ${pcmData.length} bytes (${_targetSampleRate}Hz)');

      // 检查音量
      int maxAmplitude = 0;
      for (int i = 0; i < pcmData.length - 1; i += 2) {
        final sample = (pcmData[i] | (pcmData[i + 1] << 8)).toSigned(16);
        final abs = sample.abs();
        if (abs > maxAmplitude) maxAmplitude = abs;
      }
      print('[SongRecognition] maxAmplitude=$maxAmplitude');
      if (maxAmplitude < 100) {
        print('[SongRecognition] 本段为静音，跳过');
        return false;
      }

      // 增益归一化：提升音量到目标振幅，改善指纹识别率
      final normalizedPcm = _normalizeGain(pcmData, maxAmplitude);
      print('[SongRecognition] gain normalized, sending ${normalizedPcm.length} bytes');

      final api = KugouApiClient();
      final response = await api.audioMatch(normalizedPcm);

      if (!mounted || !_isLooping) return false;

      print('[SongRecognition] 第 $_attemptCount 轮响应: $response');

      if (response != null && _hasSongData(response)) {
        setState(() {
          _result = response;
          _isRecognizing = false;
        });
        return true;
      }
      return false;
    } catch (e) {
      print('[SongRecognition] 识别出错: $e');
      return false;
    }
  }

  /// 将 PCM 数据从 fromHz 降采样到 toHz
  /// 使用均值抗混叠滤波器（anti-aliasing filter），防止高于 toHz/2 的频率混叠
  Uint8List _downsample(Uint8List input, int fromHz, int toHz) {
    if (fromHz == toHz) return input;

    final inputSamples = input.length ~/ 2;
    final ratio = fromHz / toHz;
    final outputSamples = (inputSamples * toHz / fromHz).round();
    final output = Uint8List(outputSamples * 2);

    // 抗混叠窗口大小：取 ratio 的向上取整
    // 对于 44100→8000，ratio≈5.51，窗口=6，半窗=3，每次平均 7 个采样点
    final windowSize = ratio.ceil();
    final halfWindow = windowSize ~/ 2;

    for (int i = 0; i < outputSamples; i++) {
      final centerSrcIdx = (i * ratio).floor();

      // 以 centerSrcIdx 为中心，对窗口内采样点取均值（低通滤波）
      int sum = 0;
      int count = 0;
      for (int j = -halfWindow; j <= halfWindow; j++) {
        final idx = centerSrcIdx + j;
        if (idx >= 0 && idx < inputSamples) {
          final byteIdx = idx * 2;
          final sample = (input[byteIdx] | (input[byteIdx + 1] << 8)).toSigned(16);
          sum += sample;
          count++;
        }
      }

      final avg = count > 0 ? sum ~/ count : 0;
      final clamped = avg.clamp(-32768, 32767);
      output[i * 2] = clamped & 0xFF;
      output[i * 2 + 1] = (clamped >> 8) & 0xFF;
    }

    return output;
  }

  /// 增益归一化：去除 DC 偏移并放大到目标振幅，提升指纹识别率
  Uint8List _normalizeGain(Uint8List input, int currentMaxAmplitude,
      {int targetAmplitude = 25000}) {
    if (input.isEmpty || input.length < 2) return input;

    // 1. 计算 DC 偏移（直流分量）
    int sum = 0;
    int sampleCount = input.length ~/ 2;
    for (int i = 0; i < input.length - 1; i += 2) {
      final sample = (input[i] | (input[i + 1] << 8)).toSigned(16);
      sum += sample;
    }
    final dcOffset = sampleCount > 0 ? (sum / sampleCount).round() : 0;

    // 2. 去除 DC 偏移后重新计算最大振幅
    int adjustedMax = 0;
    for (int i = 0; i < input.length - 1; i += 2) {
      final sample =
          (input[i] | (input[i + 1] << 8)).toSigned(16) - dcOffset;
      final abs = sample.abs();
      if (abs > adjustedMax) adjustedMax = abs;
    }

    if (adjustedMax < 1) return input;

    // 3. 计算增益因子
    final gain = targetAmplitude / adjustedMax;
    if (gain <= 1.0) {
      print('[SongRecognition] gain=$gain (already loud enough, no boost)');
      return input;
    }

    print('[SongRecognition] applying gain=$gain (${adjustedMax} -> $targetAmplitude)');

    // 4. 应用增益
    final output = Uint8List(input.length);
    for (int i = 0; i < input.length - 1; i += 2) {
      final sample =
          (input[i] | (input[i + 1] << 8)).toSigned(16) - dcOffset;
      final amplified = (sample * gain).round().clamp(-32768, 32767);
      output[i] = amplified & 0xFF;
      output[i + 1] = (amplified >> 8) & 0xFF;
    }

    return output;
  }

  Future<void> _stopLoop() async {
    _isLooping = false;
    _pulseController.stop();
    _pulseController.reset();

    try {
      await _recorder.stop();
    } catch (_) {}

    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
    } catch (_) {}

    if (mounted) {
      setState(() {
        _isRecording = false;
        if (_result == null) {
          _isRecognizing = false;
          if (_error == null) {
            _error = '已停止识别';
          }
        } else {
          _isRecognizing = false;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('听歌识曲'),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight - 48),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const SizedBox(height: 32),
                  _buildPulseCircle(colorScheme),
                  const SizedBox(height: 32),
                  _buildStatusText(textTheme, colorScheme),
                  const SizedBox(height: 32),
                  if (_result != null) _buildResult(colorScheme, textTheme),
                  if (_error != null) _buildError(colorScheme, textTheme),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPulseCircle(ColorScheme colorScheme) {
    return Center(
      child: GestureDetector(
        onTap: _toggleRecording,
        child: ScaleTransition(
          scale: _isRecording ? _pulseAnimation : const AlwaysStoppedAnimation(1.0),
          child: Container(
            width: 140,
            height: 140,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _isRecording
                  ? colorScheme.error
                  : _isLooping
                      ? colorScheme.tertiary
                      : colorScheme.primaryContainer,
              boxShadow: _isRecording
                  ? [
                      BoxShadow(
                        color: colorScheme.error.withValues(alpha: 0.3),
                        blurRadius: 24,
                        spreadRadius: 8,
                      ),
                    ]
                  : null,
            ),
            child: Center(
              child: Icon(
                _isRecording ? Icons.mic : (_isLooping ? Icons.stop : Icons.mic_none),
                size: 56,
                color: _isRecording
                    ? colorScheme.onError
                    : _isLooping
                        ? colorScheme.onTertiary
                        : colorScheme.onPrimaryContainer,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatusText(TextTheme textTheme, ColorScheme colorScheme) {
    String text;
    if (_isRecording) {
      final elapsed = _attemptCount * _segmentDuration;
      text = '正在聆听... ${elapsed}s / ${_maxTotalDuration}s';
    } else if (_isRecognizing) {
      text = '正在识别第 $_attemptCount 段...';
    } else if (_isLooping) {
      text = '准备录制第 $_attemptCount 段...';
    } else {
      text = '点击开始听歌识曲';
    }
    return Text(
      text,
      style: textTheme.titleMedium?.copyWith(
        color: colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _buildResult(ColorScheme colorScheme, TextTheme textTheme) {
    final data = _result!;
    final responseData = data['data'];
    Map<String, dynamic>? audioInfo;

    if (responseData is List && responseData.isNotEmpty) {
      final first = responseData.first;
      if (first is Map) {
        audioInfo = Map<String, dynamic>.from(first);
      }
    } else if (responseData is Map) {
      audioInfo = Map<String, dynamic>.from(responseData);
    } else if (data is Map) {
      audioInfo = data;
    }

    final songName = _extractField(audioInfo, ['songname', 'song_name', 'name', 'SongName']) ?? '未知歌曲';
    final artist = _extractField(audioInfo, ['singername', 'singer_name', 'artist', 'SingerName']) ?? '未知歌手';
    final albumName = _extractField(audioInfo, ['album_name', 'AlbumName', 'albumname']) ?? '';
    final score = audioInfo?['score']?.toString() ?? '';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.check_circle, color: colorScheme.primary, size: 20),
              const SizedBox(width: 8),
              Text(
                '识别成功',
                style: textTheme.titleSmall?.copyWith(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (score.isNotEmpty) ...[
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '匹配度 $score',
                    style: textTheme.labelSmall?.copyWith(color: colorScheme.primary),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 16),
          Text(
            songName,
            style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            artist,
            style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
          ),
          if (albumName.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              albumName,
              style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => _playRecognizedSong(audioInfo),
              icon: const Icon(Icons.play_arrow),
              label: const Text('播放'),
            ),
          ),
        ],
      ),
    );
  }

  bool _hasSongData(Map<String, dynamic> response) {
    final data = response['data'];
    if (data is List && data.isNotEmpty) {
      final first = data.first;
      if (first is Map) {
        final hasName = first.containsKey('songname') ||
            first.containsKey('song_name') ||
            first.containsKey('name') ||
            first.containsKey('SongName');
        final hasHash = first.containsKey('hash') ||
            first.containsKey('FileHash') ||
            first.containsKey('album_audio_id');
        return hasName || hasHash;
      }
    }
    if (data is Map) {
      final hasName = data.containsKey('songname') ||
          data.containsKey('song_name') ||
          data.containsKey('name');
      final hasHash = data.containsKey('hash') ||
          data.containsKey('FileHash') ||
          data.containsKey('album_audio_id');
      return hasName || hasHash;
    }
    return false;
  }

  Uint8List _extractPcmFromWav(List<int> bytes) {
    if (bytes.length < 44) return Uint8List.fromList(bytes);
    if (bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46) {
      for (int i = 12; i < bytes.length - 4; i++) {
        if (bytes[i] == 0x64 && bytes[i + 1] == 0x61 && bytes[i + 2] == 0x74 && bytes[i + 3] == 0x61) {
          final pcmStart = i + 8;
          if (pcmStart < bytes.length) {
            return Uint8List.fromList(bytes.sublist(pcmStart));
          }
        }
      }
    }
    return Uint8List.fromList(bytes);
  }

  String? _extractField(Map<String, dynamic>? map, List<String> keys) {
    if (map == null) return null;
    for (final key in keys) {
      final value = map[key];
      if (value != null && value.toString().isNotEmpty) {
        return value.toString();
      }
    }
    return null;
  }

  void _playRecognizedSong(Map<String, dynamic>? audioInfo) {
    if (audioInfo == null) return;
    print('[SongRecognition] 播放按钮点击，audioInfo=$audioInfo');
    final songName = _extractField(audioInfo, ['songname', 'song_name', 'name', 'SongName']) ?? '';
    final singerName = _extractField(audioInfo, ['singername', 'singer_name', 'SingerName', 'author_name']) ?? '';
    final albumAudioId = audioInfo['album_audio_id']?.toString() ??
        audioInfo['MixSongID']?.toString() ??
        audioInfo['mixsongid']?.toString();
    final hash = audioInfo['hash']?.toString() ??
        audioInfo['FileHash']?.toString() ??
        audioInfo['file_hash']?.toString();

    print('[SongRecognition] songName=$songName, singerName=$singerName, hash=$hash, albumAudioId=$albumAudioId');

    if (hash != null && hash.isNotEmpty) {
      // 有 hash，直接播放
      _playWithHash(hash, songName, singerName, albumAudioId, audioInfo);
    } else if (albumAudioId != null && albumAudioId.isNotEmpty) {
      // 没有 hash 但有 album_audio_id，通过搜索获取 hash
      _playBySearchingHash(songName, singerName, albumAudioId, audioInfo);
    } else {
      // 既没有 hash 也没有 album_audio_id，尝试通过歌曲名搜索
      _playBySearchingHash(songName, singerName, null, audioInfo);
    }
  }

  void _playWithHash(String hash, String songName, String singerName,
      String? albumAudioId, Map<String, dynamic> audioInfo) {
    final song = Song(
      id: hash,
      title: songName,
      artist: singerName,
      album: '',
      duration: Duration.zero,
      artworkUri: audioInfo['imgurl']?.toString() ??
          audioInfo['sizable_cover']?.toString() ??
          audioInfo['union_cover']?.toString()?.replaceAll('{size}', '480'),
      albumAudioId: albumAudioId,
      isOnline: true,
    );
    context.read<PlayerProvider>().playOnlinePlaylist([song], 0);
  }

  Future<void> _playBySearchingHash(String songName, String singerName,
      String? albumAudioId, Map<String, dynamic> audioInfo) async {
    if (songName.isEmpty) {
      setState(() => _error = '无法获取播放信息：缺少歌曲名');
      return;
    }
    setState(() => _isRecognizing = true);
    try {
      final query = singerName.isNotEmpty ? '$singerName $songName' : songName;
      print('[SongRecognition] 搜索歌曲获取 hash: $query');
      final api = KugouApiClient();
      final result = await api.search(query, pagesize: 5);
      if (result == null || result.songs.isEmpty) {
        setState(() {
          _isRecognizing = false;
          _error = '未找到可播放的歌曲源';
        });
        return;
      }
      // 优先匹配 album_audio_id，否则取第一个结果
      KugouSongDetail? matched;
      if (albumAudioId != null) {
        for (final s in result.songs) {
          if (s.albumAudioId == albumAudioId) {
            matched = s;
            break;
          }
        }
      }
      matched ??= result.songs.first;
      print('[SongRecognition] 搜索到歌曲: ${matched.songName}, hash=${matched.hash}');

      final song = Song(
        id: matched.hash,
        title: songName,
        artist: singerName,
        album: matched.albumName ?? '',
        duration: Duration(milliseconds: matched.duration),
        artworkUri: matched.artworkUri ?? audioInfo['imgurl']?.toString(),
        albumAudioId: matched.albumAudioId ?? albumAudioId,
        albumId: matched.albumId,
        isOnline: true,
      );
      if (!mounted) return;
      setState(() => _isRecognizing = false);
      context.read<PlayerProvider>().playOnlinePlaylist([song], 0);
    } catch (e) {
      print('[SongRecognition] 搜索播放失败: $e');
      if (!mounted) return;
      setState(() {
        _isRecognizing = false;
        _error = '播放失败: $e';
      });
    }
  }

  Widget _buildError(ColorScheme colorScheme, TextTheme textTheme) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: colorScheme.errorContainer.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(Icons.error_outline, color: colorScheme.error, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _error!,
                style: textTheme.bodyMedium?.copyWith(color: colorScheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
