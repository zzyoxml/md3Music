import 'package:material_ui/material_ui.dart';

import '../../core/utils/app_haptics.dart';
import '../../providers/player_provider.dart';
import '../playback_status_feedback.dart';
import '../player_seek_bar.dart';
import '../player_volume_bar.dart';
import 'dock_skin.dart';

/// 控制带的形态档位（计划 §2.3）。
enum PlayerDockTier {
  /// 宽屏「控制 = 独立一页」：纵向撑满整页，进度条贴顶、音量条贴底。
  /// 用户开启「横屏控制面板独立页」时的既有形态。
  detached,

  /// 宽裕：平板横屏 / 折叠展开（可用高 ≥ 300 且 pane 宽 ≥ 620）。
  /// 尺 + 传输两行。
  comfortable,

  /// 标准：约 800×360 的手机横屏（可用高 ≥ 236、pane 宽 400–620）。
  /// 尺 + 传输两行。
  standard,

  /// 极窄：可用高 < 236 / 大字号 / 车机窄栏。
  /// 尺与传输挤在同一条水平带里。
  compact,
}

/// 控制带分档判据（纯函数，便于逐档出单测）。
///
/// **只吃调用方 LayoutBuilder 的局部宽高**：转屏动画途中
/// `platformDispatcher.physicalSize` 会读到旧快照，而 tab 结构又必须由同一份判定
/// 派生，读快照会让孩子数量与 TabController.length 不一致直接抛断言（计划 R4）。
///
/// [dockMode]（车机面板）恒按 [PlayerDockTier.compact]：面板宽度虽已由
/// CarModePanel 覆盖进 MediaQuery，但它不参与横屏重排，沿用既有窄屏语义。
PlayerDockTier resolvePlayerDockTier({
  required double paneWidth,
  required double paneHeight,
  bool dockMode = false,
}) {
  if (dockMode) return PlayerDockTier.compact;
  if (paneHeight >= 300 && paneWidth >= 620) return PlayerDockTier.comfortable;
  if (paneHeight >= 236 && paneWidth >= 400) return PlayerDockTier.standard;
  return PlayerDockTier.compact;
}

/// 横屏控制带 —— 进度条 + 传输簇两组的**唯一布局实现**。
///
/// 音量不在带里：常驻档把它放进顶栏 ⋯ 的「更多」菜单，detached 档留在「控制」页内。
///
/// MD 与 AM 两版此前各写一份同构的 `_buildLandscapeControlPage`。布局收敛到这里后，
/// 皮肤差异走 [DockSkin]，而传输簇（两版的三按钮形变动画语义不同，本期不合并）与
/// 横滑手势锁（锁标志归宿主 State 持有）由宿主注入。
class PlayerControlDock extends StatefulWidget {
  const PlayerControlDock({
    super.key,
    required this.tier,
    required this.skin,
    required this.playerProvider,
    required this.colorScheme,
    required this.transport,
    this.visible = true,
    this.swipeLock,
    this.paddingHorizontal,
    this.showStatusFeedback = true,
  });

  final PlayerDockTier tier;
  final DockSkin skin;
  final PlayerProvider playerProvider;

  /// 由宿主传入而非在此 `Theme.of`：两个播放页用的 [ColorScheme] 来自
  /// `material_ui`，与 `flutter/material` 的同名类是**两个不同类型**，
  /// 本文件因此也 import material_ui，否则类型对不上。
  final ColorScheme colorScheme;

  /// 传输簇：MD 传 `_buildMainControls`（内含 MD3ETransportRow），
  /// AM 传 Selector 包起来的 `_buildMainControls`（内含 AMTransportControls）。
  ///
  /// **传 null 时本控件只渲染进度尺**：宽屏常驻档就这么用 —— 尺落在左栏曲名正下方，
  /// 传输簇由宿主排在尺的再下方（两者都横贯左栏内容宽，与封面/曲名同一条边线）。
  ///
  /// 尺要的是**宽度**、传输簇要的是**高度**：左栏纵向只有 272dp（800×360 的手机横屏），
  /// 封面边长已由 [PlayerWidePane] 把这两块的预留扣干净，再叠一层就必然把封面挤没。
  final Widget? transport;

