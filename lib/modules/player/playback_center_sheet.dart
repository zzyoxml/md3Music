import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../core/platform_capabilities.dart';
import '../../core/services/diagnostic_logger.dart';
import '../../core/services/media_output_service.dart';
import '../../core/services/output_mode_coordinator.dart';
import '../../core/services/usb_audio_service.dart';
import '../../core/services/windows_audio_output_device_service.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/utils/app_toast.dart';
import '../../data/models/song.dart';
import '../../providers/player_provider.dart';
import '../../widgets/player_volume_slider.dart';
import 'audio_quality_dialog.dart';
import 'dlna_cast_sheet.dart';
import 'song_info_page.dart';

/// 播放与输出面板：投屏 / 输出（含系统妙播）/ 音质，三件事一个入口。
///
/// 这三件事原本散在三处（⋯ 菜单的投屏格、长按音质徽章的音量弹窗、音质弹窗），
/// 但它们回答的是同一个问题 ——「声音现在从哪出、多大、多好」。合成一个面板后，
/// 右上角只留一个入口，音质档位落在**面板底部**，与输出/音量同屏：换设备时常要
/// 顺手降档，省的正是来回两趟。
/// 输出页还带「USB 独占」行（仅安卓手机，`supportsUsbExclusive`）：原 ⋯ 菜单的
/// 「歌曲信息」入口收编于此 —— 行尾开关直控独占，点行体进歌曲信息页看格式链。
Future<void> showPlaybackCenterSheet(
  BuildContext context, {
  String? mvUrl,
  String? mvTitle,
}) {
  return showM3EModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    // 与「更多」菜单一致：实色底，避免压在封面/壁纸上时内容难辨。
    backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
    builder: (_) => PlaybackCenterSheet(mvUrl: mvUrl, mvTitle: mvTitle),
  );
}

/// 面板页签。顺序即视觉顺序：投屏在左、输出在右（默认落在输出）。
enum PlaybackCenterTab { cast, output }

class PlaybackCenterSheet extends StatefulWidget {
  const PlaybackCenterSheet({
    super.key,
    this.mvUrl,
    this.mvTitle,
    this.probeSwitcherSupported = MediaOutputService.isSwitcherSupported,
    this.showSystemSwitcher = MediaOutputService.showSystemOutputSwitcher,
    this.showWindowsOutputDevices,
    this.showUsbExclusive,
    this.usbExclusiveRow,
    this.listOutputDevices = WindowsAudioOutputDeviceService.listDevices,
    this.selectedOutputDeviceId =
        WindowsAudioOutputDeviceService.selectedDeviceId,
    this.selectOutputDevice = WindowsAudioOutputDeviceService.selectDevice,
  });

  final String? mvUrl;
  final String? mvTitle;

  /// 两个原生调用可注入：单测里没有 Android 通道，真机才需要真的实现。
  final Future<bool> Function() probeSwitcherSupported;
  final Future<bool> Function() showSystemSwitcher;

  /// Windows 输出设备区：null = 按运行时平台判定（[isWindowsDesktop]）；
  /// 单测显式传 true/false 钉形态。三个设备调用与上面同口径可注入。
  final bool? showWindowsOutputDevices;

  /// 「USB 独占」行可见性：null = 按运行时能力判定（[supportsUsbExclusive]）；
  /// 单测显式传 true/false 钉形态（与 [showWindowsOutputDevices] 同口径）。
  final bool? showUsbExclusive;

  /// 「USB 独占」托盘行覆写：null = 输出页自建 [UsbExclusiveTrayRow]（真机路径）；
  /// 单测注入带 fake 状态/回调的实例，绕开 MethodChannel。
  final UsbExclusiveTrayRow? usbExclusiveRow;

  final Future<List<WindowsAudioOutputDevice>> Function() listOutputDevices;
  final Future<String?> Function() selectedOutputDeviceId;
  final Future<void> Function(String?) selectOutputDevice;

  @override
  State<PlaybackCenterSheet> createState() => _PlaybackCenterSheetState();
}

class _PlaybackCenterSheetState extends State<PlaybackCenterSheet> {
  PlaybackCenterTab _tab = PlaybackCenterTab.output;

  /// null = 还在探测：此时不画「更多设备」，避免先画出来再消失。
  bool? _switcherSupported;

  @override
  void initState() {
    super.initState();
    unawaited(_probe());
  }

  Future<void> _probe() async {
    final bool supported = await widget.probeSwitcherSupported();
    if (!mounted) return;
    setState(() => _switcherSupported = supported);
  }

