import 'dart:async';

import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/build_flags.dart';
import '../core/remote/tv_volume_stepper.dart';
import '../core/services/output_mode_coordinator.dart';
import '../core/services/usb_audio_service.dart';
import '../core/utils/app_haptics.dart';
import '../modules/player/player_volume_state.dart';
import '../providers/player_provider.dart';

/// 常驻音量条（横屏控制页用，MD/AM 两版共用）。
///
/// 三态逻辑收口在 [PlayerVolumeState]（与长按音质徽章的弹窗同一套判据）：
/// USB 独占音量 / Direct PCM unity 锁定（滑块失灵，如实提示 + 一键关闭）/
/// 应用音量。判据口径与 AGENTS §4.11「音量面板三态」一致。
///
/// 视觉：一行三元素并排 —— 小喇叭（左，点它一键静音/恢复）· 4px 细轨道（中，无手柄）
/// · 大喇叭（右，只标量程、不可点）。**不写百分数**：音量是相对量，两端的喇叭
/// 比数字更好读。两个标注都压灰，形态对齐 [PlayerSeekBar] 的 MD3 皮肤，
/// 但不随暂停褪色（音量与播放态无关，只有用户主动静音才压灰）。
///
/// 落点：横屏「控制」独立页 + 顶栏 ⋯ 更多菜单。常驻控制带**不放音量**——
/// 带高要让给进度尺与传输簇，封面也要留够尺寸。
///
/// tv: TV 构建（[kTvBuild]）下这一行是一个焦点停点：左右 ±5% 调值（按住连发）、
/// OK 切静音、静默 400ms 合并成一次写盘，上/下键放行让焦点出得去。触屏路径零变化。
///
/// 性能约定（AGENTS §10.4）：
/// - 值展示走本地 [ValueNotifier] `_display` + ValueListenableBuilder，拖动只
///   重建滑条行，**不 setState 让整页跟着重建**；
/// - 外部变化（切独占模式、系统改音量）由三路监听驱动：`PlayerProvider`（低频）、
///   `OutputModeCoordinator`（ChangeNotifier）、`UsbAudioService.statusStream`
///   （原生事件广播流），dispose 三处全部解绑；
/// - 拖动中跳过外部回写（`_dragging` 守卫），松手后按最新状态对齐一次；
/// - 落盘时机：拖动中 `persist: false`（只实时下发），`onChangeEnd` 才落盘。
class PlayerVolumeBar extends StatefulWidget {
  const PlayerVolumeBar({super.key, required this.amStyle});

  /// true = AM 深色皮肤（白色系，同 full_player_am 传输行配色）；false = MD3 主题色。
  final bool amStyle;
  @override
  State<PlayerVolumeBar> createState() => _PlayerVolumeBarState();
}

class _PlayerVolumeBarState extends State<PlayerVolumeBar> {
  PlayerProvider? _player;
  StreamSubscription<Map<String, dynamic>>? _statusSub;
  bool _dragging = false;

  /// 滑条行展示值（0..1）。拖动期间只更新它，外部回写在拖动中被跳过。
  final ValueNotifier<double> _display = ValueNotifier<double>(1.0);

  /// 当前三态（切换独占/unity 档时整体重建，拖动中不变）。
  final ValueNotifier<PlayerVolumeState> _state = ValueNotifier<PlayerVolumeState>(
    const PlayerVolumeState(source: PlayerVolumeSource.app, value: 1.0),
  );

  @override
  void initState() {
    super.initState();
    _player = context.read<PlayerProvider>();
    // 外部变化监听：Provider（低频）+ 协调器（ChangeNotifier）+ USB 状态流
    _player?.addListener(_onExternalChanged);
    OutputModeCoordinator.instance.addListener(_onExternalChanged);
    _statusSub = UsbAudioService.instance.statusStream.listen(
      (_) => _onExternalChanged(),
    );
    _refresh();
  }

