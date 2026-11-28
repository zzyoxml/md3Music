import 'package:flutter/material.dart';

/// 歌单详情页右侧 A-Z 拖动索引条（实时跟手滚动）。
///
/// 交互模型（类滚动条）：
/// - 手指在右侧上下拖动 → 按 Y 占总高的比例直接映射 ScrollController 的
///   maxScrollExtent，列表**实时跟手滚动**（连续比例，非跳转到字母）
/// - 同时在手指 Y 坐标处显示圆形放大镜气泡，内容为该比例位置对应的字母
/// - 抬手后停止滚动，列表保持当前位置
class AlphabetIndexBar extends StatefulWidget {
  const AlphabetIndexBar({
    super.key,
    required this.scrollController,
    required this.letters,
    required this.bubbleBgColor,
    required this.bubbleFgColor,
  });

  /// 歌单列表的 ScrollController，用于实时 jumpTo。
  final ScrollController scrollController;

  /// 按当前排序顺序排列的活跃字母列表（用于放大镜显示）。
  final List<String> letters;

  /// 放大镜背景色（通常取 primaryContainer）。
  final Color bubbleBgColor;

  /// 放大镜内文字色（通常取 onPrimaryContainer）。
  final Color bubbleFgColor;

  @override
  State<AlphabetIndexBar> createState() => _AlphabetIndexBarState();
}

class _AlphabetIndexBarState extends State<AlphabetIndexBar> {
  double _totalHeight = 0;

  /// 放大镜中心 Y（-1 = 不可见），跟随手指。
  double _bubbleCenterY = -1;

  String? _activeLetter;

  @override
  Widget build(BuildContext context) {
    if (widget.letters.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxHeight <= 0 ||
            !widget.scrollController.hasClients ||
            !widget.scrollController.position.hasContentDimensions) {
          return const SizedBox.shrink();
        }
        _totalHeight = constraints.maxHeight;
        final position = widget.scrollController.position;

        return Stack(
          clipBehavior: Clip.none,
          children: [
            // ── 拖动热区 ──
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => _onDrag(d.localPosition.dy, position),
              onPanStart: (d) => _onDrag(d.localPosition.dy, position),
              onPanUpdate: (d) => _onDrag(d.localPosition.dy, position),
              onTapUp: (_) => _hide(),
              onPanEnd: (_) => _hide(),
              child: Container(
                color: Colors.transparent,
                height: _totalHeight,
                width: double.infinity,
              ),
            ),

            // ── 放大镜气泡：跟随手指 Y 坐标 ──
            if (_bubbleCenterY >= 0)
              Positioned(
                right: 22,
                top: (_bubbleCenterY - 28).clamp(0.0, _totalHeight - 56),
                child: IgnorePointer(
                  child: _PreviewBubble(
                    letter: _activeLetter ?? '',
                    bgColor: widget.bubbleBgColor,
                    fgColor: widget.bubbleFgColor,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// 手指在某 Y 坐标：实时按比例滚动 + 更新放大镜内容。
  void _onDrag(double localY, ScrollPosition position) {
    if (!mounted || _totalHeight <= 0) return;
    if (!position.hasContentDimensions) return;

    // 比例映射到滚动范围
    final ratio = (localY / _totalHeight).clamp(0.0, 1.0);
    final target = ratio * position.maxScrollExtent;
    position.jumpTo(target);

    // 对应字母：按比例在活跃字母列表里取
    final idx =
        (ratio * widget.letters.length).floor().clamp(0, widget.letters.length - 1);

    setState(() {
      _activeLetter = widget.letters[idx];
      _bubbleCenterY = localY;
    });
  }

  void _hide() {
    if (mounted && (_activeLetter != null || _bubbleCenterY >= 0)) {
      setState(() {
        _activeLetter = null;
        _bubbleCenterY = -1;
      });
    }
  }
}

/// 放大镜气泡：圆形指示器，显示当前字母，带淡入动画。
class _PreviewBubble extends StatelessWidget {
  const _PreviewBubble({
    required this.letter,
    required this.bgColor,
    required this.fgColor,
  });

  final String letter;
  final Color bgColor;
  final Color fgColor;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      builder: (context, value, _) {
        return Opacity(
          opacity: value,
          child: Container(
            width: 56 * value + 4,
            height: 56 * value + 4,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: bgColor,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2 * value),
                  blurRadius: 12 * value,
                  offset: Offset(0, 4 * value),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Text(
              letter,
              style: TextStyle(
                fontSize: 22 * value,
                fontWeight: FontWeight.bold,
                color: fgColor,
              ),
            ),
          ),
        );
      },
    );
  }
}