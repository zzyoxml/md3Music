import 'package:flutter/widgets.dart';

import '../build_flags.dart';
import '../theme/motion_constants.dart';
import 'responsive_layout.dart';

/// 「文本输入正在占用焦点」的全局信号 —— 键盘是否弹出的**主判据**。
///
/// 为什么不用键盘高度：本机真机实测（小米 25102RKBEC / Android 17，讯飞 IME，
/// IME 窗口 `sim={adjust=pan}`）—— 输入法**完全弹起**的那些帧里
/// `MediaQuery.viewInsets.bottom` 与平台 `implicitView.viewInsets.bottom` **都是 0**，
/// 平台那份只在焦点切换瞬间给出 1~11 物理像素（≈ 手势条那一段，且降不回 0）。
/// 也就是本 App 在 shell 这一层根本收不到键盘高度，拿它当判据只会时灵时不灵
/// （2026-10-07 前三版都栽在这上面：误判、不收起、收了不回弹）。
///
/// 焦点态在同一份 logcat 里是唯一可靠翻转的信号：点输入框 → `primaryFocus` 从
/// 根 `FocusScope` 变成输入控件的节点；失焦 → 变回 scope。
///
/// 由 [TextInputFocusTracker] 单一持有者写（引用计数），消费方直接订阅
/// [kTextInputFocused] 即可即时收展（`ValueNotifier` 而非 `ChangeNotifier`：值变化
/// 才通知，且能在 build 里安全读取）。
final ValueNotifier<bool> kTextInputFocused = ValueNotifier<bool>(false);

/// 把焦点变化写进 [kTextInputFocused] 的全局观察者。
///
/// 首个 [attach] 者挂监听、末个 [detach] 者摘监听：本 App 里输入框到处都有，
/// 逐个控件各挂一份 `FocusManager` 监听既浪费又难对齐时序。
class TextInputFocusTracker {
  TextInputFocusTracker._();

  static int _refs = 0;

  static void attach() {
    if (_refs++ > 0) return;
    WidgetsBinding.instance.focusManager.addListener(_onChange);
    // 首次挂同步也必须延后一帧：attach 的调用点在 _ImeCollapseState.initState，
    // 即元素挂载（build 阶段）内；_sync → hasFocusedTextInput →
    // _subtreeHasEditableText 会走 visitChildElements，同步执行会抛
    // 「visitChildElements() called during build」并把元素树置成半挂载态 ——
    // 之后整场会话连锁 _dependents.isEmpty / notifyClients 断言与
    // 「此处内容加载出错」（2026-10-16 TV 版真机日志实锤，三个会话同一起因）。
    // 与 _onChange 的延后口径一致。
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  static void detach() {
    if (--_refs > 0) return;
    WidgetsBinding.instance.focusManager.removeListener(_onChange);
    kTextInputFocused.value = false;
  }

  /// 焦点变更可能发生在 build 期间（例如 autofocus 在 `didChangeDependencies` 里
  /// requestFocus），那时直接写 notifier 会连带触发消费方的 setState，报
  /// 「setState() called during build」。统一延后一帧写。
  static void _onChange() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  static void _sync() {
    final bool value = hasFocusedTextInput();
    if (value == kTextInputFocused.value) return;
    kTextInputFocused.value = value;
  }
}

/// 当前主焦点是否落在文本输入控件上。
///
/// 判据要绕开两种误判：
/// - 主焦点是 scope 自身（没人拿到焦点）—— 它的子树里当然含输入框，不能算；
/// - 焦点挂在整页级容器上（罕见）—— 向下探查限深 [kTextInputProbeDepth]，
///   只在"包住可编辑区的那层 Focus"这种几级以内的距离才认。
bool hasFocusedTextInput() {
  final FocusNode? node = FocusManager.instance.primaryFocus;
  final BuildContext? context = node?.context;
  // context.mounted 防护：路由 dispose 帧里 postFrame 回调可能拿到已失活
  // element，对它探查仍会命中 EditableText，导致 kTextInputFocused 卡在 true、
  // miniplayer 永久收没。
  if (node == null || context is! Element || !context.mounted) return false;
  if (node is FocusScopeNode) return false;
  if (context.widget is EditableText) return true;
  if (context.findAncestorWidgetOfExactType<EditableText>() != null) return true;
  return _subtreeHasEditableText(context, 0);
}

/// 向下探查 `EditableText` 的最大层数。
///
/// 仅作兜底：真机与 widget test 实测（material_ui 的 TextField，搜索页用的就是它）
/// 焦点节点挂在 `Focus` 元素上，`EditableText` 在它的**祖先链**上（相隔 11 层：
/// `Focus < _ActionsScope < Actions < UndoHistory < MouseRegion < TextFieldTapRegion
/// < Builder < _ActionsScope < Actions < _CompositionCallback < EditableText`），
/// 命中走的是上面那条不限深的祖先探查；子树里反而没有 EditableText。限深是为了
/// 不让"焦点恰好挂在整页级容器上"这种罕见形态把全页扫一遍。
const int kTextInputProbeDepth = 8;

bool _subtreeHasEditableText(Element root, int depth) {
  if (depth > kTextInputProbeDepth) return false;
  var found = false;
  root.visitChildElements((Element child) {
    if (found) return;
    if (child.widget is EditableText) {
      found = true;
      return;
    }
    if (_subtreeHasEditableText(child, depth + 1)) found = true;
  });
  return found;
}

/// 键盘（输入法）是否应当视为弹出：焦点态为主，insets 作跨设备兜底。
///
/// `MediaQuery.viewInsets` 那一路在本机恒为 0（见 [kTextInputFocused] 的实测说明），
/// 但仍保留：其它 ROM/设备上它是正确信号，且 widget test 用它注入键盘态。
/// 读数必须用 `MediaQuery.of` 全量，不要用 `MediaQuery.viewInsetsOf`——后者只登记
/// viewInsets 一个 aspect 依赖，真机上键盘弹起时该依赖不会被通知。
bool isImeVisible(BuildContext context) =>
    MediaQuery.of(context).viewInsets.bottom > 0 || kTextInputFocused.value;

/// 键盘弹出期间把子树沉底收没（高度归零、不占空间），键盘收起后原样恢复。
///
/// 用于底部播放条：键盘弹出会把播放条抬到键盘上沿、压掉一条输入页可用的列表
/// 高度，收起后那段高度让回给内容。
///
/// 收缩几何与时长/曲线跟底部导航栏的收起完全一致（`ClipRect` + 底边贴住的
/// `Align(heightFactor:)`，见 `ResponsiveScaffold._buildCompactLayout` 与
/// `_MainLayout` 的常驻条动画），三处收展看起来是同一个动作。
///
/// TV 版透传：把播放条整条移出树会连带丢掉焦点，键盘关闭后遥控用户没有落点。
class ImeCollapse extends StatefulWidget {
  const ImeCollapse({super.key, required this.child});

