import 'package:material_ui/material_ui.dart';

import 'flowing_background_palette.dart';
import 'flowing_background_uniforms.dart' show fluidPaletteBlend;

/// 流光调色板的交叉淡化（切歌 / 入场 / 明暗模式切换时的平滑过渡）。
///
/// **为什么需要它**：切歌时 [FlowingPalette] 一帧整体替换，整屏 4 个 pigment
/// 场 + base 同时跳到新配色 —— 真机表现就是「背景闪一下」，与同页模糊封面
/// 背景的 1000ms 交叉淡化（`full_player_am.dart` 的 `_artworkFadeController`）
/// 完全不同步。本类把「直接换 palette」改成「在 [duration] 内逐帧插值」。
///
/// 设计要点：
/// - **纯 Dart**：只依赖 palette 与既有缓动 [fluidPaletteBlend]（quintic
///   smoothstep，端点速度为 0），可在单测里逐帧断言，不依赖 GPU / 图片解码；
/// - **可中断**：过渡中再来目标时，以「当前混合结果」为新起点（[current]），
///   因此快速连切不会回跳、不会叠加多条过渡；
/// - **不可变输入**：从不就地改写传入的 [FlowingPalette]（缓存实例与
///   [FlowingPalette.fallback] 是共享的，改写会污染其它页面）；
/// - **仅在过渡期分配**：稳态时 [current] 就是目标实例本身、[advance] 零分配；
///   过渡期每步生成一份混合快照（4 + 1 + 32 个 [Color]），由调用方按 30fps
///   推进，最长 [defaultDuration]（0.9s），属有界开销。
class FlowingPaletteTransition {
  FlowingPaletteTransition({
    FlowingPalette? initial,
    this.duration = defaultDuration,
  })  : assert(!duration.isNegative),
        _from = initial ?? FlowingPalette.fallback,
        _to = initial ?? FlowingPalette.fallback,
        _current = initial ?? FlowingPalette.fallback;

  /// 默认过渡时长。
  ///
  /// 1. 落在上游 myune「650~1200ms 交叉淡入」区间内；
  /// 2. 与同页模糊封面背景的 1000ms 淡切同量级，两层不会一前一后各跳一次；
  /// 3. 0.9s 在 30fps 档（每拍 32ms）上约 28 步，足够平滑又不至于「拖泥带水」。
  static const Duration defaultDuration = Duration(milliseconds: 900);

  final Duration duration;

  FlowingPalette _from;
  FlowingPalette _to;
  FlowingPalette _current;
  int _elapsedMicroseconds = 0;
  bool _animating = false;

  /// 当前应渲染的调色板（过渡中为混合快照，否则就是目标实例）。
  FlowingPalette get current => _current;

  /// 是否正在过渡。
  bool get isAnimating => _animating;

  /// 立即切到 [target]（首帧初始化 / 关闭动画），不产生过渡。
  void settle(FlowingPalette target) {
    _from = target;
    _to = target;
    _current = target;
    _elapsedMicroseconds = 0;
    _animating = false;
  }

  /// 从**当前颜色**出发向 [target] 过渡。
  ///
  /// 返回 false 表示无需动画（目标与当前目标同一个实例，或时长为 0 已即时生效）。
  /// 用 `identical` 而不是颜色比较做去重：调用方对同一份 palette 只会 memo 出
  /// 一个实例（见 `_resolvePalette`），因此这条判据同时覆盖「同封面重建」与
  /// 「目标没变」两种不必要过渡。
  bool retarget(FlowingPalette target) {
    if (identical(target, _to)) return false;
    if (duration <= Duration.zero) {
      settle(target);
      return false;
    }
    // 关键：起点取**当前混合结果**而不是上一次的起点或终点。
    // 快速连切时若从旧起点重来，画面会先回跳一截再前进（肉眼可见的抖动）。
    _from = _current;
    _to = target;
    _elapsedMicroseconds = 0;
    _animating = true;
    return true;
  }

  /// 推进 [step]；返回是否仍在过渡（false = 已收敛到目标）。
  bool advance(Duration step) {
    if (!_animating) return false;
    _elapsedMicroseconds += step.inMicroseconds;
    final int total = duration.inMicroseconds;
    if (total <= 0 || _elapsedMicroseconds >= total) {
      // 收敛时直接指向目标实例（不做「progress=1 的插值」）：
      // 保证最终帧与目标逐值相等，测试可断言 == 而非 closeTo。
      settle(_to);
      return false;
    }
    final double progress = _elapsedMicroseconds / total;
    _current = _blend(_from, _to, fluidPaletteBlend(progress));
    return true;
  }

  /// 逐通道混合两份调色板（pigment 4 + base 1 + motion 32）。
  static FlowingPalette _blend(
    FlowingPalette from,
    FlowingPalette to,
    double progress,
  ) {
    final pigments = List<Color>.generate(
      from.pigments.length,
      (int i) => Color.lerp(from.pigments[i], to.pigments[i], progress)!,
      growable: false,
    );
    final motionColors = List<Color>.generate(
      from.motionColors.length,
      (int i) => Color.lerp(from.motionColors[i], to.motionColors[i], progress)!,
      growable: false,
    );
    return FlowingPalette(
      pigments: pigments,
      baseColor: Color.lerp(from.baseColor, to.baseColor, progress)!,
      motionColors: motionColors,
    );
  }
}
