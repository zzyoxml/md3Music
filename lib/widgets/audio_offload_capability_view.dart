import 'package:flutter/material.dart';

import '../core/services/audio_offload_capabilities.dart';
import '../core/services/audio_offload_service.dart';
import '../core/theme/app_dimens.dart';

/// 本机音频 HAL 的 offload 协商矩阵（只读展示）。
///
/// 数据来自原生 `probeCapabilities`：每个「编码 × 采样率 × 声道数」一条，`supported`
/// 是**协商结果**而不是静态声明 —— 同一编码在不同 ROM 上的可用组合可能完全不同，
/// 所以按编码分节逐行列出，而不是只给一句「支持 AAC」。
///
/// 本组件**不自带标题**：宿主页面把它内嵌在「系统 offload 协商」折叠区块里，标题与
/// 作用说明由折叠 header 提供（日常用户只看解码器能力，这块属于排障细节）。
///
/// 自身订阅 [AudioOffloadService]（ChangeNotifier）：重新探测完成后快照更新，
/// 即使宿主页面没有重建，本组件也会自己刷新。页面主体另有 1s 轮询兜底实测状态，
/// 与这里的能力快照互不干扰（快照只在启动读缓存或显式探测时刷新）。
class AudioOffloadCapabilityView extends StatefulWidget {
  const AudioOffloadCapabilityView({super.key});

  @override
  State<AudioOffloadCapabilityView> createState() =>
      _AudioOffloadCapabilityViewState();
}

