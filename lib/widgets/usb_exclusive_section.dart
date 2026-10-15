import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../core/build_flags.dart';
import '../core/remote/remote_slider.dart';
import '../core/theme/app_dimens.dart';
import '../core/services/output_mode_coordinator.dart';
import '../core/services/usb_audio_service.dart';
import '../core/utils/app_haptics.dart';
import '../core/utils/app_text_context_menu.dart';
import '../core/utils/app_toast.dart';
import '../core/utils/audio_format_utils.dart';
import '../providers/player_provider.dart';
import 'direct_pcm_section.dart';

/// USB bit-perfect 输出设置板块（设置页 / 歌曲信息页共用，保证信息与开关一致）。
///
/// **两层开关**（见 [OutputModeCoordinator]）：
/// 1. 外层「USB 独占输出」总开关 —— 关闭即全部走系统默认。未检测到 USB 音频设备时
///    置灰不可点（下方状态卡会说明原因）。
/// 2. 内层「改用系统 Direct PCM」—— **仅总开关打开时出现**，用于在
///    「直写 USB（音质最好，挑设备）」与「系统 Direct PCM（兼容性更好）」之间选一种。
///
/// 两条路径共用同一个 AudioSink 出口，故只显示当前生效那一侧的详情：
/// 直写侧见本类其余控件（MV 自动关独占 / TPDF / UAC 能力卡 / 输出格式强制 /
/// USB 音量 / 格式链），Direct PCM 侧见 [DirectPcmSection]。
///
/// 实时状态来自 [UsbAudioService.statusStream]（服务层每秒轮询一次原生状态）。
/// 拔线检测：总开关开启期间 deviceConnected 由 true→false 时关闭总开关并回调
/// [onAutoPause]。
class UsbExclusiveSection extends StatefulWidget {
  /// 拔线时自动暂停播放的回调（由宿主页面注入）。
  final VoidCallback? onAutoPause;

  const UsbExclusiveSection({super.key, this.onAutoPause});

  @override
  State<UsbExclusiveSection> createState() => _UsbExclusiveSectionState();
}

class _UsbExclusiveSectionState extends State<UsbExclusiveSection> {
  Map<String, dynamic> _status = const {};
  bool _loading = false;
  bool _wasDeviceConnected = false;

  /// 连续观测到「未连接」的次数（拔线去抖用，见 [_onStatus]）。
  int _lostPolls = 0;

  /// USB 独占独立音量（0..1，独立记忆，仅独占生效）。本地副本用于 slider 拖动即时反馈。
  double _usbVolume = 1.0;

  /// 输出格式强制（0=自适应跟随源）。本地副本用于下拉框即时反馈，持久化在服务层。
  int _outputRate = 0;
  int _outputBits = 0;
  int _outputChannels = 0;

  /// TPDF 抖动降位（默认关闭）。本地副本用于开关即时反馈，持久化在服务层。
  bool _ditherEnabled = false;

  /// 正在读取 DAC 能力（按钮 loading 态）。
  bool _probing = false;

  /// 已做过 override 校正的能力集（去重，避免重复下发）。
  String? _lastCapsKey;

  // ── 源文件格式（ExoPlayer TrackGroup + 文件头位深），切歌时刷新 ──
  /// 当前曲目的源格式（含歌曲原始采样率/声道/codec），null=尚未获取。
  Map<String, dynamic>? _sourceFormat;

  /// 从音频文件头解析的原始位深（FLAC/WAV），null=未知（有损格式不显示位深）。
  int? _headerBitDepth;

  /// 已拉取源格式的歌曲 id（去重，切歌才重新请求）。
  String? _sourceSongId;

  /// 状态流订阅 + 每秒轮询定时器（页面可见期间保证三行格式链实时）。
  StreamSubscription<Map<String, dynamic>>? _statusSub;
  Timer? _pollTimer;

  /// 监听协调器的外层/内层开关变化（切方案、独占失败回退、拔线自动关闭）。
  VoidCallback? _modeListener;

