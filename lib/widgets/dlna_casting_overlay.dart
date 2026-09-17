import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../main.dart';
import '../modules/player/dlna_remote_page.dart';
import '../providers/dlna_provider.dart';

/// 投屏中悬浮窗：支持贴边吸附（只显示 icon）与展开浮动两种状态。
///
/// 交互流程：
/// - 吸附态（默认）：贴左/右边缘，只显示圆形 icon
/// - 点击 icon：展开为浮动态，显示完整标题
/// - 浮动态点击：进入遥控页面 [DlnaRemotePage]
/// - 任意态拖拽：改变位置（吸附态拖拽时自动切换为浮动态）
/// - 浮动态点击外部：吸附回最近的边缘
///
/// 手势识别说明：
/// 使用 Listener 手动处理 pointer 事件，而非 GestureDetector。
/// 这样避免了 onTap 与 onPanUpdate 在手势竞技场中的竞争，
/// 确保"轻点"和"拖拽"能 100% 可靠区分。
class DlnaCastingOverlay extends StatefulWidget {
  const DlnaCastingOverlay({super.key});

  @override
  State<DlnaCastingOverlay> createState() => _DlnaCastingOverlayState();
}

class _DlnaCastingOverlayState extends State<DlnaCastingOverlay> {
  // 展开状态：false=吸附态（只显示icon），true=浮动态（完整内容）
  bool _expanded = false;
  // 吸附边：true=右边，false=左边
  bool _attachedRight = true;
  // 浮动态下的位置（左上角坐标），null 表示用默认位置
  Offset? _floatingPosition;
  // 吸附态记录的 Y 位置：吸附/拖拽时记住当前高度，避免每次吸附都回到固定高度。
  // null 表示用默认值（statusBarHeight + 56）。
  double? _attachedTop;

  // ── 手势识别状态（手动处理，避免 GestureDetector 竞争）──
  Offset? _pointerDownPosition;
  bool _isDragging = false;
  // 拖拽阈值（与 Flutter kTouchSlop 一致），超过此距离判定为拖拽
  static const double _dragThreshold = 18.0;

  // 尺寸常量
  static const double _iconSize = 48;       // 吸附态圆形 icon 直径（也是展开态高度）
  static const double _maxExpandedWidth = 280; // 浮动态最大宽度
  static const double _height = _iconSize;  // 浮动态高度，与吸附态一致

  // 测量实际渲染宽度，用于精确的边界约束（修复只能在左半屏拖动的问题）
  final GlobalKey _overlayKey = GlobalKey();
  double get _actualWidth {
    final renderBox = _overlayKey.currentContext?.findRenderObject() as RenderBox?;
    return renderBox?.size.width ?? _iconSize;
  }

  /// 进入遥控页面：通过全局 navigatorKey，避免依赖 BuildContext。
  void _enterRemotePage() {
    appNavigatorKey.currentState?.push(
      MaterialPageRoute(builder: (_) => const DlnaRemotePage()),
    );
  }

  /// 计算吸附态应使用的 Y 坐标：优先用 [_attachedTop] 记忆值，否则用默认高度。
  /// 始终 clamp 到 [statusBarHeight, maxTop] 范围内，避免越界。
  double _resolveAttachedTop(double statusBarHeight, double maxTop) {
    return (_attachedTop ?? (statusBarHeight + 56))
        .clamp(statusBarHeight, maxTop);
  }

  /// 吸附到最近的边缘：根据当前位置判断贴左还是贴右，回到吸附态。
  /// 同时记住当前 Y 坐标，下次吸附态沿用此高度，避免每次都回到固定高度。
  void _attachToEdge() {
    final screenSize = MediaQuery.sizeOf(context);
    final screenWidth = screenSize.width;
    final statusBarHeight = MediaQuery.of(context).padding.top;
    final bottomInset = MediaQuery.of(context).padding.bottom;
    final width = _actualWidth > _iconSize ? _actualWidth : _maxExpandedWidth;
    final currentX = _floatingPosition?.dx ?? (screenWidth - width);
    final maxTop = (screenSize.height - _height - bottomInset - 80)
        .clamp(statusBarHeight, double.infinity);
    final currentY = _floatingPosition?.dy ?? (statusBarHeight + 56);
    setState(() {
      _attachedRight = currentX + width / 2 > screenWidth / 2;
      // 记住当前 Y 位置，吸附态在用户拖动到的高度上贴边
      _attachedTop = currentY.clamp(statusBarHeight, maxTop);
      _expanded = false;
      _floatingPosition = null;
    });
  }

