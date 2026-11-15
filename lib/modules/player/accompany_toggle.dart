import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/build_flags.dart';
import '../../core/services/accompany/accompany_source.dart';
import '../../core/services/accompany_mix.dart';
import '../../core/services/stem_separation_service.dart';
import '../../core/utils/app_haptics.dart';
import '../../data/repositories/settings_repository.dart';
import '../../providers/player_provider.dart';

/// 伴唱按钮 + 长按生长的音量胶囊。
///
/// 挂在歌词页右下角（翻译按钮上方）：
/// - **短按**：开关伴唱（伴奏轨与原曲并行播放，跟随当前进度）。
/// - **长按**：胶囊从 36dp 圆角方块向上生长成 88dp 细长条；手指上下拖动
///   直接改变「伴奏 ↔ 原曲」比例（向上 = 伴奏占比增大）。松手后延时收起。
/// - **展开后直接拖动**：不必再次长按，按住胶囊上下拖即可继续调整。
///
/// 音量形态：胶囊内白色填充从底部向上，高度 = 伴奏占比；填充覆盖到的图标
/// 自动反色（填充内黑、填充外白），与参考视频一致，不写文字标注。
///
/// 视觉口径：
/// - AM 深色皮肤（[amStyle] = true）：半透明白底 + 纯白填充，与同页的翻译
///   按钮（`full_player_am.dart`）同一白色系。
/// - MD3 皮肤：`surfaceContainerHighest` 底 + 主题色填充。
///
/// 胶囊自身用不透明命中区吞掉触摸，展开后不会穿透到歌词行触发跳转；
/// 胶囊之外的空白区域不参与命中，歌词仍可正常点击。
class AccompanyToggle extends StatefulWidget {
  const AccompanyToggle({
    super.key,
    required this.active,
    required this.mix,
    required this.onTap,
    required this.onMixChanged,
    this.adjustable = false,
    this.amStyle = false,
    this.safePadding = 8,
  });

  /// 伴唱是否已开启。
  final bool active;

  /// 当前伴唱比例（伴奏占比 0..1）。
  final double mix;

  /// 短按：开关伴唱。
  final VoidCallback onTap;

  /// 长按拖动：比例变化（已钳到 0..1）。
  final ValueChanged<double> onMixChanged;

  /// 是否允许长按拖动调比例。
  ///
  /// **只有端侧分离可以调**：它只有一条输出管线，混音在 AudioProcessor 里做，
  /// 不存在两路 AudioTrack 排队深度不同的延迟差，调比例不会错位。
  /// 在线伴奏是两条独立解码管线，比例 < 1 必然错位，故固定纯伴奏、只留开关。
  final bool adjustable;

  /// AM 深色皮肤（纯白系配色）。
  final bool amStyle;

  /// 胶囊左右外扩的透明安全区（吸收"点偏"，避免穿透到歌词行触发跳转）。
  final double safePadding;

  @override
  State<AccompanyToggle> createState() => _AccompanyToggleState();
}

class _AccompanyToggleState extends State<AccompanyToggle> {
  /// 胶囊是否展开（长按后展开，松手延时收起）。
  bool _expanded = false;

  /// 胶囊当前显示的比例（拖动中以本地值为准，避免外部重建打断手势）。
  double _dragMix = 0.5;

  /// 本次拖动的起始比例。
  ///
  /// 拖动按「起始值 + 累计位移」计算：若像原来那样每帧把累计位移再次加到
  /// 当前值上，位移会被重复累加，手指只动几像素就冲到 0 / 1（表现就是不跟手）。
  double _dragStartMix = 0.5;

  /// 直接竖向拖动的起点（全局 Y）；null = 当前没有直接拖动。
  double? _dragOriginY;

  /// 收起延时器。
  Timer? _collapseTimer;

  /// 胶囊宽度。
  static const double _kPillWidth = 36;

  /// 展开态高度（长按后向上生长的总高）。
  static const double _kPillHeight = 88;

  /// 折叠态高度（圆角方块）。
  static const double _kCollapsedHeight = 36;

  /// 胶囊圆角。
  static const double _kPillRadius = 12;

  /// 图标尺寸。
  static const double _kIconSize = 20;

  /// 图标距胶囊底部的距离。
  static const double _kIconBottom = 8;

  /// 垂直热区外扩：折叠态 36 + 2×6 = 48，满足最小触控高度。
  static const double _kHitPadV = 6;

  /// 拖动换算跨度（逻辑像素）。
  ///
  /// 故意大于胶囊自身高度：细长条只有 88dp，若按 1:1 换算，手指小幅移动就
  /// 走完整个量程，很难细调。手指走满该跨度才对应 0 → 1。
  static const double _kDragSpan = 160;

  /// 生长 / 收起动画时长。
  static const Duration _kGrowDuration = Duration(milliseconds: 220);

  @override
  void initState() {
    super.initState();
    _dragMix = widget.mix;
  }

