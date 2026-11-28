import 'dart:async';

import 'package:material_ui/material_ui.dart';

/// 切歌时标题/副标题的延迟交叉淡入。
///
/// 为什么要有延迟：视频里封面**先滑到位**、标题随后才换；标题与封面同时换会
/// 出现「封面还在飞、文字已经变了」的分裂感。延迟窗口内旧标题继续显示，
/// 随后与新标题做交叉淡入（新标题从下方 6px 浮上来）。
///
/// 「旧标题」用的是**上一帧的 [child] 实例**，不是按文字重建成的一份新块：
/// 长歌名在 `GentleScrollingText` 下是单行滚动、在裸 `Text` 下会折行，用重建件
/// 会让延迟窗口里突然多出一行、随后又弹回去。复用 [child] 则延迟窗口与静止态
/// **逐像素同构**（布局尺寸、滚动观感、边缘渐隐都一致）。
///
/// 幂等与零成本：`version` 未变时**原样返回 [child]**，不增加任何 widget 层级、
/// 不挂任何动画（本仓「默认关闭 = 零变化」的既有口径）。
class TitleSwitchFade extends StatefulWidget {
  const TitleSwitchFade({
    super.key,
    required this.version,
    required this.align,
    required this.child,
    this.enabled = true,
    this.delay = const Duration(milliseconds: 320),
    this.duration = const Duration(milliseconds: 200),
  });

  /// 身份键：变化即触发一次交叉淡入。用曲目 id，元数据富化改标题不会触发。
  final String version;

  /// 旧标题层的对齐方式（`Alignment.centerLeft` 或 `Alignment.center`）。
  final Alignment align;

  /// 已完成样式与内容计算的新标题块；idle 时直接返回它。
  final Widget child;

  /// 关闭时退化为「直接换文字」，不做任何动画（频谱圆盘等无需分层编排的场景）。
  final bool enabled;

  /// 延迟：等封面滑入基本到位。
  final Duration delay;

  /// 交叉淡入时长。
  final Duration duration;

  @override
  State<TitleSwitchFade> createState() => _TitleSwitchFadeState();
}

class _TitleSwitchFadeState extends State<TitleSwitchFade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  Timer? _delayTimer;

  bool _fading = false;

  /// 延迟窗口是否已过（交叉淡入真正开始）。
  ///
  /// 窗口内只显示旧标题：新文字此刻连「透明的一层」都不该在场。窗口一过就建
  /// 交叉淡入的 Stack（首帧 `_fade.value` 仍是 0，新层不透明度为 0，画面不跳）。
  bool _fadeStarted = false;

  /// 正在退场的旧标题块 = 上一个版本的 [child]。
  Widget? _oldChild;

  @override
  void initState() {
    super.initState();
    _fade.addStatusListener(_onFadeStatus);
  }

  @override
  void didUpdateWidget(covariant TitleSwitchFade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration) _fade.duration = widget.duration;
    if (oldWidget.version == widget.version) return;
    // 上一次还没收敛就再次切歌：旧标题取**当前正在显示**的那一份，别取
    // 「上一次的新标题」，否则快速连切会出现中间那首的标题残影。
    if (!_fading) _oldChild = oldWidget.child;
    if (!widget.enabled) {
      // 关闭编排：整个撤掉在飞的交叉淡入，退化成「直接换文字」。
      _cancel();
      return;
    }
    setState(() => _fading = true);
    _delayTimer?.cancel();
    _delayTimer = Timer(widget.delay, () {
      if (!mounted || !_fading) return;
      // 延迟到点：从「只显示旧标题」切到「两层交叉淡入」。
      setState(() => _fadeStarted = true);
      _fade
        ..reset()
        ..forward();
    });
  }

  @override
  void dispose() {
    _delayTimer?.cancel();
    _fade
      ..removeStatusListener(_onFadeStatus)
      ..dispose();
    super.dispose();
  }

  /// 回到 idle 形态。
  void _cancel() {
    _delayTimer?.cancel();
    _delayTimer = null;
    _fade.stop();
    _fade.value = 0;
    _fading = false;
    _fadeStarted = false;
    _oldChild = null;
  }

  void _onFadeStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    // 收敛后回到 idle 形态：把旧文字层整个撤掉，避免静态时多留一个 Stack 与
    // 一层半透明文字（也顺带把「每帧重建」的风险收掉）。
    if (!mounted) return;
    setState(() {
      _fading = false;
      _fadeStarted = false;
      _oldChild = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_fading) return widget.child;
    return AnimatedBuilder(
      animation: _fade,
      builder: (context, _) {
        final double t = _fade.value;
        final Widget old = _oldChild ?? widget.child;
        // 延迟窗口内只显示旧标题：此刻新文字连「透明的一层」都不该在场
        // （`Opacity(0)` 仍然算是「已经换了」）。
        if (!_fadeStarted) return old;
        return Stack(
          // 旧文字层用 Positioned.fill 铺满，新文字层（非 Positioned）决定
          // Stack 尺寸 —— 因此布局尺寸恒等于 idle 时的尺寸，零位移。
          alignment: widget.align,
          children: [
            Transform.translate(
              offset: Offset(0, 6 * (1 - t)),
              child: Opacity(opacity: t, child: widget.child),
            ),
            Positioned.fill(
              child: Align(
                alignment: widget.align,
                child: Transform.translate(
                  offset: Offset(0, -6 * t),
                  child: Opacity(opacity: 1 - t, child: old),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
