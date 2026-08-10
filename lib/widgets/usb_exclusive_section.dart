import 'package:flutter/material.dart';

import '../core/services/usb_audio_service.dart';

/// USB 独占输出设置板块（设置页 / 歌曲信息页共用，保证信息与开关一致）。
///
/// 实时状态来自 [UsbAudioService.statusStream]（服务层每秒轮询一次原生状态）。
/// 拔线检测：独占开启期间 deviceConnected 由 true→false 时提示并回调 [onAutoPause]。
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

  @override
  void initState() {
    super.initState();
    _status = UsbAudioService.instance.lastStatus;
    UsbAudioService.instance.statusStream.listen(_onStatus);
    _wasDeviceConnected = _status['deviceConnected'] == true;
  }

  void _onStatus(Map<String, dynamic> s) {
    if (!mounted) return;
    setState(() => _status = s);
    // 拔线检测：独占开启中设备断开 → 提示 + 自动暂停
    final nowConnected = s['deviceConnected'] == true;
    final enabled = s['enabled'] == true;
    if (enabled && _wasDeviceConnected && !nowConnected) {
      widget.onAutoPause?.call();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('USB DAC 已断开，独占输出已自动关闭'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
    _wasDeviceConnected = nowConnected;
  }

  Future<void> _toggle(bool value) async {
    setState(() => _loading = true);
    try {
      if (value) {
        await UsbAudioService.instance.enableExclusive();
      } else {
        await UsbAudioService.instance.disableExclusive();
      }
      // 立即拉一次最新状态刷新 UI
      final s = await UsbAudioService.instance.getStatus();
      if (mounted) setState(() => _status = s);
    } on UsbAudioException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('USB 独占开启失败：${e.message}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('USB 独占操作失败：$e')),
        );
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
    final frames = (_status['framesWritten'] as num?)?.toInt() ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          secondary: Icon(Icons.usb, color: colorScheme.primary),
          title: const Text('USB 独占输出'),
          subtitle: const Text('绕过 Android 混音器，PCM 直写 USB DAC（支持 44.1/48/96kHz 等）'),
          value: enabled,
          onChanged: _loading ? null : _toggle,
        ),
        // 状态卡
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
                    _StatusChip(
                      connected
                          ? (alive ? '运行中' : '已连接')
                          : '未连接',
                      color: alive
                          ? Colors.green
                          : (connected ? Colors.orange : colorScheme.outline),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 16,
                  runSpacing: 4,
                  children: [
                    _InfoItem('采样率', _formatRate(_status['sampleRate'])),
                    _InfoItem('位深', '${_status['dacBitDepth'] ?? 0}-bit'),
                    _InfoItem('声道', _formatChannels(_status['channelCount'])),
                    _InfoItem('已写帧', '$frames'),
                  ],
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
                child: SelectableText(
                  _status.entries
                      .map((e) => '${e.key}: ${e.value}')
                      .join('\n'),
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontFamily: 'monospace',
                    fontSize: 10,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _formatRate(dynamic v) {
    final rate = (v as num?)?.toInt() ?? 0;
    if (rate <= 0) return '—';
    if (rate % 1000 == 0) return '${rate ~/ 1000} kHz';
    return '${(rate / 1000).toStringAsFixed(1)} kHz';
  }

  String _formatChannels(dynamic v) {
    final ch = (v as num?)?.toInt() ?? 0;
    switch (ch) {
      case 1:
        return '单声道';
      case 2:
        return '立体声';
      case > 2:
        return '$ch 声道';
      default:
        return '—';
    }
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
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _InfoItem extends StatelessWidget {
  final String label;
  final String value;

  const _InfoItem(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: textTheme.labelSmall
                ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        Text(value, style: textTheme.bodyMedium),
      ],
    );
  }
}
