// 车机模式：常驻播放器面板的外壳 + 页面级「不要显示面板」声明 mixin。
//
// 面板挂在 MaterialApp.builder 的根 Navigator **之外**（见 app.dart），
// 这是硬要求：面板要同时覆盖所有 Navigator.push 出来的二级页面。

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/car_mode_provider.dart';
import '../../providers/theme_provider.dart';
import 'car_mode_layout.dart';
import 'full_player.dart';
import 'full_player_am.dart';

/// 车机模式外壳：开启时把 [child]（整棵根 Navigator）与常驻播放器面板并排。
///
/// 关闭时**原样返回 [child]**，对既有布局零影响。
///
/// 面板与内容区之间有一根可拖动的把手（[_CarModeResizeHandle]）用于调宽度。
/// 拖动期间两侧被纯色遮罩覆盖（[_CarModeDragScrim]）且**真实内容停止渲染** ——
/// 这是本组件是 StatefulWidget 的唯一原因，缘由见 [_contentFrozen] 的注释。
class CarModePanel extends StatefulWidget {
  const CarModePanel({super.key, required this.child});

  final Widget child;

  @override
  State<CarModePanel> createState() => _CarModePanelState();
}

/// 拖动遮罩的四个阶段。用枚举而非若干 bool，避免写出
/// 「settling 与 dragging 同时为真」这类不可能状态。
enum _ScrimPhase {
  /// 未拖动，无遮罩。
  idle,

  /// 拖动中：真实内容冻结（停绘制 + 停动画），遮罩完全不透明。
  dragging,

  /// 已松手：真实内容按新宽度重建/布局，遮罩仍不透明（等绘制完成）。
  settling,

  /// 遮罩淡出中。
  fading,
}

