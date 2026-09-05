import 'package:flutter/material.dart';

/// 上一曲/暂停/下一曲三按钮联合动画控件。
///
/// 视觉行为：
/// - 静止时：3 个圆角矩形按钮水平排列，中央 play/pause 更大（72dp）
/// - 按下时：被按按钮颜色加深 + 图标下沉缩小（120ms ease-out）
/// - 松开 next：play 向左被挤压形变成 prev，next 向左滑到中央变成 play/pause，
///   右侧新 next 从外侧拉入。200ms ease-in-out-cubic
/// - 松开 prev：镜像对称（旧 prev → 新 play，旧 play → 新 next，右侧新 prev 拉入）
/// - 松开 play/pause：按钮先挤压到 0.92，再两段插值（0.92→1.05→1.0）
///
/// 业务回调在动画**开始时立即调用**（不等动画完成），消除 400ms 感知延迟。

/// 私有枚举：三按钮身份
enum _Button { prev, play, next }

/// 私有枚举：过渡类型
///
/// settledToNext / settledToPrev 是 toNext / toPrev 完成后的"已就位"状态，
/// 用于让原 play / 原 next 在动画结束后保持滑动到位的位置/形态，避免
/// default case 强制归位造成视觉瞬移。
enum _Transition {
  none,
  toNext,
  toPrev,
  playBounce,
  settledToNext,
  settledToPrev,
}

class MD3ETransportRow extends StatefulWidget {
  /// 当前是否正在播放（决定中央按钮显示 pause 还是 play_arrow）
  final bool isPlaying;

  /// 点击上一曲回调。动画进行中被禁用。
  final VoidCallback? onPrevious;

  /// 点击暂停/播放回调。
  final VoidCallback? onPlayPause;

  /// 点击下一曲回调。动画进行中被禁用。
  final VoidCallback? onNext;

  /// 左右两侧按钮尺寸，默认 56dp
  final double sideButtonSize;

  /// 中央 play/pause 按钮尺寸，默认 72dp
  final double playButtonSize;

  /// 按钮间距
  final double spacing;

  const MD3ETransportRow({
    super.key,
    required this.isPlaying,
    this.onPrevious,
    this.onPlayPause,
    this.onNext,
    this.sideButtonSize = 56,
    this.playButtonSize = 72,
    this.spacing = 8,
  });

  @override
  State<MD3ETransportRow> createState() => _MD3ETransportRowState();
}

