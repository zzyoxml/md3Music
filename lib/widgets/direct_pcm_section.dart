import 'dart:async';

import 'package:flutter/material.dart';

import '../core/services/device_capabilities.dart';
import '../core/services/direct_pcm_service.dart';
import '../core/utils/app_haptics.dart';

/// 「改用系统 Direct PCM」方案的子开关 + 实测状态面板。
///
/// **只由 `UsbExclusiveSection` 在外层总开关打开且内层选中时挂载**（即
/// `OutputModeCoordinator.isDirectPcmActive`）。反过来 usbdevfs 直写那一侧的
/// 详情（UAC 能力卡 / 输出格式强制 / MV 自动关独占 / TPDF）由父级显示 —— 两条
/// 路径只显示当前生效的那一侧，另一侧的读数是「未生效路径」的数值，显示出来等于
/// 误导（真机踩过：状态面板停在上一条流的过期实测值）。
class DirectPcmSection extends StatefulWidget {
  const DirectPcmSection({super.key});

  @override
  State<DirectPcmSection> createState() => _DirectPcmSectionState();
}

class _DirectPcmSectionState extends State<DirectPcmSection> {
  Map<String, dynamic> _status = const <String, dynamic>{};

  StreamSubscription<Map<String, dynamic>>? _statusSub;