  Future<void> _openSystemSwitcher() async {
    final bool shown = await widget.showSystemSwitcher();
    if (!mounted || shown) return;
    // 后台调用、版本过低、ROM 拒绝：如实回一句，不做无声失败。
    showToast('未能唤起系统输出面板，请在系统音量面板里切换');
  }

  bool _songIsLocal(PlayerProvider player) {
    final Song? song = player.currentSong;
    return song is Song && !song.isOnline;
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final PlayerProvider player = context.read<PlayerProvider>();
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // MD3E 拖拽把手（与「界面设置」二级菜单同一形态）
          Container(
            width: 32,
            height: 4,
            margin: const EdgeInsets.only(
              top: AppSpacing.md,
              bottom: AppSpacing.xs,
            ),
            decoration: BoxDecoration(
              color: cs.outline.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.sm,
              AppSpacing.lg,
              AppSpacing.sm,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '播放与输出',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: M3EToggleButtonGroup(
              direction: Axis.horizontal,
              semanticLabel: '播放与输出页签',
              selectedIndex: _tab.index,
              onSelectedIndexChanged: (int? index) {
                if (index == null || index == _tab.index) return;
                setState(() => _tab = PlaybackCenterTab.values[index]);
              },
              actions: const [
                M3EToggleButtonGroupAction(
                  icon: Icon(Icons.cast),
                  label: Text('投屏'),
                ),
                M3EToggleButtonGroupAction(
                  icon: Icon(Icons.speaker_group_outlined),
                  label: Text('输出'),
                ),
              ],
            ),
          ),
          ConstrainedBox(
            // 页签内容自己滚：设备列表可能十几行，音质区必须始终露在底部。
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.46,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.md,
                AppSpacing.lg,
                AppSpacing.sm,
              ),
              child: _tab == PlaybackCenterTab.cast
                  ? DlnaCastView(
                      mvUrl: widget.mvUrl,
                      mvTitle: widget.mvTitle,
                      showHeader: false,
                    )
                  // 音量控件自己订阅 provider；这里不再套一层重建。
                  : PlaybackOutputTab(
                      switcherSupported: _switcherSupported == true,
                      onMoreDevices: _openSystemSwitcher,
                      windowsDevices:
                          widget.showWindowsOutputDevices ?? isWindowsDesktop,
                      showUsbExclusive: widget.showUsbExclusive,
                      usbExclusiveRow: widget.usbExclusiveRow,
                      listOutputDevices: widget.listOutputDevices,
                      selectedOutputDeviceId: widget.selectedOutputDeviceId,
                      selectOutputDevice: widget.selectOutputDevice,
                    ),
            ),
          ),
          const Divider(height: 1),
          ListenableBuilder(
            listenable: player,
            builder: (context, _) => PlaybackQualitySection(
              selected: player.audioQuality,
              locked: _songIsLocal(player),
              onSelected: player.setAudioQuality,
            ),
          ),
        ],
      ),
    );
  }
}

/// 「输出」页：音量（m3e_core 滑杆）+ 系统输出入口 / Windows 内联设备列表。
///
/// Android 端**不显示"当前输出设备名"**：原生侧拿不到稳定可信的"当前选中输出"
/// （`AudioManager.getDevices` 只给可用列表；`MediaRouter2` 的系统路由在部分
/// ROM 上滞后），与其显示一个可能错的「本机」，不如只给能确定性操作的东西 ——
/// 音量滑杆 + 一个通向系统面板的入口。真实输出由系统面板如实展示。
///
/// Windows 端相反：本仓库 runner 自己枚举 WASAPI 播放端点并把选择持久化到
/// SharedPreferences（`WindowsAudioOutputDeviceService`），当前选择是确定的，
/// 所以直接内联设备列表点选即切（原 ⋯ 菜单二级弹窗收进这里，单一入口）。
///
/// 刻意**不**放蓝牙设置跳转：那是配对入口，与「现在从哪放」是两件事；
/// 跳过去反而要多一步才能回来。
class PlaybackOutputTab extends StatelessWidget {
  const PlaybackOutputTab({
    super.key,
    required this.switcherSupported,
    required this.onMoreDevices,
    this.windowsDevices = false,
    this.showUsbExclusive,
    this.usbExclusiveRow,
    this.listOutputDevices = WindowsAudioOutputDeviceService.listDevices,
    this.selectedOutputDeviceId =
        WindowsAudioOutputDeviceService.selectedDeviceId,
    this.selectOutputDevice = WindowsAudioOutputDeviceService.selectDevice,
  });

