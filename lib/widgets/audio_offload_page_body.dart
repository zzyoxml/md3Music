import 'dart:async';

import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/build_flags.dart';
import '../core/services/audio_decoder_capabilities.dart';
import '../core/services/audio_offload_capabilities.dart';
import '../core/services/audio_offload_service.dart';
import '../core/services/device_capabilities.dart';
import '../core/theme/app_dimens.dart';
import '../core/utils/app_haptics.dart';
import '../core/utils/app_toast.dart';
import '../providers/player_provider.dart';
import 'audio_decoder_capability_view.dart';
import 'audio_offload_capability_view.dart';

/// 「硬件解码播放」（Audio Offload）设置子页内容。
///
/// 页面按「用户决策需要的顺序」排，正文尽量少重复（开关状态只在开关上、
/// 预测结论只在状态卡「结论」行、区块说明只在各自折叠 header）：
/// 1. 总开关 + 精简状态卡（3 行常驻：实际状态 / 当前曲目 / 结论；让路原因与
///    平台不支持只在异常态追加）。硬解由系统 AudioTrack 的 offload 通道决定，
///    机型协商不可靠时会出现「开关开着但没硬解」，结论行以 offload 协商为准。
/// 2. 设备解码器能力（[AudioDecoderCapabilityView]）—— 默认折叠，header 副标题
///    常驻摘要「硬解解码器 N 个 · 支持编码 N 种」。
/// 3. 系统 offload 协商（[AudioOffloadCapabilityView]）—— 同样默认折叠：
///    它回答的是「系统肯不肯直通」，只在排查「为什么没硬解」时才需要看。
/// 4. 操作行：重新探测（同时重跑解码器枚举 + HAL 协商）+ 复制诊断文本
///    （TV 无剪贴板交互，故 `kTvBuild` 下隐藏）。
///
/// 刷新策略：1s 稀疏轮询 [AudioOffloadService.refresh]（AGENTS.md 帧率规则：这是
/// 状态查询，不是动画，禁止改成 60fps 驱动），同时监听 ChangeNotifier —— 原生主动
/// 推送（切歌/协商变化/开关）时即时重建，无需等下一次轮询。
class AudioOffloadPageBody extends StatefulWidget {
  const AudioOffloadPageBody({super.key});

  @override
  State<AudioOffloadPageBody> createState() => _AudioOffloadPageBodyState();
}

class _AudioOffloadPageBodyState extends State<AudioOffloadPageBody> {
  AudioOffloadService get _svc => AudioOffloadService.instance;

  /// 可见期间的兜底轮询间隔（与 `DirectPcmSection` 一致）。
  static const int _pollIntervalMs = 1000;
  Timer? _pollTimer;

  /// 「重新探测」调用中：按钮置灰并显示进度，避免连点堆叠多次 HAL 协商。
  bool _probeBusy = false;

  /// 「系统 offload 协商」是否展开（默认收起，正文是给排障用的细节）。
  ///
  /// 刻意不用 `ExpansionTile`：设置页列表带 `PageStorageKey`，ExpansionTile 的展开态
  /// 会和页内 SelectableText 的滚动偏移串台（docs/agents/troubleshooting.md §4.15）。
  /// 自绘 header + setState 不读写 PageStorage，天然安全。
  bool _offloadExpanded = false;

  /// 当前曲目的源格式（`player.getSourceFormat()`），仅用于展示与预测。
  Map<String, dynamic>? _sourceFormat;

  /// 已经拉取过源格式的曲目 id：切歌时补拉一次，避免每秒都跨通道取格式。
  Object? _sourceSongId;

