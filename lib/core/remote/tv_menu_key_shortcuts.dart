import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// TV 遥控「菜单键」（KEYCODE_MENU=82，Flutter 侧为
/// [LogicalKeyboardKey.contextMenu]）→ 上下文动作的通用包装。
/// 仓内先例：coverflow_page.dart 用同一逻辑键接「菜单键切沉浸模式」。
///
/// 本组件**不带** kTvBuild 门控（AGENTS §12 惯例：可测组件不依赖编译期旗标，
/// 参考 tv_exit_confirm_dialog.dart）——由调用方在 kTvBuild 分支里使用；普通
/// 构建树同样编译得到，普通 flutter test 可钉住行为。
///
/// 实现为 [CallbackShortcuts]：其 Focus 不可聚焦、不参与遍历，只挂在按键
/// 传播路径上拦截菜单键；方向/OK/BACK 等其余按键原样穿透给 dpad 引擎
/// （DpadFocusable 不消费 contextMenu，事件能到达本组件）。
///
/// 焦点在哪个子树，菜单键就命中哪个实例：行级包装（SongListItem）只触发
/// 焦点所在行的动作；页面级包装（FullPlayer / AmStyleFullPlayer）焦点在
/// 页面任意位置都触发。弹层（bottom sheet / dialog 是独立路由）打开后焦点
/// 移入其路由子树，不属于页面包装的子孙，不会重复触发。
class TvMenuKeyShortcuts extends StatelessWidget {
  /// 菜单键动作；null 时等价于裸 [child]（零包装，按键穿透）。
  /// 用于「没有更多菜单」的行（每日推荐/多选模式）传 null 免接线。
  final VoidCallback? onMenu;

  final Widget child;

  const TvMenuKeyShortcuts({super.key, this.onMenu, required this.child});

  @override
  Widget build(BuildContext context) {
    final VoidCallback? handler = onMenu;
    if (handler == null) return child;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.contextMenu): handler,
      },
      child: child,
    );
  }
}
