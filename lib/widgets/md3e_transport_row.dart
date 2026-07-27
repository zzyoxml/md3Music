import 'package:flutter/material.dart';

/// 上一曲/暂停/下一曲三按钮联合动画控件。
///
/// 视觉行为：
/// - 静止时：3 个胶囊按钮水平排列，中央 play/pause 更大（72dp）
/// - 按下时：被按按钮颜色加深 + 图标下沉缩小（120ms ease-out）
/// - 松开 next：旧 play/pause 变 prev 形态（淡入），旧 next 移到中央
///   变成 play/pause（颜色加深），450ms ease-in-out-cubic
/// - 松开 prev：镜像对称
/// - 松开 play/pause：按钮先挤压到 0.92 再弹性回弹到 1.05→1.0
///
/// 业务回调（onPrevious / onPlayPause / onNext）统一在动画完成后调用，
/// 保证视觉先于音频切换，避免不同步。

/// 私有枚举：三按钮身份
enum _Button { prev, play, next }

/// 私有枚举：过渡类型
enum _Transition { none, toNext, toPrev, playBounce }

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

  /// 松开后过渡动画总时长
  static const Duration _transitionDuration = Duration(milliseconds: 450);

  /// 按下反馈动画时长
  static const Duration _pressDuration = Duration(milliseconds: 120);

  // ===== 动画控制器 =====

  /// 共享时间轴：3 段 Interval 划分 [挤压 / 形变 / 回弹]
  late final AnimationController _controller;

  /// 阶段 1：[0.00, 0.22] 挤压启动
  late final Animation<double> _phase1;

  /// 阶段 2：[0.22, 0.55] 形变移位
  late final Animation<double> _phase2;

  /// 阶段 3：[0.55, 1.00] 收尾稳定 + 回弹（elasticOut）
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
    _phase3 = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.55, 1.00, curve: Curves.elasticOut),
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

    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed ||
          status == AnimationStatus.dismissed) {
        if (mounted) {
          setState(() {
            _isAnimating = false;
            _activeTransition = _Transition.none;
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

  void _startTransition(_Transition t) {
    setState(() {
      _isAnimating = true;
      _activeTransition = t;
    });
    _controller.forward(from: 0).whenComplete(() {
      // 动画完成后调用业务回调
      if (!mounted) return;
      switch (t) {
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
          break;
      }
    });
  }

  // ===== 构建 =====

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_controller, _pressController]),
      builder: (context, _) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildPrev(),
            SizedBox(width: widget.spacing),
            _buildPlay(),
            SizedBox(width: widget.spacing),
            _buildNext(),
          ],
        );
      },
    );
  }

  // ===== 单按钮渲染 =====

  Widget _buildPrev() {
    final isPressed = _pressedButton == _Button.prev;
    final pressT = isPressed ? _pressColor.value : 0.0;

    // 形变参数
    double widthFactor = 1.0;
    double opacity = 1.0;
    double translateX = 0;
    Color? bgOverride;
    Color? fgOverride;
    bool showPlayIcon = false;

    switch (_activeTransition) {
      case _Transition.toNext:
        // 旧 prev 渐隐消失 + 宽度收缩
        opacity = 1.0 - _phase2.value;
        widthFactor = 1.0 - (_phase2.value * 0.2);
        break;
      case _Transition.toPrev:
        // 旧 prev 变 play 形态：宽度从 56 扩到 72，颜色从浅变深
        if (_phase2.value > 0) {
          widthFactor = 1.0 + (_phase2.value * (16.0 / 56.0));
          final colorScheme = Theme.of(context).colorScheme;
          bgOverride = Color.lerp(
            colorScheme.primaryContainer,
            colorScheme.primary,
            _phase2.value,
          )!;
          fgOverride = Color.lerp(
            colorScheme.onPrimaryContainer,
            colorScheme.onPrimary,
            _phase2.value,
          )!;
          translateX = widget.sideButtonSize * 0.55 * _phase2.value;
          showPlayIcon = true;
        }
        break;
      case _Transition.playBounce:
        // playBounce 时 prev 边框被拉（border shift 轻微扩张）
        widthFactor = 1.0 + (_phase1.value * 0.04);
        translateX = widget.spacing * 0.5 * _phase1.value;
        break;
      case _Transition.none:
        break;
    }

    final colorScheme = Theme.of(context).colorScheme;
    final normalBg = colorScheme.primaryContainer;
    final normalFg = colorScheme.onPrimaryContainer;
    final pressedBg = colorScheme.primary;
    final pressedFg = colorScheme.onPrimary;

    final bg = pressT > 0
        ? Color.lerp(normalBg, pressedBg, pressT)!
        : (bgOverride ?? normalBg);
    final fg = pressT > 0
        ? Color.lerp(normalFg, pressedFg, pressT)!
        : (fgOverride ?? normalFg);

    return Transform.translate(
      offset: Offset(translateX, 0),
      child: _buildButton(
        icon: showPlayIcon
            ? (widget.isPlaying ? Icons.pause : Icons.play_arrow)
            : Icons.skip_previous,
        backgroundColor: bg,
        foregroundColor: fg,
        size: widget.sideButtonSize,
        widthFactor: widthFactor,
        opacity: opacity,
        isPressed: isPressed,
        iconOffset: isPressed ? _pressIconOffset.value : 0,
        pressScale: isPressed ? _pressScale.value : 1.0,
        onTapDown: () => _handlePressDown(_Button.prev),
        onTapUp: () => _handlePressUp(_Button.prev),
        onTapCancel: _handlePressCancel,
        enabled: !_isAnimating && widget.onPrevious != null,
        onTap: widget.onPrevious,
      ),
    );
  }

  Widget _buildPlay() {
    final isPressed = _pressedButton == _Button.play;
    final pressT = isPressed ? _pressColor.value : 0.0;

    double widthFactor = 1.0;
    double heightFactor = 1.0;
    double translateX = 0;
    Color? bgOverride;
    Color? fgOverride;
    bool showPrevIcon = false;
    bool showNextIcon = false;

    switch (_activeTransition) {
      case _Transition.toNext:
        // 旧 play → 变成 prev（宽度 72→56，颜色 primary → primaryContainer）
        if (_phase2.value > 0) {
          widthFactor = 1.0 - (_phase2.value * (16.0 / 72.0));
          heightFactor = 1.0;
          final colorScheme = Theme.of(context).colorScheme;
          bgOverride = Color.lerp(
            colorScheme.primary,
            colorScheme.primaryContainer,
            _phase2.value,
          )!;
          fgOverride = Color.lerp(
            colorScheme.onPrimary,
            colorScheme.onPrimaryContainer,
            _phase2.value,
          )!;
          // 左侧位移：play 原占 [playLeft, playLeft+72] → 变成 prev 移到 [0,56]
          translateX = -(widget.sideButtonSize * 0.55) * _phase2.value;
          showPrevIcon = true;
        }
        break;
      case _Transition.toPrev:
        // 旧 play → 变成 next（宽度 72→56，颜色 primary → surfaceContainerHighest）
        if (_phase2.value > 0) {
          widthFactor = 1.0 - (_phase2.value * (16.0 / 72.0));
          heightFactor = 1.0;
          final colorScheme = Theme.of(context).colorScheme;
          bgOverride = Color.lerp(
            colorScheme.primary,
            colorScheme.surfaceContainerHighest,
            _phase2.value,
          )!;
          fgOverride = Color.lerp(
            colorScheme.onPrimary,
            colorScheme.onSurfaceVariant,
            _phase2.value,
          )!;
          // 右侧位移：play 原占 [playLeft, playLeft+72] → 变成 next 移到 [nextLeft, nextLeft+56]
          translateX = (widget.sideButtonSize * 0.55) * _phase2.value;
          showNextIcon = true;
        }
        break;
      case _Transition.playBounce:
        // 阶段 1：缩到 0.92
        // 阶段 3：弹性过冲到 1.05
        if (_phase1.value > 0 && _phase1.value < 1) {
          heightFactor = 1.0 - (_phase1.value * 0.08);
          widthFactor = 1.0 - (_phase1.value * 0.08);
        } else if (_phase3.value > 0) {
          heightFactor = 1.0 + (_phase3.value * 0.05);
          widthFactor = 1.0 + (_phase3.value * 0.05);
        }
        break;
      case _Transition.none:
        break;
    }

    final colorScheme = Theme.of(context).colorScheme;
    final normalBg = colorScheme.primary;
    final normalFg = colorScheme.onPrimary;
    final pressedBg = colorScheme.primary.withValues(alpha: 0.85);
    final pressedFg = colorScheme.onPrimary;

    final bg = pressT > 0
        ? Color.lerp(normalBg, pressedBg, pressT)!
        : (bgOverride ?? normalBg);
    final fg = pressT > 0
        ? Color.lerp(normalFg, pressedFg, pressT)!
        : (fgOverride ?? normalFg);

    // play 位置图标：toNext 时显示 prev 图标，toPrev 时显示 next 图标，否则 play/pause
    final IconData playIcon;
    if (showPrevIcon) {
      playIcon = Icons.skip_previous;
    } else if (showNextIcon) {
      playIcon = Icons.skip_next;
    } else {
      playIcon = widget.isPlaying ? Icons.pause : Icons.play_arrow;
    }

    return Transform.translate(
      offset: Offset(translateX, 0),
      child: _buildButton(
        icon: playIcon,
        backgroundColor: bg,
        foregroundColor: fg,
        size: widget.playButtonSize,
        widthFactor: widthFactor,
        heightFactor: heightFactor,
        opacity: 1.0,
        isPressed: isPressed,
        iconOffset: isPressed ? _pressIconOffset.value : 0,
        pressScale: isPressed ? _pressScale.value : 1.0,
        onTapDown: () => _handlePressDown(_Button.play),
        onTapUp: () => _handlePressUp(_Button.play),
        onTapCancel: _handlePressCancel,
        enabled: !_isAnimating && widget.onPlayPause != null,
        onTap: widget.onPlayPause,
        isCenterPlay: true,
      ),
    );
  }

  Widget _buildNext() {
    final isPressed = _pressedButton == _Button.next;
    final pressT = isPressed ? _pressColor.value : 0.0;

    double widthFactor = 1.0;
    double opacity = 1.0;
    double translateX = 0;
    Color? bgOverride;
    Color? fgOverride;
    bool showPlayIcon = false;

    switch (_activeTransition) {
      case _Transition.toNext:
        // 旧 next → 移到中央变成 play
        if (_phase2.value > 0) {
          widthFactor = 1.0 + (_phase2.value * (16.0 / 56.0));
          final colorScheme = Theme.of(context).colorScheme;
          bgOverride = Color.lerp(
            colorScheme.surfaceContainerHighest,
            colorScheme.primary,
            _phase2.value,
          )!;
          fgOverride = Color.lerp(
            colorScheme.onSurfaceVariant,
            colorScheme.onPrimary,
            _phase2.value,
          )!;
          // 左侧位移到中央
          translateX = -(widget.sideButtonSize * 0.55) * _phase2.value;
          showPlayIcon = true;
        }
        break;
      case _Transition.toPrev:
        // 旧 next 渐隐消失
        opacity = 1.0 - _phase2.value;
        widthFactor = 1.0 - (_phase2.value * 0.2);
        break;
      case _Transition.playBounce:
        widthFactor = 1.0 + (_phase1.value * 0.04);
        translateX = -widget.spacing * 0.5 * _phase1.value;
        break;
      case _Transition.none:
        break;
    }

    final colorScheme = Theme.of(context).colorScheme;
    final normalBg = colorScheme.surfaceContainerHighest;
    final normalFg = colorScheme.onSurfaceVariant;
    final pressedBg = colorScheme.primary;
    final pressedFg = colorScheme.onPrimary;

    final bg = pressT > 0
        ? Color.lerp(normalBg, pressedBg, pressT)!
        : (bgOverride ?? normalBg);
    final fg = pressT > 0
        ? Color.lerp(normalFg, pressedFg, pressT)!
        : (fgOverride ?? normalFg);

    return Transform.translate(
      offset: Offset(translateX, 0),
      child: _buildButton(
        icon: showPlayIcon
            ? (widget.isPlaying ? Icons.pause : Icons.play_arrow)
            : Icons.skip_next,
        backgroundColor: bg,
        foregroundColor: fg,
        size: widget.sideButtonSize,
        widthFactor: widthFactor,
        opacity: opacity,
        isPressed: isPressed,
        iconOffset: isPressed ? _pressIconOffset.value : 0,
        pressScale: isPressed ? _pressScale.value : 1.0,
        onTapDown: () => _handlePressDown(_Button.next),
        onTapUp: () => _handlePressUp(_Button.next),
        onTapCancel: _handlePressCancel,
        enabled: !_isAnimating && widget.onNext != null,
        onTap: widget.onNext,
      ),
    );
  }

  /// 单个按钮的具体渲染：处理缩放、宽度、淡入淡出
  Widget _buildButton({
    required IconData icon,
    required Color backgroundColor,
    required Color foregroundColor,
    required double size,
    required double widthFactor,
    required double opacity,
    required bool isPressed,
    required double iconOffset,
    required double pressScale,
    required VoidCallback onTapDown,
    required VoidCallback onTapUp,
    required VoidCallback onTapCancel,
    required bool enabled,
    required VoidCallback? onTap,
    double heightFactor = 1.0,
    bool isCenterPlay = false,
  }) {
    final currentWidth = size * widthFactor;
    final currentHeight = size * heightFactor;
    // 中央 play 按钮的图标略大
    final iconSize = size * (isCenterPlay ? 0.45 : 0.5);

    return Opacity(
      opacity: opacity,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => onTapDown() : null,
        onTapUp: enabled ? (_) => onTapUp() : null,
        onTapCancel: enabled ? onTapCancel : null,
        // 不直接调用 onTap，避免与动画完成时的回调重复触发
        onTap: null,
        child: Transform.scale(
          scale: pressScale,
          child: SizedBox(
            width: currentWidth,
            height: currentHeight,
            child: Material(
              color: backgroundColor,
              shape: const StadiumBorder(),
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
    );
  }
}