class _CarModePanelState extends State<CarModePanel>
    with SingleTickerProviderStateMixin {
  /// 遮罩淡出用。出现是**立即**的（不淡入），否则按下时会有「先卡一下」的观感。
  ///
  /// 在 initState 里创建而不是 `late final` 懒初始化：懒初始化会让 ticker
  /// 直到首次拖动才建立，若整个生命周期都没拖过，`dispose()` 里那次访问
  /// 会「创建后立即销毁」；显式创建时序更清晰。
  late final AnimationController _scrimController;

  @override
  void initState() {
    super.initState();
    _scrimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
  }

  _ScrimPhase _phase = _ScrimPhase.idle;

  /// 拖动中的即时占比 —— **只喂给遮罩**，真实内容不吃它。
  double _dragRatio = kCarModePanelDefaultRatio;

  /// 进入拖动瞬间的占比快照 —— 拖动期间真实内容一直用它渲染，
  /// widget 参数因此保持不变，整棵子树不 rebuild。
  double _frozenRatio = kCarModePanelDefaultRatio;

  bool get _dragging => _phase != _ScrimPhase.idle;

  /// 真实内容是否处于「冻结」状态（Offstage 停绘制 + TickerMode 停动画）。
  ///
  /// **只允许在 dragging 为 true。** 写成 `_phase != idle` 会让 settling/fading
  /// 期间也吃冻结值，松手后界面永远按拖动开始时的宽度渲染 —— 表现为
  /// 「拖完松手，面板宽度没变」，是本方案最危险的写法错误。
  bool get _contentFrozen => _phase == _ScrimPhase.dragging;

  @override
  void dispose() {
    _scrimController.dispose();
    super.dispose();
  }

  void _onDragStart(double currentRatio) {
    // 可重入：settling/fading 期间用户再次按下，必须立刻回到满遮罩并终止淡出动画。
    // 否则旧动画与新拖动会抢 controller.value，表现为遮罩忽明忽暗。
    _scrimController.stop();
    _scrimController.value = 1.0;
    setState(() {
      _phase = _ScrimPhase.dragging;
      _frozenRatio = currentRatio;
      _dragRatio = currentRatio;
    });
  }

  /// 拖动增量 → 占比增量，并**立即夹取**。
  ///
  /// 用增量而非指针绝对位置：20dp 热区里手指按下点与面板分界线不重合，
  /// 按绝对位置换算会让每次起拖都向右瞬移一下（实测现象）。
  /// 增量还有个好处：即使已经顶到上下限，反向拖动仍能立刻跟手 ——
  /// 夹取发生在每次累加之后，不会攒下"虚量"。
  void _onDragDelta(double deltaX) {
    final carMode = context.read<CarModeProvider>();
    final screenWidth = MediaQuery.sizeOf(context).width;
    final next =
        _dragRatio +
        resolveCarModeRatioDelta(
          deltaX: deltaX,
          screenWidth: screenWidth,
          side: carMode.panelSide,
        );
    setState(() {
      _dragRatio = next.clamp(kCarModePanelMinRatio, kCarModePanelMaxRatio);
    });
  }

  void _onDragEnd() {
    // 落盘的是**实际生效占比**而不是 _dragRatio：窄屏上 20% 会被 196dp 物理下限
    // 托底（实际约 23%），直接存 20% 会让「存的值 ≠ 看到的宽度」，
    // 下次进来宽度与设置页滑条显示不一致。
    final screenWidth = MediaQuery.sizeOf(context).width;
    final effectiveWidth = resolveCarModePanelWidth(
      screenWidth: screenWidth,
      ratio: _dragRatio,
    );
    final effectiveRatio = screenWidth > 0
        ? effectiveWidth / screenWidth
        : _dragRatio;

    // 顺序不可调换：先落盘（provider 字段同步更新，通知在微任务里发），
    // 再解冻 —— 这样真实内容重建时读到的 panelRatio 已是终值，
    // 不会先按旧宽度渲染一帧。
    context.read<CarModeProvider>().setPanelRatio(effectiveRatio);
    setState(() => _phase = _ScrimPhase.settling);

    // 等 2 帧再淡出：第 1 帧完成新宽度的 layout + paint，第 2 帧确保已上屏。
    // 只等 1 帧多数设备也能用，但会偶发暴露半成品。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _phase != _ScrimPhase.settling) return;
        setState(() => _phase = _ScrimPhase.fading);
        _scrimController.reverse().whenComplete(() {
          if (!mounted || _phase != _ScrimPhase.fading) return;
          setState(() => _phase = _ScrimPhase.idle);
        });
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final carMode = context.watch<CarModeProvider>();
    if (!carMode.panelVisible) return widget.child;

    final mq = MediaQuery.of(context);
    final frozen = _contentFrozen;
    final isLeft = carMode.panelSide == CarModePanelSide.left;

    // 真实内容宽度：拖动中恒取冻结快照。
    // 宁可「拖动过程中面板宽度不变」，也不要逐帧重排整个播放器。
    final contentWidth = resolveCarModePanelWidth(
      screenWidth: mq.size.width,
      ratio: frozen ? _frozenRatio : carMode.panelRatio,
    );
    // 遮罩宽度：跟手。
    final previewWidth = resolveCarModePanelWidth(
      screenWidth: mq.size.width,
      ratio: _dragging ? _dragRatio : carMode.panelRatio,
    );
    final percentLabel = mq.size.width > 0
        ? '${(previewWidth / mq.size.width * 100).round()}%'
        : '${(kCarModePanelDefaultRatio * 100).round()}%';

    final panel = SizedBox(
      width: contentWidth,
      // 只覆盖 size：宽 = 面板实际宽度、高不变。
      // 面板内的响应式判定必须按「面板宽度」而不是屏幕宽度 ——
      //   * ResponsiveLayout 用 LayoutBuilder（面板实际宽 → compact）
      //   * FullPlayer._syncTabLayout 用 MediaQuery.sizeOf().width
      //   * isPadLayout 用 shortestSide
      // 三者口径不一致时，1080p 车机上 400dp 的面板会被判成宽屏：
      // tab 结构删掉封面 tab，而面板走的 compact 分支又没有左栏封面
      // → 专辑封面彻底不可达。
      //
      // padding / viewPadding / devicePixelRatio 一律保持真实值：
      // 系统栏留白与图片解码分辨率不能因为面板而改变。
      child: MediaQuery(
        data: mq.copyWith(
          size: Size(contentWidth, mq.size.height),
          // 窄容器下 1.3x 系统字号会把顶栏（音质徽章 + 睡眠药丸 + 更多）
          // 挤出溢出，面板内收紧文字缩放上限。
          textScaler: mq.textScaler.clamp(
            minScaleFactor: 1.0,
            maxScaleFactor: 1.10,
          ),
        ),
        child: const _CarModePlayerHost(),
      ),
    );

    // crossAxisAlignment: stretch 让 Row 吃满可用高度、并给 Navigator 紧约束。
    //
    // 面板与内容区**直接相邻、中间不留任何占位**。这里曾用一个
    // `SizedBox(width: hitWidth)` 给把手占位，结果是静止状态下面板右侧
    // 出现一条 20dp 的纯黑竖条（像素实测：37px @1.875x 亮度恒为 0）——
    // 占位是透明的，露出的是最底层背景。把手的 20dp 热区本来就叠在上层
    // （见下方 Positioned），根本不需要在布局里占位。
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: isLeft
          ? [panel, Expanded(child: widget.child)]
          : [Expanded(child: widget.child), panel],
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        // 真实内容：拖动中 Offstage 停绘制 + TickerMode 停动画（State 全部保留，
        // 松手后同一实例继续用，不会丢播放/歌词状态）。
        Offstage(
          offstage: frozen,
          child: TickerMode(enabled: !frozen, child: row),
        ),
        // 遮罩层：两块**无缝相邻**的纯色区域。
        // 这里刻意不留缝 —— 拖动时真实内容被 offstage，缝里什么都没有，
        // 会直接露出最底层背景，视觉上就是一条与热区同宽（20dp）的粗黑条。
        // 分区感改由叠在它上面的把手细线承担。
        if (_dragging)
          IgnorePointer(
            child: FadeTransition(
              opacity: _scrimController,
              child: _CarModeDragScrim(
                side: carMode.panelSide,
                panelWidth: previewWidth,
                percentLabel: percentLabel,
              ),
            ),
          ),
        // 把手必须同时满足两点，缺一不可：
        // 1) 在 Offstage **之外** —— 否则拖动一开始它自己就被 offstage
        //    （RenderOffstage 不参与 hit test），后续手势全丢、拖动立即中断；
        // 2) 在遮罩**之上** —— 遮罩已无缝，把手若在下面会被整块盖住。
        //    遮罩自己包了 IgnorePointer，不会抢把手的事件。
        // 热区以分界线为中心（左右各 hitWidth/2），使把手细线与面板边缘对齐。
        Positioned(
          left: (isLeft ? previewWidth : mq.size.width - previewWidth) -
              _CarModeResizeHandle.hitWidth / 2,
          top: 0,
          bottom: 0,
          width: _CarModeResizeHandle.hitWidth,
          child: _CarModeResizeHandle(
            active: _dragging,
            onDragStart: () => _onDragStart(carMode.panelRatio),
            onDragDelta: _onDragDelta,
            onDragEnd: _onDragEnd,
            onReset: () => context
                .read<CarModeProvider>()
                .setPanelRatio(kCarModePanelDefaultRatio),
          ),
        ),
      ],
    );
  }
}

