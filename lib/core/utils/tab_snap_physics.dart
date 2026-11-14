import 'package:flutter/widgets.dart';

/// 多 tab 页面（TabBarView）手势滑动松手后的吸附弹簧。
///
/// material_ui 的 TabBarView 未传 physics 时走框架默认弹簧
/// （stiffness 100 / ratio 1.1 过阻尼），末段收敛拖到 ~0.6s；
/// 本类换用更刚的临界阻尼弹簧（stiffness 240 / ratio 1.0），
/// 末段约减半且无回弹。点 tab 切换走 animateToPage 曲线，不走此弹簧。
///
/// 用法：`TabBarView(physics: const TabSnapPhysics(), ...)`。
/// 继承 [ClampingScrollPhysics] 是为了顶替默认链（PageScrollPhysics →
/// ClampingScrollPhysics）中它的位置：material_ui 会把传入 physics
/// 作为 PageScrollPhysics 的 parent，其 [spring] 覆写即被吸附模拟取用。
class TabSnapPhysics extends ClampingScrollPhysics {
  const TabSnapPhysics({super.parent});

  @override
  TabSnapPhysics applyTo(ScrollPhysics? ancestor) =>
      TabSnapPhysics(parent: buildParent(ancestor));

  @override
  SpringDescription get spring => SpringDescription.withDampingRatio(
        mass: 0.5,
        stiffness: 240,
        ratio: 1.0,
      );
}