  /// 可见期间的兜底轮询。
  ///
  /// 原生已在「AudioTrack 建轨 / 新流开始 / 音量变化 / 设备插拔」时主动推状态，
  /// 但 native 输出率也可能被**其它应用**或系统策略改动（我们收不到钩子），
  /// 故按 1s 轮询一次。父级 `UsbExclusiveSection` 的 1s 轮询打的是
  /// `UsbAudioService`（另一套通道），两者不重复。
  ///
  /// 注意 AGENTS.md §10：稀疏 1Hz 查询，**不得**改成 60fps 驱动。
  static const int _pollIntervalMs = 1000;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _status = DirectPcmService.instance.lastStatus;
    _statusSub = DirectPcmService.instance.statusStream.listen((s) {
      if (mounted) setState(() => _status = s);
    });
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: _pollIntervalMs),
      (_) => DirectPcmService.instance.refresh(),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      DirectPcmService.instance.refresh();
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _statusSub?.cancel();
    super.dispose();
  }

  /// 生成某子开关的 onChanged：SDK 不足时返回 null（渲染为置灰不可点）。
  ///
  /// 注意置灰时**不改写持久化的用户值** —— 系统升级后该开关自动恢复生效。
  void Function(bool)? _featureToggle(
      DirectPcmFeature f, DeviceCapabilities caps) {
    if (!caps.supports(f)) return null;
    return (bool v) async {
      AppHaptics.lightImpact(HapticCategory.control);
      setState(() {});
      await DirectPcmService.instance.setFeature(f, v);
      if (mounted) setState(() {});
    };
  }

  /// 子开关副标题：功能说明 + 置灰原因（SDK 版本要求）。
  ///
  /// 副标题允许是动态文本（搜索索引只要求 **标题** 为字面量），因此把版本提示
  /// 拼在这里：置灰时用户能直接看到「为什么不能用、需要什么系统版本」。
  String _featureSubtitle(DirectPcmFeature f) {
    final String desc;
    switch (f) {
      case DirectPcmFeature.highPrecisionOutput:
        desc = 'float32 直通，不把 24/32bit 源降为 16bit';
      case DirectPcmFeature.dspBypass:
        desc = '进入本方案时自动关闭音量均衡/均衡器/母带';
      case DirectPcmFeature.unityVolume:
        desc = '音量固定 1.0，改用系统媒体音量键';
      case DirectPcmFeature.lowLatency:
        desc = '请求 AudioTrack 低延迟；能否真正走 fast 通道取决于 ROM';
      case DirectPcmFeature.exactRouteProbe:
        desc = '低版本改用 getDeviceId 兼容探测，结果一致';
      case DirectPcmFeature.nativeRateConfirm:
        desc = '反射 AudioTrack.getNativeOutputSampleRate';
      case DirectPcmFeature.rateAlignment:
        desc = '开发中（未接入 UI）';
    }
    final String? reason = DeviceCapabilities.instance.unavailableReason(f);
    return reason == null ? desc : '$desc · $reason';
  }

  @override
  Widget build(BuildContext context) {
    final caps = DeviceCapabilities.instance;
    return Material(
      type: MaterialType.transparency,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('Direct PCM 选项',
                style: Theme.of(context).textTheme.titleSmall),
          ),
          // 子开关写成显式 tile（而非循环）：设置搜索索引生成器
          // （scripts/tools/gen_settings_search_index.dart）只能从 tile 参数里的
          // 字符串字面量标题提取条目，`title: someVar` 会被判为「非字面量」而漏进索引。
          // search: 高规格 float 32bit 24bit 无损 直通 不降位
          SwitchListTile(
            title: const Text('高规格输出'),
            subtitle: Text(_featureSubtitle(DirectPcmFeature.highPrecisionOutput)),
            value: DirectPcmService.instance
                .featureEffective(DirectPcmFeature.highPrecisionOutput),
            onChanged: _featureToggle(DirectPcmFeature.highPrecisionOutput, caps),
          ),
          // search: 旁路 效果链 均衡器 母带 响度归一
          SwitchListTile(
            title: const Text('旁路效果链'),
            subtitle: Text(_featureSubtitle(DirectPcmFeature.dspBypass)),
            value: DirectPcmService.instance
                .featureEffective(DirectPcmFeature.dspBypass),
            onChanged: _featureToggle(DirectPcmFeature.dspBypass, caps),
          ),
          // search: unity 音量 unity gain 系统音量 音量键
          SwitchListTile(
            title: const Text('unity 音量'),
            subtitle: Text(_featureSubtitle(DirectPcmFeature.unityVolume)),
            value: DirectPcmService.instance
                .featureEffective(DirectPcmFeature.unityVolume),
            onChanged: _featureToggle(DirectPcmFeature.unityVolume, caps),
          ),
          // search: 低延迟 fast 通道 latency
          SwitchListTile(
            title: const Text('低延迟（fast 通道）'),
            subtitle: Text(_featureSubtitle(DirectPcmFeature.lowLatency)),
            value: DirectPcmService.instance
                .featureEffective(DirectPcmFeature.lowLatency),
            onChanged: _featureToggle(DirectPcmFeature.lowLatency, caps),
          ),
          // search: 路由设备 探测
          SwitchListTile(
            title: const Text('精确路由设备探测'),
            subtitle: Text(_featureSubtitle(DirectPcmFeature.exactRouteProbe)),
            value: DirectPcmService.instance
                .featureEffective(DirectPcmFeature.exactRouteProbe),
            onChanged: _featureToggle(DirectPcmFeature.exactRouteProbe, caps),
          ),
          // search: 原生率 实际输出率 采样率
          SwitchListTile(
            title: const Text('确认实际输出率'),
            subtitle: Text(_featureSubtitle(DirectPcmFeature.nativeRateConfirm)),
            value: DirectPcmService.instance
                .featureEffective(DirectPcmFeature.nativeRateConfirm),
            onChanged: _featureToggle(DirectPcmFeature.nativeRateConfirm, caps),
          ),
          const Divider(height: 24),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Text('实测状态',
                style: Theme.of(context).textTheme.titleSmall),
          ),
          _buildStatusPanel(),
        ],
      ),
    );
  }

  Widget _buildStatusPanel() {
    final Map<String, dynamic> s = _status;
    final bool nativeKnown = s['nativeRateKnown'] == true;
    final int nativeRate = (s['nativeOutputSampleRate'] as num?)?.toInt() ?? -1;
    final int srcRate = (s['sourceSampleRate'] as num?)?.toInt() ?? 0;
    final int srcCh = (s['sourceChannelCount'] as num?)?.toInt() ?? 0;
    final bool bitPerfect = s['bitPerfect'] == true;
    final String? reason = s['bitPerfectReason'] as String?;
    final bool unity = s['unityVolume'] == true;
    final bool dspBypassed = s['dspBypassed'] == true;
    final int trackRate = (s['audioTrackSampleRate'] as num?)?.toInt() ?? 0;
    final int bufferMs = (s['audioTrackBufferMs'] as num?)?.toInt() ?? 0;
    final int latencyMs = (s['audioTrackLatencyMs'] as num?)?.toInt() ?? -1;
    final bool lowLatencyMode = s['audioTrackLowLatencyMode'] == true;
    final bool lowLatencyApplied = s['lowLatencyRequestApplied'] == true;
    final List<int> deviceRates =
        (s['deviceSampleRates'] as List?)?.map((e) => (e as num).toInt()).toList() ??
            const <int>[];
    final String deviceName = (s['deviceName'] as String?) ??
        (s['deviceTypeName'] as String?) ??
        '未知设备';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _row('输出设备', deviceName),
          _row('解码流', srcRate > 0 ? '$srcRate Hz · ${srcCh}ch' : '待播放'),
          _row('位深', (s['sourceEncodingName'] as String?) ?? '待播放'),
          _row(
            'AudioTrack 率',
            trackRate > 0
                ? '$trackRate Hz${s['halDowngradedRate'] == true ? '（HAL 已降级）' : ''}'
                : '待播放',
          ),
          _row(
            '实际输出原生率',
            nativeKnown ? '$nativeRate Hz' : '无法确认（当前 ROM 不提供查询接口）',
            warn: !nativeKnown,
          ),
          if (deviceRates.isNotEmpty) _row('设备支持率', deviceRates.join(' / ')),
          // 以下两行是**实测值**：fast 通道能否生效由厂商 audio HAL 决定，
          // 不得凭「已请求 setPerformanceMode」就宣称低延迟已达成。
          _row('fast 通道',
              !lowLatencyApplied
                  ? '未请求'
                  : lowLatencyMode
                      ? '已生效'
                      : '已请求但未生效（ROM/HAL 不支持）',
              warn: !lowLatencyMode),
          _row('输出缓冲 / 延迟',
              bufferMs > 0
                  ? '$bufferMs ms${latencyMs > 0 ? ' / $latencyMs ms' : ''}'
                  : '待播放'),
          _row('音量 unity', unity ? '开' : '关', warn: !unity),
          _row('效果链旁路', dspBypassed ? '已旁路' : '未旁路', warn: !dspBypassed),
          const SizedBox(height: 8),
          _row('bit-perfect', bitPerfect ? '达成' : '未达成',
              warn: !bitPerfect, strong: true),
          if (!bitPerfect && reason != null)
            Padding(
              padding: const EdgeInsets.only(left: 4, top: 2),
              child: Text(reason,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Colors.orange.shade800)),
            ),
        ],
      ),
    );
  }

  Widget _row(String k, String v, {bool warn = false, bool strong = false}) {
    final ThemeData theme = Theme.of(context);
    final TextStyle? style =
        strong ? theme.textTheme.bodyMedium : theme.textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(width: 116, child: Text(k, style: style)),
          Expanded(
            child: Text(
              v,
              style: style?.copyWith(
                color: warn ? Colors.orange.shade800 : null,
                fontWeight: strong ? FontWeight.w600 : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