/// 面板内的播放器宿主。
///
/// 必须自带一层 [Navigator]：面板在根 Navigator 之外，而 FullPlayer 内部有
/// 25+ 处 `showDialog` / `showModalBottomSheet` / `PopupMenuButton`
/// （播放列表删除确认、音质/倍速/音量弹窗、更多菜单、评论设置…）都会
/// `Navigator.of` 与 `Overlay`，没有这层会直接抛
/// "Navigator operation requested with a context that does not include a Navigator"。
///
/// 面板内的**整页跳转**（专辑 / 歌手 / MV / 歌曲信息 / 均衡器 / 音效）已由
/// [FullPlayer.dockMode] 重定向到根 Navigator —— 否则那些页面会顶掉面板内容，
/// 常驻播放器视觉上消失。
class _CarModePlayerHost extends StatelessWidget {
  const _CarModePlayerHost();

  @override
  Widget build(BuildContext context) {
    // 这层 Navigator 只创建一次：路由页复用同一个 [_CarModePlayerBody]，
    // 播放页样式（MD/AM）切换由它内部的 watch 处理，只替换播放器组件、
    // 不重建 Navigator —— 重建会让旧实例 dispose 时 stop 掉频谱服务。
    // 面板这层 Navigator 必须有**自己的** HeroController：
    // MaterialApp 通过 HeroControllerScope 把同一个 HeroController 提供给其下
    // 所有 Navigator，嵌套 Navigator 会拿到根 Navigator 已绑定的那个 →
    //   * initState 断言 `observer.navigator == null` 失败；
    //   * 由于该断言中断了 `observer._navigator = this`，后续 push 弹层时
    //     HeroController.didChangeTop 又因 navigator 为 null 而崩溃
    //     （真机复现：面板内点「更多」菜单直接抛 heroes.dart 'navigator != null'，
    //     并连带触发 navigator.dart '!_debugLocked'）。
    // 包一层独立的 HeroControllerScope 即给面板一个专属实例，两个问题同时消除。
    return HeroControllerScope(
      controller: HeroController(),
      child: Navigator(
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (_) => const _CarModePlayerBody(),
        ),
      ),
    );
  }
}

