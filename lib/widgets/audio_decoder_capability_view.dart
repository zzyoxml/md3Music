import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';

import '../core/build_flags.dart';
import '../core/services/audio_decoder_capabilities.dart';
import '../core/services/audio_offload_service.dart';
import '../core/theme/app_dimens.dart';

/// **设备解码器能力**（MediaCodec 枚举结果）区块，默认折叠。
///
/// 与 [AudioOffloadCapabilityView] 是两个数据源，不能混为一谈：
/// - 这里回答「这台设备装了哪些解码器、每种编码 / 采样率 / 位深支不支持」；
/// - 那边回答「系统 offload 通道肯不肯把整段音频直通给 AudioFlinger」。
/// 只有两边都支持，开关打开后才会真正硬解。日常只看 header 副标题的摘要
/// （硬解解码器数 / 支持编码数），细节矩阵点开再看，与 offload 协商同款交互。
///
/// 自身订阅 [AudioOffloadService]（ChangeNotifier）：重新探测完成后快照更新，
/// 即使宿主页面没有重建，本组件也会自己刷新。**不自己轮询** —— 页面主体已有 1s
/// 稀疏轮询（AGENTS.md 帧率规则）。
class AudioDecoderCapabilityView extends StatefulWidget {
  const AudioDecoderCapabilityView({super.key});

  @override
  State<AudioDecoderCapabilityView> createState() =>
      _AudioDecoderCapabilityViewState();
}