  @override
  void dispose() {
    // tv: 会话还没落定就被拆掉（菜单被 pop、页面被切走）时补一次写盘。
    // 不能直接调 _onDragEnd：它会 setState，而本方法之后节点已脱树；
    // 也不能只 _tvStepper?.dispose()：那只清 Timer，用户按出来的音量就丢了。
    if (kTvBuild && (_tvStepper?.isAdjusting ?? false)) {
      final PlayerProvider? player = _player;
      if (player != null) {
        unawaited(_state.value.apply(player, _display.value, persist: true));
      }
    }
    _tvStepper?.dispose();
    _tvStepper = null;
    _player?.removeListener(_onExternalChanged);
    OutputModeCoordinator.instance.removeListener(_onExternalChanged);
    _statusSub?.cancel();
    _statusSub = null;
    _display.dispose();
    _state.dispose();
    super.dispose();
  }

  /// 外部状态变化 → 重算三态并更新展示值（用户正在拖动时跳过回写）。
  void _onExternalChanged() {
    if (_dragging) return;
    _refresh();
  }

  void _refresh() {
    final PlayerProvider? player = _player;
    if (player == null) return;
    final PlayerVolumeState state = PlayerVolumeState.of(player);
    _state.value = state;
    _display.value = state.value;
    if (state.value > 0) _lastAudible = state.value;
  }

  /// 最近一次「非零」音量：静音后再点恢复到这里。
  /// 只记非零值，所以用户自己把滑条拖到 0 也能一键弹回上一个可听音量。
  double _lastAudible = 1.0;

  /// tv: 遥控调节状态机（懒建，普通构建永不实例化）。
  TvVolumeStepper? _tvStepper;

  /// tv: 把状态机接到本控件：四个回调全部走触屏同一条既有出口，
  /// 不新增第二套音量下发/落盘逻辑（同 player_seek_bar.dart 的 `_tvAdjust`）。
  TvVolumeStepper get _tvAdjust => _tvStepper ??= TvVolumeStepper(
    onBegin: _onDragStart,
    onStep: _onDrag,
    // 落定 = 触屏松手：写盘 + 按最新三态对齐一次。mounted 守卫是因为 debounce
    // 可能在控件脱树之后才 firing（那份补落盘已在 dispose 里做过）。
    onCommit: (double v) {
      if (mounted) _onDragEnd(v);
    },
    // 放弃：不写盘，但**必须复位 _dragging** —— 它是「跳过外部回写」的闸门，
    // 卡在 true 就让滑条从此不反映系统/独占音量变化。
    onAbort: () {
      if (mounted) setState(() => _dragging = false);
    },
  );

  void _onDragStart() {
    // 内联档的百分数只在拖动期间出现，起止都要重建这一行才看得见/收得回
    setState(() => _dragging = true);
    // 触觉只在按住那一刻给一次反馈；拖动过程不再逐 1% 震动
    //（全程最多 100 次，AGENTS §0.4 与 Apple playing-haptics 都反对高频触觉）
    AppHaptics.tick(HapticCategory.slider);
  }

  void _onDrag(double v) {
    _display.value = v;
    final PlayerVolumeState state = _state.value;
    if (!state.interactive) return;
    if (v > 0) _lastAudible = v;
    // 拖动中轻量下发：不写盘（setVolume/setUsbVolume 的 persist 透传）
    state.apply(_player!, v, persist: false);
  }

  Future<void> _onDragEnd(double v) async {
    setState(() => _dragging = false);
    final PlayerVolumeState state = _state.value;
    if (state.interactive) {
      if (v > 0) _lastAudible = v;
      await state.apply(_player!, v, persist: true);
    }
    // 松手后按最新状态对齐一次（外部变化此时恢复回写）
    _refresh();
  }

