import 'package:flutter/rendering.dart' show OverflowBoxFit;
import 'package:material_ui/material_ui.dart';

import '../../widgets/player_artwork_image.dart';
import 'full_player_route.dart';
import 'player_cover_morph.dart';
import 'player_cover_shadow.dart';

/// 画在 **Navigator 之上**的封面形变层（挂在 `app.dart` 的 Stack 里，
/// 紧跟 [PlayerDragOverlay]）。
///
/// 为什么必须提到页面之外：播放页整体在路由里跟着手指上下平移，封面若留在
/// 页面内就会被页面的变换拖着走，做不到"同一个封面在飞"——那正是 Flutter
/// [Hero] 把 hero 渲染进 Overlay 的原因。这里自己实现而不用 `Hero`，是为了
/// 复用本项目已有的 `playerExpansion` 曲线（跟手 / easeOutCubic / expressive
/// 三种进入路径共用一个进度）、复用两端的圆角与占位参数，并让 MD 与 AM
/// 两个播放器共用同一套登记簿。
///
/// **驱动方式必须是 `AnimatedBuilder(animation: playerExpansion)`，别动。**
///
/// 真机实测（本 SDK / 本位置）三种驱动只有这一种逐帧正常：
/// - ✅ `AnimatedBuilder(animation: playerExpansion)` —— 逐帧正常，形变正常；
/// - ❌ `ListenableBuilder(listenable: Listenable.merge([...]))` —— 不重建；
/// - ❌ `AnimatedBuilder(animation: Listenable.merge([...]))` —— 同样不重建；
/// - ❌ 本 widget 自己 `State` 里 `addListener` + `setState` —— 调用上千次，
///   `build` 只在启动时跑过一次。
///
/// 症状都一样：`build` 只执行一次，形变层一帧都不画；而播放页的真封面此时
/// 已被 `PlayerCoverSlot` 让位隐藏，于是整段转场封面凭空消失。
/// **`Listenable.merge` 在这里是个坑，已实测两次，不要再用。**
///
/// 代价：端点矩形在「转场之外」变化（转屏 / 切歌导致 `revision` 自增）时
/// 形变层不会立刻重建。但这不影响观感——转场之外 `playerExpansion` 恒为 0 或 1，
/// `_buildLayer` 本来就返回 `SizedBox.shrink()`；下一次转场开始时
/// `playerExpansion` 变化会把它带起来，且探针是逐帧 paint 上报的，届时矩形
/// 已是最新值。
class PlayerCoverMorphLayer extends StatelessWidget {
  const PlayerCoverMorphLayer({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: playerExpansion,
      builder: (context, _) => _buildLayer(context),
    );
  }

  Widget _buildLayer(BuildContext context) {
    final bus = PlayerCoverMorphBus.instance;
    // 系统「减弱动态效果」：写进登记簿，由 willDraw / textWillDraw 一并关闭形变。
    // 绘制侧与两端槽位的让位侧读的是同一组判据，所以形变关掉的瞬间不会出现
    // 「形变层不画 + 真实封面仍隐藏」的空洞。跟手拖拽本身不降级——playerExpansion
    // 由路由照常写入，减弱动画下它只会更快地落到 0 / 1 端点。
    bus.reducedMotion = MediaQuery.disableAnimationsOf(context);
    final expansion = playerExpansion.value;
    // 两端不画：p=0 归 MiniPlayer 自己的封面，p=1 归播放页自己的封面。
    // 由形变层交接正是为了避免"整页淡出 + 重新淡入"造成的闪断。
    if (expansion <= 0.0 || expansion >= 1.0) {
      // 端点必须**由形变层**复位锁存：p=0 时没有任何槽位存活（MiniPlayer 独显），
      // 槽位侧的 `resolveCoverEligible` 根本不会被调用；不复位的话上一程锁存的
      // 「不合格」会泄漏到下一程 —— 表现为「第一次可以，收起后再拉就不行」。
      bus.latchedCoverEligible = null;
      bus.latchedTextEligible = null;
      // 转场收口：打一行计数器摘要（随后清零），并把线程归因那一行留在尾窗后打印。
      // 判据关闭时整段不取仪表单例（`instance` 是静态字段，取了就把仪表建起来）。
      if (coverMorphPerfLogEnabled) {
        coverMorphDebugLogFlight(bus);
        CoverMorphFrameTrace.instance.closeFlight();
      }
      return const SizedBox.shrink();
    }
    // 过了端点早退即视为「本帧形变层真的在为转场产出内容」——端点帧不计数。
    coverMorphDebugCountLayerBuild();
    // 同时给线程归因探针记一帧（UI build / Raster 时长由 FrameTiming 提供）。
    // 段身份也在这里落：`playerDragActive` 为真 = 拖拽起飞，否则点按起飞。
    if (coverMorphPerfLogEnabled) {
      CoverMorphFrameTrace.instance.noteFlightFrame(
        progress: expansion,
        drag: playerDragActive.value,
      );
    }
    // 端点矩形缺失、或尺寸为 0 时不画：否则 scale 会除出 NaN / Infinity，
    // 让整个 Transform 失效（表现为封面凭空消失）。
    // 判据与 [PlayerCoverSlot] 的让位条件同源，两者不可能打架。
    //
    // 封面与文字各自独立判断：资格是同一个锁存值，所以正常情况下要么都画、
    // 要么都不画；独立判断只是为了在某一侧端点矩形暂时缺失时，另一侧仍能正常画。
    final t = coverMorphT(expansion);
    // 本帧形变层的真实产出（含文字侧整套重配）计入 `layer` 热点。
    // 判据关闭时直接调 `_buildFlightContent`：热点包装要收一个闭包，
    // 而形变层在转场期每帧都重建，release 不该为仪表每帧分配闭包。
    if (coverMorphPerfLogEnabled) {
      return coverMorphHot<Widget>('layer', () => _buildFlightContent(bus, t));
    }
    return _buildFlightContent(bus, t);
  }