/// 二选一渲染当前播放页样式（MD / AM）。位于面板 Navigator 的某一页内部，
/// 但依赖的 Provider 在 MaterialApp 之上，所以样式开关切换时本组件会重建。
class _CarModePlayerBody extends StatelessWidget {
  const _CarModePlayerBody();

  @override
  Widget build(BuildContext context) {
    final useAm = context.watch<ThemeProvider>().useAmStylePlayer;
    return useAm
        ? const AmStyleFullPlayer(dockMode: true)
        : const FullPlayer(dockMode: true);
  }
}

/// 让页面向车机模式面板声明「我在前台时不要显示常驻播放器面板」。
///
/// 为什么用生命周期而不是路由名判定：
///   * 设置页既可以是底部 tab（此时路由恒为 `/`，路由名判不出来），
///     也可以是被 push 的二级页；
///   * 登录页不是命名路由（各调用点都是 `Navigator.push(MaterialPageRoute)`），
///     同样拿不到路由名。
/// 由页面自己在 initState / dispose 里配对声明与释放，两种形态都能覆盖。
///
/// 用法（三步，缺一不可）：
/// ```dart
/// class _FooState extends State<Foo> with CarModePanelSuppressor<Foo> {
///   @override
///   void initState() {
///     super.initState();
///     suppressCarModePanel();   // 必须在 super.initState() 之后
///   }
///
///   @override
///   void dispose() {
///     releaseCarModePanel();    // 必须在 super.dispose() 之前
///     super.dispose();
///   }
/// }
/// ```
mixin CarModePanelSuppressor<T extends StatefulWidget> on State<T> {
  // dispose 阶段已不能再依赖 context 查 Provider，抑制时把引用缓存下来
  // （与 _AppViewState 缓存 ShortcutConfigProvider 的做法一致）。
  CarModeProvider? _carModeProvider;

  /// 声明抑制。可在同一 State 上重复调用，计数成对释放。
  void suppressCarModePanel() {
    _carModeProvider = context.read<CarModeProvider>();
    _carModeProvider!.suppressPanel();
  }

  /// 释放抑制。与 [suppressCarModePanel] 成对，必须在 dispose 里调用。
  void releaseCarModePanel() {
    _carModeProvider?.releasePanel();
    _carModeProvider = null;
  }
}

/// 面板与内容区之间的宽度把手。
///
/// 热区 20dp、视觉只有 1~6dp：触摸设备上必须靠热区保证可命中，
/// 而细线视觉又与系统分屏的分隔条观感一致。
class _CarModeResizeHandle extends StatelessWidget {
  /// 热区宽度。遮罩层用它留出中间的缝，两端共用同一常量以免视觉对不齐。
  static const double hitWidth = 20.0;

  const _CarModeResizeHandle({
    required this.active,
    required this.onDragStart,
    required this.onDragDelta,
    required this.onDragEnd,
    required this.onReset,
  });

  /// 是否正在拖动（视觉加宽 + 染主色）。
  final bool active;

  final VoidCallback onDragStart;

  /// 回调参数是本次事件的**指针位移增量**；由调用方按停靠侧换算占比。
  final ValueChanged<double> onDragDelta;

  /// 松手 / 手势被打断时收尾（占比由调用方从自身状态取）。
  final VoidCallback onDragEnd;