class _MD3ETransportRowState extends State<MD3ETransportRow>
    with TickerProviderStateMixin {
  // ===== 常量 =====

  /// 松开后过渡动画总时长（350ms：放慢让挤压形变更明显）
  static const Duration _transitionDuration = Duration(milliseconds: 350);

  /// 按下反馈动画时长
  static const Duration _pressDuration = Duration(milliseconds: 120);

  // ===== 动画控制器 =====

  /// 共享时间轴：3 段 Interval 划分 [挤压 / 形变 / 回弹]
  late final AnimationController _controller;

  /// 阶段 1：[0.00, 0.22] 挤压启动
  late final Animation<double> _phase1;

  /// 阶段 2：[0.22, 0.55] 形变移位
  late final Animation<double> _phase2;

  /// 阶段 3：[0.55, 1.00] 收尾稳定 + 回弹（两段插值）
  late final Animation<double> _phase3;

  /// 按下反馈独立控制器（120ms ease-out）
  late final AnimationController _pressController;
  late final Animation<double> _pressScale; // 1.0 → 0.92
  late final Animation<double> _pressColor; // 0 → 1 用于 Color.lerp
  late final Animation<double> _pressIconOffset; // 0 → 2dp

  // ===== 状态机 =====

  /// 当前被按下的按钮
  _Button? _pressedButton;

  /// 是否有动画正在播放（用于锁定所有回调）
  bool _isAnimating = false;

  /// 当前正在执行的过渡类型
  _Transition _activeTransition = _Transition.none;

  /// 业务回调是否已触发（防止 phase2 末段重复触发）
  bool _callbackFired = false;

  /// 动画开始时的 isPlaying 快照：动画进行中固定使用此值，避免
  /// playerProvider 异步切歌过程中多次 notifyListeners 导致
  /// widget.isPlaying 在动画中间变化（图标闪烁 = "功能错乱"）。
  /// 动画完成时（completed）解除冻结为 null。
  bool? _frozenIsPlaying;

  /// playBounce 的额外缩放系数（1.0=无缩放），用于 play 按钮圆心居中缩放
  ///
  /// 阶段分布（按 _controller.value）：
  /// - [0.00, 0.22] phase1：1.0 → 0.92（挤压）
  /// - [0.22, 0.55] phase2：保持 0.92（短暂稳定）
  /// - [0.55, 1.00] phase3：两段插值 0.92 → 1.05 → 1.0（单一过冲 + 平滑归位）
  ///
  /// 注意：phase3 用 Curves.linear + 手动两段插值，避免 easeOutBack
  /// 在 _phase3.value 上产生多重 overshoot 造成"闪现归位"。
  double get _playBounceScale {
    if (_activeTransition != _Transition.playBounce) return 1.0;
    if (_phase3.value > 0) {
      // phase3：两段线性插值，前半过冲、后半归位
      // _phase3.value ∈ [0, 1]
      //   [0.0, 0.5] 0.92 → 1.05（过冲）
      //   [0.5, 1.0] 1.05 → 1.0（归位）
      final t = _phase3.value;
      if (t < 0.5) {
        return 0.92 + (t * 2) * 0.13; // 0.92 → 1.05
      }
      return 1.05 - ((t - 0.5) * 2) * 0.05; // 1.05 → 1.0
    }
    // phase1/2 期间：缩到 0.92（_phase1.value 0→1）
    if (_phase1.value > 0) {
      return 1.0 - _phase1.value * 0.08; // 1.0 → 0.92
    }
    return 1.0;
  }

  // ===== 生命周期 =====

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: _transitionDuration,
    );
    _phase1 = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.00, 0.22, curve: Curves.easeIn),
    );
    _phase2 = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.22, 0.55, curve: Curves.easeInOutCubic),
    );
    // phase3 用 linear：手动两段插值（0.92→1.05→1.0），
    // 避免 easeOutBack 的多重 overshoot 在 _phase3.value 上叠加造成"闪现归位"
    _phase3 = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.55, 1.00, curve: Curves.linear),
    );

    _pressController = AnimationController(
      vsync: this,
      duration: _pressDuration,
    );
    _pressScale = Tween<double>(begin: 1.0, end: 0.92).animate(
      CurvedAnimation(parent: _pressController, curve: Curves.easeOut),
    );
    _pressColor = CurvedAnimation(
      parent: _pressController,
      curve: Curves.easeOut,
    );
    _pressIconOffset = Tween<double>(begin: 0, end: 2).animate(
      CurvedAnimation(parent: _pressController, curve: Curves.easeOut),
    );

    // 监听 _controller.value，phase2 末段（约 _controller.value=0.5 时）触发
    // 业务回调，保证视觉形变接近完成时再切歌，避免"功能错乱"
    _controller.addListener(_onControllerTick);

    // 动画完成后切到对应 settled 状态，让原 play / 原 next
    // 保持在滑动到位的位置/形态，避免 default case 归位造成瞬移
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        if (mounted) {
          setState(() {
            _isAnimating = false;
            _frozenIsPlaying = null; // 解除冻结，恢复跟随 widget.isPlaying
            switch (_activeTransition) {
              case _Transition.toNext:
                _activeTransition = _Transition.settledToNext;
                break;
              case _Transition.toPrev:
                _activeTransition = _Transition.settledToPrev;
                break;
              case _Transition.playBounce:
              case _Transition.none:
              case _Transition.settledToNext:
              case _Transition.settledToPrev:
                _activeTransition = _Transition.none;
                break;
            }
          });
        }
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _pressController.dispose();
    super.dispose();
  }

  // ===== 交互入口 =====

  void _handlePressDown(_Button button) {
    if (_isAnimating) return;
    setState(() => _pressedButton = button);
    _pressController.forward(from: 0);
  }

  void _handlePressUp(_Button button) {
    if (_isAnimating) return;
    _pressController.reverse();
    setState(() => _pressedButton = null);

    // 松开：根据按下的按钮触发不同动画
    switch (button) {
      case _Button.prev:
        _startTransition(_Transition.toPrev);
        break;
      case _Button.play:
        _startTransition(_Transition.playBounce);
        break;
      case _Button.next:
        _startTransition(_Transition.toNext);
        break;
    }
  }

  void _handlePressCancel() {
    if (_isAnimating) return;
    _pressController.reverse();
    setState(() => _pressedButton = null);
  }

  /// 当前 slot 在 _activeTransition 状态下的"视觉身份"——即该 slot 当前
  /// 实际呈现的图标/语义身份。用于判断按压反馈 `isPressed` 是否作用在该
  /// slot 上（而不是按"原 slot 身份"判断，否则 settled 状态下按压反馈
  /// 会作用在隐藏的原 slot 上，表现为"按压反馈作用在错误按钮"）。
  ///
  /// - settledToNext：原 play slot 接管 _prevLeft 显示 prev 形态 → 视觉身份 = prev
  ///                 原 next slot 接管 _playLeft 显示 play 形态 → 视觉身份 = play
  ///                 原 prev slot 隐藏 → 视觉身份 = play（占位，hidden 时无意义）
  /// - settledToPrev：镜像对称
  /// - 其他（none / toNext / toPrev / playBounce）：视觉身份 = 原 slot
  _Button _visualIdentityOf(_Button slot) {
    switch (_activeTransition) {
      case _Transition.settledToNext:
        if (slot == _Button.prev) return _Button.play; // 隐藏
        if (slot == _Button.play) return _Button.prev;
        if (slot == _Button.next) return _Button.play;
        break;
      case _Transition.settledToPrev:
        if (slot == _Button.next) return _Button.play; // 隐藏
        if (slot == _Button.prev) return _Button.play;
        if (slot == _Button.play) return _Button.next;
        break;
      case _Transition.none:
      case _Transition.toNext:
      case _Transition.toPrev:
      case _Transition.playBounce:
        return slot;
    }
    return slot;
  }

  /// 根据视觉身份返回 (normalBg, pressedBg, normalFg, pressedFg) 配色。
  /// settled 状态下原 slot 可能接管其他位置并显示不同形态，按压反馈的
  /// 配色应跟随当前视觉形态，否则颜色会"错位"（如 prev 形态按压时
  /// 颜色却用 play 形态的 primary.withValues(0.85)）。
  ({
    Color normalBg,
    Color pressedBg,
    Color normalFg,
    Color pressedFg,
  }) _resolvePressColors(_Button visualId, ColorScheme cs) {
    switch (visualId) {
      case _Button.prev:
        return (
          normalBg: cs.primaryContainer,
          pressedBg: cs.primary,
          normalFg: cs.onPrimaryContainer,
          pressedFg: cs.onPrimary,
        );
      case _Button.play:
        return (
          normalBg: cs.primary,
          pressedBg: cs.primary.withValues(alpha: 0.85),
          normalFg: cs.onPrimary,
          pressedFg: cs.onPrimary,
        );
      case _Button.next:
        return (
          normalBg: cs.primaryContainer,
          pressedBg: cs.primary,
          normalFg: cs.onPrimaryContainer,
          pressedFg: cs.onPrimary,
        );
    }
  }

  /// 根据当前 _activeTransition 状态，决定某个原 slot（_buildPrev/Play/NextPositioned）
  /// 实际应该响应的点击回调。
  ///
  /// 为什么要做这个映射？
  /// toNext / toPrev 动画完成后，三个原 _Button 身份会"重新分配"槽位：
  ///   - settledToNext：
  ///       _prevLeft  ← 原 play（已形变成 prev 形态）→ 应触发 onPrevious
  ///       _playLeft  ← 原 next（已形变成 play 形态）→ 应触发 onPlayPause
  ///       _nextLeft  ← 新 next（_buildNewNextPositioned）   → 应触发 onNext
  ///       原 prev 隐藏
  ///   - settledToPrev：镜像对称
  /// 若不重映射，点击 _prevLeft 位置（视觉是 prev）会触发 onPlayPause，
  /// 表现为"上一首按钮变成暂停按钮"——这正是本次要修的 bug。
  ///
  /// 动画进行中（_isAnimating=true）一律禁用所有点击，避免动画中重复触发。
  ({VoidCallback? onTapDown, VoidCallback? onTapUp, bool enabled})
      _resolveInteraction(_Button slot) {
    // 动画进行中：所有点击禁用
    if (_isAnimating) {
      return (onTapDown: null, onTapUp: null, enabled: false);
    }

    // 1) 决定该 slot 当前代表的真实身份
    _Button? mapped;
    bool hidden = false;
    switch (_activeTransition) {
      case _Transition.settledToNext:
        if (slot == _Button.prev) {
          hidden = true;
        } else if (slot == _Button.play) {
          mapped = _Button.prev; // 原 play 位置现显示 prev 形态
        } else if (slot == _Button.next) {
          mapped = _Button.play; // 原 next 位置现显示 play 形态
        }
        break;
      case _Transition.settledToPrev:
        if (slot == _Button.next) {
          hidden = true;
        } else if (slot == _Button.prev) {
          mapped = _Button.play; // 原 prev 位置现显示 play 形态
        } else if (slot == _Button.play) {
          mapped = _Button.next; // 原 play 位置现显示 next 形态
        }
        break;
      case _Transition.none:
      case _Transition.toNext:
      case _Transition.toPrev:
      case _Transition.playBounce:
        // 静止或动画中：使用原身份
        mapped = slot;
        break;
    }

    if (hidden || mapped == null) {
      return (onTapDown: null, onTapUp: null, enabled: false);
    }

    // 2) 按映射身份查对应的 widget 回调（回调为 null 时也禁用）
    VoidCallback? down;
    VoidCallback? up;
    switch (mapped) {
      case _Button.prev:
        if (widget.onPrevious != null) {
          down = () => _handlePressDown(_Button.prev);
          up = () => _handlePressUp(_Button.prev);
        }
        break;
      case _Button.play:
        if (widget.onPlayPause != null) {
          down = () => _handlePressDown(_Button.play);
          up = () => _handlePressUp(_Button.play);
        }
        break;
      case _Button.next:
        if (widget.onNext != null) {
          down = () => _handlePressDown(_Button.next);
          up = () => _handlePressUp(_Button.next);
        }
        break;
    }

    return (
      onTapDown: down,
      onTapUp: up,
      enabled: down != null && up != null,
    );
  }

  void _startTransition(_Transition t) {
    setState(() {
      _isAnimating = true;
      _activeTransition = t;
      _callbackFired = false;
      // 冻结动画开始时的 isPlaying，避免切歌异步过程多次 rebuild
      // 导致 widget.isPlaying 在动画中间变化（图标闪烁 = 功能错乱）
      _frozenIsPlaying = widget.isPlaying;
    });
    _controller.forward(from: 0);
  }

  /// 监听 _controller.value，phase2 末段（_controller.value >= 0.5）
  /// 触发业务回调。此时形变接近完成，视觉与音频同步更好，
  /// 同时人眼对 ~100ms 的延迟基本无感知。
  void _onControllerTick() {
    if (_callbackFired) return;
    if (_controller.value < 0.5) return;
    _callbackFired = true;
    switch (_activeTransition) {
      case _Transition.toNext:
        widget.onNext?.call();
        break;
      case _Transition.toPrev:
        widget.onPrevious?.call();
        break;
      case _Transition.playBounce:
        widget.onPlayPause?.call();
        break;
      case _Transition.none:
      case _Transition.settledToNext:
      case _Transition.settledToPrev:
        break;
    }
  }

  // ===== 位置计算辅助 =====

  /// prev slot 的 left 起点
  double get _prevLeft => 0.0;

  /// play slot 的 left 起点
  double get _playLeft => widget.sideButtonSize + widget.spacing;

  /// next slot 的 left 起点
  double get _nextLeft =>
      _playLeft + widget.playButtonSize + widget.spacing;

  // ===== 构建 =====

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_controller, _pressController]),
      builder: (context, _) {
        // Stack 容器：每个按钮通过 Positioned 独立控制 left/width/opacity
        // 相比 Row + Transform.translate，Positioned 可以精确控制 widget
        // 在容器中的位置，避免 Row 布局约束对动画造成干扰
        final totalWidth = _nextLeft + widget.sideButtonSize;

        return SizedBox(
          width: totalWidth,
          height: widget.playButtonSize,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              _buildPrevPositioned(),
              _buildPlayPositioned(),
              _buildNextPositioned(),
              // 槽位 3/4：toNext 时右侧拉入新 next，toPrev 时左侧拉入新 prev，
              // 动画结束后由对应 settled 状态保持显示，避免位置/形态跳变
              _buildNewPrevPositioned(),
              _buildNewNextPositioned(),
            ],
          ),
        );
      },
    );
  }

  // ===== 单按钮渲染（Positioned 版本）=====

  Widget _buildPrevPositioned() {
    // settled 状态下原 prev slot 可能已隐藏或接管别处，按"视觉身份"判断按压反馈
    final isPressed = _pressedButton == _visualIdentityOf(_Button.prev);
    final pressT = isPressed ? _pressColor.value : 0.0;
    // 动画中用冻结值，避免切歌异步过程导致图标闪烁
    final effectiveIsPlaying = _frozenIsPlaying ?? widget.isPlaying;
    // 真实点击交互身份（toNext 完成后此 slot 隐藏，toPrev 完成后此 slot 接管 play）
    final interaction = _resolveInteraction(_Button.prev);

    // 形变参数
    double currentWidth = widget.sideButtonSize;
    double opacity = 1.0;
    double left = _prevLeft;
    Color? bgOverride;
    Color? fgOverride;
    IconData? iconOverride;

    switch (_activeTransition) {
      case _Transition.toNext:
        // toNext 期间旧 prev 渐隐消失，让位给 _buildPlayPositioned
        // 滑到 _prevLeft 变成新 prev
        opacity = 1.0 - _phase2.value;
        currentWidth = widget.sideButtonSize * (1.0 - _phase2.value * 0.2);
        break;
      case _Transition.toPrev:
        // toPrev 期间旧 prev 向右滑到 _playLeft 变成 play 形态
        if (_phase2.value > 0) {
          final widthDiff = widget.playButtonSize - widget.sideButtonSize;
          currentWidth = widget.sideButtonSize + widthDiff * _phase2.value;
          left = _prevLeft + _playLeft * _phase2.value;
          final cs = Theme.of(context).colorScheme;
          bgOverride = Color.lerp(
            cs.primaryContainer,
            cs.primary,
            _phase2.value,
          )!;
          fgOverride = Color.lerp(
            cs.onPrimaryContainer,
            cs.onPrimary,
            _phase2.value,
          )!;
          iconOverride = effectiveIsPlaying ? Icons.pause : Icons.play_arrow;
        }
        break;
      case _Transition.settledToNext:
        // toNext 完成后完全隐藏，让位给 _buildPlayPositioned 接管 _prevLeft
        opacity = 0;
        break;
      case _Transition.settledToPrev:
        // toPrev 完成后保持在 _playLeft 显示 play 形态（变成新 play）
        left = _playLeft;
        currentWidth = widget.playButtonSize;
        final cs = Theme.of(context).colorScheme;
        bgOverride = cs.primary;
        fgOverride = cs.onPrimary;
        iconOverride = effectiveIsPlaying ? Icons.pause : Icons.play_arrow;
        break;
      case _Transition.playBounce:
        // playBounce 时 prev 右边框被拉（border shift 轻微扩张 + 左移）
        currentWidth = widget.sideButtonSize * (1.0 + _phase1.value * 0.04);
        left = _prevLeft - widget.spacing * 0.5 * _phase1.value;
        break;
      case _Transition.none:
        break;
    }

    // 按压配色跟随当前视觉身份（settled 状态下原 slot 可能接管别处显示别的形态）
    final colorScheme = Theme.of(context).colorScheme;
    final visualId = _visualIdentityOf(_Button.prev);
    final pressColors = _resolvePressColors(visualId, colorScheme);
    final normalBg = pressColors.normalBg;
    final normalFg = pressColors.normalFg;
    final pressedBg = pressColors.pressedBg;
    final pressedFg = pressColors.pressedFg;

    final bg = pressT > 0
        ? Color.lerp(normalBg, pressedBg, pressT)!
        : (bgOverride ?? normalBg);
    final fg = pressT > 0
        ? Color.lerp(normalFg, pressedFg, pressT)!
        : (fgOverride ?? normalFg);
    final icon = iconOverride ?? Icons.skip_previous;

    return Positioned(
      left: left,
      top: 0,
      width: currentWidth,
      height: widget.playButtonSize,
      child: _buildButtonBody(
        icon: icon,
        backgroundColor: bg,
        foregroundColor: fg,
        size: widget.playButtonSize,
        widthFactor: currentWidth / widget.playButtonSize,
        opacity: opacity,
        isPressed: isPressed,
        iconOffset: isPressed ? _pressIconOffset.value : 0,
        pressScale: isPressed ? _pressScale.value : 1.0,
        onTapDown: interaction.onTapDown,
        onTapUp: interaction.onTapUp,
        onTapCancel: _handlePressCancel,
        enabled: interaction.enabled,
      ),
    );
  }

  Widget _buildPlayPositioned() {
    // settled 状态下原 play slot 已接管其他位置，按"视觉身份"判断按压反馈
    final isPressed = _pressedButton == _visualIdentityOf(_Button.play);
    final pressT = isPressed ? _pressColor.value : 0.0;
    // 动画中用冻结值，避免切歌异步过程导致图标闪烁
    final effectiveIsPlaying = _frozenIsPlaying ?? widget.isPlaying;
    // 真实点击交互身份（toNext 完成后此 slot 接管 prev，toPrev 完成后此 slot 接管 next）
    final interaction = _resolveInteraction(_Button.play);

    // 注意：playBounce 的缩放由 _buildButtonBody 内的 Transform.scale
    // 以圆心为锚点实现，这里 Positioned 始终保持 playLeft / playButtonSize，
    // 避免按左上角缩小导致位置漂移。
    double currentWidth = widget.playButtonSize;
    double left = _playLeft;
    Color? bgOverride;
    Color? fgOverride;
    IconData? iconOverride;

    switch (_activeTransition) {
      case _Transition.toNext:
        // toNext 期间 play 按钮向左被挤压形变成 prev 形态：
        // - left 从 _playLeft 滑到 _prevLeft（向左挤压）
        // - width 从 72 缩到 56
        // - color primary → primaryContainer
        // - icon play/pause → skip_previous
        if (_phase2.value > 0) {
          final widthDiff = widget.playButtonSize - widget.sideButtonSize;
          currentWidth = widget.playButtonSize - widthDiff * _phase2.value;
          left = _playLeft - _playLeft * _phase2.value;
          final cs = Theme.of(context).colorScheme;
          bgOverride = Color.lerp(
            cs.primary,
            cs.primaryContainer,
            _phase2.value,
          )!;
          fgOverride = Color.lerp(
            cs.onPrimary,
            cs.onPrimaryContainer,
            _phase2.value,
          )!;
          iconOverride = Icons.skip_previous;
        }
        break;
      case _Transition.toPrev:
        // toPrev 期间 play 按钮向右被挤压形变成 next 形态：
        // - left 从 _playLeft 滑到 _nextLeft（向右挤压）
        // - width 从 72 缩到 56
        // - color primary → primaryContainer
        // - icon play/pause → skip_next
        if (_phase2.value > 0) {
          final widthDiff = widget.playButtonSize - widget.sideButtonSize;
          currentWidth = widget.playButtonSize - widthDiff * _phase2.value;
          left = _playLeft + (_nextLeft - _playLeft) * _phase2.value;
          final cs = Theme.of(context).colorScheme;
          bgOverride = Color.lerp(
            cs.primary,
            cs.primaryContainer,
            _phase2.value,
          )!;
          fgOverride = Color.lerp(
            cs.onPrimary,
            cs.onPrimaryContainer,
            _phase2.value,
          )!;
          iconOverride = Icons.skip_next;
        }
        break;
      case _Transition.settledToNext:
        // toNext 完成后保持在 _prevLeft 显示 prev 形态（变成新 prev）
        left = _prevLeft;
        currentWidth = widget.sideButtonSize;
        final cs = Theme.of(context).colorScheme;
        bgOverride = cs.primaryContainer;
        fgOverride = cs.onPrimaryContainer;
        iconOverride = Icons.skip_previous;
        break;
      case _Transition.settledToPrev:
        // toPrev 完成后保持在 _nextLeft 显示 next 形态（变成新 next）
        left = _nextLeft;
        currentWidth = widget.sideButtonSize;
        final cs = Theme.of(context).colorScheme;
        bgOverride = cs.primaryContainer;
        fgOverride = cs.onPrimaryContainer;
        iconOverride = Icons.skip_next;
        break;
      case _Transition.playBounce:
        // 缩放由 _buildButtonBody 内的 Transform.scale 实现（圆心锚点）
        // Positioned 保持不变
        break;
      case _Transition.none:
        break;
    }

    // 按压配色跟随当前视觉身份（settled 状态下原 play slot 可能接管 _prevLeft/_nextLeft）
    final colorScheme = Theme.of(context).colorScheme;
    final visualId = _visualIdentityOf(_Button.play);
    final pressColors = _resolvePressColors(visualId, colorScheme);
    final normalBg = pressColors.normalBg;
    final normalFg = pressColors.normalFg;
    final pressedBg = pressColors.pressedBg;
    final pressedFg = pressColors.pressedFg;

    final bg = pressT > 0
        ? Color.lerp(normalBg, pressedBg, pressT)!
        : (bgOverride ?? normalBg);
    final fg = pressT > 0
        ? Color.lerp(normalFg, pressedFg, pressT)!
        : (fgOverride ?? normalFg);
    final icon = iconOverride ??
        (effectiveIsPlaying ? Icons.pause : Icons.play_arrow);

    return Positioned(
      left: left,
      top: 0,
      width: currentWidth,
      height: widget.playButtonSize,
      child: _buildButtonBody(
        icon: icon,
        backgroundColor: bg,
        foregroundColor: fg,
        size: widget.playButtonSize,
        widthFactor: currentWidth / widget.playButtonSize,
        opacity: 1.0,
        isPressed: isPressed,
        iconOffset: isPressed ? _pressIconOffset.value : 0,
        // playBounce 的圆心缩放与按下反馈缩放相乘
        pressScale: (isPressed ? _pressScale.value : 1.0) * _playBounceScale,
        onTapDown: interaction.onTapDown,
        onTapUp: interaction.onTapUp,
        onTapCancel: _handlePressCancel,
        enabled: interaction.enabled,
        isCenterPlay: true,
      ),
    );
  }

  Widget _buildNextPositioned() {
    // settled 状态下原 next slot 已接管其他位置，按"视觉身份"判断按压反馈
    final isPressed = _pressedButton == _visualIdentityOf(_Button.next);
    final pressT = isPressed ? _pressColor.value : 0.0;
    // 动画中用冻结值，避免切歌异步过程导致图标闪烁
    final effectiveIsPlaying = _frozenIsPlaying ?? widget.isPlaying;
    // 真实点击交互身份（toNext 完成后此 slot 接管 play，toPrev 完成后此 slot 隐藏）
    final interaction = _resolveInteraction(_Button.next);

    double currentWidth = widget.sideButtonSize;
    double opacity = 1.0;
    double left = _nextLeft;
    Color? bgOverride;
    Color? fgOverride;
    IconData? iconOverride;

    switch (_activeTransition) {
      case _Transition.toNext:
        // toNext 期间旧 next 向左滑到 _playLeft 变成 play 形态：
        // - left 从 _nextLeft 滑到 _playLeft
        // - width 从 56 扩到 72
        // - color primaryContainer → primary
        // - icon skip_next → play/pause
        if (_phase2.value > 0) {
          final widthDiff = widget.playButtonSize - widget.sideButtonSize;
          currentWidth = widget.sideButtonSize + widthDiff * _phase2.value;
          left = _nextLeft - (_nextLeft - _playLeft) * _phase2.value;
          final cs = Theme.of(context).colorScheme;
          bgOverride = Color.lerp(
            cs.primaryContainer,
            cs.primary,
            _phase2.value,
          )!;
          fgOverride = Color.lerp(
            cs.onPrimaryContainer,
            cs.onPrimary,
            _phase2.value,
          )!;
          iconOverride = effectiveIsPlaying ? Icons.pause : Icons.play_arrow;
        }
        break;
      case _Transition.toPrev:
        // toPrev 期间旧 next 渐隐消失，让位给 _buildNewNextPositioned
        // 从右侧拉到 _nextLeft 显示新 next
        opacity = 1.0 - _phase2.value;
        currentWidth = widget.sideButtonSize * (1.0 - _phase2.value * 0.2);
        break;
      case _Transition.settledToNext:
        // toNext 完成后保持在 _playLeft 显示 play 形态（变成新 play）
        left = _playLeft;
        currentWidth = widget.playButtonSize;
        final cs = Theme.of(context).colorScheme;
        bgOverride = cs.primary;
        fgOverride = cs.onPrimary;
        iconOverride = effectiveIsPlaying ? Icons.pause : Icons.play_arrow;
        break;
      case _Transition.settledToPrev:
        // toPrev 完成后完全隐藏，让位给 _buildNewNextPositioned 接管
        opacity = 0;
        break;
      case _Transition.playBounce:
        // next 左边框被拉（轻微扩张 + 右移）
        currentWidth = widget.sideButtonSize * (1.0 + _phase1.value * 0.04);
        left = _nextLeft + widget.spacing * 0.5 * _phase1.value;
        break;
      case _Transition.none:
        break;
    }

    // 按压配色跟随当前视觉身份（settled 状态下原 next slot 可能接管 _playLeft 显示 play）
    final colorScheme = Theme.of(context).colorScheme;
    final visualId = _visualIdentityOf(_Button.next);
    final pressColors = _resolvePressColors(visualId, colorScheme);
    final normalBg = pressColors.normalBg;
    final normalFg = pressColors.normalFg;
    final pressedBg = pressColors.pressedBg;
    final pressedFg = pressColors.pressedFg;

    final bg = pressT > 0
        ? Color.lerp(normalBg, pressedBg, pressT)!
        : (bgOverride ?? normalBg);
    final fg = pressT > 0
        ? Color.lerp(normalFg, pressedFg, pressT)!
        : (fgOverride ?? normalFg);
    final icon = iconOverride ?? Icons.skip_next;

    return Positioned(
      left: left,
      top: 0,
      width: currentWidth,
      height: widget.playButtonSize,
      child: _buildButtonBody(
        icon: icon,
        backgroundColor: bg,
        foregroundColor: fg,
        size: widget.playButtonSize,
        widthFactor: currentWidth / widget.playButtonSize,
        opacity: opacity,
        isPressed: isPressed,
        iconOffset: isPressed ? _pressIconOffset.value : 0,
        pressScale: isPressed ? _pressScale.value : 1.0,
        onTapDown: interaction.onTapDown,
        onTapUp: interaction.onTapUp,
        onTapCancel: _handlePressCancel,
        enabled: interaction.enabled,
      ),
    );
  }

  /// 新 prev slot —— toPrev 时从左侧外拉到 _prevLeft 位置显示新 prev，
  /// 动画结束后由 settledToPrev 保持显示，其他状态时不可见。
  Widget _buildNewPrevPositioned() {
    double currentWidth = 0;
    double opacity = 0;
    double left = _prevLeft;

    if (_activeTransition == _Transition.toPrev && _phase2.value > 0) {
      // 从左侧外拉到 prevLeft，宽度 0 → sideButtonSize
      currentWidth = widget.sideButtonSize * _phase2.value;
      opacity = _phase2.value;
      // left 从 (_prevLeft - sideButtonSize - spacing) 渐近到 _prevLeft
      left = _prevLeft -
          (widget.sideButtonSize + widget.spacing) * (1.0 - _phase2.value);
    } else if (_activeTransition == _Transition.settledToPrev) {
      // 动画完成后保持在 _prevLeft 显示
      currentWidth = widget.sideButtonSize;
      opacity = 1.0;
      left = _prevLeft;
    }

    if (currentWidth <= 0.01 || opacity <= 0.01) {
      return const SizedBox.shrink();
    }

    // 交互：仅在 settledToPrev 且非动画中、且 onPrevious 非空时启用
    final bool activeSettled =
        _activeTransition == _Transition.settledToPrev && !_isAnimating;
    final bool enabled = activeSettled && widget.onPrevious != null;
    final VoidCallback? onTapDown = enabled
        ? () => _handlePressDown(_Button.prev)
        : null;
    final VoidCallback? onTapUp =
        enabled ? () => _handlePressUp(_Button.prev) : null;
    // 按压反馈：此 slot 固定显示 prev 形态
    final bool isPressed = _pressedButton == _Button.prev;
    final double pressT = isPressed ? _pressColor.value : 0.0;
    final double pressScale = isPressed ? _pressScale.value : 1.0;
    final double iconOffset = isPressed ? _pressIconOffset.value : 0;
    // 按压配色跟随当前视觉形态（prev 形态 = primaryContainer ↔ primary）
    final cs = Theme.of(context).colorScheme;
    final pressColors = _resolvePressColors(_Button.prev, cs);
    final Color bg = pressT > 0
        ? Color.lerp(pressColors.normalBg, pressColors.pressedBg, pressT)!
        : pressColors.normalBg;
    final Color fg = pressT > 0
        ? Color.lerp(pressColors.normalFg, pressColors.pressedFg, pressT)!
        : pressColors.normalFg;

    return Positioned(
      left: left,
      top: 0,
      width: currentWidth,
      height: widget.playButtonSize,
      child: _buildButtonBody(
        icon: Icons.skip_previous,
        backgroundColor: bg,
        foregroundColor: fg,
        size: widget.playButtonSize,
        widthFactor: currentWidth / widget.playButtonSize,
        opacity: opacity,
        isPressed: isPressed,
        iconOffset: iconOffset,
        pressScale: pressScale,
        onTapDown: onTapDown,
        onTapUp: onTapUp,
        onTapCancel: _handlePressCancel,
        enabled: enabled,
      ),
    );
  }

  /// 新 next slot —— toNext 时从右侧外拉到 _nextLeft 位置显示新 next，
  /// toPrev 时也由本 slot 接管显示新 next。
  /// 动画结束后由 settledToNext / settledToPrev 保持显示，其他状态时不可见。
  Widget _buildNewNextPositioned() {
    double currentWidth = 0;
    double opacity = 0;
    double left = _nextLeft;

    if (_activeTransition == _Transition.toNext && _phase2.value > 0) {
      // toNext 期间新 next 从右侧外拉到 _nextLeft，宽度 0 → sideButtonSize
      currentWidth = widget.sideButtonSize * _phase2.value;
      opacity = _phase2.value;
      left = _nextLeft +
          (widget.sideButtonSize + widget.spacing) * (1.0 - _phase2.value);
    } else if (_activeTransition == _Transition.toPrev && _phase2.value > 0) {
      // toPrev 期间新 next 从右侧外拉到 _nextLeft，宽度 0 → sideButtonSize
      currentWidth = widget.sideButtonSize * _phase2.value;
      opacity = _phase2.value;
      left = _nextLeft +
          (widget.sideButtonSize + widget.spacing) * (1.0 - _phase2.value);
    } else if (_activeTransition == _Transition.settledToNext ||
        _activeTransition == _Transition.settledToPrev) {
      // 动画完成后保持在 _nextLeft 显示
      currentWidth = widget.sideButtonSize;
      opacity = 1.0;
      left = _nextLeft;
    }

    if (currentWidth <= 0.01 || opacity <= 0.01) {
      return const SizedBox.shrink();
    }

    // 交互：仅在 settledToNext / settledToPrev 且非动画中、且 onNext 非空时启用
    final bool activeSettled =
        (_activeTransition == _Transition.settledToNext ||
                _activeTransition == _Transition.settledToPrev) &&
            !_isAnimating;
    final bool enabled = activeSettled && widget.onNext != null;
    final VoidCallback? onTapDown = enabled
        ? () => _handlePressDown(_Button.next)
        : null;
    final VoidCallback? onTapUp =
        enabled ? () => _handlePressUp(_Button.next) : null;
    // 按压反馈：此 slot 固定显示 next 形态
    final bool isPressed = _pressedButton == _Button.next;
    final double pressT = isPressed ? _pressColor.value : 0.0;
    final double pressScale = isPressed ? _pressScale.value : 1.0;
    final double iconOffset = isPressed ? _pressIconOffset.value : 0;
    // 按压配色跟随当前视觉形态（next 形态 = primaryContainer ↔ primary）
    final cs = Theme.of(context).colorScheme;
    final pressColors = _resolvePressColors(_Button.next, cs);
    final Color bg = pressT > 0
        ? Color.lerp(pressColors.normalBg, pressColors.pressedBg, pressT)!
        : pressColors.normalBg;
    final Color fg = pressT > 0
        ? Color.lerp(pressColors.normalFg, pressColors.pressedFg, pressT)!
        : pressColors.normalFg;

    return Positioned(
      left: left,
      top: 0,
      width: currentWidth,
      height: widget.playButtonSize,
      child: _buildButtonBody(
        icon: Icons.skip_next,
        backgroundColor: bg,
        foregroundColor: fg,
        size: widget.playButtonSize,
        widthFactor: currentWidth / widget.playButtonSize,
        opacity: opacity,
        isPressed: isPressed,
        iconOffset: iconOffset,
        pressScale: pressScale,
        onTapDown: onTapDown,
        onTapUp: onTapUp,
        onTapCancel: _handlePressCancel,
        enabled: enabled,
      ),
    );
  }

  /// 单个按钮的具体渲染：处理缩放、宽度、淡入淡出
  Widget _buildButtonBody({
    required IconData icon,
    required Color backgroundColor,
    required Color foregroundColor,
    required double size,
    required double widthFactor,
    required double opacity,
    required bool isPressed,
    required double iconOffset,
    required double pressScale,
    required VoidCallback? onTapDown,
    required VoidCallback? onTapUp,
    required VoidCallback onTapCancel,
    required bool enabled,
    double heightFactor = 1.0,
    bool isCenterPlay = false,
  }) {
    // widthFactor 是相对 playButtonSize 的比例（因为 Positioned.width = playButtonSize）
    final currentWidth = size * widthFactor;
    final currentHeight = size * heightFactor;
    // 中央 play 按钮的图标略大
    final iconSize = size * (isCenterPlay ? 0.45 : 0.5);

    // 用 Center + SizedBox 包裹按钮，Transform.scale 默认以中心为锚点，
    // 这样 playBounce 的缩放就是"以圆心居中缩放"，不会从左上角漂移。
    return Opacity(
      opacity: opacity,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // 用 onTapDown?.call() 而非 onTapDown()，保证 null 安全
        // （enabled=false 时 onTapDown/onTapUp 为 null，但 enabled 也会关掉回调）
        onTapDown: enabled ? (_) => onTapDown?.call() : null,
        onTapUp: enabled ? (_) => onTapUp?.call() : null,
        onTapCancel: enabled ? onTapCancel : null,
        // 不直接调用 onTap，避免与动画开始时的回调重复触发
        onTap: null,
        child: Center(
          child: Transform.scale(
            scale: pressScale,
            child: SizedBox(
              width: currentWidth,
              height: currentHeight,
              child: Material(
                color: backgroundColor,
                // 圆角矩形：圆角 8dp，比胶囊形更克制、更现代
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                clipBehavior: Clip.antiAlias,
                child: Center(
                  child: Transform.translate(
                    offset: Offset(0, iconOffset),
                    child: Icon(
                      icon,
                      size: iconSize,
                      color: foregroundColor,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