  /// 点喇叭 = 一键静音 / 恢复。三态分别下发：
  ///   * 应用音量档 → setVolume(0)；
  ///   * USB 独占档 → setUsbVolume(0)（音频绕过 AudioFlinger，必须动这一档才听得出）；
  ///   * unity 档 → 值恒 1.0 且本就不可调，图标不挂手势（调用也无效，点了不响是诚实）。
  Future<void> _toggleMute() async {
    final PlayerProvider? player = _player;
    final PlayerVolumeState state = _state.value;
    if (player == null || !state.interactive) return;
    final double current = _display.value;
    final double target;
    if (current > 0) {
      _lastAudible = current;
      target = 0;
    } else {
      target = _lastAudible;
    }
    _display.value = target;
    await state.apply(player, target, persist: true);
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '音量',
      child: ValueListenableBuilder<PlayerVolumeState>(
        valueListenable: _state,
        builder: (context, state, _) {
          final Widget row = ValueListenableBuilder<double>(
            valueListenable: _display,
            builder: (context, value, _) =>
                _buildSliderRow(context, state, value),
          );
          if (state.interactive) return row;
          // unity 锁定：滑条禁用 + 提示 + 一键关闭该档（紧凑版 notice）
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[row, const PlayerVolumeUnityNotice(dense: true)],
          );
        },
      ),
    );
  }

  /// 音量条本体：上行「喇叭 + 百分比」（灰），下行细轨道。
  ///
  /// 三元素并排：喇叭（左，兼静音开关）· 轨道（中）· 百分数（右）。
  /// 轨道形态对齐进度条的细线（见 [PlayerSeekBar] 的 MD3 皮肤），但**不复制它的
  /// 褪色**：进度条把已播段褪成未播色是「此刻没有在推进」的播放语义，音量与播放
  /// 态无关，褪了灰反而让人误判滑条失灵。静音是用户显式按出来的，那一次压灰才算数。
  Widget _buildSliderRow(
    BuildContext context,
    PlayerVolumeState state,
    double value,
  ) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool usbExclusive = state.source == PlayerVolumeSource.usbExclusive;
    final bool muted = value <= 0;
    // 未设置段走语义色而不是手调 alpha：MD 用 surfaceContainerHighest 打底、
    // 叠 3/4 的 outlineVariant（即评审里说的 surfaceVariant 那一档，Flutter 已把
    // 它改名弃用，MD3 baseline 色调层等价：#E6E0E9 vs #E7E0EC）。
    // 按 baseline 中性色算 ≈3.0:1 浅 / 4.6:1 深，过 3:1 门槛，且跟随主题的对比层级变化。
    final Color inactive = usbExclusive
        ? Colors.green.withValues(alpha: 0.4)
        : (widget.amStyle
              ? Colors.white38
              : Color.lerp(cs.surfaceContainerHighest, cs.outlineVariant, 0.75)!);
    // 已设置段：静音时与未设置段同灰（整条读起来是"没有声音"）；
    // 否则 USB 独占绿（与原弹窗模式徽标一致）、按皮肤取主题色/白
    final Color active = muted
        ? inactive
        : (usbExclusive
              ? Colors.green
              : (widget.amStyle ? Colors.white : cs.primary));
    // 喇叭与百分数压灰：它们是标注信息，不该与滑条抢视觉重量
    final Color labelColor = widget.amStyle
        ? Colors.white70
        : cs.onSurfaceVariant;
    final track = PlayerVolumeTrackBar(
      value: value,
      enabled: state.interactive,
      activeColor: active,
      inactiveColor: inactive,
      onDragStart: state.interactive ? _onDragStart : null,
      onChanged: state.interactive ? _onDrag : null,
      onDragEnd: state.interactive ? _onDragEnd : null,
    );
    // unity 档不可调，也就没有静音可言：按钮禁用，别让人点了没反应还猜原因。
    // 左边「声音小」是静音开关，右边「声音大」只标量程、不可点；静音态左边换成
    // volume_off，让"现在没有声音"有形状可认，而不是只靠变灰（color-not-only）。
    final row = Row(
      children: <Widget>[
        _MuteButton(
          icon: muted ? Icons.volume_off : Icons.volume_down,
          color: labelColor,
          enabled: state.interactive,
          muted: muted,
          onPressed: _toggleMute,
        ),
        Expanded(child: track),
        const SizedBox(width: 8),
        Icon(Icons.volume_up, size: 20, color: labelColor),
      ],
    );

    // tv: 音量行原本是纯手势控件（喇叭键 onTap + 轨道横拖），TV 上**不是焦点停点**，
    // 菜单里走到这一行就是黑洞。这里给它一个停点：左右 ±5%（按住连发）、OK 切静音、
    // 静默 400ms 合并成一次写盘；上/下键放行，焦点能正常移出（AGENTS §12.4）。
    // 形态照抄 player_seek_bar.dart，**不换成 RemoteSlider**：那条路只认真 Slider，
    // 套在自绘 GestureDetector 轨道上不起作用。
    if (kTvBuild) {
      return DpadFocusable(
        debugLabel: 'tv/player-volume-bar',
        // unity 锁定态不可调 → 不设停点（dpad 会把 canRequestFocus:false 的项
        // 整个移出遍历，不会形成"按了没反应"的死停点）。
        enabled: state.interactive,
        // 不自动滚进视野：dpad 的 DpadScroll.ensureVisible 会遍历**所有**祖先
        // Scrollable（含菜单的 SingleChildScrollView 与页面里的 PageView），
        // 聚焦反而可能带动滚动/切页（同进度条的处置）。
        autoScroll: false,
        // 混设备（TV 包装在带触屏的盒子/平板）把点区让给子树自己的手势，
        // 不与喇叭键的 onTap、轨道的横拖抢手势竞技场。
        tapToSelect: false,
        onSelect: () {
          // OK 的语义 = 原左端喇叭键（静音/恢复）。但会话进行中要先落定：
          // 否则刚按出的静音会在 debounce 之后被状态机里那份旧 target 盖回去。
          if (_tvStepper?.isAdjusting ?? false) {
            _tvStepper!.flush();
            return;
          }
          unawaited(_toggleMute());
        },
        onDirection: (direction) => _tvAdjust.handleDirection(
          direction,
          current: _display.value,
        ),
        onFocusChange: (focused) {
          // 失焦（上下键移出/路由切换）立即落定，不留「看不见还挂着」的待写盘
          if (!focused) _tvStepper?.flush();
        },
        child: row,
      );
    }
    return row;
  }
}

