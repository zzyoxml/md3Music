import 'package:material_ui/material_ui.dart';

/// peek 渐隐的作用域：宿主播放页把「chrome 的额外压暗因子」（1.0 = 不压暗）下发给
/// 子树里所有 [ZenFade]。
///
/// 用作用域而不是逐个挂载点传值：传裸 `double` 会让整页每 tick 重跑一次 build，
/// 而这条斜坡本身就是给子树改透明度用的（AGENTS §10.4.2）。子树里没有本作用域时
/// 因子按 1.0 处理，ZenFade 的既有行为不变。
class ZenChromeDim extends InheritedNotifier<ValueNotifier<double>> {
  const ZenChromeDim({
    super.key,
    required super.notifier,
    required super.child,
  });

  static double of(BuildContext context) {
    // notifier 在基类里是可空的（T?），没有作用域或没给因子都按「不压暗」处理。
    final scope = context.dependOnInheritedWidgetOfExactType<ZenChromeDim>();
    return scope?.notifier?.value ?? 1.0;
  }
}

/// Zen 模式的 chrome 淡出/折叠组件 —— MD 与 AM 两版播放页共用一份实现。
///
/// [animation] 为 0（正常模式）时完全显示子组件；为 1（Zen 模式）时淡出并把高度
/// 折成 0，把垂直空间让给歌词 / 封面。
///
/// 折到 0 之后必须 `Offstage`：`Opacity(0)` 的子树照旧参与命中测试，那会让 Zen 下
/// 这块区域变成一层「看不见但拦着手势」的膜 —— 控制带淡掉之后切页通道就全断了
/// （计划 §0「Zen 的真缺口」）。停帧不靠这里，靠宿主把可见性显式传给常驻带
/// （`PlayerControlDock.visible`），因为 Offstage 不会自己停下来自驱动的 Timer。
///
/// 最终不透明度还要乘 [ZenChromeDim] 的因子（peek 倒计时渐隐），但**折叠与摘出命中树
/// 的 `hidden` 判据只认 [animation]**：压暗只是视觉上的，中途 chrome 仍要占位、仍可点。
class ZenFade extends StatefulWidget {
  const ZenFade({super.key, required this.animation, required this.child});

  final Animation<double> animation;
  final Widget child;

  @override
  State<ZenFade> createState() => _ZenFadeState();
}

class _ZenFadeState extends State<ZenFade> {
  late final Animation<double> _reverse;

  @override
  void initState() {
    super.initState();
    _reverse = Tween<double>(begin: 1.0, end: 0.0).animate(widget.animation);
  }

  @override
  void didUpdateWidget(covariant ZenFade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      _reverse = Tween<double>(begin: 1.0, end: 0.0).animate(widget.animation);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 取在 AnimatedBuilder 外层：这里注册 inherited 依赖，因子变化时只重建本组件
    final dim = ZenChromeDim.of(context);
    return AnimatedBuilder(
      animation: _reverse,
      builder: (context, _) {
        final hidden = _reverse.value <= 0.0;
        return SizeTransition(
          sizeFactor: _reverse,
          alignment: Alignment.topCenter,
          child: Opacity(
            opacity: (_reverse.value * dim).clamp(0.0, 1.0),
            child: Offstage(offstage: hidden, child: widget.child),
          ),
        );
      },
    );
  }
}