  final Widget child;

  @override
  State<ImeCollapse> createState() => _ImeCollapseState();
}

class _ImeCollapseState extends State<ImeCollapse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sink;
  late final CurvedAnimation _sinkCurve;
  bool _synced = false;

  @override
  void initState() {
    super.initState();
    _sink = AnimationController(
      vsync: this,
      duration: kBottomChromeToggleDuration,
    );
    // CurvedAnimation 只建一次：放进 build 会每帧给 _sink 多挂一个监听。
    _sinkCurve = CurvedAnimation(
      parent: _sink,
      curve: M3ExpressiveMotion.panelCollapseEasing,
      reverseCurve: M3ExpressiveMotion.panelExpandEasing,
    );
    TextInputFocusTracker.attach();
  }

  @override
  void dispose() {
    TextInputFocusTracker.detach();
    _sinkCurve.dispose();
    _sink.dispose();
    super.dispose();
  }

  /// 把收起动画驱动到目标态（幂等）。首个有效帧直接定到端点：应用启动时键盘
  /// 可能已经弹着，不该播一遍收起动画。
  ///
  /// **"已到目标态"必须按 value 判，不能按 `status == completed` 判**：键盘在收起
  /// 动画走完之前就关闭时，`forward` 方向的 status 既不是 completed、value 也没到 0，
  /// 用 status 判会命中"无需动作"的早退分支，而外层 build 之后不会被动画回调再触发
  /// （`AnimatedBuilder` 只重建它自己那层），于是永久卡在收没态、要切页或重启才恢复。
  ///
  /// **挂起的反向动画必须取消**：子树被不透明路由盖住时 ticker 静音，
  /// `forward/reverse` 只会停在起点且 `isAnimating` 挂起（例：设置页搜索框聚焦
  /// 发出 forward、value 仍为 0）。此时目标翻回 0 的话，若只按 value 早退，
  /// 挂起的 forward 会在 ticker 恢复（返回首页）那帧续跑到 1，把内容收没。
  void _sync({required bool visible, required bool reduceMotion}) {
    if (!mounted) return;
    final double target = visible ? 1.0 : 0.0;
    if (!_synced) {
      _synced = true;
      _sink.value = target;
      return;
    }
    final bool atTarget = (_sink.value - target).abs() < 0.001;
    if (_sink.isAnimating) {
      final bool towardTarget =
          (_sink.status == AnimationStatus.forward) == (target > 0.5);
      // 已在朝目标播（含静音期挂起的同向动画）则不干预。
      if (towardTarget && !atTarget) return;
      _sink.stop(canceled: true);
    } else if (atTarget) {
      return;
    }
    if (reduceMotion || atTarget) {
      _sink.value = target;
    } else if (visible) {
      _sink.forward();
    } else {
      _sink.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (kTvBuild) return widget.child;
    // 焦点翻转（kTextInputFocused）与 insets 变化（MediaQuery 依赖）都要能驱动
    // 本层重建：前者靠下面的 ListenableBuilder，后者靠 build 里这次全量读数。
    return ListenableBuilder(
      listenable: kTextInputFocused,
      builder: (BuildContext context, Widget? _) {
        _sync(
          visible: isImeVisible(context),
          reduceMotion: MediaQuery.disableAnimationsOf(context),
        );
        // 收展期间必须由动画自身驱动重建：`_sync` 里 forward/reverse 不会触发 build，
        // 只读一次 `_sinkCurve.value` 会让动画原地不动（与 `_MainLayout` 常驻条用
        // `AnimatedBuilder` 包 MiniPlayer 同一手法）。
        return AnimatedBuilder(
          animation: _sinkCurve,
          builder: (BuildContext context, Widget? _) {
            final double t = _sinkCurve.value;
            if (t <= 0) return widget.child;
            if (t >= 1) return const SizedBox.shrink();
            return ClipRect(
              child: Align(
                alignment: Alignment.bottomCenter,
                heightFactor: 1 - t,
                child: widget.child,
              ),
            );
          },
        );
      },
    );
  }
}