  /// chrome 此刻是否可见（宿主用 `!_zenMode` 传）。
  ///
  /// Zen 淡出后 `_ZenFade` 会把本控件 `Offstage` 掉，但 Offstage 只停绘制与命中，
  /// **不停本控件树里的 Timer 与共享节拍订阅** —— 可见性必须显式传进来，
  /// 否则「界面看不见但整页帧率被顶高」（AGENTS §10.4 第 3/6 条、计划 R5）。
  final bool visible;

  /// 横滑手势锁：按住滑条行期间锁掉 pager 翻页，松手还原。
  ///
  /// 置位时机是**指针按下**而不是滑条自己的拖拽起手——那要晚一帧以上，
  /// PageView 可能已在手势竞技场里把这次拖拽认领走。
  ///
  /// **常驻带档位传 null**：dock 已经不在 pager 的 children 里，滑条与 pager 是
  /// 兄弟节点，拖动滑条不会抢走翻页手势，再上锁只会让整页滑不动（计划 §2.2 ①）。
  final Widget Function(Widget child)? swipeLock;

  /// 常驻带的水平外衬覆盖值（null = 用带内默认的 16）。
  ///
  /// 进度尺搬进左栏曲名下方时宿主必须传 0：左栏已经按 [PlayerWidePane] 的统一比例
  /// 内衬过一次，这里再叠一层 16，尺就比封面/曲名窄一截，左右边线立刻对不齐
  /// （正是本次要修的病灶）。
  final double? paddingHorizontal;

  /// 是否在尺的上方挂一条 [PlaybackStatusFeedback]（加载/失败提示，默认真）。
  ///
  /// 尺搬进左栏时宿主必须传 false：那条约提示有 44~52dp 高（错误文案两行），
  /// 而左栏 chrome 全是**不定高的非 flex 子项**，一旦占位就吃掉封面、
  /// 再往上就是 RenderFlex 溢出（800×360 + 1.3 倍字 + 报错，实测会炸）。
  /// 右栏那条 chrome 上面是 `Expanded` 的内容区，提示变高只会自己吸收。
  final bool showStatusFeedback;

  /// 常驻档的**进度尺带定高**（尺 40，含时间数字那一行）。
  ///
  /// 宿主用它从左栏可用高里扣封面边长，见 `player_wide_pane.dart`。
  static const double seekBandHeight = 40;

  @override
  State<PlayerControlDock> createState() => _PlayerControlDockState();
}

class _PlayerControlDockState extends State<PlayerControlDock> {
  /// 拖动前的播放态：松手 seek 完成后据此决定是否恢复播放。
  bool _wasPlayingBeforeDrag = false;

  /// 常驻带档位的带高（不含底部系统栏内衬）见 [PlayerControlDock.seekBandHeight]：
  /// 宿主算封面预算要用同一个数，故不在这里另存一份。
  ///
  /// 这里**不**给子树套固定高度的 SizedBox：状态反馈行在有提示文案时会撑高，
  /// 大字号档下固定高度就是 RenderFlex 溢出（本仓在 800×360 + 1.3 倍字上踩过）。
  /// 高度靠各元素自身的定高（尺 40 / 音量 40）与间隙累出来。
  ///
  /// 带内行间距：页签条回到带的下方单独占一行后，800×360 的内容区掉到 146，
  /// 低于计划「5 行歌词 ≥ 150」的验收硬线；带内留白从 8/4 收到 4/2 把它抵回来。
  static const double _bandGap = 4;
  static const double _bandPaddingHorizontal = 16;

