import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../../core/utils/app_toast.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../player/mini_player.dart';
import 'floating_recognition_service.dart';
import 'recognition_utils.dart';

class SongRecognitionPage extends StatefulWidget {
  /// 是否在页面底部显示 MiniPlayer。
  /// 作为独立路由打开时为 true（页面自带 MiniPlayer）；
  /// 作为主页 Tab / LaunchPad 二级页面时为 false（由 _MainLayout 统一提供，
  /// 避免重复）。
  final bool showMiniPlayer;

  const SongRecognitionPage({super.key, this.showMiniPlayer = true});

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
    // 监听悬浮窗识曲状态变化（开启/关闭）刷新入口按钮
    FloatingRecognitionService.instance.addListener(_onFloatingRecognitionChanged);
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  void _onFloatingRecognitionChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    FloatingRecognitionService.instance.removeListener(_onFloatingRecognitionChanged);
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

      // 优先用本地 Rust 服务器做 PCM 前处理（WAV 解析 + 降采样 + 增益归一化），
      // 全程网络 IO + Rust 计算，不占用 UI isolate；服务器不可用时降级回 Dart 实现。
      final rustResult = await processPcmWithRust(
        input: fileBytes,
        fromHz: _recordSampleRate,
        toHz: _targetSampleRate,
      );
      Uint8List pcmData;
      int maxAmplitude;
      if (rustResult != null) {
        pcmData = rustResult.pcm;
        maxAmplitude = rustResult.maxAmplitude;
        print('[SongRecognition] rust pcm: len=${pcmData.length} (${_targetSampleRate}Hz) maxAmp=$maxAmplitude');
      } else {
        // 降级：Dart 实现（原逻辑）
        final rawPcm = _extractPcmFromWav(fileBytes);
        print('[SongRecognition] fileBytes=${fileBytes.length}, rawPcm=${rawPcm.length} (${_recordSampleRate}Hz)');
        pcmData = downsamplePcm(rawPcm, _recordSampleRate, _targetSampleRate);
        print('[SongRecognition] dart pcm fallback: ${pcmData.length} bytes (${_targetSampleRate}Hz)');
        maxAmplitude = computeMaxAmplitude(pcmData);
        if (maxAmplitude >= kSilenceAmplitudeThreshold) {
          pcmData = normalizeGain(pcmData, maxAmplitude);
        }
      }

      // 检查音量（静音段跳过）
      print('[SongRecognition] maxAmplitude=$maxAmplitude');
      if (maxAmplitude < kSilenceAmplitudeThreshold) {
        print('[SongRecognition] 本段为静音，跳过');
        return false;
      }

      final api = KugouApiClient();
      final response = await api.audioMatch(pcmData);

      if (!mounted || !_isLooping) return false;

      print('[SongRecognition] 第 $_attemptCount 轮响应: $response');

      if (response != null && hasSongData(response)) {
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
    // 悬浮窗运行中时同步最新主题色（跟随设置页莫奈/动态取色）
    if (FloatingRecognitionService.instance.isActive) {
      FloatingRecognitionService.instance
          .pushThemeColors(Theme.of(context).colorScheme);
    }
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('听歌识曲'),
      ),
      body: Column(
        children: [
          _buildFloatingEntry(colorScheme, textTheme),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight - 48,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        const SizedBox(height: 32),
                        _buildPulseCircle(colorScheme),
                        const SizedBox(height: 32),
                        _buildStatusText(textTheme, colorScheme),
                        const SizedBox(height: 32),
                        if (_result != null)
                          _buildResult(colorScheme, textTheme),
                        if (_error != null) _buildError(colorScheme, textTheme),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          if (widget.showMiniPlayer) const MiniPlayer(),
        ],
      ),
    );
  }

  /// 悬浮窗识曲入口按钮（顶部横幅）。
  /// 点击开启/关闭悬浮窗式识曲；Android < 10 或权限缺失时给出提示。
  Widget _buildFloatingEntry(ColorScheme colorScheme, TextTheme textTheme) {
    final active = FloatingRecognitionService.instance.isActive;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton.tonalIcon(
          onPressed: _openFloatingRecognition,
          icon: Icon(active ? Icons.stop : Icons.picture_in_picture_alt),
          label: Text(active ? '关闭悬浮窗识曲' : '悬浮窗模式'),
        ),
      ),
    );
  }

  Future<void> _openFloatingRecognition() async {
    final svc = FloatingRecognitionService.instance;
    if (svc.isActive) {
      await svc.stop();
      if (mounted) {
        showToast('已关闭悬浮窗识曲', long: true);
        setState(() {});
      }
      return;
    }

    final result = await svc.start();
    if (!mounted) return;
    switch (result) {
      case FloatingStartResult.started:
        // 开启后立即同步当前主题色到悬浮窗
        await svc.pushThemeColors(Theme.of(context).colorScheme);
        if (!mounted) return;
        showToast('悬浮窗识曲已开启，可返回任意界面点击悬浮按钮识别', long: true);
        Navigator.of(context).pop();
      case FloatingStartResult.alreadyActive:
        break;
      case FloatingStartResult.unsupported:
        showToast('仅支持 Android 10 及以上', long: true);
      case FloatingStartResult.permissionDenied:
        showToast('需要麦克风/悬浮窗权限，请在系统设置中开启后重试', long: true);
      case FloatingStartResult.failed:
        showToast('启动失败，请重试', long: true);
    }
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

    final songName = extractField(audioInfo, ['songname', 'song_name', 'name', 'SongName']) ?? '未知歌曲';
    final artist = extractField(audioInfo, ['singername', 'singer_name', 'artist', 'SingerName']) ?? '未知歌手';
    final albumName = extractField(audioInfo, ['album_name', 'AlbumName', 'albumname']) ?? '';
    final score = audioInfo?['score']?.toString() ?? '';
    // 封面 URL（与播放逻辑中的字段顺序一致），union_cover 可能带 {size} 占位符
    final coverUrl = extractCoverUrl(audioInfo);

    // 歌曲信息列（歌名/歌手/专辑）
    final infoColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
      ],
    );

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
          // 有封面时：左侧封面 + 右侧信息；无封面时保持原有纯文本布局
          if (coverUrl != null && coverUrl.isNotEmpty)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildCover(coverUrl, colorScheme),
                const SizedBox(width: 16),
                Expanded(child: infoColumn),
              ],
            )
          else
            infoColumn,
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => playRecognizedSong(
                context,
                audioInfo,
                openFullPlayer: true,
                onError: (msg) {
                  if (mounted) setState(() => _error = msg);
                },
              ),
              icon: const Icon(Icons.play_arrow),
              label: const Text('播放'),
            ),
          ),
        ],
      ),
    );
  }

  /// 识别结果卡片左侧的歌曲封面（96x96 圆角，带加载中/失败占位）。
  Widget _buildCover(String coverUrl, ColorScheme colorScheme) {
    Widget placeholder() => Container(
      width: 96,
      height: 96,
      color: colorScheme.surfaceContainerHighest,
      child: Icon(Icons.music_note, color: colorScheme.onSurfaceVariant, size: 32),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: CachedNetworkImage(
        imageUrl: coverUrl,
        width: 96,
        height: 96,
        fit: BoxFit.cover,
        memCacheWidth: 288,
        memCacheHeight: 288,
        placeholder: (_, _) => placeholder(),
        errorWidget: (_, _, _) => placeholder(),
      ),
    );
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