  /// 双击复位到默认占比。
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        // opaque：20dp 热区内任何位置都能起拖，不依赖是否点在细线上
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => onDragStart(),
        // 传位移增量而非全局坐标：见 resolveCarModeRatioDelta 的说明
        // （按绝对坐标换算会让每次起拖都瞬移「按下点与分界线的差值」）。
        onHorizontalDragUpdate: (details) => onDragDelta(details.delta.dx),
        onHorizontalDragEnd: (_) => onDragEnd(),
        // 拖动被系统打断（来电 / 权限弹窗等）也必须收尾，否则会卡在遮罩态
        onHorizontalDragCancel: onDragEnd,
        onDoubleTap: onReset,
        child: SizedBox(
          width: hitWidth,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // 分隔线：**恒定 1dp 淡色**，拖动时也不加粗、不换色。
              // 拖动者的视觉锚点是下面那根 grab 条；线一加深就会被看成「黑条」。
              Center(
                child: SizedBox(
                  width: 1,
                  height: double.infinity,
                  child: ColoredBox(color: cs.outlineVariant),
                ),
              ),
              // 中部 grab 条：唯一随拖动变化的元素（略加宽 + 染主色）
              Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: active ? 5 : 3,
                  height: 28,
                  decoration: BoxDecoration(
                    color: active ? cs.primary : cs.outlineVariant,
                    borderRadius: BorderRadius.circular(2.5),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 拖动期间覆盖在两侧的纯色遮罩：**面板侧**与**主界面侧**各一块，
/// 各自中央一个圆角徽章图标 + 分区文字，中间留出把手热区的缝。
///
/// 为什么需要它：拖动期间真实内容被 offstage（看不见），若无标识，
/// 屏幕会像「白屏」；分区标识把「左边是播放器 / 右边是主界面」讲清楚，
/// 与系统分屏调整界面的做法一致。
class _CarModeDragScrim extends StatelessWidget {
  const _CarModeDragScrim({
    required this.side,
    required this.panelWidth,
    required this.percentLabel,
  });

  final CarModePanelSide side;
  final double panelWidth;

  /// 当前面板占比（如 `30%`），显示在面板侧分区标识下方。
  final String percentLabel;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    Widget block({
      required Color badgeColor,
      required Color iconColor,
      required IconData icon,
      required String label,
      String? subLabel,
    }) {
      final textTheme = Theme.of(context).textTheme;
      return ColoredBox(
        color: cs.surfaceContainerHighest,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: badgeColor,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Icon(icon, size: 30, color: iconColor),
              ),
              const SizedBox(height: 14),
              Text(
                label,
                style: textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              if (subLabel != null) ...[
                const SizedBox(height: 4),
                Text(
                  subLabel,
                  style: textTheme.labelMedium?.copyWith(color: cs.primary),
                ),
              ],
            ],
          ),
        ),
      );
    }

    // 两块遮罩**无缝相邻**：中间不留缝。留缝会露出 offstage 之后的底层背景
    // （深色主题下就是黑），看起来是一条与热区同宽（20dp）的粗黑条。
    // 分区感由叠在遮罩之上的把手细线提供。
    return Row(
      children: side == CarModePanelSide.left
          ? [
              SizedBox(
                width: panelWidth,
                child: block(
                  badgeColor: cs.primaryContainer,
                  iconColor: cs.onPrimaryContainer,
                  icon: Icons.play_circle_outline,
                  label: '播放器',
                  subLabel: percentLabel,
                ),
              ),
              Expanded(
                child: block(
                  badgeColor: cs.secondaryContainer,
                  iconColor: cs.onSecondaryContainer,
                  icon: Icons.home_outlined,
                  label: '主界面',
                ),
              ),
            ]
          : [
              Expanded(
                child: block(
                  badgeColor: cs.secondaryContainer,
                  iconColor: cs.onSecondaryContainer,
                  icon: Icons.home_outlined,
                  label: '主界面',
                ),
              ),
              SizedBox(
                width: panelWidth,
                child: block(
                  badgeColor: cs.primaryContainer,
                  iconColor: cs.onPrimaryContainer,
                  icon: Icons.play_circle_outline,
                  label: '播放器',
                  subLabel: percentLabel,
                ),
              ),
            ],
    );
  }
}