  /// L 档传输簇的定宽：三按钮联合形变组 44+8+60+8+44 = 164，留 16 余量给两端侧键。
  static const double _transportNaturalWidth = 180;

  double _seekHeight(PlayerDockTier tier) => tier == PlayerDockTier.detached
      ? 38
      : PlayerControlDock.seekBandHeight;

  bool get _isBand => widget.tier != PlayerDockTier.detached;

  /// 进度条 —— 皮肤决定轨道形态与配色，档位决定常驻带才开启的刻度尺增强。
  ///
  /// 监听 positionNotifier（高频 ~200ms）+ provider（duration 等低频），
  /// 不因 positionStream 触发整页重建；
  /// 波浪回退开关只在 MD 侧并入监听，与两版改动前的重建面一致。
  Widget _buildSeekRow() {
    final player = widget.playerProvider;
    final song = player.currentSong;
    final colorScheme = widget.colorScheme;
    final amStyle = widget.skin.amStyle;
    final listenables = <Listenable>[
      // 高频通道只在可见时订阅：Zen 淡出后还挂着 positionNotifier，
      // 每 ~200ms 一次重建会换算成一次 scheduleFrame —— 看不见还在产帧。
      if (widget.visible) player.positionNotifier,
      player,
      if (!amStyle) kSeekBarWaveEnabled,
    ];
    return ListenableBuilder(
      listenable: Listenable.merge(listenables),
      builder: (context, _) => PlayerSeekBar(
        position: player.position,
        duration: player.duration ?? Duration.zero,
        isPlaying: player.isPlaying,
        visible: widget.visible,
        md3Style: widget.skin.md3Style,
        waveEnabled: amStyle ? true : kSeekBarWaveEnabled.value,
        speed: player.speed,
        activeColor: widget.skin.seekActive(colorScheme),
        inactiveColor: widget.skin.seekInactive(colorScheme),
        labelColor: widget.skin.seekLabel(colorScheme),
        climaxStart: song?.climaxStart,
        climaxEnd: song?.climaxEnd,
        height: _seekHeight(widget.tier),
        // 刻度尺四件套只在常驻带开启：detached 档有整页高度，维持旧观，
        // 也让竖屏 compact 的进度条与本改动前逐像素一致。
        tickMarks: _isBand,
        showRemaining: _isBand,
        onDoubleTapSkip: _onSkip,
        onSeekStart: () {
          _wasPlayingBeforeDrag = player.isPlaying;
          if (_wasPlayingBeforeDrag) {
            player.pauseForSeek();
          }
        },
        onSeekEnd: (value) async {
          AppHaptics.tick(HapticCategory.transport);
          // forceNotify：松手是用户显式动作，远端纠偏的抑制窗口不得吞掉通告
          // （否则听众的「拖动即脱离」会被静默吞掉并被纠偏拉回）
          await player.seek(value, forceNotify: true);
          if (_wasPlayingBeforeDrag) {
            player.resume();
          }
        },
      ),
    );
  }

  /// 双击左右半区 ±15 秒：进度条只决定时机与增量，落地（seek / 暂停恢复）在这里。
  Future<void> _onSkip(int deltaSeconds) async {
    final player = widget.playerProvider;
    final total = player.duration ?? Duration.zero;
    final delta = Duration(seconds: deltaSeconds);
    // 夹在 [0, 时长]：在 0:05 处连点左半区不能把 seek 递成一个负数
    var target = player.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (total > Duration.zero && target > total) target = total;
    _wasPlayingBeforeDrag = player.isPlaying;
    if (_wasPlayingBeforeDrag) {
      player.pauseForSeek();
    }
    AppHaptics.tick(HapticCategory.transport);
    await player.seek(target, forceNotify: true);
    if (_wasPlayingBeforeDrag) {
      player.resume();
    }
  }

  Widget _locked(Widget child) =>
      widget.swipeLock == null ? child : widget.swipeLock!(child);