  Widget _buildFlightContent(PlayerCoverMorphBus bus, double t) {
    // 封面一侧改读 coverLayerWillDraw：写真生效时不飞封面（文字照旧）。
    final cover = bus.coverLayerWillDraw
        ? _MorphCoverFlight(t: t)
        : const SizedBox.shrink();
    final text = bus.textWillDraw ? _buildText(t) : const SizedBox.shrink();
    if (!bus.coverLayerWillDraw && !bus.textWillDraw) {
      return const SizedBox.shrink();
    }
    return Positioned.fill(
      child: IgnorePointer(
        // 拖拽期间形变层绝不能吃掉指针：手势还在下层 MiniPlayer 的 Listener 上。
        child: Stack(
          children: [cover, text],
        ),
      ),
    );
  }

  /// 歌曲名 + 歌手文字块。
  ///
  /// **不做整体缩放**：迷你条与播放页的「文字/封面尺寸比」根本不同
  /// （14px/44px ≈ 0.32 vs 24px/300px ≈ 0.08），同一个缩放系数不可能同时对上
  /// 两端，硬缩放还会把放大那一侧糊掉。改为：
  /// - **矩形**用 [coverMorphTargetRect] 插值（与封面同一套位置曲线，两者同拍）；
  /// - **样式**用 [coverMorphLerpTextStyle] 插值字号/字重/字距/行高（进度按
  ///   [kCoverMorphTextSteps] 档走，见其说明），文字始终按真实字号绘制；
  /// - **内容**只在中段做交叉淡入（迷你条是 `歌名/歌手`，播放页是
  ///   `歌名全大写 / 歌手 · 专辑`，样式插值覆盖不到）。
  /// 于是 t=0 与真实迷你文字逐像素一致、t=1 与真实标题一致，全程清晰。
  Widget _buildText(double t) {
    final bus = PlayerCoverMorphBus.instance;
    final rect = coverMorphTargetRect(
      mini: bus.miniTextRect!,
      settled: bus.settledTextRect!,
      t: t,
    );
    final titleStyle = coverMorphLerpTextStyle(
      bus.miniTitleStyle,
      bus.fullTitleStyle,
      t,
    );
    final subtitleStyle = coverMorphLerpTextStyle(
      bus.miniSubtitleStyle,
      bus.fullSubtitleStyle,
      t,
    );
    // 内容交叉淡入放在中段：两端各自纯净，中段错开时也看不出重影
    final cf = ((t - 0.35) / 0.30).clamp(0.0, 1.0);
    // 水平对齐也插值：迷你条「块内左对齐」→ 播放页竖屏「块内居中」/ 横屏左对齐。
    final align = Alignment.lerp(Alignment.centerLeft, bus.fullTitleAlign, t)!;
    // 只给 left/top/width，**不给高度**。
    // 用 `Positioned.fromRect` 会把插值出来的矩形高度当作**紧约束**，而内容高度
    // 是按字号插值独立变化的：飞行途中「内容高于盒子」时 RenderFlex 直接报
    // bottom overflowed。宽度必须给（要按矩形宽度裁切），高度交给内容自撑。
    // 宽度本身**保持逐帧连续**：两行的排版宽度已经是无界的（见 `_buildTextLine`），
    // 再量化它只会让居中的文字每 2dp 抖一下，换不到任何性能。
    return Positioned(
      left: rect.left,
      top: rect.top,
      width: rect.width,
      // 阶段归因（仪表 v3）：两套 TextStyle.lerp 逐帧改字号/字重/字距，文字每帧都要
      // 重新排版——这笔钱在 build 阶段的任何构造热点里都量不到，只在 layout 里。
      child: CoverMorphPhaseProbe(
        layoutKey: 'textLayout',
        paintKey: 'textPaint',
        child: IgnorePointer(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            // **stretch 而不是 start**：真实播放页标题块是 `Column(crossAxisAlignment:
            // center)`（竖屏，标题在块内居中）或 `stretch`（横屏，标题左对齐），
            // 而迷你条是 start（左对齐）。若这里固定用 start，标题（通常比副标题窄）
            // 在播放页那侧会比真实位置偏左 `(块宽 − 标题宽)/2` —— 松手交接瞬间跳一下。
            // 改成 stretch 让每行占满矩形宽度、由每行自己的 `Align` 决定横向位置，
            // 两端就都能与真实排版严格重合。
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildTextLine(
                bus.miniTitleText ?? '',
                bus.fullTitleText ?? '',
                titleStyle,
                cf,
                align,
              ),
              // 迷你条两行之间没有间距、播放页是 2：按进度插值，两端都不跳
              SizedBox(height: 2 * t),
              _buildTextLine(
                bus.miniSubtitleText ?? '',
                bus.fullSubtitleText ?? '',
                subtitleStyle,
                cf,
                align,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 单行文字的内容过渡：迷你条内容 → 播放页内容。
  ///
  /// **不做两串交叉淡入**。真机踩过的坑：
  /// - 标题那行两串其实**完全相同**（迷你条 `歌名`、播放页 `歌名.toUpperCase()`，
  ///   中文大小写不变），所以交叉淡入看不出问题；
  /// - 副标题两串**真的不同**（`歌手` → `歌手 · 专辑`），交叉淡入就是两串字叠在
  ///   一起显影 —— 读起来是"新旧交叉"，而且更宽的那串主导视觉、看着像被挤到中间。
  ///
  /// 因此改为按内容差分成两种处理：
  /// 1. **追加后缀**（`歌手` → `歌手 · 专辑`）：让多出来的后缀自己淡入。
  ///    读起来是一句话在生长，既不叠字也不会跳。
  ///    后缀**全程留在树上**（用 `Opacity` 控可见度），增删会改变 `Row` 宽度、
  ///    而外层按插值对齐摆位，宽度一变整块文字就横向跳一下。
  /// 2. **内容重排**（例如英文歌名的大小写变化）：两串无公共前缀关系，直接硬切。
  ///    硬切只有一帧、不留残影，比叠字可接受得多。
  Widget _buildTextLine(
    String miniText,
    String fullText,
    TextStyle? style,
    double cf,
    Alignment align,
  ) {
    final isAppend =
        fullText.length > miniText.length && fullText.startsWith(miniText);
    if (!isAppend) {
      // 内容重排（例如英文歌名的大小写变化）：两串无公共前缀关系，硬切。
      // 硬切只有一帧、不留残影，比叠字可接受得多。
      //
      // **为什么这里也要 ClipRect + 无界 OverflowBox**（第五轮治 `textLayout`）：
      // 中文标题的两串通常是**同一个串**（`fullText == miniText`，长度相等就判不进
      // append 分支），所以绝大多数转场里两行都走这一支。原先用 `Align + ellipsis`，
      // 文字拿到的是**逐帧插值出来的紧约束块宽** → `RenderParagraph` 每帧按新宽度
      // 重新排版一次，这正是真机 `textLayout avg 3~5.6ms、n = 帧数` 的那笔钱。
      // 改成与下面 append 分支同源的无界排版后，段落的排版键里不再有块宽，
      // 只有样式档位变化那一几帧才真的重排；超出的部分由 `ClipRect` 裁掉。
      // 不画省略号与既有口径一致（`GentleScrollingText` 从不打省略号，
      // 「飞行途中冒出 …、松手又消失」才是要避免的穿帮）。
      return ClipRect(
        child: OverflowBox(
          alignment: align,
          fit: OverflowBoxFit.deferToChild,
          minWidth: 0,
          maxWidth: double.infinity,
          minHeight: 0,
          maxHeight: double.infinity,
          child: Text(
            cf < 0.5 ? miniText : fullText,
            maxLines: 1,
            softWrap: false,
            style: style,
          ),
        ),
      );
    }

    final tail = fullText.substring(miniText.length);
    return ClipRect(
      // ClipRect + OverflowBox(deferToChild)：让文字**允许比盒子宽**，超长时
      // 由裁切处理，而不是打省略号。
      // 为什么不用省略号：真实播放页用的是 GentleScrollingText（滚动展示完整
      // 内容），形变层若打省略号就会出现「飞行途中冒出一串 …，松手又消失」的
      // 突兀变化。裁切至少与滚动视口一致地始终展示串首。
      // 注意 min/max 必须显式给：本 SDK 的 OverflowBox 这四个参数默认是 null
      // （含义 = 沿用父约束），不写就拿不到无界约束、文字仍会被压到省略。
      child: OverflowBox(
        alignment: align,
        fit: OverflowBoxFit.deferToChild,
        minWidth: 0,
        maxWidth: double.infinity,
        minHeight: 0,
        maxHeight: double.infinity,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 前缀**不加 Flexible**：加了它会与后缀平分宽度（曾把后缀限死在
            // 盒子宽度的一半，长专辑名必然省略号）。
            Text(miniText, maxLines: 1, softWrap: false, style: style),
            // 后缀按**宽度**揭开，而不是淡入：
            // `widthFactor: cf` 让 cf=0 时宽度为 0 —— 既不占位（否则会把前缀
            // 挤短），也不改变可见内容；随进度平滑长出来，读起来是一句话在生长。
            ClipRect(
              child: Align(
                alignment: Alignment.centerLeft,
                widthFactor: cf,
                child: Text(tail, maxLines: 1, softWrap: false, style: style),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 飞行中的封面本体：把 settled 尺寸的方盒子整体搬到 target 的中心、缩放 scale、
/// 绕自身中心转 tilt，并带上随形变进度淡入淡出的投影。
///
/// **为什么是 StatefulWidget 而不是形变层里的私有方法**：封面本体
/// （[PlayerArtworkImage]）的全部入参都取自登记簿，在一次转场内是常量，而形变层
/// 被 `playerExpansion` 逐帧驱动、整棵子树每帧重配。本组件把封面本体 memo 成
/// **同一个 Widget 实例**：Flutter 在同一槽位收到同一个实例时直接跳过整棵子树的
/// update，于是飞行途中不再逐帧重配图片、那张 settled 全尺寸位图也不再逐帧重栅格化。
/// 外层随 t 变的东西（矩阵、局部圆角、阴影强度）照旧逐帧现算，几何与观感不变。
///
/// memo 的失效判据见 [_ArtworkSignature]：登记簿里被封面本体读到的字段一个都不能漏，
/// 否则转场中途切歌会飞着上一首的封面。
///
/// **首帧必然新鲜**：形变层在 `p <= 0 || p >= 1` 早退返回 `SizedBox.shrink()`，
/// 飞行子树只在 (0,1) 存活 ⇒ 每次转场都是新建的本组件、memo 为空，不存在「拿上一程
/// 的图起飞」。`dispose` 里显式清空只是卫生措施，顺带让缓存随本 State 一起释放。
class _MorphCoverFlight extends StatefulWidget {
  const _MorphCoverFlight({required this.t});

  final double t;

  @override
  State<_MorphCoverFlight> createState() => _MorphCoverFlightState();
}

class _MorphCoverFlightState extends State<_MorphCoverFlight> {
  Object? _signature;
  Widget? _artwork;

  @override
  void dispose() {
    _artwork = null;
    _signature = null;
    super.dispose();
  }

  /// 封面本体：签名未变就复用同一实例，变了才现造。
  ///
  /// `RepaintBoundary` **只包住图片本体**，不包圆角与阴影：`markNeedsPaint` 沿祖先链
  /// 上溯到最近的 repaint boundary 才停下，而 `ClipRRect` 的半径是逐帧变的——若把
  /// 「阴影 + 圆角 + 图片」整块圈进同一个 boundary，每帧都会因圆角标脏而整块重录，
  /// 连两层模糊和图片一起重画，boundary 退化成纯开销。只圈图片时，每帧重录的只有
  /// 外层变换与裁剪，图片那层的已栅格化纹理被直接引用。
  Widget _artworkFor(PlayerCoverMorphBus bus) {
    final signature = _ArtworkSignature(
      bus.artworkUri,
      bus.fallbackFilePath,
      bus.iconSize,
      bus.placeholderColor,
    );
    final cached = _artwork;
    if (cached != null && _signature == signature) return cached;
    coverMorphDebugCountArtworkBuild();
    final artwork = RepaintBoundary(
      child: PlayerArtworkImage(
        artworkUri: bus.artworkUri,
        fallbackFilePath: bus.fallbackFilePath,
        fit: BoxFit.cover,
        iconSize: bus.iconSize,
        backgroundColor: bus.placeholderColor,
      ),
    );
    _signature = signature;
    _artwork = artwork;
    return artwork;
  }

  /// 封面本体 + 随形变进度淡入淡出的投影。
  ///
  /// 投影原先只在两端由真实封面画（`PlayerCoverShadow.wrap`）：形变期间槽位
  /// `Opacity(0)` 隐藏真实封面，阴影跟着瞬间消失；交接回来又瞬间出现——
  /// 展开/收起时看着是"啪"地一下。改为形变层代画：规格与真实封面**同一份**
  /// （[PlayerCoverShadow.decoration]，side 取同一视觉边长、圆角取同一插值
  /// 局部圆角），只有 intensity 乘形变进度——迷你端无阴影（t=0 不画），
  /// 全屏端淡入到与真实封面等强，两端交接处左右两份阴影等价，无感换手。
  Widget _shadowedArtwork(
    PlayerCoverMorphBus bus,
    double t,
    double scale,
    Rect settled,
  ) {
    final artwork = ClipRRect(
      // 局部半径 = 屏幕圆角 / scale，保证两端与真实封面严格对齐
      borderRadius: BorderRadius.circular(coverMorphLocalRadius(t, scale)),
      child: _artworkFor(bus),
    );
    final shadowColor = bus.shadowColor;
    if (shadowColor == null) return artwork;
    return DecoratedBox(
      // side 用视觉盒边长（暂停态 0.85 已计入）：settledScale=1 时与真实阴影
      // 的取径完全一致；暂停交接下模糊/扩散的上下限钳制会差出零点几到几个
      // 像素（真实阴影先钳制再被 0.85 缩放），弥散影上不可辨。
      decoration: PlayerCoverShadow.decoration(
        shadowColor: shadowColor,
        side: settled.width,
        radius: coverMorphLocalRadius(t, scale),
        intensity: kCoverShadowIntensity.value * t,
      ),
      child: artwork,
    );
  }

  /// 计时壳：飞行封面本帧的矩阵 / 局部圆角 / 阴影构造计入 `cover` 热点。
  /// 本体还是下面那个方法，逐帧几何算式一字未动。
  // 判据关闭时直接 `_buildFlightFrame()`：tear-off 本身也是一次闭包分配，
  // 而这个组件在转场期每帧 build。
  @override
  Widget build(BuildContext context) => coverMorphPerfLogEnabled
      ? coverMorphHot<Widget>('cover', _buildFlightFrame)
      : _buildFlightFrame();

  Widget _buildFlightFrame() {
    final bus = PlayerCoverMorphBus.instance;
    // 本帧形变进度由父级形变层逐帧传入（原来是 `_buildCover(double t)` 的形参，
    // 搬进 State 后从 widget 取，下面的几何算式一字未改）。
    final t = widget.t;
    final settledLayout = bus.settledRect!;
    final mini = bus.miniRect!;
    // 终点用**真实屏幕矩形**（暂停态 0.85 已计入），否则松手那帧真实封面会
    // 从满尺寸动画缩到 0.85 —— 就是「松手后还有个缩放动画」的来源。
    final settled = coverSettledVisualRect(
      layout: settledLayout,
      scale: bus.settledArtworkScale,
      anchor: bus.settledArtworkAnchor,
    );
    final target = coverMorphTargetRect(mini: mini, settled: settled, t: t);
    // 两端都是正方形（MiniPlayer 固定 44×44，播放页是 AspectRatio(1)），
    // 故用单标量缩放。
    final scale = target.width / settled.width;

    // 把 settled 尺寸的方盒子整体搬到 target 的中心、缩放 scale、绕自身中心
    // 转 tilt；等价于 m = T(target.center)·Rz·S·T(-size/2)，局部 (0,0)（方块
    // 左上角）经此矩阵落到 target 的左上角。
    // 用 translateByDouble / scaleByDouble：vector_math 2.4 已把
    // translate(x,y) / scale(s) 标记为 deprecated。
    // 末位 tw / sw 必须给 1.0（老 API 的默认值就是 1.0）：给 0 会把矩阵第 4 行
    // 清零、退化成非仿射，求逆随之奇异，localToGlobal 直接返回 NaN / Infinity。
    final matrix = Matrix4.identity()
      ..translateByDouble(target.center.dx, target.center.dy, 0, 1)
      ..rotateZ(coverMorphTilt(t))
      ..scaleByDouble(scale, scale, scale, 1)
      ..translateByDouble(-settled.width / 2, -settled.height / 2, 0, 1);

    return Positioned.fill(
      child: CoverMorphPhaseProbe(
        // 阶段归因（仪表 v3）：飞行封面每帧要重录 Transform + 逐帧变的局部圆角 +
        // 两层 BoxShadow。构造类热点量不到这笔（它在 paint 录制阶段），所以在这里
        // 单独圈一棵；与 `textLayout/textPaint`、`pageLayout/pagePaint` 两两不相交。
        layoutKey: 'coverLayout',
        paintKey: 'coverPaint',
        child: IgnorePointer(
          // 拖拽期间形变层绝不能吃掉指针：手势还在下层 MiniPlayer 的 Listener 上。
          //
          // 注意：这里**不套任何 Opacity**。播放页本身有"前 20% 屏高内淡入"的
          // 进度映射，若封面再叠一层淡入，两者相乘会让飞行中的专辑看起来是
          // 灰色的、像被虚化过。共享元素应当全程保持不透明，只让页面自己淡入。
          // p≈0 时形变封面与 MiniPlayer 封面矩形几乎重合，由 MiniPlayer 那侧
          // 直接隐藏（`PlayerCoverMorphBus.layerWillDraw`）即可完成交接。
          // 阴影同理不套 Opacity：它只包住本层要淡变的 BoxShadow（改
          // intensity 实现），封面本体不受影响，交接与淡变互不干扰。
          child: Transform(
            transform: matrix,
            transformHitTests: false,
            // OverflowBox 而非 Align：Align 把紧约束传给子级，SizedBox 在**有界**
            // 约束下会被收进可用尺寸（实测 800×600 视口里 720×720 被压成
            // 720×600），渲染盒不再是 settled 那个正方形，整套矩阵假设随之失真。
            //
            // 注意 min/max 必须**显式**给：本 SDK 的 OverflowBox 这四个参数默认是
            // null，含义是"沿用父约束"（老版本默认 0 / infinity，行为不同），
            // 不显式写的话子级仍会被紧约束压扁。子级拿到无界约束后 SizedBox
            // 严格按 settled 尺寸布局；OverflowBox 自身因 fit=max 仍是全屏，
            // 保证 Transform 矩阵的原点就是屏幕左上角。
            child: OverflowBox(
              alignment: Alignment.topLeft,
              minWidth: 0,
              maxWidth: double.infinity,
              minHeight: 0,
              maxHeight: double.infinity,
              child: SizedBox(
                width: settled.width,
                height: settled.height,
                child: _shadowedArtwork(bus, t, scale, settled),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// [_MorphCoverFlightState] 的 memo 失效判据：飞行封面本体读到的登记簿字段，
/// 一个都不能漏（漏一个就是「转场中途切歌仍飞着上一首封面」这类缺陷）。
///
/// **不含** `settledRect` / `miniRect` / `settledArtworkScale` /
/// `settledArtworkAnchor` / `shadowColor`：这些都在每帧现算的外层被读到
/// （`SizedBox` 的边长、`Transform` 的矩阵、`DecoratedBox` 的阴影），不经过
/// memo，因此不存在陈旧问题。
///
/// 解码档位同样不进签名：`PlayerArtworkImage` 用 `LayoutBuilder` 在**布局阶段**
/// 按实际约束选档，子树被冻结时仍会随新约束重算，不会过解或欠解。
class _ArtworkSignature {
  const _ArtworkSignature(
    this.artworkUri,
    this.fallbackFilePath,
    this.iconSize,
    this.placeholderColor,
  );

  final String? artworkUri;
  final String? fallbackFilePath;
  final double iconSize;
  final Color placeholderColor;

  @override
  bool operator ==(Object other) =>
      other is _ArtworkSignature &&
      other.artworkUri == artworkUri &&
      other.fallbackFilePath == fallbackFilePath &&
      other.iconSize == iconSize &&
      other.placeholderColor == placeholderColor;

  @override
  int get hashCode =>
      Object.hash(artworkUri, fallbackFilePath, iconSize, placeholderColor);
}

/// 播放页「歌曲名 + 歌手」标题块的槽位：上报目标矩形与两套文字，并在形变期间让位。
///
/// 与 [PlayerCoverSlot] 同构，但**不需要** `settledScale` / `settledAnchor`——
/// 标题块在播放页里是 `AnimatedScale` 的**兄弟节点**（只有封面参与暂停缩放），
/// 所以它的布局矩形就是它的屏幕矩形。
class PlayerTitleSlot extends StatelessWidget {
  const PlayerTitleSlot({
    super.key,
    required this.title,
    required this.subtitle,
    required this.titleStyle,
    required this.subtitleStyle,
    required this.align,
    required this.eligible,
    required this.child,
  });

  final String title;
  final String subtitle;
  final TextStyle? titleStyle;
  final TextStyle? subtitleStyle;
  final Alignment align;

  /// 形变资格回调，见 [PlayerCoverSlot.eligible] 的说明（切换 tab 后必须现场求值）。
  final bool Function() eligible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bus = PlayerCoverMorphBus.instance;
    return ValueListenableBuilder<double>(
      valueListenable: playerExpansion,
      builder: (context, expansion, content) {
        // 维护**文字侧**资格锁存（与封面各自独立，见 PlayerCoverMorphBus）
        final latched = bus.resolveTextEligible(
          expansion: expansion,
          live: eligible(),
        );
        return CoverGeometryProbe(
          onRect: (measured, logicalSize) {
            bus.publishFullText(
              measured: measured,
              logicalSize: logicalSize,
              pageOffset: bus.pageOffset,
              title: title,
              subtitle: subtitle,
              titleStyle: titleStyle,
              subtitleStyle: subtitleStyle,
              align: align,
              eligible: latched,
            );
          },
          child: Opacity(
            // 让位条件与形变层绘制条件同源（bus.textWillDraw），**并且必须带上
            // 进度范围**：`textWillDraw` 在 p=1 时依然为真（资格与矩形都还在），
            // 漏掉 `expansion < 1.0` 会让真实标题被永久隐藏 —— 播放页里再也
            // 看不到歌名/歌手/专辑，只有拖动过程和迷你条能看到。
            opacity: expansion > 0.0 &&
                    expansion < 1.0 &&
                    bus.textWillDraw
                ? 0.0
                : 1.0,
            child: content!,
          ),
        );
      },
      child: child,
    );
  }
}

/// MiniPlayer「歌曲名 + 歌手」文字块的槽位：上报起点矩形，并在形变层接管后立即让位。
///
/// 与封面的让位判据同源，所以封面与文字是**同一时刻**一起交棒的。
class MiniPlayerTextSlot extends StatelessWidget {
  const MiniPlayerTextSlot({
    super.key,
    required this.title,
    required this.subtitle,
    required this.titleStyle,
    required this.subtitleStyle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final TextStyle? titleStyle;
  final TextStyle? subtitleStyle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bus = PlayerCoverMorphBus.instance;
    return ValueListenableBuilder<double>(
      valueListenable: playerExpansion,
      builder: (context, expansion, content) => CoverGeometryProbe(
        onRect: (rect, _) => bus.publishMiniText(
          rect: rect,
          title: title,
          subtitle: subtitle,
          titleStyle: titleStyle,
          subtitleStyle: subtitleStyle,
        ),
        child: Opacity(
          opacity: expansion > 0.0 && bus.textWillDraw ? 0.0 : 1.0,
          child: content!,
        ),
      ),
      child: child,
    );
  }
}

/// 播放页的封面槽位：包在 `AnimatedScale` **外层**（`AnimatedScale` 只改绘制
/// 不改布局，探针必须量到未被缩放的方盒子），负责
/// 1. 把"归位后的封面矩形"与绘制参数写进 [PlayerCoverMorphBus]；
/// 2. 在形变期间让位（不绘制），把显示权交给 [PlayerCoverMorphLayer]。
///
/// 让位用 `Opacity(0)` 而不是 `SizedBox.shrink()`：后者会把布局盒收成 0，
/// 连带把外层 `Column` / `Row` 顶塌，播放页排版当场崩掉。
class PlayerCoverSlot extends StatelessWidget {
  const PlayerCoverSlot({
    super.key,
    required this.songId,
    required this.artworkUri,
    required this.fallbackFilePath,
    required this.iconSize,
    required this.placeholderColor,
    this.shadowColor,
    required this.eligible,
    required this.settledScale,
    required this.settledAnchor,
    required this.child,
  });

  final String? songId;
  final String? artworkUri;
  final String? fallbackFilePath;
  final double iconSize;
  final Color placeholderColor;

  /// 封面阴影色（宿主页面的 `colorScheme.shadow`），转发给登记簿
  /// [PlayerCoverMorphBus.shadowColor]：飞行途中的阴影由形变层代画并随
  /// 进度淡入淡出，不传则形变层不画阴影（旧行为）。
  final Color? shadowColor;

  /// 本次转场是否允许**封面**形变接管。频谱圆盘 / 写真 / 3D 深度封面 / 动态封面 /
  /// 车机常驻面板一律传 false——形变层画的是一张平面方图，盖在这些形态上会穿帮。
  ///
  /// **判据必须同步可读**（见 `PlayerCoverMorphBus.resolveCoverEligible`）：
  /// 跟手覆盖层里的播放页是当场新建的，首帧就在 0<p<1，它自己的异步偏好还没读到。
  ///
  /// 本次转场是否允许形变接管。
  ///
  /// **是回调而不是布尔值**：资格依赖「封面此刻是否真的可见」，而它会随 tab
  /// 切换变化，但播放页不会因切 tab 而重建（两个播放页都没监听 `_tabController`）。
  /// 若传布尔值，槽位会一直拿着切换前的旧值。槽位本身由 `playerExpansion` 驱动
  /// 逐帧 build，改成回调即可每次现场求值，天然新鲜。
  final bool Function() eligible;

  /// 本槽位外层那个 `AnimatedScale` 的稳定态缩放（播放中 1.0 / 暂停 0.85）。
  /// 形变层据此把终点落到真实屏幕矩形，交接时无需再补一段缩放动画。
  final double settledScale;

  /// 与 [settledScale] 对应的 `AnimatedScale.alignment`。
  final Alignment settledAnchor;

  /// 真实封面子树。
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: playerExpansion,
      builder: (context, expansion, artwork) {
        final bus = PlayerCoverMorphBus.instance;
        // 封面侧资格在转场起点锁存、全程不变：动态封面 / 3D 封面是异步就绪的，
        // 常在拖拽途中才翻成「就绪」，实时求值会让形变半空中被中断。
        final eligible = bus.resolveCoverEligible(
          expansion: expansion,
          live: this.eligible(),
        );
        return CoverGeometryProbe(
          onRect: (measured, logicalSize) {
            bus.publishFull(
              measured: measured,
              logicalSize: logicalSize,
              // 与 measured 同帧：路由过渡在 build 阶段写入，覆盖层同理
              pageOffset: bus.pageOffset,
              songId: songId,
              artworkUri: artworkUri,
              fallbackFilePath: fallbackFilePath,
              iconSize: iconSize,
              placeholderColor: placeholderColor,
              shadowColor: shadowColor,
              eligible: eligible,
              settledArtworkScale: settledScale,
              settledArtworkAnchor: settledAnchor,
            );
          },
          child: Opacity(
            // 只在形变层**确实会画**时才让位。判据与 [PlayerCoverMorphLayer]
            // 完全同源（[PlayerCoverMorphBus.willDraw]），两者不可能打架。
            // 否则「形变层不画 + 真实封面已隐藏」= 整段转场封面凭空消失，
            // 回退路径反而比不启用形变更糟。
            opacity: expansion > 0.0 &&
                    expansion < 1.0 &&
                    bus.willDraw(eligible: eligible)
                ? 0.0
                : 1.0,
            child: artwork!,
          ),
        );
      },
      // child 只构造一次、逐帧只被重新挂载，不重建封面子树：
      // playerExpansion 每帧变化时只有 builder 跑，child 作为已构建好的
      // widget 实例被原样传下去，内部的 DepthCoverHost / DynamicCoverView
      // 不会跟着逐帧重建。
      child: child,
    );
  }
}