  @override
  void initState() {
    super.initState();
    _svc.addListener(_onServiceChanged);
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: _pollIntervalMs),
      (_) => _onPollTick(),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_svc.refresh());
      unawaited(_refreshSourceFormat());
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _svc.removeListener(_onServiceChanged);
    super.dispose();
  }

  void _onServiceChanged() {
    if (mounted) setState(() {});
  }

  /// 1s 轮询：刷新实测状态；顺带比对当前曲目 id，切歌时补拉源格式。
  void _onPollTick() {
    if (!mounted) return;
    unawaited(_svc.refresh());
    final PlayerProvider? provider = _maybePlayerProvider();
    final Object? songId = provider?.currentSong?.id;
    if (songId != _sourceSongId) {
      unawaited(_refreshSourceFormat());
    }
  }

  /// 取当前曲目的源格式；取不到时静默（仅用于展示，失败不影响开关）。
  Future<void> _refreshSourceFormat() async {
    final PlayerProvider? provider = _maybePlayerProvider();
    final Object? songId = provider?.currentSong?.id;
    final player = provider?.audioService?.player;
    _sourceSongId = songId;
    if (player == null) return;
    try {
      final Map<String, dynamic>? fmt = await player.getSourceFormat();
      if (mounted) setState(() => _sourceFormat = fmt);
    } catch (_) {
      // 源格式仅用于展示，失败静默
    }
  }

  /// Provider 只在上层 App 里注册；单独挂载本页（测试/预览）时不应抛异常。
  PlayerProvider? _maybePlayerProvider() {
    try {
      return Provider.of<PlayerProvider>(context, listen: false);
    } on ProviderNotFoundException {
      return null;
    }
  }

  /// 总开关：先震动反馈 + 立即重绘（开关跟手），再落持久化与原生下发。
  Future<void> _toggle(bool value) async {
    AppHaptics.lightImpact(HapticCategory.control);
    setState(() {});
    try {
      await _svc.setEnabled(value);
    } catch (_) {
      // 服务层内部已记录失败原因（状态卡/让路原因会体现），此处只保证 UI 不卡住
    }
    if (mounted) setState(() {});
  }

  /// 重新探测：一次按钮同时重跑「解码器枚举」与「HAL offload 协商」两个数据源。
  ///
  /// `reprobe: true` 会强制原生重跑；两个探测在服务层并行、互不阻塞。
  Future<void> _reprobe() async {
    if (_probeBusy) return;
    setState(() => _probeBusy = true);
    try {
      await _svc.reloadAllCapabilities(reprobe: true);
    } catch (_) {
      // 探测失败原因由快照的 probeError 展示，不额外弹窗
    } finally {
      if (mounted) setState(() => _probeBusy = false);
    }
  }

  Future<void> _copyDiagnostics() async {
    await Clipboard.setData(ClipboardData(text: _buildDiagnosticsText()));
    if (mounted) showToast('已复制解码能力诊断');
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colorScheme = theme.colorScheme;
    final AudioOffloadService svc = _svc;
    final Map<String, dynamic>? fmt = _sourceFormat;
    final bool hasFormat = fmt != null && fmt['hasData'] == true;
    final String? codec = hasFormat ? (fmt['codec'] as String?) : null;
    final int rate =
        hasFormat ? ((fmt['sampleRate'] as num?)?.toInt() ?? 0) : 0;
    final int channels =
        hasFormat ? ((fmt['channelCount'] as num?)?.toInt() ?? 0) : 0;
    final bool hasTrack = hasFormat && codec != null && rate > 0;
    // 两个数据源分别预测：设备解码器能力（MediaCodec）与系统 offload 协商。
    // 只有两者都说「支持」，开关打开后才真正硬解，所以分开显示、不做合并。
    final bool? decoderPredicted =
        hasTrack ? svc.predictDecoderSupported(codec, rate, channels) : null;
    final bool? offloadPredicted =
        hasTrack ? svc.predictSupported(codec, rate, channels) : null;

    // 两个预测都说支持、开关也开着，但原生实测没有进入 offload —— 这类机型协商
    // 不可靠，必须显式告警，不能让用户以为已经省电了。
    //
    // 判据必须带 `requestedMode > 0`：它由 DefaultAudioSink.setOffloadMode 在
    // 每次 configure 时写入，为 0 说明「本次还没走到配置」（暂停在起播前 / 刚切歌
    // 未就绪）。没有这条门控时，「载入后暂停」会误报「探测支持但实际回落」。
    final int requestedMode =
        (svc.status['requestedMode'] as num?)?.toInt() ?? 0;
    final bool predictionMissed = decoderPredicted == true &&
        offloadPredicted == true &&
        !svc.offloaded &&
        svc.effective &&
        requestedMode > 0;

    // 必须自带 flutter/material 的 Material：本页宿主是设置页的 **material_ui**
    // Scaffold，它插入的是 material_ui 自家同名不同型的 `Material`；flutter/material
    // 的 ListTile/SwitchListTile/InkWell 按类型找祖先 → 找不到会抛
    // `No Material widget found`，再被全局 _FallbackErrorWidget 顶成
    // 「此处内容加载出错」（见 docs/agents/troubleshooting.md §4.13）。
    // 参考 lib/widgets/direct_pcm_section.dart 的同款写法。
    return Material(
      type: MaterialType.transparency,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // 标题必须是字符串字面量：设置搜索索引生成器只从字面量提取条目。
        // search: 硬解 offload 硬件解码 省电 低功耗 直通 direct 解码器 能力 矩阵
        SwitchListTile(
          title: const Text('硬件解码播放'),
          subtitle:
              const Text('MP3/AAC 等交给硬件解码播放，显著省电；与均衡器/母带/频谱/倍速互斥'),
          value: svc.userEnabled,
          onChanged: _toggle,
        ),
        _buildStatusCard(
          theme,
          colorScheme,
          svc,
          hasFormat,
          codec,
          rate,
          channels,
          decoderPredicted,
          offloadPredicted,
          predictionMissed,
        ),
        const Divider(height: 24),
        // 主信息：设备解码器能力（每编码一张卡 + 解码器清单折叠）。
        const AudioDecoderCapabilityView(),
        const Divider(height: 8),
        // 次要信息：系统 offload 协商矩阵，默认收起。
        _buildOffloadSectionHeader(theme, colorScheme),
        if (_offloadExpanded) const AudioOffloadCapabilityView(),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.sm,
            AppSpacing.lg,
            AppSpacing.xl,
          ),
          child: Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: <Widget>[
              FilledButton.tonalIcon(
                onPressed: _probeBusy ? null : _reprobe,
                icon: _probeBusy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.radar_outlined, size: 18),
                label: Text(_probeBusy ? '探测中…' : '重新探测'),
              ),
              // TV 上没有剪贴板交互（遥控器无法粘贴），按项目约定用 kTvBuild 门控隐藏。
              if (!kTvBuild)
                OutlinedButton.icon(
                  onPressed: _copyDiagnostics,
                  icon: const Icon(Icons.copy_all_outlined, size: 18),
                  label: const Text('复制诊断文本'),
                ),
            ],
          ),
        ),
        ],
      ),
    );
  }

  // ── 系统 offload 协商（自绘折叠 header）──────────────────────────

  /// 「系统 offload 协商」折叠 header：标题 + 一句作用说明 + 展开箭头。
  ///
  /// 默认收起是刻意的：这块回答的是「系统肯不肯直通」，属于排障细节；日常用户只
  /// 需要看上面的解码器能力与状态卡的结论。
  Widget _buildOffloadSectionHeader(ThemeData theme, ColorScheme colorScheme) {
    void toggle() => setState(() => _offloadExpanded = !_offloadExpanded);
    final Widget header = InkWell(
      onTap: toggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.xs,
          AppSpacing.lg,
          AppSpacing.xs,
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xxs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  Text('系统 offload 协商', style: theme.textTheme.titleSmall),
                  Text(
                    '决定本开关是否真正生效',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            AnimatedRotation(
              turns: _offloadExpanded ? 0.5 : 0,
              duration: const Duration(milliseconds: 160),
              child: Icon(
                Icons.expand_more,
                size: 20,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
    // TV 构建必须显式接 DpadFocusable：遥控器 OK 走 onSelect，不靠 InkWell 点击。
    return kTvBuild ? DpadFocusable(onSelect: toggle, child: header) : header;
  }

  // ── 实测状态卡 ─────────────────────────────────────────────────

  Widget _buildStatusCard(
    ThemeData theme,
    ColorScheme colorScheme,
    AudioOffloadService svc,
    bool hasFormat,
    String? codec,
    int rate,
    int channels,
    bool? decoderPredicted,
    bool? offloadPredicted,
    bool predictionMissed,
  ) {
    final String? yieldReason = svc.yieldReason;
    final bool hasYield = yieldReason != null && yieldReason.isNotEmpty;
    final int sdk = DeviceCapabilities.instance.sdkInt;
    final String platformText = svc.platformSupported
        ? (sdk > 0 ? 'Android $sdk（API≥29）' : 'Android（API≥29）')
        : '当前平台/系统版本不支持';
    // 实际状态一行说完：开关意图由上方 SwitchListTile 表达，这里只讲结果——
    // 生效（含休眠调度）/ 让路 / 关闭。休眠调度只在生效时才有意义，融入不单列。
    final String actualText = !svc.effective
        ? (hasYield ? '已让路（软解）' : '已关（软解）')
        : (svc.offloaded
            ? (svc.sleeping ? '硬解生效 · 休眠调度中' : '硬解生效')
            : '未生效（软解）');

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _row(theme, '实际状态', actualText),
          _row(
            theme,
            '当前曲目',
            hasFormat && codec != null ? '$codec · ${rate}Hz · ${channels}ch' : '待播放',
          ),
          _row(
            theme,
            '结论',
            _conclusionLabel(
              decoderPredicted,
              offloadPredicted,
              svc.offloaded,
              predictionMissed,
            ),
            warn: predictionMissed,
          ),
          // 让路原因 / 平台不支持只在异常态出现，正常态零信息量不占行。
          if (hasYield)
            _row(theme, '让路原因', yieldReason, warn: true),
          if (!svc.platformSupported)
            _row(theme, '平台', platformText, warn: true),
        ],
      ),
    );
  }

  /// 结论：以 **offload 协商**为准（它决定开关是否真正生效）；解码器能力只作
  /// 参考信息。真机证据：小米 Android16 上 `hardware=0`（音频 MediaCodec 全是软解
  /// ——offload 由 DSP 完成，不经 MediaCodec）但 offload 协商 6 项支持。若把
  /// MediaCodec 硬解数量当 AND 条件，这类设备会永远误报「软解」。
  String _conclusionLabel(
    bool? decoderPredicted,
    bool? offloadPredicted,
    bool offloaded,
    bool predictionMissed,
  ) {
    final String base;
    if (offloadPredicted == false) {
      base = '软解';
    } else if (offloadPredicted == true) {
      base = '可硬解';
    } else {
      base = '不确定';
    }
    final String actual = offloaded ? '实测：硬解中' : '实测：软解中';
    final String suffix = predictionMissed ? '（探测支持但实际回落，机型协商不可靠）' : '';
    return '$base · $actual$suffix';
  }

  /// 状态行：左侧固定宽度标签 + 右侧可换行取值；`warn` 用主题 error 色强调。
  Widget _row(ThemeData theme, String label, String value,
      {bool warn = false}) {
    final TextStyle? style = theme.textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 84,
            child: Text(
              label,
              style: style?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: style?.copyWith(
                color: warn ? theme.colorScheme.error : null,
                fontWeight: warn ? FontWeight.w600 : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── 诊断文本 ───────────────────────────────────────────────────

  /// 复制到剪贴板的纯文本：实测状态 + 解码器能力摘要 + offload 协商摘要 + 原生
  /// status 全量键值。
  ///
  /// 用户反馈「开了不省电」时，这份文本能直接区分是开关没下发、解码器不支持、
  /// ROM 协商失败，还是被均衡器/倍速等条件让路。
  String _buildDiagnosticsText() {
    final AudioOffloadService svc = _svc;
    final StringBuffer buf = StringBuffer('=== 硬件解码播放诊断 ===\n');
    buf.writeln('平台支持: ${svc.platformSupported}'
        '${svc.platformFailed ? '（原生报告 failed）' : ''}');
    buf.writeln('用户开关: ${svc.userEnabled}');
    buf.writeln('实际生效: ${svc.effective}');
    buf.writeln('硬解中: ${svc.offloaded}  休眠调度: ${svc.sleeping}');
    buf.writeln('让路原因: ${svc.yieldReason ?? '—'}');
    final Map<String, dynamic>? fmt = _sourceFormat;
    if (fmt != null && fmt['hasData'] == true) {
      buf.writeln('当前曲目: ${fmt['codec']} · ${fmt['sampleRate']}Hz · '
          '${fmt['channelCount']}ch');
    } else {
      buf.writeln('当前曲目: 待播放');
    }

    _writeDecoderDiagnostics(buf, svc.decoderCapabilities);
    _writeOffloadDiagnostics(buf, svc.capabilities);

    buf.writeln('--- 原生 status ---');
    svc.status.forEach((String key, dynamic value) {
      buf.writeln('$key: $value');
    });
    return buf.toString();
  }

  /// 解码器能力摘要：解码器数量 + 每编码的采样率 / 声道 / 位深。
  void _writeDecoderDiagnostics(
    StringBuffer buf,
    AudioDecoderCapabilitySnapshot? snap,
  ) {
    buf.writeln('--- 解码器能力（MediaCodec）---');
    if (snap == null || snap.isEmpty) {
      buf.writeln('解码器快照: 尚未探测');
      return;
    }
    buf.writeln('设备指纹: ${snap.deviceKey.isEmpty ? '未知' : snap.deviceKey}'
        '  API: ${snap.sdkInt}  探测耗时: ${snap.probeCostMs} ms');
    buf.writeln('硬解解码器: ${snap.hardwareCodecCount} 个'
        '  可硬解编码: ${snap.supportedFormatCount} 种'
        '  全部编码: ${snap.formatCount} 种'
        '  条目: ${snap.entries.length}');
    final String probeError = (snap.probeError ?? '').trim();
    if (probeError.isNotEmpty) buf.writeln('探测失败: $probeError');
    for (final AudioDecoderFormatCapability format in snap.byFormat.values) {
      buf.writeln('  ${format.formatLabel} ${format.mime}'
          ' → ${format.hasHardware ? '硬解' : '软解'}'
          '  解码器: ${format.codecNames.length}'
          '  采样率: ${format.sampleRates.isEmpty ? '未知' : format.sampleRates.join('/')}'
          '  声道: ${format.maxChannels > 0 ? format.maxChannels : '未知'}'
          '  位深: ${_bitDepthDiagnostics(format.bitDepths)}');
    }
    for (final String note in snap.notes) {
      buf.writeln('  备注: $note');
    }
  }

  /// 位深三态压缩成一行：`16✓ 24✗ 32? float?`（缺失按 unknown）。
  String _bitDepthDiagnostics(
    Map<DecoderBitDepth, DecoderBitDepthSupport> bitDepths,
  ) {
    String mark(DecoderBitDepthSupport? support) {
      switch (support ?? DecoderBitDepthSupport.unknown) {
        case DecoderBitDepthSupport.supported:
          return '✓';
        case DecoderBitDepthSupport.unsupported:
          return '✗';
        case DecoderBitDepthSupport.unknown:
          return '?';
      }
    }

    return '16=${mark(bitDepths[DecoderBitDepth.bit16])} '
        '24=${mark(bitDepths[DecoderBitDepth.bit24])} '
        '32=${mark(bitDepths[DecoderBitDepth.bit32])} '
        'float=${mark(bitDepths[DecoderBitDepth.float])}';
  }

  /// offload 协商摘要（原生 HAL 协商结果，与解码器能力是两个数据源）。
  void _writeOffloadDiagnostics(
    StringBuffer buf,
    AudioOffloadCapabilitySnapshot? snap,
  ) {
    buf.writeln('--- 系统 offload 协商 ---');
    if (snap == null || snap.isEmpty) {
      buf.writeln('协商快照: 尚未探测');
      return;
    }
    buf.writeln('设备指纹: ${snap.deviceKey.isEmpty ? '未知' : snap.deviceKey}'
        '  API: ${snap.sdkInt}');
    buf.writeln('原生输出率: ${snap.outputSampleRate} Hz'
        '  每缓冲帧数: ${snap.outputFramesPerBuffer}');
    buf.writeln('变速支持: ${snap.variableRateSupported}'
        '  探测时间: ${snap.probedAt.toLocal()}');
    final String? probeError = snap.probeError;
    if (probeError != null && probeError.trim().isNotEmpty) {
      buf.writeln('探测失败: ${probeError.trim()}');
    }
    for (final AudioOffloadCapability cap in snap.entries) {
      buf.writeln('  ${cap.shortName} ${cap.sampleRate}Hz '
          '${cap.channelCount}ch → ${cap.supported ? '支持' : '不支持'}'
          '${cap.gapless ? ' gapless' : ''}'
          '${cap.speedChange ? ' 变速' : ''}');
    }
  }
}