class _AudioDecoderCapabilityViewState
    extends State<AudioDecoderCapabilityView> {
  AudioOffloadService get _svc => AudioOffloadService.instance;

  /// 整个区块是否展开（默认收起，header 摘要常驻）。
  ///
  /// 刻意不用 `ExpansionTile`：设置页二级分类列表带 `PageStorageKey`，而
  /// ExpansionTile 的展开态也写进同一个 PageStorage 桶，会和页内 SelectableText 的
  /// 滚动偏移串台（docs/agents/troubleshooting.md §4.15）。自绘 header + setState
  /// 不碰 PageStorage，天然没有这个问题。
  bool _sectionExpanded = false;

  /// 「解码器清单」是否展开（仅在区块展开后可见）。
  bool _listExpanded = false;

  @override
  void initState() {
    super.initState();
    _svc.addListener(_onServiceChanged);
  }

  @override
  void dispose() {
    _svc.removeListener(_onServiceChanged);
    super.dispose();
  }

  void _onServiceChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colorScheme = theme.colorScheme;
    final AudioDecoderCapabilitySnapshot? snap = _svc.decoderCapabilities;
    final bool hasData = snap != null && !snap.isEmpty;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _buildSectionHeader(theme, colorScheme, hasData, snap),
          if (_sectionExpanded) ...<Widget>[
            if (!hasData)
              Text(
                '尚未探测，点击下方重新探测',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              )
            else ...<Widget>[
              const Gap(AppSpacing.sm),
              // 来源说明全区块只说一次：下面每张编码卡的采样率都是解码器上报值。
              Text(
                '以下能力为设备解码器（MediaCodec）上报，仅供参考',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const Gap(AppSpacing.sm),
              ..._buildFormatCards(theme, colorScheme, snap),
              ..._buildNotes(theme, colorScheme, snap),
              const Gap(AppSpacing.xs),
              _buildDecoderList(theme, colorScheme, snap),
            ],
          ],
        ],
      ),
    );
  }

  // ── 区块折叠 header ─────────────────────────────────────────────

  /// 标题 + 摘要副标题常驻，点开才渲染编码卡。摘要复用原 `_buildSummary` 的
  /// 文案（耗时是排查「设置页首次打开卡不卡」的关键读数）；探测失败时收起态
  /// 也要能看到（error 色），展开后另有完整卡片。
  Widget _buildSectionHeader(
    ThemeData theme,
    ColorScheme colorScheme,
    bool hasData,
    AudioDecoderCapabilitySnapshot? snap,
  ) {
    final String probeError =
        hasData ? (snap!.probeError ?? '').trim() : '';
    final String summary;
    if (!hasData) {
      summary = '尚未探测';
    } else if (probeError.isNotEmpty) {
      summary = '探测失败：$probeError';
    } else if (snap!.hardwareCodecCount == 0) {
      // 移动平台音频解码普遍不走 MediaCodec 硬件路径（硬解在 DSP/offload
      // 完成），全软解是常态而非故障。摘要必须给出格式总数并点明原因，
      // 否则用户会把「硬解 0 个」误读成探测坏了（下方 offload 协商区块
      // 往往同时显示多项支持，两个数字直接打架）。
      summary = '探测到 ${snap.formatCount} 种编码 · 均为软解'
          '（音频硬解通常走 DSP，不经 MediaCodec）';
    } else {
      summary = '硬解解码器 ${snap.hardwareCodecCount} 个 · '
          '支持编码 ${snap.supportedFormatCount} 种 · '
          '探测耗时 ${snap.probeCostMs} ms';
    }
    final Color summaryColor =
        probeError.isNotEmpty && hasData ? colorScheme.error : colorScheme.onSurfaceVariant;

    void toggle() => setState(() => _sectionExpanded = !_sectionExpanded);
    final Widget header = InkWell(
      onTap: toggle,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xxs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  Text('设备解码器能力', style: theme.textTheme.titleSmall),
                  Text(
                    summary,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: summaryColor,
                    ),
                  ),
                ],
              ),
            ),
            AnimatedRotation(
              turns: _sectionExpanded ? 0.5 : 0,
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

  // ── 每个编码一张卡 ─────────────────────────────────────────────

  List<Widget> _buildFormatCards(
    ThemeData theme,
    ColorScheme colorScheme,
    AudioDecoderCapabilitySnapshot snap,
  ) {
    final List<Widget> out = <Widget>[];
    // byFormat 已按「MP3 → AAC → HE-AAC → …」固定顺序排好，直接顺序渲染，
    // 不在 UI 层重复排序（顺序规则收敛在模型层 `_kFormatOrder`）。
    snap.byFormat.forEach(
      (String label, AudioDecoderFormatCapability format) {
        out.add(_buildFormatCard(theme, colorScheme, snap, format));
      },
    );
    return out;
  }

  Widget _buildFormatCard(
    ThemeData theme,
    ColorScheme colorScheme,
    AudioDecoderCapabilitySnapshot snap,
    AudioDecoderFormatCapability format,
  ) {
    final TextStyle? hintStyle = theme.textTheme.bodySmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
    );
    final bool bitDepthProbed = _isBitDepthProbed(snap, format);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // 标题行：左侧格式名 + 硬解徽标（Wrap 可换行），右侧解码器计数。
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Wrap(
                  spacing: AppSpacing.xs,
                  runSpacing: AppSpacing.xxs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    Text(format.formatLabel, style: theme.textTheme.titleSmall),
                    _buildHardwareBadge(theme, colorScheme, format.hasHardware),
                  ],
                ),
              ),
              const Gap(AppSpacing.xs),
              Text('${format.codecNames.length} 个解码器', style: hintStyle),
            ],
          ),
          const Gap(AppSpacing.xs),
          _buildSampleRates(theme, colorScheme, format),
          const Gap(AppSpacing.xxs),
          Text(_channelLabel(format.maxChannels), style: hintStyle),
          const Gap(AppSpacing.xxs),
          _buildBitDepths(theme, colorScheme, format, bitDepthProbed),
        ],
      ),
    );
  }

  /// 硬解 / 软解徽标：硬解用主题主色描边，软解用 onSurfaceVariant，不硬编码颜色。
  Widget _buildHardwareBadge(
    ThemeData theme,
    ColorScheme colorScheme,
    bool hardware,
  ) {
    final Color color =
        hardware ? colorScheme.primary : colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xs,
        vertical: AppSpacing.xxs,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.full),
        border: Border.all(color: color),
      ),
      child: Text(
        hardware ? '硬解' : '软解',
        style: theme.textTheme.bodySmall?.copyWith(
          color: color,
          fontWeight: hardware ? FontWeight.w600 : null,
        ),
      ),
    );
  }

  /// 采样率 chips：只列**设备解码器上报支持**的采样率，不列不支持项。
  ///
  /// 采样率是离散步进（44100 / 48000 / 96000 …），全部列出不会太长；来源说明
  /// 已上移到区块顶部全区块只说一次，卡内不再重复。
  Widget _buildSampleRates(
    ThemeData theme,
    ColorScheme colorScheme,
    AudioDecoderFormatCapability format,
  ) {
    final TextStyle? hintStyle = theme.textTheme.bodySmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
    );
    final List<int> rates = format.sampleRates;
    return Wrap(
      spacing: AppSpacing.xs,
      runSpacing: AppSpacing.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        if (rates.isEmpty)
          Text('采样率未上报', style: hintStyle)
        else
          for (final int rate in rates) _buildRateChip(theme, colorScheme, rate),
      ],
    );
  }

  Widget _buildRateChip(
    ThemeData theme,
    ColorScheme colorScheme,
    int rate,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xs,
        vertical: AppSpacing.xxs,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.full),
        border: Border.all(color: colorScheme.primary),
      ),
      child: Text(
        '$rate Hz',
        style: theme.textTheme.bodySmall?.copyWith(
          color: colorScheme.primary,
        ),
      ),
    );
  }

  /// 声道：`0` 是「未知」而不是「不支持」，措辞必须区分开。
  String _channelLabel(int maxChannels) {
    if (maxChannels <= 0) return '声道数未知';
    return '最多 $maxChannels 声道';
  }

  /// 位深三态徽标：supported 主色 / unsupported onSurfaceVariant / unknown outline 描边。
  ///
  /// 三态必须区分显示：把 unknown 画成「不支持」会让用户误判设备能力
  /// （模型层注释也是同一约定）。
  Widget _buildBitDepths(
    ThemeData theme,
    ColorScheme colorScheme,
    AudioDecoderFormatCapability format,
    bool bitDepthProbed,
  ) {
    final TextStyle? hintStyle = theme.textTheme.bodySmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
    );
    return Wrap(
      spacing: AppSpacing.xs,
      runSpacing: AppSpacing.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        Text('位深', style: hintStyle),
        for (final DecoderBitDepth depth in DecoderBitDepth.values)
          _buildBitDepthBadge(theme, colorScheme, depth, format.bitDepths[depth]),
        if (!bitDepthProbed)
          // 文案区分两种「未实测」：该格式根本没有硬件解码器可试配（全软解
          // 设备的常态，位深试配只对硬解条目跑）；真的有硬解但被预算跳过。
          // 两者都显示会与「均为软解」的 header 语义重复，统一收敛为一句。
          Text(
            format.hasHardware
                ? '未实测（configure 预算内跳过）'
                : '未实测（无硬件解码器，不做试配）',
            style: hintStyle,
          ),
      ],
    );
  }

  Widget _buildBitDepthBadge(
    ThemeData theme,
    ColorScheme colorScheme,
    DecoderBitDepth depth,
    DecoderBitDepthSupport? support,
  ) {
    final DecoderBitDepthSupport state =
        support ?? DecoderBitDepthSupport.unknown;
    final Color borderColor;
    final Color textColor;
    final bool bordered;
    switch (state) {
      case DecoderBitDepthSupport.supported:
        borderColor = colorScheme.primary;
        textColor = colorScheme.primary;
        bordered = true;
      case DecoderBitDepthSupport.unsupported:
        // 明确不支持：只给灰字，不描边，避免和「未探测」的描边混淆。
        borderColor = colorScheme.onSurfaceVariant;
        textColor = colorScheme.onSurfaceVariant;
        bordered = false;
      case DecoderBitDepthSupport.unknown:
        borderColor = colorScheme.outline;
        textColor = colorScheme.onSurfaceVariant;
        bordered = true;
    }
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xs,
        vertical: AppSpacing.xxs,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.full),
        border: bordered ? Border.all(color: borderColor) : null,
      ),
      child: Text(
        _bitDepthLabel(depth),
        style: theme.textTheme.bodySmall?.copyWith(
          color: textColor,
          fontWeight:
              state == DecoderBitDepthSupport.supported ? FontWeight.w600 : null,
        ),
      ),
    );
  }

  String _bitDepthLabel(DecoderBitDepth depth) {
    switch (depth) {
      case DecoderBitDepth.bit16:
        return '16';
      case DecoderBitDepth.bit24:
        return '24';
      case DecoderBitDepth.bit32:
        return '32';
      case DecoderBitDepth.float:
        return 'float';
    }
  }

  /// 该格式是否有解码器**真的**做过位深探测。
  ///
  /// 格式聚合结果本身不带这个标记（聚合只是取优），所以回到条目里按聚合键匹配：
  /// 只要有一个参与聚合的解码器 `bitDepthProbed == true`，这一行的位深就是实测值。
  bool _isBitDepthProbed(
    AudioDecoderCapabilitySnapshot snap,
    AudioDecoderFormatCapability format,
  ) {
    for (final AudioDecoderCapability entry in snap.entries) {
      if (!entry.bitDepthProbed) continue;
      final String label = entry.formatLabel.trim().isEmpty
          ? '未知'
          : entry.formatLabel.trim();
      if (label == format.formatLabel) return true;
    }
    return false;
  }

  // ── 原生备注 ───────────────────────────────────────────────────

  /// 「某编码没有系统解码器只能软解」这类原生备注必须展示：否则该格式会从卡片里
  /// 静默消失，用户会误以为是本机硬件不支持。
  List<Widget> _buildNotes(
    ThemeData theme,
    ColorScheme colorScheme,
    AudioDecoderCapabilitySnapshot snap,
  ) {
    final List<String> notes = snap.notes
        .map((String e) => e.trim())
        .where((String e) => e.isNotEmpty)
        .toList(growable: false);
    if (notes.isEmpty) return const <Widget>[];
    final TextStyle? style = theme.textTheme.bodySmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
    );
    return <Widget>[
      for (final String note in notes)
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.xxs),
          child: Text('· $note', style: style),
        ),
    ];
  }

  // ── 解码器清单（自绘折叠块）────────────────────────────────────

  Widget _buildDecoderList(
    ThemeData theme,
    ColorScheme colorScheme,
    AudioDecoderCapabilitySnapshot snap,
  ) {
    final TextStyle? hintStyle = theme.textTheme.bodySmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
    );
    void toggle() => setState(() => _listExpanded = !_listExpanded);
    final Widget header = InkWell(
      onTap: toggle,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '解码器清单（${snap.entries.length}）',
                style: theme.textTheme.titleSmall,
              ),
            ),
            AnimatedRotation(
              turns: _listExpanded ? 0.5 : 0,
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // TV 构建必须显式接 DpadFocusable：遥控器 OK 走 onSelect，不靠 InkWell 点击。
        if (kTvBuild) DpadFocusable(onSelect: toggle, child: header) else header,
        if (_listExpanded)
          for (final AudioDecoderCapability entry in snap.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    entry.codecName.trim().isEmpty
                        ? '未知解码器'
                        : entry.codecName.trim(),
                    style: theme.textTheme.bodySmall,
                  ),
                  Text(
                    entry.mime.trim().isEmpty ? '未知 MIME' : entry.mime.trim(),
                    style: hintStyle,
                  ),
                ],
              ),
            ),
      ],
    );
  }
}