  @override
  void initState() {
    super.initState();
    _status = UsbAudioService.instance.lastStatus;
    _statusSub = UsbAudioService.instance.statusStream.listen(_onStatus);
    _wasDeviceConnected = _status['deviceConnected'] == true;
    // 两层开关的状态由协调器持有（外层开关不能读 native：内层选中 Direct PCM 时
    // 直写并未开启，但外层仍应为 ON）。故本组件要跟随协调器重建。
    _modeListener = () {
      if (mounted) setState(() {});
    };
    OutputModeCoordinator.instance.addListener(_modeListener!);
    // 从服务恢复已持久化的 USB 音量（服务启动时已从 SharedPreferences 读取）
    _usbVolume = (UsbAudioService.instance.usbVolumePercent / 100).clamp(0.0, 1.0);
    // 从服务恢复输出格式强制值
    _outputRate = UsbAudioService.instance.outputRate;
    _outputBits = UsbAudioService.instance.outputBits;
    _outputChannels = UsbAudioService.instance.outputChannels;
    // 恢复 TPDF 抖动开关（服务层已持久化+下发原生；此处仅同步本地副本，幂等）
    _ditherEnabled = UsbAudioService.instance.ditherEnabled;
    UsbAudioService.instance.initDither().then((_) {
      if (mounted) {
        setState(() => _ditherEnabled = UsbAudioService.instance.ditherEnabled);
      }
    });
    // 兜底 c：页面可见时主动查一次（覆盖原生事件未推送的边界场景）
    UsbAudioService.instance.refresh();
    // 每秒轮询原生状态：切歌/钳制重建等场景的格式变化 1s 内刷新到格式链
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      UsbAudioService.instance.refresh();
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _statusSub?.cancel();
    if (_modeListener != null) {
      OutputModeCoordinator.instance.removeListener(_modeListener!);
      _modeListener = null;
    }
    super.dispose();
  }

  /// 拉取当前曲目的源格式（TrackGroup）+ 文件头原始位深（FLAC/WAV）。
  /// 两个拉取相互独立：getSourceFormat 失败不应吞掉文件头位深的解析
  /// （实测 32bit FLAC 场景源文件行的位深因此缺失）。
  /// provider/song 在首个 await 之前取好，避免跨异步间隙使用 BuildContext。
  Future<void> _refreshSourceFormat() async {
    final provider = context.read<PlayerProvider>();
    final player = provider.audioService?.player;
    final song = provider.currentSong;
    try {
      Map<String, dynamic>? fmt;
      if (player != null) {
        fmt = await player.getSourceFormat();
      }
      if (mounted) {
        setState(() => _sourceFormat = fmt);
      }
    } catch (_) {
      // 源格式仅用于展示，失败静默
    }
    try {
      final headerBits =
          await AudioFormatUtils.parseAudioBitDepth(song?.url, song?.localPath);
      if (mounted) {
        setState(() => _headerBitDepth = headerBits);
      }
    } catch (_) {
      // 文件头解析失败静默处理
    }
  }

  void _onStatus(Map<String, dynamic> s) {
    if (!mounted) return;
    setState(() => _status = s);
    _reconcileOverrides();
    // 拔线检测：总开关开启中设备断开 → 关闭总开关回到系统默认 + 自动暂停。
    // 判定读协调器而非 native `enabled`：内层选中系统 Direct PCM 时直写并未开启，
    // 但用户「在 USB DAC 上做 bit-perfect」的意图同样随设备断开而消失。
    final nowConnected = s['deviceConnected'] == true;
    if (nowConnected) {
      _lostPolls = 0;
    } else if (_wasDeviceConnected) {
      // **必须去抖**：释放独占时 DAC 会短暂掉线再重连（真机日志
      // `devices-removed` 紧跟 `devices-added`）。不抖动的话，切换方案时那一下
      // 会被当成拔线，把用户刚打开的总开关又关掉。要求连续 2 次（约 1s）未连接。
      _lostPolls++;
      if (_lostPolls >= 2 && OutputModeCoordinator.instance.enabled) {
        widget.onAutoPause?.call();
        // 关闭走协调器（会连带关直写/关 Direct PCM/恢复效果链与音量）；
        // 提示文案由协调器写入 lastFallbackNotice。
        OutputModeCoordinator.instance.onDeviceLost();
        _lostPolls = 0;
      }
    }
    _wasDeviceConnected = nowConnected;
  }