  @override
  void didUpdateWidget(AccompanyToggle oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 未在拖动时跟随外部值（伴唱关闭 / 切歌重置比例）。
    if (!_expanded && oldWidget.mix != widget.mix) {
      _dragMix = widget.mix;
    }
  }

  @override
  void dispose() {
    _collapseTimer?.cancel();
    super.dispose();
  }

  /// 展开胶囊。
  void _expand() {
    _collapseTimer?.cancel();
    // 已展开时再次长按只是接着拖，别把刚调好的比例重置回外部旧值。
    if (_expanded) {
      _dragStartMix = _dragMix;
      return;
    }
    AppHaptics.mediumImpact(HapticCategory.gesture);
    setState(() {
      _expanded = true;
      _dragMix = widget.mix;
      _dragStartMix = widget.mix;
    });
  }

  /// 松手：延时收起胶囊（保留一小段时间让用户看清最终比例）。
  void _collapse() {
    _collapseTimer?.cancel();
    _collapseTimer = Timer(const Duration(milliseconds: 1200), () {
      if (!mounted) return;
      setState(() => _expanded = false);
    });
  }

  /// 长按拖动：手指纵向累计位移映射到比例（向上 = 伴奏更响）。
  ///
  /// 用全局位移 [LongPressMoveUpdateDetails.offsetFromOrigin] 而不是局部
  /// 位移：长按触发后胶囊正在向上生长，局部坐标系会随布局一起移动，若用
  /// 局部位移，手指未动也会被算成一次大跳变。
  void _onDragUpdate(LongPressMoveUpdateDetails details) {
    _applyDrag(-details.offsetFromOrigin.dy);
  }

  /// 展开态直接竖向拖动：不必再长按，按住胶囊即可跟手调整。
  void _onVerticalDragStart(DragStartDetails details) {
    if (!_expanded) return;
    // 拖动期间先撤销自动收起，否则手还在拖胶囊就被收掉了。
    _collapseTimer?.cancel();
    _dragStartMix = _dragMix;
    _dragOriginY = details.globalPosition.dy;
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    final origin = _dragOriginY;
    if (!_expanded || origin == null) return;
    _applyDrag(origin - details.globalPosition.dy);
  }

  void _onVerticalDragEnd() {
    _dragOriginY = null;
    if (_expanded) _collapse();
  }

