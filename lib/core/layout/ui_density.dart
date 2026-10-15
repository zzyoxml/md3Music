import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

/// 「显示大小」全局缩放：语义等同安卓系统设置里的「显示大小」。
///
/// **两条互不相干的轴**（别把它们混成一个）：
/// 1. 显示大小（本文件 + 设置页滑块）：改变**有效密度**。逻辑视口 ÷ s、
///    devicePixelRatio × s，再由一层 [FittedBox] 把设计像素映射回物理屏。
///    字、图标、封面、间距、圆角、安全区**同比**变化，而可用逻辑区同步缩小
///    —— 所以放大只是"一屏装得少一点"，不会溢出。
/// 2. 系统字体大小（[MediaQueryData.textScaler]）：只影响文字，
///    在 [DisplayScaleScope] 里限幅到 [kMaxSystemTextScale]。
///
/// **DPI 适配不在这里**：Flutter 的逻辑像素（dp）本身就是 DPI 无关的，
/// 页面尺寸一律直接写 dp 设计 token（封面 52、导航栏 44、侧栏 34…），
/// 屏幕差异交给断点（[getScreenType]）、可用空间（LayoutBuilder）与
/// WindowInsets（SafeArea）。默认 1.0 档就是设备真实 dp，零干预。
///
/// 历史：本文件替代了已删除的 `core/utils/ui_scale.dart`。那套实现把
/// textScaler 当通用缩放通道、再在两百多处调用点手工乘尺寸，元素被乘大而
/// 可用逻辑尺寸不变，放大必然破版。**不要再引入逐元素缩放的辅助函数。**

/// 显示大小档位下限（与安卓「显示大小」最小档一致）。
const double kMinDisplayScale = 0.85;

/// 显示大小档位上限。
const double kMaxDisplayScale = 5.0;

/// 默认档位：设备真实 dp，不做任何变换。
const double kDefaultDisplayScale = 1.0;

/// 系统「字体大小」的跟随上限。
///
/// 只压上限、下限钉在 1.0：系统调大时 App 跟随（最多 1.3x），调小时不跟随
/// —— 想让整体变小用显示大小滑块，那条路径不会让容器装不下文字。
const double kMaxSystemTextScale = 1.30;

/// 把 [base] 换算到"设计像素"坐标系：逻辑尺寸 ÷ [scale]，密度 × [scale]。
///
/// 守恒量：`size × devicePixelRatio` 不变，恒等于真实物理像素。
/// 所以 `core/widgets/app_background.dart` 那种"宽 × dpr = 解码宽度"的算法
/// 不需要任何改动就仍然正确。
///
/// 缩放的字段与理由：
/// - [MediaQueryData.size]：可用逻辑区变小 → 内容装得少，这是"显示大小"的本质。
/// - [MediaQueryData.padding] / [MediaQueryData.viewPadding] /
///   [MediaQueryData.viewInsets] / [MediaQueryData.systemGestureInsets]：
///   状态栏、底部小横条、键盘占的是**固定物理高度**（我们并没有真的改系统密度），
///   所以在设计像素里要 ÷ s 才能恰好留出那块物理区域。不除会多留 s 倍。
/// - [MediaQueryData.displayFeatures]：折叠屏铰链区，`DisplayFeatureSubScreen`
///   （对话框/弹出菜单避让）要用，bounds 同属逻辑坐标。
///
/// **刻意不缩放**的字段：
/// - [MediaQueryData.gestureSettings]：touchSlop 是 dp 语义，物理滑动阈值
///   随密度一起变大才与原生一致（原生改显示大小时 slop 的 dp 值不变）。
/// - [MediaQueryData.textScaler] 与 lineHeight/letterSpacing 等文字覆盖项：
///   属于轴 2，由 [DisplayScaleScope] 单独处理。
/// - `displayCornerRadii`：[MediaQueryData.copyWith] 未暴露该参数（会原样透传），
///   要缩放它就得手写完整构造函数、每次 SDK 加字段都会漏。本项目没有任何地方
///   读它，因此接受原样透传。
MediaQueryData applyDisplayScale(MediaQueryData base, double scale) {
  if (scale == kDefaultDisplayScale) return base;
  return base.copyWith(
    size: base.size / scale,
    devicePixelRatio: base.devicePixelRatio * scale,
    padding: base.padding / scale,
    viewPadding: base.viewPadding / scale,
    viewInsets: base.viewInsets / scale,
    systemGestureInsets: base.systemGestureInsets / scale,
    displayFeatures: base.displayFeatures.isEmpty
        ? base.displayFeatures
        : [
            for (final feature in base.displayFeatures)
              ui.DisplayFeature(
                bounds: Rect.fromLTRB(
                  feature.bounds.left / scale,
                  feature.bounds.top / scale,
                  feature.bounds.right / scale,
                  feature.bounds.bottom / scale,
                ),
                type: feature.type,
                state: feature.state,
              ),
          ],
  );
}