  /// 系统是否有输出切换器（Android 14+）；false 时整行隐藏。
  final bool switcherSupported;
  final VoidCallback onMoreDevices;

  /// 是否显示 Windows 内联输出设备区（仅 Windows 构建为 true）。
  final bool windowsDevices;

  /// 是否显示「USB 独占」行：null = 按运行时能力判定（[supportsUsbExclusive]，
  /// 仅安卓手机为真），单测显式传 true/false 钉形态。
  final bool? showUsbExclusive;

  /// 托盘行实例覆写：null = 自建默认 [UsbExclusiveTrayRow]（真机路径）；
  /// 单测注入带 fake 状态/回调的实例，绕开 MethodChannel。
  final UsbExclusiveTrayRow? usbExclusiveRow;

  final Future<List<WindowsAudioOutputDevice>> Function() listOutputDevices;
  final Future<String?> Function() selectedOutputDeviceId;
  final Future<void> Function(String?) selectOutputDevice;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextTheme tt = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.xs,
          ),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          // 三态（应用音量 / USB 独占 / unity 锁定）全在控件内部判定，
          // 这里只负责给它一块卡片底。
          child: const PlayerVolumeSlider(),
        ),
        // USB 独占行：音量与「更多设备」之间，安卓手机专属（桌面端/TV 无原生
        // 插件，露出来就是点不动的死 UI）。
        if (showUsbExclusive ?? supportsUsbExclusive) ...[
          const SizedBox(height: AppSpacing.sm),
          usbExclusiveRow ?? const UsbExclusiveTrayRow(),
        ],
        if (windowsDevices) ...[
          const SizedBox(height: AppSpacing.sm),
          WindowsOutputDeviceSection(
            listOutputDevices: listOutputDevices,
            selectedOutputDeviceId: selectedOutputDeviceId,
            selectOutputDevice: selectOutputDevice,
          ),
        ],
        if (switcherSupported) ...[
          const SizedBox(height: AppSpacing.sm),
          Material(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(AppRadius.md),
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.md),
              onTap: onMoreDevices,
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Row(
                  children: [
                    Icon(
                      Icons.devices_other,
                      size: 20,
                      color: cs.onSurfaceVariant,
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '更多设备',
                            style: tt.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '通过系统面板选择蓝牙、音箱等输出',
                            style: tt.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.chevron_right,
                      size: 20,
                      color: cs.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// 「USB 独占」托盘行：原 ⋯ 菜单「歌曲信息」入口在安卓上的新家。
///
/// 行体点击进 [SongInfoPage]（音频格式 + 完整 USB 独占设置）；行尾外置开关
/// **直接联动**外层「USB 独占输出」总开关 —— 数据源与设置页 / 歌曲信息页的
/// [UsbExclusiveSection] 同为 [OutputModeCoordinator]，三处状态必然一致。
/// 切换语义必须与 `usb_exclusive_section.dart` 的 `_toggle` 保持同构：走协调器
/// （native 状态、效果链旁路、unity 音量都挂在它上面），失败时消费回退提示。
///
/// 连接态来自 `UsbAudioService.statusStream`（插拔由原生推事件，不挂轮询
/// Timer）；未连接时开关置灰、副标题说明原因，不留点不动的假开关。
class UsbExclusiveTrayRow extends StatefulWidget {
  const UsbExclusiveTrayRow({
    super.key,
    this.initialStatus,
    this.coordinator,
    this.onToggle,
    this.onOpenDetails,
  });

  /// 初始 USB 状态（单测注入；null = 读服务端 lastStatus）。
  final Map<String, dynamic>? initialStatus;

  /// 协调器（单测注入 fake；null = [OutputModeCoordinator.instance] 单例 ——
  /// 单例是 static final 非 const，不能做构造参数默认值）。
  final OutputModeCoordinator? coordinator;

  /// 开关切换（单测捕获；null = 走真实协调器路径）。
  final Future<void> Function(bool value)? onToggle;

  /// 点行体进二级页（单测捕获；null = 真实 push [SongInfoPage]）。
  final VoidCallback? onOpenDetails;

  @override
  State<UsbExclusiveTrayRow> createState() => _UsbExclusiveTrayRowState();
}

class _UsbExclusiveTrayRowState extends State<UsbExclusiveTrayRow> {
  Map<String, dynamic> _status = const {};
  StreamSubscription<Map<String, dynamic>>? _statusSub;
  bool _loading = false;

  /// 协调器：widget 注入优先，缺省用单例（static final 非 const，不能当默认参数）。
  OutputModeCoordinator get _coordinator =>
      widget.coordinator ?? OutputModeCoordinator.instance;

  @override
  void initState() {
    super.initState();
    _status = widget.initialStatus ?? UsbAudioService.instance.lastStatus;
    _statusSub = UsbAudioService.instance.statusStream.listen((s) {
      if (mounted) setState(() => _status = s);
    });
    // 兜底：行可见时主动查一次（覆盖原生事件未推送的边界场景，与歌曲信息页同款）。
    UsbAudioService.instance.refresh();
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    super.dispose();
  }

  /// 开关：与 `usb_exclusive_section.dart` 的 `_toggle` 同语义（走协调器）。
  Future<void> _toggle(bool value) async {
    final Future<void> Function(bool)? injected = widget.onToggle;
    if (injected != null) {
      setState(() => _loading = true);
      await injected(value);
      if (mounted) setState(() => _loading = false);
      return;
    }
    setState(() => _loading = true);
    try {
      await _coordinator.setEnabled(value);
      // 开启失败时协调器保持关闭并记下原因，在这里消费掉，免得再被
      // PlayerProvider 的监听器弹一次同样的 toast（与 section 口径一致）。
      if (value && !_coordinator.enabled) {
        if (mounted) {
          showToast(
            _coordinator.consumeFallbackNotice() ??
                'USB 独占不可用，已恢复普通输出',
            long: true,
          );
        } else {
          _coordinator.consumeFallbackNotice();
        }
      }
      final s = await UsbAudioService.instance.getStatus();
      if (mounted) setState(() => _status = s);
    } catch (e) {
      if (mounted) showToast('USB 独占操作失败：$e', long: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openDetails() {
    final VoidCallback? injected = widget.onOpenDetails;
    if (injected != null) {
      injected();
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SongInfoPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextTheme tt = Theme.of(context).textTheme;
    final bool connected = _status['deviceConnected'] == true;
    final String subtitle = connected
        ? (_status['deviceName'] as String? ?? '未知设备')
        : '未检测到 USB 音频设备';

    // 开关值在 builder 内读协调器（与 section 外层开关同口径，不能读 native
    // `enabled`：内层选中 Direct PCM 时直写并未开启，但外层仍应为 ON）；
    // 协调器 notifyListeners 时整行重建，与设置页/歌曲信息页三处联动。
    return ListenableBuilder(
      listenable: _coordinator,
      builder: (context, _) {
        final bool enabled = _coordinator.enabled;
        return Material(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.md),
            onTap: _openDetails,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: Row(
                children: [
                  Icon(
                    Icons.usb,
                    size: 20,
                    color: cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'USB 独占',
                          style: tt.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: tt.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: enabled,
                    // 未连接（或操作中）置灰；点开关区域不进二级页。
                    onChanged: (!connected || _loading)
                        ? null
                        : (v) => _toggle(v),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Windows 内联输出设备选择区：跟随系统默认 + WASAPI 枚举的播放端点。
///
/// 交互口径与原 ⋯ 菜单二级弹窗一致（`WindowsAudioOutputDeviceService` 的
/// 偏好 + 原生 `setOutputDevice`），但当前选择直接显示 check、点一下就切，
/// 不再多一层弹窗。原生层在设备离线时自动回落系统默认并在重连后切回，
/// 这里不需要额外的离线态处理。
class WindowsOutputDeviceSection extends StatefulWidget {
  const WindowsOutputDeviceSection({
    super.key,
    required this.listOutputDevices,
    required this.selectedOutputDeviceId,
    required this.selectOutputDevice,
  });

  final Future<List<WindowsAudioOutputDevice>> Function() listOutputDevices;
  final Future<String?> Function() selectedOutputDeviceId;
  final Future<void> Function(String?) selectOutputDevice;

  @override
  State<WindowsOutputDeviceSection> createState() =>
      _WindowsOutputDeviceSectionState();
}

class _WindowsOutputDeviceSectionState
    extends State<WindowsOutputDeviceSection> {
  /// null = 还在加载。加载失败按「未发现可用设备」呈现，不留假入口。
  List<WindowsAudioOutputDevice>? _devices;
  String? _selectedId;
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final List<WindowsAudioOutputDevice> devices =
          await widget.listOutputDevices();
      final String? selectedId = await widget.selectedOutputDeviceId();
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _selectedId = selectedId;
      });
    } catch (error) {
      DiagnosticLogger.instance.warning('[AudioOutput] list failed: $error');
      if (!mounted) return;
      setState(() {
        _devices = const [];
        _loadFailed = true;
      });
    }
  }

  Future<void> _select(String? id, String name) async {
    final String? previous = _selectedId;
    setState(() => _selectedId = id);
    try {
      await widget.selectOutputDevice(id);
      if (!mounted) return;
      showToast('已切换到$name');
    } catch (error) {
      DiagnosticLogger.instance.e('[AudioOutput] switch failed: $error');
      if (!mounted) return;
      setState(() => _selectedId = previous);
      showToast('切换输出设备失败');
    }
  }

  /// 蓝牙判定沿用旧 picker：设备名含 bluetooth/蓝牙 就给蓝牙音频图标。
  static IconData _iconFor(WindowsAudioOutputDevice device) {
    final String lower = device.name.toLowerCase();
    return (lower.contains('bluetooth') || lower.contains('蓝牙'))
        ? Icons.bluetooth_audio
        : Icons.speaker;
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextTheme tt = Theme.of(context).textTheme;
    final List<WindowsAudioOutputDevice>? devices = _devices;

    Widget row({
      required IconData icon,
      required String title,
      String? subtitle,
      required bool selected,
      required VoidCallback onTap,
    }) {
      return Material(
        color: selected
            ? cs.primary.withValues(alpha: 0.08)
            : cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.md),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Row(
              children: [
                Icon(icon, size: 20, color: cs.onSurfaceVariant),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: tt.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: tt.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (selected)
                  Icon(Icons.check, size: 20, color: cs.primary),
              ],
            ),
          ),
        ),
      );
    }

    return Column(
      key: const ValueKey('windows-audio-output-device'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(
              Icons.devices_other,
              size: 20,
              color: cs.onSurfaceVariant,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                '输出设备',
                style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        row(
          icon: Icons.speaker_group_outlined,
          title: '跟随系统默认',
          selected: _selectedId == null,
          onTap: () => unawaited(_select(null, '系统默认设备')),
        ),
        if (devices == null) ...[
          const SizedBox(height: AppSpacing.sm),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
            child: SizedBox(
              height: 20,
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ] else if (devices.isEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            _loadFailed ? '读取输出设备失败' : '未发现可用的输出设备',
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
        for (final device in devices ?? const <WindowsAudioOutputDevice>[]) ...[
          const SizedBox(height: AppSpacing.sm),
          row(
            icon: _iconFor(device),
            title: device.name,
            subtitle: device.isSystemDefault ? '系统默认' : null,
            selected: _selectedId == device.id,
            onTap: () => unawaited(_select(device.id, device.name)),
          ),
        ],
      ],
    );
  }
}

/// 面板底部的音质档位：与音质弹窗同源（[kPlayerAudioQualities] + 短标签）。
///
/// [locked] = 本地歌曲：档位只读（实际音质由文件码率决定，切了也没用），
/// 与旧音质胶囊「本地歌曲屏蔽点击」是同一条口径。
class PlaybackQualitySection extends StatelessWidget {
  const PlaybackQualitySection({
    super.key,
    required this.selected,
    required this.locked,
    required this.onSelected,
    this.qualities = kPlayerAudioQualities,
  });

  final List<AudioQuality> qualities;
  final AudioQuality selected;
  final bool locked;
  final ValueChanged<AudioQuality> onSelected;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextTheme tt = Theme.of(context).textTheme;
    final int index = qualities.indexOf(selected);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        AppSpacing.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '音质',
                style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              Text(
                locked ? '本地文件按码率显示' : audioQualityShortLabel(selected),
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          // 与设置页「失去音频焦点时」同款：横排 + xs + 紧凑密度，文字过长省略。
          // 四档在 360dp 窄屏上也放得下（超宽时组件自己改成横向滚动）。
          AbsorbPointer(
            absorbing: locked,
            child: M3EToggleButtonGroup(
              direction: Axis.horizontal,
              size: M3EButtonSize.xs,
              density: M3EButtonGroupDensity.compact,
              semanticLabel: '音质',
              selectedIndex: locked || index < 0 ? null : index,
              onSelectedIndexChanged: (int? picked) {
                if (locked ||
                    picked == null ||
                    picked < 0 ||
                    picked >= qualities.length) {
                  return;
                }
                onSelected(qualities[picked]);
              },
              actions: [
                for (final AudioQuality quality in qualities)
                  M3EToggleButtonGroupAction(
                    label: Text(
                      audioQualityShortLabel(quality),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