  /// 尺那一行。音质徽章不在带里（统一在顶栏），页签条也不挤在这一行 ——
  /// 它回到带的下方单独一行。
  Widget _seekRowLine() => _buildSeekRow();

  @override
  Widget build(BuildContext context) {
    return switch (widget.tier) {
      PlayerDockTier.detached => _buildDetachedPage(),
      PlayerDockTier.comfortable ||
      PlayerDockTier.standard => _buildTwoRowBand(),
      PlayerDockTier.compact => _buildSingleRowBand(),
    };
  }

  /// 「控制 = 独立一页」：纵向撑满，进度条贴顶、音量条贴底。
  /// 内容收窄 420 居中：右栏在 6:4 分栏下很宽，滑条横贯整栏行程过长难精调。
  Widget _buildDetachedPage() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.max,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // 三组而不是七个平铺：spaceBetween 会把空隙**均分**给每一对相邻子项，
              // 逐个子项平铺会把「状态反馈—进度条」这对强相关的东西拉开。
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PlaybackStatusFeedback(amStyle: widget.skin.amStyle),
                  // 与上方拉开距离：进度条拖动时时间标签会向上浮出
                  const SizedBox(height: 4),
                  _locked(_buildSeekRow()),
                ],
              ),
              // detached 档由宿主传入放大后的传输簇（这一档不会传 null）
              if (widget.transport != null) widget.transport!,
              // 音量条留在控制页里（常驻档把它挪进了顶栏 ⋯ 的「更多」菜单）
              _locked(PlayerVolumeBar(amStyle: widget.skin.amStyle)),
            ],
          ),
        ),
      ),
    );
  }

  /// S / M 档：「尺（含同行音质徽章）」＋「传输」（若宿主把传输簇放进带里）。
  ///
  /// 宽屏常驻档传 `transport: null` —— 传输簇在左栏曲名正下方，带里只剩尺；
  /// 音量也不在带里（更多菜单 / 独立控制页）。
  ///
  /// 外衬上下各 2：页签条回到带的下方单独占一行后，800×360 的内容区掉到 146，
  /// 低于计划「5 行歌词 ≥ 150」的验收硬线；带内留白（行距 8→4、外衬 4→2）把它抵回来。
  Widget _buildTwoRowBand() {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: widget.paddingHorizontal ?? _bandPaddingHorizontal,
        vertical: 2,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.showStatusFeedback)
            PlaybackStatusFeedback(amStyle: widget.skin.amStyle),
          _seekRowLine(),
          if (widget.transport != null) ...[
            const SizedBox(height: _bandGap),
            widget.transport!,
          ],
        ],
      ),
    );
  }

  /// L 档（极窄横屏 / 大字号）：尺与传输挤在同一条水平带里。
  ///
  /// 传输簇给**定宽**而不是 flex：簇内三按钮 + 两端侧键的自然宽约 164dp，
  /// 再让尺去分剩余宽度。用 flex 分给它会在窄 pane 下压到 161dp，实测
  /// RenderFlex 右侧溢出 2.5px —— 计划 R2 的底线是「绝不缩按钮」。
  ///
  /// 带里没有传输簇时（宽屏常驻档把簇搬去左栏曲名下方）尺独占整行。
  /// 音质徽章不在带里 —— 各形态统一挂在顶栏，只有车机窄面板才回到时间数字那一行，
  /// 所以这一档既不占行也不内嵌，避免出现第二枚徽章。
  Widget _buildSingleRowBand() {
    final transport = widget.transport;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: widget.paddingHorizontal ?? _bandPaddingHorizontal,
        vertical: 4,
      ),
      child: Row(
        children: [
          Expanded(child: _seekRowLine()),
          if (transport != null) ...[
            const SizedBox(width: 8),
            SizedBox(width: _transportNaturalWidth, child: transport),
          ],
        ],
      ),
    );
  }
}