/// 全局「显示大小」作用域：整个 App 的唯一缩放点。
///
/// 挂在 `MaterialApp.builder` 的最外层，所以背景层、Navigator（含全部路由）、
/// Overlay（对话框 / 底部弹层 / 菜单 / Tooltip）、DLNA 覆盖层、拖拽覆盖层
/// 全在作用域内 —— 天然全局通用，页面侧零调用点。
class DisplayScaleScope extends StatelessWidget {
  const DisplayScaleScope({
    super.key,
    required this.scale,
    required this.child,
  });

  /// 显示大小档位，取值 [kMinDisplayScale] ~ [kMaxDisplayScale]。
  final double scale;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    // 用 FittedBox 而非 Transform.scale：外层是紧约束（= 物理逻辑尺寸），
    // Transform 不改自身尺寸，里面的 SizedBox 会被紧约束吃掉、拿不到设计尺寸。
    // RenderFittedBox 反过来用无界约束给子级布局（SizedBox 立刻收紧成设计
    // 尺寸），自身取父级紧约束，两轴同比故 BoxFit.fill 无形变；命中测试与
    // 语义矩形由 RenderFittedBox.hitTestChildren + applyPaintTransform 反变换。
    //
    // scale == 1.0 时也保留 FittedBox / SizedBox 这两层（identity 变换）：
    // 若按档位短路成 `return child`，拖动滑块跨过 1.00 会改变元素树结构，
    // Navigator 整棵重建、路由栈与页面状态全丢。
    return MediaQuery(
      data: applyDisplayScale(mq, scale).copyWith(
        textScaler: mq.textScaler.clamp(
          minScaleFactor: 1.0,
          maxScaleFactor: kMaxSystemTextScale,
        ),
      ),
      child: FittedBox(
        fit: BoxFit.fill,
        child: SizedBox(
          width: mq.size.width / scale,
          height: mq.size.height / scale,
          child: DisplayScaleAnchor(child: child),
        ),
      ),
    );
  }
}

/// 设计像素空间的参照锚点（纯坐标参照，无任何绘制/布局行为）。
///
/// [DisplayScaleScope] 的 FittedBox 把整棵子树缩放输出到窗口；挂在
/// SizedBox 之下的本锚点所在坐标系 = **设计像素**。需要跨组件对齐矩形的
/// 测量方（封面形变探针、MiniPlayer 顶端）一律变换到锚点而非 RenderView
/// 根——否则 s≠1 时量得窗口像素、画进设计空间，偏 s 倍。
/// scale == 1.0 时锚点空间 ≡ 根空间，行为不变。
class _RenderDisplayScaleAnchor extends RenderProxyBox {}

class _DisplayScaleAnchorBox extends SingleChildRenderObjectWidget {
  const _DisplayScaleAnchorBox({super.key, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderDisplayScaleAnchor();
}

/// 向 [DisplayScaleScope] 后代暴露设计像素锚点的组件。
///
/// 首帧 build 时子树 RenderObject 尚未 mount，post-frame 拿到锚点后 setState
/// 触发第二帧：[DisplayScaleReference] 带上锚点重建子树，探针的
/// updateRenderObject 随之收到。转场消费远晚于两帧，无视觉影响。
///
/// 与 [DisplayScaleScope] 的 FittedBox / SizedBox 同理**不按档位短路**：
/// scale == 1.0 时同样挂锚点（identity 变换），跨过 1.00 档不改变元素树结构。
class DisplayScaleAnchor extends StatefulWidget {
  const DisplayScaleAnchor({super.key, required this.child});

  final Widget child;

  @override
  State<DisplayScaleAnchor> createState() => _DisplayScaleAnchorState();
}

class _DisplayScaleAnchorState extends State<DisplayScaleAnchor> {
  final GlobalKey _anchorKey = GlobalKey();
  RenderObject? _anchor;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ro = _anchorKey.currentContext?.findRenderObject();
      if (!identical(ro, _anchor)) setState(() => _anchor = ro);
    });
  }

  @override
  Widget build(BuildContext context) {
    return _DisplayScaleAnchorBox(
      key: _anchorKey,
      child: _anchor == null
          ? widget.child
          : DisplayScaleReference(anchor: _anchor!, child: widget.child),
    );
  }
}

/// 向后代暴露 [DisplayScaleAnchor] 的 RenderObject（设计像素锚点）。
///
/// 只读；锚点实例变化（理论不发生，GlobalKey 跨帧稳定）才触发重建。
class DisplayScaleReference extends InheritedWidget {
  const DisplayScaleReference({
    super.key,
    required this.anchor,
    required super.child,
  });

  final RenderObject anchor;

  /// 最近的设计像素锚点；不在 [DisplayScaleScope] 内时为 null
  /// （调用方回退 RenderView 根空间，与修复前行为逐位一致）。
  static RenderObject? anchorOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<DisplayScaleReference>()
      ?.anchor;

  @override
  bool updateShouldNotify(covariant DisplayScaleReference oldWidget) =>
      anchor != oldWidget.anchor;
}