/// 喇叭按钮：点一下静音、再点恢复上一个非零音量。
///
/// 命中框 40×40，比 Apple 的最小控件尺寸 28×28 宽裕（轨道本身也给了 40 高，
/// 两者同线才能一眼看出这是同一个控件）。禁用态只压色、不删图标，图标位置恒定
/// 才不会在切到 unity 档时让整行跳动。
class _MuteButton extends StatelessWidget {
  const _MuteButton({
    required this.icon,
    required this.color,
    required this.enabled,
    required this.muted,
    required this.onPressed,
  });

  final IconData icon;
  final Color color;
  final bool enabled;
  final bool muted;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: enabled,
      label: muted ? '恢复音量' : '静音',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onPressed : null,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Center(
            child: Icon(
              icon,
              size: 20,
              color: enabled ? color : color.withValues(alpha: 0.38),
            ),
          ),
        ),
      ),
    );
  }
}

/// 音量轨道条 —— 复用 [PlayerSeekBar] 的细线形态：4px 圆头轨道、末端没有手柄、
/// 已设置段与未设置段之间留一道缝。
///
/// 但**不随暂停褪色**：进度条把已播段褪成未播色是「此刻没有在推进」的播放语义，
/// 音量与播放态无关，褪了灰反而让人误判滑条失灵。静音态由调用方把 activeColor
/// 也换成同一支灰，这里只负责画两条线段。
///
/// 不用 M3ESlider：它把自身高度强钳到 `thumbRippleRadius * 2` = 48dp（与
/// trackHeight 无关），横屏本就缺高度，控制页这一段再吃 48dp 会被大字号顶出
/// RenderFlex 溢出（实测 800×360 + 1.3 倍字）。这里 [_hitHeight] = 40：既躲开
/// Apple「最小控件 28×28」的地板（24 那一版是踩过来的），又比进度条自己的 38
/// 只高一点点，不会把这行抬成整页最重的元素。
class PlayerVolumeTrackBar extends StatelessWidget {
  const PlayerVolumeTrackBar({
    super.key,
    required this.value,
    required this.activeColor,
    required this.inactiveColor,
    this.enabled = true,
    this.onDragStart,
    this.onChanged,
    this.onDragEnd,
  });

  /// 0..1
  final double value;
  final Color activeColor;
  final Color inactiveColor;

  /// false = 只展示不可调（unity 音量档），此时三个回调都不挂
  final bool enabled;

  /// 按下 / 拖起手（父层据此进入「拖动中」状态，暂停外部回写）
  final VoidCallback? onDragStart;

  /// 拖动中逐帧下发（父层不写盘）
  final ValueChanged<double>? onChanged;

  /// 松手 / 点击落点（父层在此落盘）
  final ValueChanged<double>? onDragEnd;

  static const double _trackHeight = 4;
  static const double _hitHeight = 40;