class _AudioOffloadCapabilityViewState extends State<AudioOffloadCapabilityView> {
  AudioOffloadService get _svc => AudioOffloadService.instance;

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
    final AudioOffloadCapabilitySnapshot? snap = _svc.capabilities;
    final bool hasData = snap != null && !snap.isEmpty;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.xs,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (!hasData) ...<Widget>[
            Text(
              '尚未探测',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            Text(
              '点击下方重新探测',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ] else ...<Widget>[
            _buildDeviceCard(theme, colorScheme, snap),
            const Gap(AppSpacing.md),
            ..._buildEncodingSections(theme, colorScheme, snap),
            const Gap(AppSpacing.sm),
            _buildLegend(theme, colorScheme),
            ..._buildNotes(theme, colorScheme, snap),
          ],
        ],
      ),
    );
  }

  // ── 顶部设备信息卡 ─────────────────────────────────────────────

  Widget _buildDeviceCard(
    ThemeData theme,
    ColorScheme colorScheme,
    AudioOffloadCapabilitySnapshot snap,
  ) {
    final String deviceKey =
        snap.deviceKey.trim().isEmpty ? '未知' : snap.deviceKey.trim();
    final String probeError = (snap.probeError ?? '').trim();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _infoRow(theme, '设备指纹', deviceKey),
          _infoRow(theme, '探测时间', _formatLocalTime(snap.probedAt)),
          _infoRow(
            theme,
            '系统版本',
            snap.sdkInt > 0 ? 'API ${snap.sdkInt}' : '未知',
          ),
          _infoRow(
            theme,
            '原生输出率',
            snap.outputSampleRate > 0 ? '${snap.outputSampleRate} Hz' : '未知',
          ),
          _infoRow(
            theme,
            '每缓冲帧数',
            snap.outputFramesPerBuffer > 0
                ? '${snap.outputFramesPerBuffer} 帧'
                : '未知',
          ),
          _infoRow(
            theme,
            '变速支持',
            snap.variableRateSupported ? '支持' : '不支持',
          ),
          _infoRow(
            theme,
            '探测结果',
            '${snap.supportedCount}/${snap.probedCount} 组合可硬解',
          ),
          // 探测失败原因用主题 error 色：矩阵可能是旧缓存，用户需要知道这份数据不可信。
          if (probeError.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xxs),
              child: Text(
                '探测失败：$probeError',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.error,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── 编码分节 ───────────────────────────────────────────────────

  List<Widget> _buildEncodingSections(
    ThemeData theme,
    ColorScheme colorScheme,
    AudioOffloadCapabilitySnapshot snap,
  ) {
    final List<_EncodingGroup> groups = _groupByEncoding(snap);
    final List<Widget> out = <Widget>[];
    for (final _EncodingGroup group in groups) {
      final int supported =
          group.caps.where((AudioOffloadCapability c) => c.supported).length;
      out.add(
        Padding(
          padding: const EdgeInsets.only(top: AppSpacing.sm),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(group.label, style: theme.textTheme.titleSmall),
              ),
              Text(
                '$supported/${group.caps.length}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
      for (final AudioOffloadCapability cap in group.caps) {
        out.add(_buildCapabilityRow(theme, colorScheme, cap));
      }
    }
    return out;
  }

  /// 单行：采样率 · 声道（gapless / 变速小字）· 状态徽标。
  ///
  /// 采样率与徽标用固定宽度、声道区用 [Expanded] + [Wrap]：TV 横屏与窄屏
  /// （含系统字体放大）都不会溢出，gapless/变速小字换行而不是被截断。
  Widget _buildCapabilityRow(
    ThemeData theme,
    ColorScheme colorScheme,
    AudioOffloadCapability cap,
  ) {
    final TextStyle? smallStyle = theme.textTheme.bodySmall;
    final TextStyle? hintStyle = smallStyle?.copyWith(
      color: colorScheme.onSurfaceVariant,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          SizedBox(
            width: 76,
            child: Text('${cap.sampleRate} Hz', style: smallStyle),
          ),
          Expanded(
            child: Wrap(
              spacing: AppSpacing.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                Text(_channelLabel(cap.channelCount), style: hintStyle),
                // API 31+ 才回传的细节：gapless 与变速只影响体验，不改变「能否硬解」，
                // 因此作为小字附在声道后面，不单列行列。
                if (cap.gapless) Text('gapless', style: hintStyle),
                if (cap.speedChange) Text('变速', style: hintStyle),
              ],
            ),
          ),
          SizedBox(
            width: 48,
            child: Text(
              cap.supported ? '支持' : '不支持',
              textAlign: TextAlign.right,
              style: smallStyle?.copyWith(
                color: cap.supported
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant,
                fontWeight: cap.supported ? FontWeight.w600 : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 图例：「未探测」对应矩阵为空时的整体空态（下表只列出探测过的组合）。
  Widget _buildLegend(ThemeData theme, ColorScheme colorScheme) {
    final TextStyle? style = theme.textTheme.bodySmall;
    Widget dot(Color color) => Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        );
    Widget item(Color color, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            dot(color),
            const Gap(AppSpacing.xs),
            Text(
              label,
              style: style?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
          ],
        );
    return Wrap(
      spacing: AppSpacing.md,
      runSpacing: AppSpacing.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        item(colorScheme.primary, '支持'),
        item(colorScheme.onSurfaceVariant, '不支持'),
        item(colorScheme.outline, '未探测'),
      ],
    );
  }

  /// 「未探测」项说明：哪些编码因为引擎能力没进矩阵、原因是什么。
  ///
  /// 必须展示 —— 否则 FLAC/ALAC 这类「探测阶段就被跳过」的格式会从矩阵里静默消失，
  /// 用户会误以为是「本机硬件不支持」，实际是「当前播放引擎（media3 1.4.1）
  /// 没有该格式的 offload 编码通路」，升级引擎后可能就支持了。
  List<Widget> _buildNotes(
    ThemeData theme,
    ColorScheme colorScheme,
    AudioOffloadCapabilitySnapshot snap,
  ) {
    final List<String> notes = snap.notes
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    if (notes.isEmpty) return const <Widget>[];
    final TextStyle? style = theme.textTheme.bodySmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
    );
    return <Widget>[
      const Gap(AppSpacing.sm),
      Text('未进入矩阵的编码', style: theme.textTheme.titleSmall),
      const Gap(AppSpacing.xxs),
      for (final String note in notes)
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.xxs),
          child: Text('· $note', style: style),
        ),
    ];
  }

  Widget _infoRow(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 84,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }

  // ── 分组与排序 ─────────────────────────────────────────────────

  /// 按 `byEncoding` 分组并按固定编码顺序排列，未知编码追加末尾。
  ///
  /// `byEncoding` 的 key 已经是 [AudioOffloadCapability.shortName]（原生名归一后的
  /// UI 短名），直接作为分节标题；空 key 归到「未知」。
  List<_EncodingGroup> _groupByEncoding(AudioOffloadCapabilitySnapshot snap) {
    final List<_EncodingGroup> groups = <_EncodingGroup>[];
    snap.byEncoding.forEach((String key, List<AudioOffloadCapability> caps) {
      if (caps.isEmpty) return;
      final String label = key.trim().isEmpty ? '未知' : key.trim();
      groups.add(_EncodingGroup(
        label: label,
        caps: caps,
        rank: _encodingRank(label),
      ));
    });
    groups.sort((_EncodingGroup a, _EncodingGroup b) {
      final int byRank = a.rank.compareTo(b.rank);
      if (byRank != 0) return byRank;
      // 同一档（两个未知编码）用名字兜底，保证每次重建顺序稳定。
      return a.label.compareTo(b.label);
    });
    return groups;
  }

  /// 编码展示顺序：MP3 → AAC-LC → HE-AAC v1/v2 → OPUS → FLAC → ALAC → VORBIS → AC3 → E-AC3。
  ///
  /// 归一化后做包含匹配，兼容短名（`AAC-LC`）与原生/未来可能出现的变体写法；
  /// 匹配不到返回 [_rankUnknown]，追加在所有已知编码之后。
  int _encodingRank(String label) {
    final String t = label.toUpperCase().replaceAll(RegExp(r'[\s_\-]'), '');
    if (t.contains('MP3')) return 0;
    // HE-AAC 必须排在 AAC-LC 之前判断（HE 变体名里同样含 AAC）。
    if (t.contains('HEAAC')) {
      return t.contains('V2') || t.contains('PS') ? 3 : 2;
    }
    if (t.contains('AAC')) return 1;
    if (t.contains('OPUS')) return 4;
    if (t.contains('FLAC')) return 5;
    if (t.contains('ALAC')) return 6;
    if (t.contains('VORBIS')) return 7;
    // E-AC3 必须先于 AC3 判断（名字里包含 AC3）。
    if (t.contains('EAC3')) return 9;
    if (t.contains('AC3')) return 8;
    return _rankUnknown;
  }

  static const int _rankUnknown = 100;

  /// 声道数展示：与 USB 侧保持一致的措辞（单声道 / 双声道）。
  String _channelLabel(int channels) {
    if (channels <= 0) return '未知声道';
    if (channels == 1) return '单声道';
    if (channels == 2) return '双声道';
    return '$channels 声道';
  }

  /// 探测时间按本地时区展示，精确到秒（排查「什么时候探的」够用）。
  String _formatLocalTime(DateTime t) {
    final DateTime local = t.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }
}

/// 一个编码分组（渲染中间结构）。
class _EncodingGroup {
  const _EncodingGroup({
    required this.label,
    required this.caps,
    required this.rank,
  });

  final String label;
  final List<AudioOffloadCapability> caps;
  final int rank;
}