  /// 获取悬浮窗在屏幕中的矩形区域，用于判断点击是否在外部。
  Rect _currentRect(Size screenSize, double statusBarHeight, double bottomInset) {
    final width = _expanded ? _actualWidth : _iconSize;
    final height = _expanded ? _height : _iconSize;
    final maxTop = (screenSize.height - height - bottomInset - 80)
        .clamp(statusBarHeight, double.infinity);
    final maxLeft = (screenSize.width - width).clamp(0.0, double.infinity);
    final left = _expanded
        ? (_floatingPosition?.dx ?? (screenSize.width - width))
            .clamp(0.0, maxLeft)
        : (_attachedRight ? screenSize.width - _iconSize : 0.0);
    final top = _expanded
        ? (_floatingPosition?.dy ?? (statusBarHeight + 56))
            .clamp(statusBarHeight, maxTop)
        : _resolveAttachedTop(statusBarHeight, maxTop);
    return Rect.fromLTWH(left, top, width, height);
  }

  /// 处理 pointer down：记录起始位置
  void _onPointerDown(PointerDownEvent event) {
    _pointerDownPosition = event.position;
    _isDragging = false;
  }

  /// 处理 pointer move：超过阈值则标记为拖拽，更新位置
  void _onPointerMove(
    PointerMoveEvent event,
    Size screenSize,
    double statusBarHeight,
    double bottomInset,
  ) {
    if (_pointerDownPosition == null) return;
    final delta = event.position - _pointerDownPosition!;
    final width = _actualWidth;
    // 首次超过阈值，标记为拖拽
    if (!_isDragging && delta.distance > _dragThreshold) {
      _isDragging = true;
      // 吸附态开始拖拽时，先切换为浮动态
      if (!_expanded) {
        final initialLeft = _attachedRight
            ? (screenSize.width - width).clamp(0.0, double.infinity)
            : 0.0;
        // 沿用吸附态记录的 Y，避免拖拽瞬间跳到顶部固定高度
        final maxTop = (screenSize.height - _height - bottomInset - 80)
            .clamp(statusBarHeight, double.infinity);
        final initialTop = _resolveAttachedTop(statusBarHeight, maxTop);
        setState(() {
          _expanded = true;
          _floatingPosition = Offset(initialLeft, initialTop);
        });
      }
    }
    // 拖拽中：实时更新位置
    if (_isDragging) {
      final maxTop = (screenSize.height - _height - bottomInset - 80)
          .clamp(statusBarHeight, double.infinity);
      final maxLeft = (screenSize.width - width).clamp(0.0, double.infinity);
      setState(() {
        final baseDx = _floatingPosition?.dx ?? (screenSize.width - width);
        final baseDy = _floatingPosition?.dy ?? (statusBarHeight + 56);
        final newDx = (baseDx + event.delta.dx).clamp(0.0, maxLeft);
        final newDy = (baseDy + event.delta.dy)
            .clamp(statusBarHeight, maxTop);
        _floatingPosition = Offset(newDx, newDy);
      });
    }
  }

  /// 处理 pointer up：未拖拽则当作 tap 处理
  void _onPointerUp(PointerUpEvent event) {
    if (!_isDragging && _pointerDownPosition != null) {
      _handleTap();
    }
    _pointerDownPosition = null;
    _isDragging = false;
  }

