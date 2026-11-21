import 'package:flutter/foundation.dart';
import 'package:m3_expressive/m3_expressive.dart';
import 'package:material_ui/material_ui.dart';

/// 一次可撤销的破坏性操作请求。
///
/// - [onUndo]：用户点了「撤销」——把刚才的删除恢复回来。
/// - [onConfirm]：删除最终生效（倒计时归零 / 用户点 ✕ / 宿主被卸载）。
///   「延迟提交」型删除（如远端歌单删歌）在这里才真正调用远端 API；
///   「先删后撤」型删除（如本地队列）这里通常为空操作。
class M3EUndoRequest {
  final String label;
  final VoidCallback onUndo;
  final VoidCallback onConfirm;

  const M3EUndoRequest({
    required this.label,
    required this.onUndo,
    required this.onConfirm,
  });
}

/// M3E 撤销条（m3_expressive 的 M3UndoPill）统一接入层。
///
/// 用法：把 [M3EUndoPillHost] 作为页面/面板 Stack 的直接子级放在最上层，
/// 传入页面 State 持有的 [request] ValueNotifier；删除时给 notifier 赋一个
/// 新的 [M3EUndoRequest]：
/// - 用户点「撤销」→ onUndo，撤销条消失；
/// - 倒计时归零 / 点 ✕ / 宿主从树中卸载 → onConfirm，删除最终生效；
/// - 未结算时又来了新请求 → 先结算旧请求（onConfirm），再展示新撤销条。
///
/// 注意：M3UndoPill 内部自建 Positioned（bottom = 安全区 + 16 / 32），
/// 因此本宿主必须直接位于 Stack 下，不能再包 Align/Positioned/MediaQuery。
///
/// 主题说明：m3_expressive 内部读的是 flutter/material 的 Theme，与本项目
/// 的 material_ui fork 不是同一套 InheritedWidget——因此所有颜色一律由
/// 本组件从 material_ui 侧取值后显式传入，不依赖包内默认取色。
class M3EUndoPillHost extends StatefulWidget {
  /// 页面持有的「当前待结算撤销请求」。置 null 即无撤销条。
  final ValueNotifier<M3EUndoRequest?> request;

  /// 倒计时时长（同时是用户可撤销的窗口期）。
  final Duration duration;

  /// 距屏幕/面板左右的内边距。
  final double horizontalPadding;

  const M3EUndoPillHost({
    super.key,
    required this.request,
    this.duration = const Duration(seconds: 5),
    this.horizontalPadding = 24,
  });

  @override
  State<M3EUndoPillHost> createState() => _M3EUndoPillHostState();
}

class _M3EUndoPillHostState extends State<M3EUndoPillHost> {
  M3EUndoRequest? _active;
  bool _settled = true;

  @override
  void initState() {
    super.initState();
    widget.request.addListener(_onRequestChanged);
    _active = widget.request.value;
    _settled = _active == null;
  }

  @override
  void dispose() {
    // 宿主被卸载（页面退出/面板关闭）时还有未结算的删除 → 视为确认删除，
    // 让「延迟提交」型操作的远端调用不丢。onConfirm 实现须自行保证
    // 不再触碰已卸载的 context（本适配层约定只捕获 provider/api 实例）。
    if (!_settled && _active != null) {
      _active!.onConfirm();
    }
    widget.request.removeListener(_onRequestChanged);
    super.dispose();
  }

  void _onRequestChanged() {
    final next = widget.request.value;
    if (identical(next, _active)) return;
    if (_active != null && !_settled) {
      // 新请求顶掉旧请求：旧删除先落地
      _active!.onConfirm();
    }
    setState(() {
      _active = next;
      _settled = next == null;
    });
  }

  void _settle({required bool undo}) {
    final req = _active;
    if (req == null || _settled) return;
    _settled = true;
    if (undo) {
      req.onUndo();
    } else {
      req.onConfirm();
    }
    // 通知页面清空（会再走一次 _onRequestChanged，此时 _settled 已为 true，
    // 不会重复结算）。
    if (identical(widget.request.value, req)) {
      widget.request.value = null;
    }
    setState(() {
      _active = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final req = _active;
    if (req == null) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    return M3UndoPill(
      // 请求切换时重建 pill，重置倒计时进度条
      key: ValueKey(identityHashCode(req)),
      label: req.label,
      undoLabel: '撤销',
      duration: widget.duration,
      onComplete: () => _settle(undo: false),
      onCancel: () => _settle(undo: true),
      horizontalPadding: widget.horizontalPadding,
      backgroundColor: cs.surfaceContainerLow,
      progressColor: cs.surfaceContainerHighest,
      accentColor: cs.primary,
      foregroundColor: cs.onSurface,
    );
  }
}