  /// 外层「USB 独占输出」总开关。
  ///
  /// **必须走 [OutputModeCoordinator]**：直接调 `UsbAudioService.enableExclusive()`
  /// 会让 native 状态与协调器脱节 —— 效果链旁路、交叉淡化互斥、unity 音量等判定
  /// 全读协调器，绕过它会出现「独占已开但 DSP 仍被旁路」这类不一致。
  Future<void> _toggle(bool value) async {
    setState(() => _loading = true);
    try {
      await OutputModeCoordinator.instance.setEnabled(value);
      // 开启失败时协调器保持关闭并记下原因（见 _enterUsbdevfs）。在这里消费掉，
      // 免得再被 PlayerProvider 的监听器弹一次同样的 toast。
      if (value && !OutputModeCoordinator.instance.enabled) {
        if (mounted) {
          showToast(OutputModeCoordinator.instance.consumeFallbackNotice() ??
              'USB 独占不可用，已恢复普通输出',
              long: true);
        } else {
          OutputModeCoordinator.instance.consumeFallbackNotice();
        }
      }
      final s = await UsbAudioService.instance.getStatus();
      if (mounted) setState(() => _status = s);
    } catch (e) {
      if (mounted) {
        showToast('USB 独占操作失败：$e', long: true);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 内层「改用系统 Direct PCM」方案开关（仅外层打开时可见）。
  ///
  /// 切回直写若开启失败，协调器会**关闭外层**回到系统默认（不自动换到 Direct PCM）
  /// 并记下原因，同样在本处消费提示。
  Future<void> _toggleViaSystem(bool value) async {
    setState(() => _loading = true);
    try {
      await OutputModeCoordinator.instance.setViaSystem(value);
      if (!OutputModeCoordinator.instance.enabled) {
        if (mounted) {
          showToast(OutputModeCoordinator.instance.consumeFallbackNotice() ??
              'USB 独占不可用，已恢复普通输出',
              long: true);
        } else {
          OutputModeCoordinator.instance.consumeFallbackNotice();
        }
      }
      final s = await UsbAudioService.instance.getStatus();
      if (mounted) setState(() => _status = s);
    } catch (e) {
      if (mounted) {
        showToast('切换输出方案失败：$e', long: true);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final enabled = _status['enabled'] == true;
    final connected = _status['deviceConnected'] == true;
    final alive = _status['streamAlive'] == true;
    final deviceName = _status['deviceName'] as String? ?? '未知设备';
    // 两层开关（协调器持有；外层开关**不能**读 native `enabled`）
    final mode = OutputModeCoordinator.instance;
    final modeEnabled = mode.enabled;
    final viaSystem = mode.viaSystem;
    final viaSystemActive = mode.isDirectPcmActive;
    // UAC1 / UAC2（AudioControl 描述符 bcdADC）——未读取到时为空，不显示徽标
    final uacLabel = _status['uacLabel'] as String? ?? '';
    // 输出格式可选项：全部来自接入 DAC 的能力（无能力时只有"自适应"且禁用）
    final rates = _supportedRates();
    final bits = _supportedBits();
    final channels = _supportedChannels();

    // 切歌后异步拉取源格式（以歌曲 id 去重，与歌曲信息页同一机制）
    final song = context.watch<PlayerProvider>().currentSong;
    if (song?.id != _sourceSongId) {
      _sourceSongId = song?.id;
      _refreshSourceFormat();
    }

    // ── 三行格式链数据：源文件 / 播放流 / DAC 端点 ──────────────
    // 源文件：歌曲原始格式（TrackGroup 采样率/声道 + 文件头位深 + codec 名）
    final src = _sourceFormat;
    final hasSrc = src != null && src['hasData'] == true;
    final srcRate = hasSrc ? ((src['sampleRate'] as num?)?.toInt() ?? 0) : 0;
    final srcCh = hasSrc ? ((src['channelCount'] as num?)?.toInt() ?? 0) : 0;
    final srcCodec = hasSrc ? src['codec'] as String? : null;
    // FLAC 扩展 extractor 会在 extractor 层直接解码为 raw PCM（2026-09-14 定位），
    // 此时 TrackGroup 的 mime 是 audio/raw（解码后 PCM，不含容器/位深信息）。
    // 这种情况回落到「按文件扩展名」推断原始编码，而不是把 audio/raw 当 codec 展示。
    final mimeIsDecodedPcm = srcCodec == 'audio/raw';
    final codecLabel = (srcCodec != null &&
            srcCodec.isNotEmpty &&
            !mimeIsDecodedPcm)
        ? srcCodec
        : AudioFormatUtils.codecLabelFromPath(song?.url, song?.localPath);
    // 有损格式（MP3/AAC/…）无位深概念；无损格式仅在文件头解析成功时展示
    final srcBits =
        (codecLabel != null && AudioFormatUtils.lossyCodecs.contains(codecLabel))
            ? 0
            : (_headerBitDepth ?? 0);

    // 播放流：独占开启=实际写入 USB 的流配置；未开启=ExoPlayer 解码输出格式
    final ready = _status['streamReady'] == true;
    final streamActive = enabled && ready;
    final usbRate = (_status['sampleRate'] as num?)?.toInt() ?? 0;
    final usbCh = (_status['channelCount'] as num?)?.toInt() ?? 0;
    final dacBits = (_status['dacBitDepth'] as num?)?.toInt() ?? 0;
    final decRate = (_status['lastSampleRate'] as num?)?.toInt() ?? 0;
    final decCh = (_status['lastChannelCount'] as num?)?.toInt() ?? 0;
    final decEnc = (_status['lastEncoding'] as num?)?.toInt() ?? 0;
    final playRate = streamActive ? usbRate : decRate;
    final playCh = streamActive ? usbCh : decCh;
    final playBits = streamActive
        ? dacBits
        : (decRate > 0 ? AudioFormatUtils.encodingBits(decEnc) : 0);
    // DIRECT：整数 PCM 直写（率/声道一致且非 float 输出），native 仅做位深对齐、无 DSP；
    // 经过 float 域（重采样/声道转换/32bit float 开关）为 PCM。
    final isDirect = streamActive &&
        decRate > 0 &&
        decRate == usbRate &&
        decCh == usbCh &&
        decEnc != 4; // C.ENCODING_PCM_FLOAT
    // 与源不一致的率/声道（钳制降级/重采样/上混）用橙色高亮
    final rateConverted = srcRate > 0 && playRate > 0 && srcRate != playRate;
    final chConverted = srcCh > 0 && playCh > 0 && srcCh != playCh;
    final convertColor = Colors.orange.shade800;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── 外层总开关：USB 独占输出 ─────────────────────────────
        // 未检测到 USB 音频设备时置灰不可点；下方状态卡会说明原因
        // （静默不可点会让用户困惑，不知道为什么点不动）。
        // search: usb dac 独占 音频
        SwitchListTile(
          secondary: Icon(Icons.usb, color: colorScheme.primary),
          title: const Text('USB 独占输出'),
          subtitle: Text(_outerSubtitle(
            modeEnabled: modeEnabled,
            viaSystem: viaSystem,
            connected: connected,
          )),
          value: modeEnabled,
          onChanged: (!connected || _loading) ? null : _toggle,
        ),
        // ── 内层方案开关：仅外层打开时出现 ──────────────────────
        if (modeEnabled) ...[
          // search: 系统 direct pcm bit perfect 无损 直通 备用
          SwitchListTile(
            secondary: Icon(Icons.graphic_eq, color: colorScheme.primary),
            title: const Text('改用系统 Direct PCM'),
            subtitle: const Text(
                '不直写 USB，改用系统 AudioTrack；兼容性好，采样率与 DAC 原生率一致时达成 bit-perfect'),
            value: viaSystem,
            onChanged: _loading ? null : _toggleViaSystem,
          ),
        ],
        // 只显示当前生效那一侧：系统 Direct PCM 生效时，直写侧的控件全部隐藏
        // （它们对系统 AudioTrack 无意义：没有 UAC 能力协商、没有直写流可强制格式）。
        // 判据是 `viaSystemActive`（= 外层开 且 内层选中），**不是** `modeEnabled` ——
        // 外层开 + 内层未选时仍然走直写，那一侧的详情必须照常显示。
        if (viaSystemActive) const DirectPcmSection() else ...[
        // 播放 MV 时自动关闭独占（默认开启）：独占绕过 AudioFlinger，MV 无系统音频
        FutureBuilder<bool>(
          future: UsbAudioService.instance.getAutoDisableForMv(),
          builder: (context, snapshot) {
            final autoClose = snapshot.data ?? true;
            // search: usb 独占 mv
            return SwitchListTile(
              secondary: Icon(Icons.movie_outlined, color: colorScheme.primary),
              title: const Text('播放 MV 时自动关闭独占'),
              value: autoClose,
              onChanged: (v) async {
                AppHaptics.lightImpact(HapticCategory.control);
                await UsbAudioService.instance.setAutoDisableForMv(v);
                if (mounted) setState(() {});
              },
            );
          },
        ),
        // TPDF 抖动降位（默认关闭）：独占降位(如 32→24)时加三角抖动消除截断失真，
        // 数据路径每块缓冲读取 → 切换立即生效，无需重建流
        // search: tpdf 抖动 dither 降位 量化 32bit 位深
        SwitchListTile(
          secondary: Icon(Icons.graphic_eq, color: colorScheme.primary),
          title: const Text('TPDF 抖动降位'),
          subtitle: const Text('独占输出降位(如 32→24)时加三角抖动，消除截断失真；噪底略升。立即生效'),
          value: _ditherEnabled,
          onChanged: (v) async {
            AppHaptics.lightImpact(HapticCategory.control);
            setState(() => _ditherEnabled = v);
            await UsbAudioService.instance.setDither(v);
          },
        ),
        // 状态卡：设备名 + UAC1/UAC2 + 总线速度 + 能力摘要
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        connected ? deviceName : '未连接 USB 音频设备',
                        style: textTheme.bodyMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // UAC1 / UAC2：来自 AudioControl 描述符的 bcdADC
                    if (uacLabel.isNotEmpty) ...[
                      _StatusChip(uacLabel, color: colorScheme.tertiary),
                      const SizedBox(width: 6),
                    ],
                    _StatusChip(
                      connected ? (alive ? '运行中' : '已连接') : '未连接',
                      color: alive
                          ? Colors.green
                          : (connected ? Colors.orange : colorScheme.outline),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  _deviceSummary(),
                  style: textTheme.bodySmall
                      ?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
        // 输出格式选择（采样率/位深/声道，默认自适应；独占开启时改选立即重建流生效）
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              // 三行格式下拉（率/位深/声道）原本靠 DropdownButton 自带的行高
              // 撑开间距；换成 M3E 字段后行高变矮，需显式给定行距，
              // 否则三行会挤在一起、与页内其它设置项的节奏不一致。
              spacing: 12,
              children: [
                // 可选项全部来自 DAC 能力；未读取到能力时禁用（避免写入 DAC 不支持的格式）
                _formatDropdown(
                  context,
                  icon: Icons.speed,
                  label: '输出采样率',
                  value: _outputRate,
                  currentValue: () => _outputRate,
                  items: {
                    0: '自适应',
                    for (final r in rates) r: _rateLabel(r),
                  },
                  enabled: rates.isNotEmpty,
                  onChanged: (v) => _updateFormat(rate: v ?? 0),
                ),
                _formatDropdown(
                  context,
                  icon: Icons.high_quality,
                  label: '输出位深',
                  value: _outputBits,
                  currentValue: () => _outputBits,
                  items: {
                    0: '自适应',
                    for (final b in bits) b: '$b-bit',
                  },
                  enabled: bits.isNotEmpty,
                  onChanged: (v) => _updateFormat(bits: v ?? 0),
                ),
                _formatDropdown(
                  context,
                  icon: Icons.surround_sound,
                  label: '输出声道',
                  value: _outputChannels,
                  currentValue: () => _outputChannels,
                  items: {
                    0: '自适应',
                    for (final c in channels) c: _channelLabel(c),
                  },
                  enabled: channels.isNotEmpty,
                  onChanged: (v) => _updateFormat(channels: v ?? 0),
                ),
                Text(
                  _capsHintText(connected),
                  style: textTheme.bodySmall
                      ?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
                // 手动读取（未授权时弹系统授权框；只读描述符，不打断系统音频）
                if (connected)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _probing ? null : _probeCaps,
                      icon: Icon(Icons.refresh,
                          size: 16, color: colorScheme.primary),
                      label: Text(
                        _probing ? '读取中…' : '读取 DAC 能力',
                        style: textTheme.labelMedium
                            ?.copyWith(color: colorScheme.primary),
                      ),
                    ),
                  ),
                // ── 实时格式链：源文件 → 播放流 → DAC 端点 ──────────────
                const Padding(
                  padding: EdgeInsets.only(top: 12, bottom: 10),
                  child: Divider(height: 1),
                ),
                _FormatChainRow(
                  label: '源文件',
                  segments: [
                    _ChainText(codecLabel ?? '—'),
                    _ChainText(AudioFormatUtils.formatRate(srcRate)),
                    _ChainText(AudioFormatUtils.formatCh(srcCh)),
                    if (srcBits > 0)
                      _ChainText(AudioFormatUtils.formatBits(srcBits)),
                  ],
                ),
                const SizedBox(height: 14),
                _FormatChainRow(
                  label: '播放流',
                  segments: [
                    // DIRECT=整数直写无损（绿）；PCM=经 float 域转换（蓝）；
                    // 未开独占走系统混音=灰色 PCM；无任何播放数据时显示 —
                    if (streamActive)
                      _StatusChip(
                        isDirect ? 'DIRECT' : 'PCM',
                        color:
                            isDirect ? Colors.green : colorScheme.primary,
                      )
                    else if (decRate > 0)
                      _StatusChip('PCM', color: colorScheme.outline)
                    else
                      const _ChainText('—'),
                    _ChainText(
                      AudioFormatUtils.formatRate(playRate),
                      color: rateConverted ? convertColor : null,
                    ),
                    _ChainText(
                      AudioFormatUtils.formatCh(playCh),
                      color: chConverted ? convertColor : null,
                    ),
                    _ChainText(AudioFormatUtils.formatBits(playBits)),
                  ],
                ),
                const SizedBox(height: 14),
                _FormatChainRow(
                  label: 'DAC 端点',
                  // 端点仅在独占流就绪时有实际硬件配置；未开启独占显示 —
                  segments: streamActive
                      ? [
                          const _ChainText('PCM'),
                          _ChainText(AudioFormatUtils.formatRate(usbRate)),
                          _ChainText(AudioFormatUtils.formatCh(usbCh)),
                          _ChainText(AudioFormatUtils.formatBits(dacBits)),
                        ]
                      : [const _ChainText('—')],
                ),
              ],
            ),
          ),
        ),
        // USB 独占独立音量（任何时候可调；独立记忆，仅对独占生效）
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      _usbVolume <= 0
                          ? Icons.volume_off
                          : _usbVolume < 0.5
                              ? Icons.volume_down
                              : Icons.volume_up,
                      size: 18,
                      color: colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'USB 音量',
                        style: textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    Text(
                      '${(_usbVolume * 100).round()}%',
                      style: textTheme.labelMedium
                          ?.copyWith(color: colorScheme.primary),
                    ),
                  ],
                ),
                // tv: TV 构建换 RemoteSlider——M3ESlider 自带 Focus 吞四方向键；
                // TV 分支丢 M3ESliderDecoration 触觉参数（P-C）
                kTvBuild
                    ? RemoteSlider(
                        value: _usbVolume,
                        // 不传 divisions = 无级调节（无节点）
                        // 实时生效：拖动即下发原生，无需松手
                        onChanged: (v) {
                          setState(() => _usbVolume = v);
                          UsbAudioService.instance.setUsbVolume(v * 100);
                        },
                      )
                    : M3ESlider(
                        value: _usbVolume,
                        // 不传 divisions = 无级调节（无节点）
                        decoration: const M3ESliderDecoration(
                          // 显式给离散触觉配置：divisions 为空时组件默认取连续触觉
                          //（10ms 最小间隔），拖动会高频走震动通道导致马达饱和
                          haptic: M3EHapticFeedback.medium,
                          hapticConfig: M3EHapticConfig.discrete(),
                        ),
                        // 实时生效：拖动即下发原生，无需松手
                        onChanged: (v) {
                          setState(() => _usbVolume = v);
                          UsbAudioService.instance.setUsbVolume(v * 100);
                        },
                      ),
                Text(
                  enabled
                      ? '已生效：DAC 音量 = 系统音量 × USB 音量'
                      : '未开启独占时暂不生效，开启后即按此音量输出',
                  style: textTheme.bodySmall
                      ?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
        // 调试信息（折叠）：便于真机排查问题，避免后续反复加日志
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(Icons.bug_report_outlined,
                size: 18, color: colorScheme.onSurfaceVariant),
            title: Text('调试信息',
                style: textTheme.bodySmall
                    ?.copyWith(color: colorScheme.onSurfaceVariant)),
            initiallyExpanded: false,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 一键复制 Salt Player 式诊断（设备拓扑/所选端点/有效格式/Rate Set）。
                    // 运行日志走设置页「导出诊断日志」（usb.log 随报告打包）。
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () async {
                          final text = _status['diagnostics']?.toString() ??
                              _status.entries
                                  .map((e) => '${e.key}: ${e.value}')
                                  .join('\n');
                          await Clipboard.setData(ClipboardData(text: text));
                          if (mounted) showToast('诊断信息已复制');
                        },
                        icon: Icon(Icons.copy,
                            size: 14, color: colorScheme.primary),
                        label: Text('复制诊断信息',
                            style: textTheme.labelSmall
                                ?.copyWith(color: colorScheme.primary)),
                      ),
                    ),
                    SelectableText(
                      _status.entries
                          .map((e) => '${e.key}: ${e.value}')
                          .join('\n'),
                      contextMenuBuilder: buildAppTextContextMenu,
                      style: textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        ],
      ],
    );
  }

  /// 外层总开关的副标题：说明**当前实际生效**的是什么，避免「开关显示 ON 但其实
  /// 没独占」的误解（内层选中时并没有 force-claim USB 接口）。
  String _outerSubtitle({
    required bool modeEnabled,
    required bool viaSystem,
    required bool connected,
  }) {
    if (modeEnabled) {
      return viaSystem
          ? '当前：经系统 AudioTrack 输出，不直写 USB（兼容性更好）'
          : '当前：绕过 AudioFlinger 直写 USB DAC（音质最好，挑设备）';
    }
    if (!connected) return '未检测到 USB 音频设备，全部走系统默认输出';
    return '开启后可在「直写 USB」与「系统 Direct PCM」两种方案间选择';
  }

  // ── 输出格式选择辅助 ─────────────────────────────────────────

  /// 更新输出格式（持久化 + 下发原生；独占开启中原生会立即重建流）。
  void _updateFormat({int? rate, int? bits, int? channels}) {
    AppHaptics.selectionClick(HapticCategory.control);
    final r = rate ?? _outputRate;
    final b = bits ?? _outputBits;
    final c = channels ?? _outputChannels;
    if (r == _outputRate && b == _outputBits && c == _outputChannels) return;
    setState(() {
      _outputRate = r;
      _outputBits = b;
      _outputChannels = c;
    });
    UsbAudioService.instance.setOutputFormat(r, b, c);
  }

  // ── DAC 能力（全部来自接入设备的 USB 描述符，无硬编码兜底） ───────

  /// DAC 支持的采样率（UAC1 离散列表 / UAC2 连续区间按声明范围生成）。
  List<int> _supportedRates() => _intList('supportedRates');

  /// DAC 支持的位深。
  List<int> _supportedBits() => _intList('supportedBits');

  /// DAC 支持的声道数。
  List<int> _supportedChannels() => _intList('supportedChannels');

  /// 从未开启独占时是否只有"自适应"可选（DAC 能力未知）。
  bool get _hasCaps =>
      _supportedRates().isNotEmpty ||
      _supportedBits().isNotEmpty ||
      _supportedChannels().isNotEmpty;

  List<int> _intList(String key) {
    final list = _status[key];
    if (list is List && list.isNotEmpty) {
      return list.map((e) => (e as num).toInt()).toSet().toList()..sort();
    }
    return const [];
  }

  /// UAC2 连续区间时原生给出的声明范围（0=未声明/离散列表）。
  int get _rateRangeMin => (_status['rateRangeMin'] as num?)?.toInt() ?? 0;
  int get _rateRangeMax => (_status['rateRangeMax'] as num?)?.toInt() ?? 0;

  /// 能力来源：active=已打开设备（实际流配置）/ probed=只读描述符探测 / none=未知。
  String get _capsSource => _status['capabilitiesSource'] as String? ?? 'none';

  /// DAC 能力读取完成后，清除当前 DAC 不支持的强制值（回落自适应）。
  /// 每个能力集只处理一次（按内容去重），避免重复下发。
  void _reconcileOverrides() {
    final rates = _supportedRates();
    final bits = _supportedBits();
    final chs = _supportedChannels();
    if (rates.isEmpty && bits.isEmpty && chs.isEmpty) return;
    final key = '$rates|$bits|$chs';
    if (key == _lastCapsKey) return;
    _lastCapsKey = key;
    var r = _outputRate;
    var b = _outputBits;
    var c = _outputChannels;
    if (r != 0 && rates.isNotEmpty && !rates.contains(r)) r = 0;
    if (b != 0 && bits.isNotEmpty && !bits.contains(b)) b = 0;
    if (c != 0 && chs.isNotEmpty && !chs.contains(c)) c = 0;
    if (r == _outputRate && b == _outputBits && c == _outputChannels) return;
    setState(() {
      _outputRate = r;
      _outputBits = b;
      _outputChannels = c;
    });
    UsbAudioService.instance.setOutputFormat(r, b, c);
  }

  /// 手动读取一次接入 DAC 的能力（原生只读描述符，不打断系统音频）。
  Future<void> _probeCaps() async {
    setState(() => _probing = true);
    try {
      await UsbAudioService.instance.probeDacCapabilities();
      final s = await UsbAudioService.instance.getStatus();
      if (mounted) {
        setState(() => _status = s);
        _reconcileOverrides();
        showToast(_hasCaps ? '已读取 DAC 能力' : '未读取到 DAC 能力');
      }
    } on UsbAudioException catch (e) {
      if (mounted) showToast('读取 DAC 能力失败：${e.message}', long: true);
    } catch (e) {
      if (mounted) showToast('读取 DAC 能力失败：$e', long: true);
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  String _rateLabel(int rate) {
    if (rate % 1000 == 0) return '${rate ~/ 1000} kHz';
    return '${(rate / 1000).toStringAsFixed(1)} kHz';
  }

  String _channelLabel(int ch) {
    if (ch == 1) return '单声道';
    if (ch == 2) return '立体声';
    return '$ch 声道';
  }

  /// 设备卡副标题：VID:PID · 总线速度 · UAC 版本 · DAC 支持的能力并集。
  String _deviceSummary() {
    if (_status['deviceConnected'] != true) {
      return '连接 USB DAC 后自动读取其 UAC 版本与支持的格式';
    }
    final seg = <String>[];
    final vid = (_status['deviceVid'] as num?)?.toInt() ?? 0;
    final pid = (_status['devicePid'] as num?)?.toInt() ?? 0;
    if (vid > 0 && pid > 0) seg.add('${_hex4(vid)}:${_hex4(pid)}');
    final speed = _status['usbSpeed'] as String? ?? '';
    if (speed == 'full') {
      seg.add('全速 Full-Speed');
    } else if (speed == 'high') {
      seg.add('高速 High-Speed');
    }
    final uac = _status['uacLabel'] as String? ?? '';
    if (uac.isNotEmpty) seg.add(uac);
    final rates = _supportedRates();
    final bits = _supportedBits();
    final channels = _supportedChannels();
    if (rates.isEmpty && bits.isEmpty && channels.isEmpty) {
      seg.add('未读取到 DAC 能力');
      return seg.join(' · ');
    }
    if (rates.isNotEmpty) {
      seg.add(rates.map(_rateShort).join('/'));
      // UAC2 连续区间：说明可选项来自 DAC 声明的范围
      if (_rateRangeMin > 0 && _rateRangeMax >= _rateRangeMin) {
        seg.add('声明范围 ${_rateShort(_rateRangeMin)}-${_rateShort(_rateRangeMax)}');
      }
    }
    if (bits.isNotEmpty) seg.add('${bits.join('/')}-bit');
    if (channels.isNotEmpty) seg.add(channels.map(_channelLabel).join('/'));
    // 未开启独占时能力来自"只读描述符"探测（未 claim 接口），与独占中的实际流配置区分
    if (_capsSource == 'probed') seg.add('未开启独占');
    return seg.join(' · ');
  }

  /// 钳制提示：强制值被 DAC 能力降级时说明实际下发的采样率。
  String _clampHint() {
    final override = (_status['outputRateOverride'] as num?)?.toInt() ?? 0;
    final effective = (_status['outputRateEffective'] as num?)?.toInt() ?? 0;
    if (override > 0 && effective > 0 && override != effective) {
      return 'DAC 不支持 ${_rateLabel(override)}，已钳制为 ${_rateLabel(effective)}';
    }
    return '';
  }

  /// 输出格式卡提示：无能力时提示先读取；有连续区间时说明来源。
  String _capsHintText(bool connected) {
    final clamp = _clampHint();
    if (clamp.isNotEmpty) return clamp;
    if (!connected) return '未连接 USB DAC，连接后按其描述符提供可选项';
    if (!_hasCaps) return '该 DAC 未声明支持的采样率，可点下方「读取 DAC 能力」再试';
    if (_rateRangeMin > 0 && _rateRangeMax >= _rateRangeMin) {
      return 'DAC 声明连续采样率区间，可选项已限制在该范围内；自适应跟随歌曲格式';
    }
    return '可选项来自 DAC 描述符；自适应跟随歌曲格式，强制值与源不同时将重采样';
  }

  String _rateShort(int rate) => _rateLabel(rate).replaceAll(' ', '');

  String _hex4(int v) => v.toRadixString(16).toUpperCase().padLeft(4, '0');

  Widget _formatDropdown(
    BuildContext context, {
    required IconData icon,
    required String label,
    required int value,
    required Map<int, String> items,
    required ValueChanged<int?> onChanged,
    required int Function() currentValue,
    bool enabled = true,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    // 传入值不在可选项内时回落到「自适应」(0)，与原 DropdownButton 一致
    final effectiveValue = items.containsKey(value) ? value : 0;
    return Row(
      children: [
        Icon(icon,
            size: 18,
            color: enabled ? colorScheme.primary : colorScheme.outline),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: textTheme.bodyMedium?.copyWith(
              color: enabled ? null : colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        // M3E 字段式下拉需要有限宽度：固定宽度保持行内「左侧图标+标签、
        // 右侧控件」的布局骨架，取值过长时在字段内省略
        SizedBox(
          width: 150,
          child: M3EDropdownMenu<int>(
            items: [
              for (final e in items.entries)
                M3EDropdownItem(
                  label: e.value,
                  value: e.key,
                  selected: e.key == effectiveValue,
                ),
            ],
            singleSelect: true,
            showChipAnimation: false,
            // 未读取到 DAC 能力时禁用（只有"自适应"），避免下发 DAC 不支持的格式
            enabled: enabled,
            fieldStyle: M3EDropdownFieldStyle(
              hintText: label,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              // 禁用时保持旧 DropdownButton 的灰化取值与箭头
              foregroundColor: enabled ? null : colorScheme.outline,
              selectedTextStyle: textTheme.bodyMedium?.copyWith(
                color: enabled ? null : colorScheme.outline,
              ),
            ),
            // currentValue 用函数而非按值捕获的局部变量：M3EDropdownMenu 只在
            // 挂载时保存一次该回调，闭包捕获的局部变量会残留首帧旧值
            onSelectionChanged: (selected) {
              // 单选下再次点击已选中项会被取消选中：强制重建以恢复原值
              if (selected.isEmpty) {
                setState(() {});
                return;
              }
              final v = selected.first.value;
              if (v == currentValue()) return;
              onChanged(v);
            },
          ),
        ),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String label;
  final Color color;

  const _StatusChip(this.label, {required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      // 字号走 labelSmall（11sp，与原裸值同大小），不再绕开字阶体系。
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 格式链中的一行：小灰标签 + 一行粗体格式段（codec/率/声道/位深或徽标）。
class _FormatChainRow extends StatelessWidget {
  final String label;
  final List<Widget> segments;

  const _FormatChainRow({required this.label, required this.segments});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: textTheme.bodySmall
              ?.copyWith(color: colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 20,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: segments,
        ),
      ],
    );
  }
}

/// 格式链中的一个文本段（大字号粗体 + 等宽数字）；[color] 非空时用于高亮转换项。
class _ChainText extends StatelessWidget {
  final String text;
  final Color? color;

  const _ChainText(this.text, {this.color});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Text(
      text,
      style: (textTheme.titleSmall ?? const TextStyle()).copyWith(
        fontWeight: FontWeight.w700,
        fontFeatures: const [FontFeature.tabularFigures()],
        color: color ?? Theme.of(context).colorScheme.onSurface,
      ),
    );
  }
}
