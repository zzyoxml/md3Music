import 'package:flutter/widgets.dart';

import '../build_flags.dart';

/// tv: m3e 弹层（bottom sheet / dialog 路由）打开后把首焦点交给 [targetNode]。
///
/// `autofocus` 在 m3e 弹层这种复用/延迟挂载的路由里不可靠（2026-10-05 真机
/// 实测：首项拿不到焦点，焦点反而落到评分更高的末行控件上），必须在弹层
/// 挂载后显式 `requestFocus` 一次。此前该逻辑只存在于 library_page 的私有
/// `_tvEnsureSheetFocus`，各弹层各自复制易漏——扫描文件夹 / 排除文件夹
/// 管理面板、云音乐上传菜单都漏了接线，TV 上打开后遥控器无任何落点。
///
/// 用法：包在弹层内容根节点外层，[targetNode] 挂到主动作控件（首停点）上：
///
/// ```dart
/// return TvSheetFocus(
///   targetNode: _addButtonNode,
///   child: SafeArea(child: ...),
/// );
/// ```
///
/// 每 build 都会尝试挂 post-frame 回调，但内部自锁只真正请求一次；若焦点
/// 已落在弹层子树内（用户已手动移动）则不抢。非 TV 构建原样返回 [child]，
/// 触屏 / 桌面零变化。
class TvSheetFocus extends StatefulWidget {
  const TvSheetFocus({
    super.key,
    required this.targetNode,
    required this.child,
  });

  /// 首焦点落点，须挂在弹层内某个 [DpadFocusable] / 控件上。
  final FocusNode targetNode;

  final Widget child;

  @override
  State<TvSheetFocus> createState() => _TvSheetFocusState();
}

class _TvSheetFocusState extends State<TvSheetFocus> {
  /// 收工标记：焦点已落进弹层子树，或重试窗口耗尽。
  bool _settled = false;

  /// 已尝试帧数。TV 真机（2026-11-12）实测：请求帧若落在弹层转场动画中，
  /// requestFocus 会被路由完成后的焦点重建冲掉，首焦点落回页面节点（高亮
  /// 画在弹层外，OK 无反应）。故不能「只请求一次」，需在短窗口内逐帧重试，
  /// 直到 primaryFocus 真正进入弹层子树；窗口耗尽即放弃，避免无限抢焦点。
  static const int _maxTries = 45;
  int _tries = 0;

  /// 弹层路由的转场动画，build 中从 ModalRoute 缓存
  /// （dependOnInherited 查询不允许在 post-frame 回调里做）。
  Animation<double>? _routeAnimation;

  void _ensure() {
    if (!kTvBuild || _settled) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _attempt());
  }

  void _attempt() {
    if (_settled || !mounted) return;
    // 等弹层转场动画完成再抢焦点：ModalRoute 在转场期间禁止子树获焦，
    // 提前 requestFocus 会被 FocusManager 静默丢弃——低端 TV 上重试窗口
    // 会整段耗在转场里，转场一完成 dpad root 的 restore 兜底又会把焦点
    // 放回页面节点（实测：首焦点落在页面「扫描音乐」/顶部标签按钮上）。
    // 动画在 build 中缓存（ModalRoute.of 只能在 build 中查询）。
    final animation = _routeAnimation;
    if (animation != null && animation.status != AnimationStatus.completed) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _attempt());
      return;
    }
    // 「弹层内是否已有人持焦」必须按子树归属判断，不能只看
    // primaryFocus.hasFocus：弹层打开瞬间焦点从页面移交到弹层路由是
    // 异步的，此刻 primaryFocus 仍是页面里的节点（如扫描 FAB）且
    // hasFocus == true，按 hasFocus 判会把首项焦点整个吞掉。
    final primary = FocusManager.instance.primaryFocus?.context;
    if (primary != null) {
      final sheet = context as Element;
      var inside = false;
      primary.visitAncestorElements((el) {
        if (identical(el, sheet)) {
          inside = true;
          return false;
        }
        return true;
      });
      // 焦点已在弹层子树内（自然落定或用户已手动移动）：收工，不再抢。
      if (inside) {
        _settled = true;
        return;
      }
    }
    final target = widget.targetNode;
    if (target.canRequestFocus &&
        target.context != null &&
        target.context!.mounted) {
      target.requestFocus();
    }
    _tries++;
    if (_tries >= _maxTries) {
      _settled = true;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _attempt());
  }

  @override
  void didUpdateWidget(TvSheetFocus oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 弹层内容切换主动作（如目录选择器进入子目录）或同一 State 被复用到新
    // 弹层时，重新开窗口请求首焦点。
    if (oldWidget.targetNode != widget.targetNode) {
      _settled = false;
      _tries = 0;
      _ensure();
    }
  }

  @override
  Widget build(BuildContext context) {
    _routeAnimation = ModalRoute.of(context)?.animation;
    _ensure();
    return widget.child;
  }
}