  /// 处理点击行为：吸附态→展开，浮动态→进入遥控页
  void _handleTap() {
    if (_expanded) {
      _enterRemotePage();
    } else {
      final screenSize = MediaQuery.sizeOf(context);
      final screenWidth = screenSize.width;
      final statusBarHeight = MediaQuery.of(context).padding.top;
      final bottomInset = MediaQuery.of(context).padding.bottom;
      // 展开时位置基于实际宽度计算（首次展开用 _maxExpandedWidth 估算）
      final width = _actualWidth > _iconSize ? _actualWidth : _maxExpandedWidth;
      final initialLeft = _attachedRight
          ? (screenWidth - width).clamp(0.0, double.infinity)
          : 0.0;
      // 就近展开：Y 沿用吸附态记录的位置，而不是跳到顶部固定高度
      final maxTop = (screenSize.height - _height - bottomInset - 80)
          .clamp(statusBarHeight, double.infinity);
      final initialTop = _resolveAttachedTop(statusBarHeight, maxTop);
      setState(() {
        _expanded = true;
        _floatingPosition = Offset(initialLeft, initialTop);
      });
      // 浮动态宽度自适应，首次展开时 _actualWidth 还是 icon 宽度，
      // 用 _maxExpandedWidth 估算的 left 会导致悬浮窗偏离右边（跳到中间）。
      // 下一帧测量实际渲染宽度后，修正 left 使右/左边缘对齐屏幕边缘。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_expanded || _isDragging) return;
        final actualWidth = _actualWidth;
        if (actualWidth <= _iconSize) return; // 宽度尚未更新，跳过
        final correctedLeft = _attachedRight
            ? (screenWidth - actualWidth).clamp(0.0, double.infinity)
            : 0.0;
        final curPos = _floatingPosition;
        if (curPos != null) {
          setState(() {
            _floatingPosition = Offset(correctedLeft, curPos.dy);
          });
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Selector 只监听必要字段，避免 position 每 2 秒更新触发重建
    return Selector<DlnaProvider,
        ({bool isCasting, bool isPlaying, String? castTitle, String? deviceName})>(
      selector: (_, p) => (
        isCasting: p.isCasting,
        isPlaying: p.isPlaying,
        castTitle: p.castTitle,
        deviceName: p.deviceName,
      ),
      builder: (context, state, _) {
        if (!state.isCasting) {
          // 投屏结束时重置本地状态
          if (_expanded || _floatingPosition != null || _attachedTop != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                setState(() {
                  _expanded = false;
                  _floatingPosition = null;
                  _attachedTop = null;
                });
              }
            });
          }
          return const SizedBox.shrink();
        }

        final theme = Theme.of(context);
        final screenSize = MediaQuery.sizeOf(context);
        final statusBarHeight = MediaQuery.of(context).padding.top;
        final bottomInset = MediaQuery.of(context).padding.bottom;

        // 浮动态时，底层放全屏 Listener 检测外部点击 → 吸附回边缘
        // 用 deferred hit test：悬浮窗在上层优先接收事件，外部点击穿透到底层
        return Stack(
          children: [
            // 底层：仅在浮动态时显示，检测外部点击
            if (_expanded)
              Positioned.fill(
                child: Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: (event) {
                    final rect = _currentRect(screenSize, statusBarHeight, bottomInset);
                    // 点击在悬浮窗外部 → 吸附回边缘
                    if (!rect.contains(event.position)) {
                      _attachToEdge();
                    }
                  },
                ),
              ),
            // 悬浮窗本身（吸附态或浮动态）
            _buildOverlay(state, theme, screenSize, statusBarHeight, bottomInset),
          ],
        );
      },
    );
  }

  /// 构建悬浮窗本体：根据 _expanded 状态返回吸附态或浮动态。
  /// 两者共用同一个 Listener 手势处理，确保拖拽和点击一致。
  Widget _buildOverlay(
    ({bool isCasting, bool isPlaying, String? castTitle, String? deviceName}) state,
    ThemeData theme,
    Size screenSize,
    double statusBarHeight,
    double bottomInset,
  ) {
    final maxTop = (screenSize.height - _height - bottomInset - 80)
        .clamp(statusBarHeight, double.infinity);

    // 计算位置：用实际渲染宽度做边界约束，避免内容比 _maxExpandedWidth 窄时
    // 被错误限制在左半屏（clamp 上界 = screenWidth - actualWidth）
    final double left;
    final double top;
    final width = _actualWidth;

    if (_expanded) {
      final maxLeft = (screenSize.width - width).clamp(0.0, double.infinity);
      left = (_floatingPosition?.dx ?? (screenSize.width - width))
          .clamp(0.0, maxLeft);
      top = (_floatingPosition?.dy ?? (statusBarHeight + 56))
          .clamp(statusBarHeight, maxTop);
    } else {
      left = _attachedRight ? screenSize.width - _iconSize : 0.0;
      // 沿用记忆的 Y 位置，使吸附态可在不同高度停留
      top = _resolveAttachedTop(statusBarHeight, maxTop);
    }

    return Positioned(
      left: left,
      top: top,
      child: Listener(
        key: _overlayKey,
        behavior: HitTestBehavior.opaque,
        onPointerDown: _onPointerDown,
        onPointerMove: (event) => _onPointerMove(
          event, screenSize, statusBarHeight, bottomInset,
        ),
        onPointerUp: _onPointerUp,
        child: _expanded
            ? _buildFloatingContent(state, theme)
            : _buildAttachedIcon(state, theme),
      ),
    );
  }

  /// 吸附态内容：半圆形 icon
  Widget _buildAttachedIcon(
    ({bool isCasting, bool isPlaying, String? castTitle, String? deviceName}) state,
    ThemeData theme,
  ) {
    return Container(
      width: _iconSize,
      height: _iconSize,
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: _attachedRight
            ? const BorderRadius.horizontal(left: Radius.circular(_iconSize / 2))
            : const BorderRadius.horizontal(right: Radius.circular(_iconSize / 2)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Icon(
        state.isPlaying ? Icons.cast_connected : Icons.cast,
        color: theme.colorScheme.onPrimaryContainer,
        size: 24,
      ),
    );
  }

  /// 浮动态内容：完整标题，宽度根据文本自适应（最大 280）
  Widget _buildFloatingContent(
    ({bool isCasting, bool isPlaying, String? castTitle, String? deviceName}) state,
    ThemeData theme,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            state.isPlaying ? Icons.cast_connected : Icons.cast,
            color: theme.colorScheme.onPrimaryContainer,
            size: 20,
          ),
          const SizedBox(width: 8),
          // 自适应宽度：文本短则窄，长则截断，最大不超过 _maxExpandedWidth - icon - padding
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _maxExpandedWidth - 60),
            child: Text(
              state.castTitle ?? '正在投屏播放中',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