  /// 按「起始比例 + 累计上移距离」换算新的比例。
  void _applyDrag(double travelUpPx) {
    final next = (_dragStartMix + travelUpPx / _kDragSpan).clamp(0.0, 1.0);
    if ((next - _dragMix).abs() < 0.005) return;
    // 触觉按 10% 一档给，避免细长条上每零点几像素震一次（同音量条的既有口径）。
    final stepped = (_dragMix * 10).floor() != (next * 10).floor();
    // 本地 setState：伴唱未开启时宿主只记录待生效比例、不会 notifyListeners，
    // 只靠外部重建的话填充会停住不动。
    setState(() => _dragMix = next);
    widget.onMixChanged(next);
    if (stepped) AppHaptics.selectionClick(HapticCategory.slider);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final panelColor = widget.amStyle
        ? Colors.white.withValues(alpha: 0.12)
        : colorScheme.surfaceContainerHighest.withValues(alpha: 0.92);
    final fillColor = widget.amStyle ? Colors.white : colorScheme.primary;
    final iconOutside = widget.amStyle
        ? (widget.active
              ? Colors.white
              : Colors.white.withValues(alpha: 0.45))
        : (widget.active
              ? colorScheme.primary
              : colorScheme.onSurfaceVariant.withValues(alpha: 0.45));
    final iconInside = widget.amStyle
        ? Colors.black.withValues(alpha: 0.87)
        : colorScheme.onPrimary;

    return SizedBox(
      width: _kPillWidth + widget.safePadding * 2,
      height: _kPillHeight + _kHitPadV * 2,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Semantics(
          label: widget.adjustable ? '伴唱音量' : '伴唱',
          value: widget.adjustable ? '${(_dragMix * 100).round()}%' : (widget.active ? '已开启' : '已关闭'),
          slider: true,
          child: GestureDetector(
            key: const ValueKey('accompany-mix-track'),
            behavior: HitTestBehavior.opaque,
            // 展开态是滑条，短按不开关；折叠态短按才切换伴唱。
            onTap: _expanded ? null : widget.onTap,
            onLongPressStart: widget.adjustable ? (_) => _expand() : null,
            onLongPressMoveUpdate: widget.adjustable ? _onDragUpdate : null,
            onLongPressEnd: widget.adjustable ? (_) => _collapse() : null,
            onLongPressCancel: widget.adjustable ? _collapse : null,
            // 展开后不必再长按：直接按住胶囊上下拖即可调整（折叠态不接管，
            // 避免在图标上误滑就改值）。
            onVerticalDragStart: widget.adjustable ? _onVerticalDragStart : null,
            onVerticalDragUpdate: widget.adjustable ? _onVerticalDragUpdate : null,
            onVerticalDragEnd: widget.adjustable ? (_) => _onVerticalDragEnd() : null,
            onVerticalDragCancel: widget.adjustable ? _onVerticalDragEnd : null,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: widget.safePadding,
                vertical: _kHitPadV,
              ),
              child: AnimatedContainer(
                key: const ValueKey('accompany-pill'),
                duration: _kGrowDuration,
                curve: Curves.easeOutCubic,
                width: _kPillWidth,
                height: (widget.adjustable && _expanded)
                    ? _kPillHeight
                    : _kCollapsedHeight,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: panelColor,
                  borderRadius: BorderRadius.circular(_kPillRadius),
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final pillHeight = constraints.maxHeight;
                    // 图标位置固定：底层白图标 + 填充内反色图标叠在同一处，
                    // 填充边界经过图标时自然形成「上白下黑」的切分。
                    final icon = widget.active ? Icons.mic : Icons.mic_none;
                    return Stack(
                      children: [
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: _kIconBottom,
                          child: Icon(
                            icon,
                            size: _kIconSize,
                            color: iconOutside,
                          ),
                        ),
                        // 白色填充：底部向上，高度 = 伴奏占比。
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          height: pillHeight * _dragMix,
                          child: AnimatedOpacity(
                            opacity: _expanded ? 1.0 : 0.0,
                            duration: const Duration(milliseconds: 160),
                            child: ClipRect(
                              key: const ValueKey('accompany-fill'),
                              child: Stack(
                                children: [
                                  Positioned.fill(
                                    child: ColoredBox(color: fillColor),
                                  ),
                                  Positioned(
                                    left: 0,
                                    right: 0,
                                    bottom: _kIconBottom,
                                    child: Icon(
                                      icon,
                                      size: _kIconSize,
                                      color: iconInside,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 构建伴唱按钮（播放页共用）。
///
/// 显示条件：
/// - 伴唱功能开关已开启（设置 → 播放 → 播放行为 → 伴唱；默认关闭）；
/// - 非 Zen 模式（Zen 下其它控件一并隐藏）；
/// - 当前有在播的歌，且满足当前「伴奏来源」的前提：
///   - 在线伴奏：须在线歌曲且带 `albumAudioId`（酷狗匹配的必需入参）；
///   - 端侧分离：只要安装包带模型即可（本地歌、匹配不到的在线歌都能用）。
///
/// **是否可调比例按来源分流**（这是关键差异）：
/// - 端侧分离：`adjustable = true`，长按拖动调「原音 ↔ 伴奏」比例。它只有
///   一条输出管线，混音在 AudioProcessor 里做，不存在两路 AudioTrack 排队
///   深度不同的延迟差，调比例不会错位。
/// - 在线伴奏：`adjustable = false`，只保留短按开关。两条独立解码管线，
///   比例 < 1 必然错位（历史上偏移滑块与自动对齐都因此失败），故固定纯伴奏。
///
/// [amStyle] 区分 AM 深色皮肤（纯白系）与 MD3 皮肤（主题色）。
Widget buildAccompanyToggle({
  required BuildContext context,
  required bool amStyle,
  required bool zenMode,
}) {
  // 用两层 ValueListenableBuilder：设置页开关伴唱 / 切换来源后，已打开的
  // 播放页即时隐藏、恢复或切换交互形态。
  return ValueListenableBuilder<bool>(
    valueListenable: SettingsRepository.accompanyFeatureEnabled,
    builder: (context, enabled, _) {
      if (!enabled) return const SizedBox.shrink();
      return ValueListenableBuilder<AccompanySource>(
        valueListenable: SettingsRepository.accompanySource,
        builder: (context, source, _) {
          final player = context.read<PlayerProvider>();
          final song = player.currentSong;
          final onDevice = source == AccompanySource.onDevice;
          final usable = !zenMode &&
              song != null &&
              switch (source) {
                // 端侧分离作用在当前播放的那条轨道上，与来源无关；
                // lite 包无分离能力（kStemSeparationAvailable=false），此处恒 false。
                AccompanySource.onDevice =>
                  kStemSeparationAvailable &&
                      StemSeparationService.instance.available,
                AccompanySource.online =>
                  song.isOnline && (song.albumAudioId?.isNotEmpty ?? false),
              };
          if (!usable) return const SizedBox.shrink();
          return ListenableBuilder(
            listenable: Listenable.merge([
              player,
              player.accompanyActiveNotifier,
            ]),
            builder: (context, _) {
              // 端侧用 provider 的比例；在线恒为纯伴奏。
              final mix = onDevice
                  ? player.stemMix
                  : AccompanyMix.accompanyOnly.mix;
              return AccompanyToggle(
                active: player.accompanyActive,
                mix: mix,
                adjustable: onDevice,
                amStyle: amStyle,
                onTap: () => player.toggleAccompany(),
                onMixChanged: (value) => player.setStemMix(value),
              );
            },
          );
        },
      );
    },
  );
}
