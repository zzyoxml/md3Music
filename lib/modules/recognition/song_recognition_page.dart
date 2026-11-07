import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dpad/dpad.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../../core/build_flags.dart';
import '../../core/platform_capabilities.dart';
import '../../core/services/windows_audio_input_device_service.dart';
import '../../core/services/windows_system_audio_capture_service.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/utils/app_toast.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../player/secondary_mini_player.dart';
import 'floating_recognition_service.dart';
import 'recognition_utils.dart';

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

  /// Windows 端枚举到的录音端点；未加载时为空（只显示「跟随系统默认」）。
  final List<WindowsAudioInputDevice> _inputDevices =
      <WindowsAudioInputDevice>[];

  /// 当前选中的录音端点；null = 跟随系统默认。
  WindowsAudioInputDevice? _selectedInputDevice;

  /// 当前音源（Windows 可切「麦克风 / 系统声音」，其它平台恒为麦克风）。
  RecognitionAudioSource _source = RecognitionAudioSource.microphone;

  /// 麦克风下拉条目。**稳定实例**，只在设备列表或选中项变化时整体重建
  /// （M3EDropdownMenu 以列表同一性判断是否 setItems）。
  List<M3EDropdownItem<String>> _inputDeviceItems =
      _buildInputDeviceItems(const <WindowsAudioInputDevice>[], null);
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
    if (isWindowsDesktop) {
      unawaited(_refreshInputDevices());
      unawaited(_restoreAudioSource());
    }
  }

  Future<void> _restoreAudioSource() async {
    final source = await loadRecognitionAudioSource();
    if (!mounted) return;
    setState(() => _source = source);
  }

  /// 系统声音内录只在 Windows 成立（WASAPI 设备环回）。
  bool get _usesSystemAudio =>
      isWindowsDesktop && _source == RecognitionAudioSource.system;

  /// 拉取持久化选择 + 当前设备列表；保存的设备已失效时静默回落系统默认。
  Future<void> _refreshInputDevices() async {
    final selectedId = await WindowsAudioInputDeviceService.selectedDeviceId();
    final devices = await WindowsAudioInputDeviceService.listDevices();
    if (!mounted) return;
    setState(() {
      _inputDevices
        ..clear()
        ..addAll(devices);
      _selectedInputDevice = resolveInputDevice(devices, selectedId);
      _rebuildInputDeviceItems();
    });
  }

  /// 生成下拉条目：首项是「跟随系统默认」（值为空串）。
  static List<M3EDropdownItem<String>> _buildInputDeviceItems(
    List<WindowsAudioInputDevice> devices,
    WindowsAudioInputDevice? selected,
  ) {
    final selectedId = selected?.id ?? '';
    return [
      M3EDropdownItem(
        label: '跟随系统默认',
        value: '',
        selected: selectedId.isEmpty,
      ),
      for (final device in devices)
        M3EDropdownItem(
          label: device.isSystemDefault
              ? '${device.name}（系统默认）'
              : device.name,
          value: device.id,
          selected: device.id == selectedId,
        ),
    ];
  }

  void _rebuildInputDeviceItems() {
    _inputDeviceItems =
        _buildInputDeviceItems(_inputDevices, _selectedInputDevice);
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
    // Windows 不走 Android 那套：record_windows 的 hasPermission 恒为 true，
    // 真正的授权失败在 start() 时以 PlatformException（0x80070005）抛回，
    // 由 describeRecordingStartError 翻成隐私设置指引。
    if (!isWindowsDesktop && !await _ensureMicPermission()) return;

    setState(() {
      _error = null;
      _result = null;
      _isLooping = true;
      _attemptCount = 0;
    });

    // 切换音频会话为录音模式（Android/iOS 概念，Windows 无对应实现）
    if (!isWindowsDesktop) {
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
    }

    await _recordAndRecognizeSegment();
  }

  /// Android 侧麦克风权限：先问 record，再走 permission_handler 兜底。
  Future<bool> _ensureMicPermission() async {
    if (await _recorder.hasPermission()) return true;
    try {
      final status = await Permission.microphone.request();
      if (status.isGranted) return true;
    } catch (_) {}
    if (mounted) setState(() => _error = '需要麦克风权限才能使用听歌识曲');
    return false;
  }

  Future<void> _recordAndRecognizeSegment() async {
    if (!_isLooping) return;

    final elapsed = _attemptCount * _segmentDuration;
    if (elapsed >= _maxTotalDuration) {
      await _stopLoop();
      if (_result == null && _error == null) {
        setState(() => _error = _usesSystemAudio
            ? '未识别出系统声音：请确认有音乐正在播放（DRM 保护音轨与独占模式播放无法内录）'
            : '未能识别出歌曲，请换个环境重试');
      }
      return;
    }

    _attemptCount++;
    print('[SongRecognition] === 第 $_attemptCount 轮，已用 ${elapsed}s / ${_maxTotalDuration}s ===');

    if (_usesSystemAudio) {
      await _systemAudioSegment();
      return;
    }

    final dir = await getTemporaryDirectory();
    final filePath = '${dir.path}/recording_${DateTime.now().millisecondsSinceEpoch}.wav';
    if (!await _startRecorder(filePath)) return;

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

  /// 启动录音。Android 保持 unprocessed → mic 的两级回退；
  /// Windows 按 [kWindowsCaptureFormats] 逐个试设备原生格式
  /// （MediaFoundation 不做重采样，不支持请求格式时 start 直接抛异常）。
  Future<bool> _startRecorder(String filePath) async {
    if (!isWindowsDesktop) {
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
        return true;
      } catch (_) {
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
          return true;
        } catch (e) {
          if (mounted) {
            setState(() {
              _isLooping = false;
              _error = '录音启动失败: $e';
            });
          }
          return false;
        }
      }
    }

    Object? lastError;
    final selected = _selectedInputDevice;
    for (final format in kWindowsCaptureFormats) {
      try {
        await _recorder.start(
          RecordConfig(
            encoder: AudioEncoder.wav,
            sampleRate: format.sampleRate,
            numChannels: format.channels,
            autoGain: false,
            echoCancel: false,
            noiseSuppress: false,
            device: selected == null
                ? null
                : InputDevice(id: selected.id, label: selected.name),
          ),
          path: filePath,
        );
        print('[SongRecognition] windows capture '
            '${format.sampleRate}Hz/${format.channels}ch '
            'device=${selected?.name ?? 'system-default'}');
        return true;
      } catch (e) {
        lastError = e;
      }
    }

    if (mounted) {
      setState(() {
        _isLooping = false;
        _error = describeRecordingStartError(lastError, windows: true);
      });
    }
    return false;
  }

  /// 系统声音的一轮：内录 8s → 直接送指纹（无文件、无 WAV 头）。
  Future<void> _systemAudioSegment() async {
    if (!await WindowsSystemAudioCaptureService.start()) {
      if (mounted) {
        setState(() {
          _isLooping = false;
          _error = '无法开始内录：未找到默认播放设备；'
              'DRM 保护音轨或独占模式播放同样无法采集';
        });
      }
      return;
    }

    setState(() {
      _isRecording = true;
      _isRecognizing = false;
      _error = null;
    });
    _pulseController.repeat(reverse: true);

    await Future.delayed(const Duration(seconds: _segmentDuration));

    final segment = await WindowsSystemAudioCaptureService.stop();
    _pulseController.stop();

    if (!_isLooping) return;

    setState(() {
      _isRecording = false;
      _isRecognizing = true;
    });

    if (segment == null) {
      await _recordAndRecognizeSegment();
      return;
    }

    final recognized = await _recognizeBytes(
      segment.pcm,
      fallbackSampleRate: segment.sampleRate,
    );

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

      return await _recognizeBytes(
        fileBytes,
        fallbackSampleRate: _recordSampleRate,
        isWavContainer: true,
      );
    } catch (e) {
      print('[SongRecognition] 识别出错: $e');
      return false;
    }
  }

  /// 把一段音频（WAV 容器或裸 PCM16 单声道）交给指纹链路。
  ///
  /// - [fallbackSampleRate]：读不到 WAV 头时（裸 PCM）用的采样率；
  /// - [isWavContainer]：true 才尝试解析 WAV 头拿真实采样率/声道数
  ///   （Windows 录音生效格式由设备决定，只有文件头能确认）。
  Future<bool> _recognizeBytes(
    Uint8List bytes, {
    required int fallbackSampleRate,
    bool isWavContainer = false,
  }) async {
    try {
      final wavInfo = isWavContainer ? parseWavInfo(bytes) : null;
      final fromHz = wavInfo?.sampleRate ?? fallbackSampleRate;

      // 优先用本地 Rust 服务器做 PCM 前处理（WAV 解析 + 降采样 + 增益归一化），
      // 全程网络 IO + Rust 计算，不占用 UI isolate；服务器不可用时降级回 Dart 实现。
      final rustResult = await processPcmWithRust(
        input: bytes,
        fromHz: fromHz,
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
        var rawPcm = isWavContainer ? _extractPcmFromWav(bytes) : bytes;
        final channels = wavInfo?.channels ?? 1;
        if (channels > 1) rawPcm = downmixToMono(rawPcm, channels);
        print('[SongRecognition] bytes=${bytes.length}, '
            'rawPcm=${rawPcm.length} (${fromHz}Hz/${channels}ch)');
        pcmData = downsamplePcm(rawPcm, fromHz, _targetSampleRate);
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

    // 麦克风走 record.stop()，内录必须单独收口：不停采集线程会一直跑到
    // maxDurationMs 上限，用户点了停止却还在采。
    if (_usesSystemAudio) {
      try {
        await WindowsSystemAudioCaptureService.stop();
      } catch (_) {}
    }

    if (!isWindowsDesktop) {
      try {
        final session = await AudioSession.instance;
        await session.configure(const AudioSessionConfiguration.music());
      } catch (_) {}
    }

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
      // 悬浮播放器宿主统一承载：二级形态渲染悬浮条，一级 Tab 形态自动退化
      // 交由主脚手架底部常驻 MiniPlayer（复用 isSecondaryRoutePage 路由栈判据）
      body: SecondaryMiniPlayerHost(
        child: _buildRecognitionBody(colorScheme, textTheme),
      ),
    );
  }

  Widget _buildRecognitionBody(ColorScheme colorScheme, TextTheme textTheme) {
    return Column(
        children: [
          // 悬浮窗识曲依赖 Android 悬浮窗权限 + MediaProjection，桌面端不出现
          if (supportsFloatingSongRecognition)
            _buildFloatingEntry(colorScheme, textTheme),
          if (isWindowsDesktop) _buildAudioSourceSelector(),
          // 设备选择只对麦克风有意义；内录固定跟随默认播放设备
          if (isWindowsDesktop && !_usesSystemAudio)
            _buildInputDeviceSelector(),
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
        ],
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

  /// Windows：音源二选一（与设置页「主题模式」同款 M3EToggleButtonGroup）。
  /// 识别中禁用，避免一轮中途换源。
  Widget _buildAudioSourceSelector() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      // 与设置页「主题模式」同宽：外层 Column 是居中对齐（松约束），
      // 这里显式给满宽，组内两段才会像设置页那样铺开。
      child: SizedBox(
        width: double.infinity,
        child: M3EToggleButtonGroup(
          actions: [
            M3EToggleButtonGroupAction(
              label: const Text('麦克风'),
              icon: const Icon(Icons.mic),
              enabled: !_isLooping,
            ),
            M3EToggleButtonGroupAction(
              label: const Text('系统声音'),
              icon: const Icon(Icons.computer),
              enabled: !_isLooping,
            ),
          ],
          selectedIndex: _source == RecognitionAudioSource.system ? 1 : 0,
          onSelectedIndexChanged: (index) {
            if (index == null) return;
            unawaited(_selectAudioSource(
              index == 1
                  ? RecognitionAudioSource.system
                  : RecognitionAudioSource.microphone,
            ));
          },
        ),
      ),
    );
  }

  Future<void> _selectAudioSource(RecognitionAudioSource source) async {
    await saveRecognitionAudioSource(source);
    if (!mounted) return;
    setState(() => _source = source);
  }

  /// Windows：麦克风设备下拉（M3E 字段式下拉，单选）。
  ///
  /// `items` 必须是**稳定实例**：M3EDropdownMenu 以列表同一性判断是否 setItems，
  /// 每次 build 新建列表会触发 build 期间回调互递归（真机 ANR）。故只在设备
  /// 列表或选中项真正变化时整体重建（见 [_rebuildInputDeviceItems]）。
  Widget _buildInputDeviceSelector() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: SizedBox(
        width: double.infinity,
        child: M3EDropdownMenu<String>(
          items: _inputDeviceItems,
          singleSelect: true,
          // 单选下关闭 chip 动画，当前值才渲染为可省略的纯文本
          showChipAnimation: false,
          // 外层 20 = 条目外角 12 + 列表内边距 8，同心圆（默认 28 过大）
          containerRadius: AppRadius.dropdownPanel,
          enabled: !_isLooping,
          fieldStyle: const M3EDropdownFieldStyle(
            hintText: '选择麦克风设备',
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
          onSelectionChanged: _onInputDeviceSelected,
        ),
      ),
    );
  }

  /// 下拉选中回调。
  ///
  /// 两个守卫缺一不可：
  /// - 空选（单选下再点已选中项会取消选中）只重建条目，恢复原值；
  /// - 同值守卫读**实时字段**而非闭包参数：setItems 会在 build 期间同步回调，
  ///   闭包里的旧值会让守卫失效（见 comments_view 的同源教训）。
  void _onInputDeviceSelected(List<M3EDropdownItem<String>> selected) {
    if (selected.isEmpty) {
      setState(_rebuildInputDeviceItems);
      return;
    }
    final id = selected.first.value;
    if (id == (_selectedInputDevice?.id ?? '')) return;
    WindowsAudioInputDevice? device;
    for (final candidate in _inputDevices) {
      if (candidate.id == id) {
        device = candidate;
        break;
      }
    }
    unawaited(_applyInputDevice(device));
  }

  Future<void> _applyInputDevice(WindowsAudioInputDevice? device) async {
    await WindowsAudioInputDeviceService.selectDevice(device?.id);
    if (!mounted) return;
    setState(() {
      _selectedInputDevice = device;
      _rebuildInputDeviceItems();
    });
  }

  Widget _buildPulseCircle(ColorScheme colorScheme) {
    return Center(
      // tv: TV 构建下识别大圆钮单停点（GestureDetector 不可聚焦，D-pad 原生
      // 遍历到不了；OK=开始/停止识别），并作为本页主操作抢占初始焦点
      child: kTvBuild
          ? DpadFocusable(
              autofocus: kTvBuild,
              onSelect: _toggleRecording,
              child: _buildPulseCircleBody(colorScheme),
            )
          : GestureDetector(
              onTap: _toggleRecording,
              child: _buildPulseCircleBody(colorScheme),
            ),
    );
  }

  Widget _buildPulseCircleBody(ColorScheme colorScheme) {
    return ScaleTransition(
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
