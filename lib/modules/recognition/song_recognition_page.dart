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
  String? _error;
  Map<String, dynamic>? _result;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  Timer? _autoStopTimer;

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
    _autoStopTimer?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _toggleRecording() async {
    if (_isRecording) {
      await _stopRecording();
    } else {
      await _startRecording();
    }
  }

  Future<void> _startRecording() async {
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
    });

    try {
      // 切换音频会话为录音模式（暂停播放器释放音频焦点）
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
        avAudioSessionMode: AVAudioSessionMode.defaultMode,
        androidAudioAttributes: AndroidAudioAttributes(
          contentType: AndroidAudioContentType.speech,
          usage: AndroidAudioUsage.voiceCommunication,
        ),
        androidWillPauseWhenDucked: false,
      ));

      final dir = await getTemporaryDirectory();
      final filePath = '${dir.path}/recording_${DateTime.now().millisecondsSinceEpoch}.wav';
      await _recorder.start(
        RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: filePath,
      );
      setState(() {
        _isRecording = true;
        _error = null;
      });
      _pulseController.repeat(reverse: true);

      _autoStopTimer = Timer(const Duration(seconds: 8), () async {
        if (_isRecording) {
          await _stopRecording();
        }
      });
    } catch (e) {
      setState(() => _error = '录音启动失败: $e');
    }
  }

  Future<void> _stopRecording() async {
    _pulseController.stop();
    _pulseController.reset();
    _autoStopTimer?.cancel();

    final path = await _recorder.stop();
    setState(() {
      _isRecording = false;
      _isRecognizing = true;
    });

    // 恢复音频会话为播放模式
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
    } catch (_) {}

    if (path == null || path.isEmpty) {
      setState(() {
        _isRecognizing = false;
        _error = '录音数据为空，请重试';
      });
      return;
    }

    try {
      final file = File(path);
      final exists = await file.exists();
      if (!exists) {
        setState(() {
          _isRecognizing = false;
          _error = '录音文件不存在，请重试';
        });
        return;
      }

      final fileBytes = await file.readAsBytes();
      await file.delete().catchError((_) {});

      if (fileBytes.isEmpty) {
        setState(() {
          _isRecognizing = false;
          _error = '录音数据为空，请重试';
        });
        return;
      }

      // 去掉 WAV 文件头，提取纯 PCM 数据
      final pcmData = _extractPcmFromWav(fileBytes);
      print('[SongRecognition] fileBytes=${fileBytes.length}, pcmData=${pcmData.length}');
      if (pcmData.isEmpty || pcmData.length < 32000) {
        // 至少 1 秒的 PCM 数据 (16000Hz * 2bytes)
        setState(() {
          _isRecognizing = false;
          _error = pcmData.isEmpty ? '音频数据解析失败，请重试' : '录音时间太短，请多录一会儿';
        });
        return;
      }

      // 检查是否全是静音
      final isSilent = _isSilentAudio(pcmData);
      if (isSilent) {
        setState(() {
          _isRecognizing = false;
          _error = '没有检测到声音，请确保周围有音乐播放';
        });
        return;
      }

      final api = KugouApiClient();
      final response = await api.audioMatch(pcmData);

      if (!mounted) return;

      print('[SongRecognition] raw response: $response');

      if (response != null && _hasSongData(response)) {
        setState(() {
          _result = response;
          _isRecognizing = false;
        });
      } else if (response != null) {
        setState(() {
          _isRecognizing = false;
          _error = '未能识别出歌曲，请换个片段重试';
        });
      } else {
        setState(() {
          _isRecognizing = false;
          _error = '识别失败，请重试';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isRecognizing = false;
          _error = '识别出错: $e';
        });
      }
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
                  if (_isRecognizing)
                    const Padding(
                      padding: EdgeInsets.only(top: 24),
                      child: CircularProgressIndicator(),
                    ),
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
        onTap: _isRecognizing ? null : _toggleRecording,
        child: ScaleTransition(
          scale: _isRecording ? _pulseAnimation : const AlwaysStoppedAnimation(1.0),
          child: Container(
            width: 140,
            height: 140,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _isRecording
                  ? colorScheme.error
                  : _isRecognizing
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
                _isRecording ? Icons.mic : Icons.mic_none,
                size: 56,
                color: _isRecording
                    ? colorScheme.onError
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
      text = '正在聆听...';
    } else if (_isRecognizing) {
      text = '正在识别...';
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
    final audioid = data['data'];
    Map<String, dynamic>? audioInfo;

    if (audioid is Map<String, dynamic>) {
      audioInfo = audioid;
    } else if (data is Map<String, dynamic>) {
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

  /// 检查 PCM 数据是否为静音
  bool _isSilentAudio(Uint8List pcmData) {
    // 采样检查：每隔 1000 个样本检查一次
    int nonZeroCount = 0;
    final step = 2000; // 每 2000 字节（1000 个 16bit 样本）检查一次
    final checkCount = (pcmData.length / step).floor().clamp(1, 100);
    for (int i = 0; i < checkCount; i++) {
      final offset = i * step;
      if (offset + 1 < pcmData.length) {
        final sample = (pcmData[offset] | (pcmData[offset + 1] << 8)).toSigned(16);
        if (sample.abs() > 500) {
          nonZeroCount++;
        }
      }
    }
    // 如果 10% 以上的采样点有声音，认为不是静音
    return nonZeroCount < (checkCount * 0.1);
  }

  /// 检查 API 响应是否包含有效歌曲数据
  bool _hasSongData(Map<String, dynamic> response) {
    final data = response['data'];
    if (data is List && data.isNotEmpty) {
      final first = data.first;
      if (first is Map<String, dynamic>) {
        // 检查是否有实际的歌曲字段
        final hasName = first.containsKey('songname') || first.containsKey('song_name') || first.containsKey('name');
        final hasHash = first.containsKey('hash') || first.containsKey('FileHash');
        return hasName || hasHash;
      }
    }
    return false;
  }

  /// 从 WAV 文件中提取纯 PCM 数据（去掉 WAV 头）
  Uint8List _extractPcmFromWav(List<int> bytes) {
    if (bytes.length < 44) return Uint8List.fromList(bytes);
    // 检查 RIFF 头
    if (bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46) {
      // 找到 "data" 标记：遍历查找 "data" 字符串
      for (int i = 12; i < bytes.length - 4; i++) {
        if (bytes[i] == 0x64 && bytes[i + 1] == 0x61 && bytes[i + 2] == 0x74 && bytes[i + 3] == 0x61) {
          // data chunk: 4 bytes "data" + 4 bytes size + PCM data
          final pcmStart = i + 8;
          if (pcmStart < bytes.length) {
            return Uint8List.fromList(bytes.sublist(pcmStart));
          }
        }
      }
    }
    // 非标准 WAV，直接返回全部数据
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
    final songName = _extractField(audioInfo, ['songname', 'song_name', 'name', 'SongName']) ?? '';
    final singerName = _extractField(audioInfo, ['singername', 'singer_name', 'SingerName']) ?? '';
    final albumAudioId = audioInfo['album_audio_id']?.toString() ?? audioInfo['MixSongID']?.toString();
    final hash = audioInfo['hash']?.toString() ?? audioInfo['FileHash']?.toString();

    if (hash != null && hash.isNotEmpty) {
      final song = Song(
        id: albumAudioId ?? hash,
        title: songName,
        artist: singerName,
        album: '',
        duration: Duration.zero,
        artworkUri: audioInfo['imgurl']?.toString(),
        isOnline: true,
      );
      context.read<PlayerProvider>().playOnlinePlaylist([song], 0);
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