  /// 已设置段与未设置段之间的缝宽（同进度条的 4px 间隙做法）
  static const double _gap = 4;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      slider: true,
      value: '${(value.clamp(0.0, 1.0) * 100).round()}%',
      child: SizedBox(
        height: _hitHeight,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final double extent = constraints.maxWidth;
            final double fill = (extent * value.clamp(0.0, 1.0)).clamp(
              0.0,
              extent,
            );
            final double restStart = (fill + _gap).clamp(0.0, extent);
            double fractionAt(Offset local) =>
                extent <= 0 ? 0 : (local.dx / extent).clamp(0.0, 1.0);
            final bool interactive = enabled && onChanged != null;
            final BorderRadius radius = BorderRadius.circular(
              _trackHeight / 2,
            );
            void startAt(Offset p) {
              onDragStart?.call();
              onChanged!(fractionAt(p));
            }

            void updateAt(Offset p) => onChanged!(fractionAt(p));
            void endAt() => onDragEnd!(value);
            Widget segment(Color color, double from, double to) {
              final double along = (to - from).clamp(0.0, extent);
              return Positioned(
                left: from,
                top: (constraints.maxHeight - _trackHeight) / 2,
                width: along,
                height: _trackHeight,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: radius,
                  ),
                ),
              );
            }

            return GestureDetector(
              // 轨道只有 4px，透明命中框让整条（含留白）都能点/拖
              behavior: HitTestBehavior.opaque,
              onTapDown: interactive
                  ? (TapDownDetails d) => startAt(d.localPosition)
                  : null,
              onTapUp: interactive && onDragEnd != null
                  ? (TapUpDetails d) => onDragEnd!(fractionAt(d.localPosition))
                  : null,
              // 只挂横向：两轴同时注册会在竞技场里互相抢
              onHorizontalDragStart: interactive
                  ? (DragStartDetails d) => startAt(d.localPosition)
                  : null,
              onHorizontalDragUpdate: interactive
                  ? (DragUpdateDetails d) => updateAt(d.localPosition)
                  : null,
              onHorizontalDragEnd: interactive && onDragEnd != null
                  ? (DragEndDetails d) => endAt()
                  : null,
              // 取消（被系统手势抢走等）也必须收尾：父层的 _dragging 只在这里复位，
              // 漏掉就会永久跳过外部回写，滑条从此不反映系统/独占音量变化
              onHorizontalDragCancel: interactive && onDragEnd != null
                  ? endAt
                  : null,
              child: Stack(
                children: <Widget>[
                  segment(inactiveColor, restStart, extent),
                  segment(activeColor, 0, fill),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// unity 音量档的说明面板：滑块失效，改为说明 + 一键关闭该档。
///
/// 从 full_player 的 `_buildUnityVolumeNotice` 抽出为可复用组件：
/// - [dense] = false：弹窗完整版，与原实现逐字一致（徽标 / 图标 / 多行文案 /
///   12px 间距）；
/// - [dense] = true：紧凑版（单行提示 + 小号按钮），给常驻音量条用。
/// 文案与开关动作统一走 [PlayerVolumeState]，弹窗与常驻条不再分叉。
class PlayerVolumeUnityNotice extends StatelessWidget {
  const PlayerVolumeUnityNotice({super.key, this.dense = false, this.onDisabled});

  /// false = 弹窗完整版；true = 常驻条紧凑版。
  final bool dense;

  /// 关闭 unity 档完成后的回调（弹窗场景在此 pop）。
  final VoidCallback? onDisabled;

  Future<void> _disableUnity() async {
    await PlayerVolumeState.disableUnityVolume();
    onDisabled?.call();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    if (dense) {
      return Row(
        children: <Widget>[
          Expanded(
            child: Text(
              PlayerVolumeState.unityHintLabel,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              textStyle: Theme.of(context).textTheme.labelSmall,
              foregroundColor: cs.primary,
            ),
            onPressed: _disableUnity,
            child: const Text('关闭 unity 音量，恢复应用内滑块'),
          ),
        ],
      );
    }
    // 完整版：与 full_player._buildUnityVolumeNotice 逐字一致
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: cs.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              PlayerVolumeState.unityChipLabel,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: cs.primary,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Icon(Icons.volume_up, size: 32, color: cs.primary),
        const SizedBox(height: 8),
        Text(
          'Direct PCM（unity 音量）下应用音量固定为 100%，\n请用系统媒体音量键调节。',
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: _disableUnity,
          child: const Text('关闭 unity 音量，恢复应用内滑块'),
        ),
      ],
    );
  }
}
