import 'package:flutter/material.dart';

import '../../modules/player/player_wide_pane.dart';
import 'settings_preview_frame.dart';

/// 「顶栏与页签」三级子页的演示卡。
///
/// 这一页 5 个开关分别作用于**不同朝向**，所以演示卡给两个框：
/// 左 = 竖屏（portrait）、右 = 宽屏（landscape / 平板）。只给一个框就会漏掉
/// 另一半——「横屏控制面板独立页」在竖屏下根本没有生效形态。
///
/// ## 五个开关的真实口径（逐条对过播放页源码）
///
/// - **横屏控制面板独立页**（[kLandscapeDetachedControlsEnabled]）：只在宽屏生效。
///   关 = 传输/进度控件常驻右栏底部；开 = 右栏多出一条「控制」页签，控件收进它，
///   歌词/歌单页签占满整栏（full_player.dart:3347 的 `!dockMode && ...`）。
/// - **横屏左右对称分栏**（[kSymmetricWidePaneEnabled]）：**只作用于宽屏**。
///   开 = 左右 1:1 对称；关 = 左 4 右 6，右栏（歌词/歌单等内容）获得更多宽度，
///   占比口径见 `PlayerWidePane.leftPaneFraction`（player_wide_pane.dart）。
/// - **胶囊按钮收缩**（[kTopBarPillCollapseEnabled]）：**只作用于竖屏**。宽屏顶栏
///   有整行宽度，文案常显更好读（player_top_bar_actions.dart:453-455）。
///   关 = 「睡眠定时 / 一起听 / ⋯」文案常显；开 = 收成一颗只露 ⋯ 的胶囊，
///   点一下展开、停留 3 秒收回。
/// - **顶栏页签圆点**（[kTopBarTabDotsEnabled]）：竖屏时页签条从底部升到顶栏中央，
///   形态由「图标 + 指示线」变成一排圆点；宽屏时页签条恒在右栏底部，只变形态
///   （player_top_bar_tab_dots.dart:40 的 `wide || !enabled` 早退）。
/// - **自定义宽屏边距**（`kWidePaneMarginOverride`）：**只作用于宽屏**。null = 自动
///   （按屏宽比例，示意 12dp 起步）；非 null = 固定内衬，0 = 最小边距（挖孔机型
///   仍保留挖孔避让，不是真正贴边）。口径见 `PlayerWidePane.gutter` 的 `override`
///   参数，挖孔避让另见 `PlayerWidePane.cutoutSymmetricInset`。
class PlayerChromePreview extends StatelessWidget {
  final bool landscapeDetachedControls;
  final bool symmetricWidePane;

  /// 宽屏左栏内衬覆盖值（dp）。null = 自动口径；非 null 完全取代比例算法。
  final double? widePaneMargin;

  /// 是否忽略挖孔（刘海）对称补偿。仅在 [widePaneMargin] 非 null（自定义边距
  /// 开启）时有意义：开启后内容延伸到挖孔/刘海区域真贴边。宽屏框绘制本身不画
  /// 挖孔，本参数只影响 footnote 的边距口径说明。
  final bool ignoreCutout;
  final bool pillCollapse;
  final bool topBarTabDots;

  const PlayerChromePreview({
    super.key,
    required this.landscapeDetachedControls,
    this.symmetricWidePane = true,
    this.widePaneMargin,
    this.ignoreCutout = false,
    required this.pillCollapse,
    required this.topBarTabDots,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // footnote 里的边距档位：null = 自动，0 = 最小（挖孔机型另有挖孔避让），
    // 其余显示 dp 值（整数不带小数点，小数保留 1 位，与设置页值列同口径）
    final margin = widePaneMargin;
    final marginNote = margin == null
        ? '自动'
        // 自定义边距 + 忽略挖孔避让：真贴边（含挖孔区），挖孔遮挡由用户自担
        : ignoreCutout
        ? '贴边（含挖孔区）'
        : margin <= 0
        ? '最小'
        : margin == margin.roundToDouble()
        ? '${margin.toStringAsFixed(0)}dp'
        : '${margin.toStringAsFixed(1)}dp';
    return SettingsPreviewFrame(
      title: '播放页 chrome 预览',
      subtitle: '左 = 竖屏 · 右 = 宽屏（横屏 / 平板）',
      footnote:
          '胶囊收缩只影响竖屏；控制面板独立页只影响宽屏；对称分栏只影响宽屏；'
          '边距：$marginNote',
      height: 210,
      background: colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: _Frame(
                label: '竖屏',
                wide: false,
                landscapeDetachedControls: landscapeDetachedControls,
                pillCollapse: pillCollapse,
                topBarTabDots: topBarTabDots,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: _Frame(
                label: '宽屏',
                wide: true,
                landscapeDetachedControls: landscapeDetachedControls,
                symmetricWidePane: symmetricWidePane,
                widePaneMargin: widePaneMargin,
                pillCollapse: pillCollapse,
                topBarTabDots: topBarTabDots,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 一个朝向的手机/平板框：顶栏 + 内容区（竖屏单栏 / 宽屏左右双栏）。
class _Frame extends StatelessWidget {
  final String label;
  final bool wide;
  final bool landscapeDetachedControls;

  /// 宽屏分栏是否对称（只读给宽屏框用，竖屏忽略）。
  final bool symmetricWidePane;

  /// 宽屏左栏内衬覆盖值（dp）。只读给宽屏框用，竖屏忽略。null = 自动口径。
  final double? widePaneMargin;
  final bool pillCollapse;
  final bool topBarTabDots;

  const _Frame({
    required this.label,
    required this.wide,
    required this.landscapeDetachedControls,
    this.symmetricWidePane = true,
    this.widePaneMargin,
    required this.pillCollapse,
    required this.topBarTabDots,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 10, color: colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: colorScheme.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colorScheme.outlineVariant),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                _TopBar(
                  wide: wide,
                  pillCollapse: pillCollapse,
                  topBarTabDots: topBarTabDots,
                  colorScheme: colorScheme,
                ),
                Expanded(
                  child: wide
                      ? _WideContent(
                          detached: landscapeDetachedControls,
                          symmetric: symmetricWidePane,
                          tabDots: topBarTabDots,
                          widePaneMargin: widePaneMargin,
                          colorScheme: colorScheme,
                        )
                      : _PortraitContent(
                          tabDots: topBarTabDots,
                          colorScheme: colorScheme,
                        ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 顶栏：左返回 + 中段（页签圆点开时才有）+ 尾部动作胶囊。
class _TopBar extends StatelessWidget {
  final bool wide;
  final bool pillCollapse;
  final bool topBarTabDots;
  final ColorScheme colorScheme;

  const _TopBar({
    required this.wide,
    required this.pillCollapse,
    required this.topBarTabDots,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    // 圆点只在竖屏顶栏出现（wide 时顶栏没有可供挤进中段的水平线）
    final showMiddleDots = !wide && topBarTabDots;
    // 胶囊收缩只作用于竖屏
    final collapsed = !wide && pillCollapse;

    return Container(
      height: 26,
      color: colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          Icon(Icons.keyboard_arrow_down, size: 12, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 4),
          if (showMiddleDots) ...[
            // 一排圆点（4 个页签）
            Row(
              children: [
                for (var i = 0; i < 4; i++)
                  Container(
                    width: 4,
                    height: 4,
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    decoration: BoxDecoration(
                      color: i == 0
                          ? colorScheme.primary
                          : colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                      shape: BoxShape.circle,
                    ),
                  ),
              ],
            ),
          ],
          const Spacer(),
          if (collapsed)
            // 收缩态：只露一颗 ⋯，点一下才展开
            Icon(Icons.more_horiz, size: 12, color: colorScheme.onSurfaceVariant)
          else
            // 常显态：三个格子带文案
            Row(
              children: [
                for (final seg in const ['音质', '睡眠', '一起听'])
                  Container(
                    margin: const EdgeInsets.only(left: 3),
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      seg,
                      style: TextStyle(
                        fontSize: 6,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                Icon(Icons.more_horiz, size: 12, color: colorScheme.onSurfaceVariant),
              ],
            ),
        ],
      ),
    );
  }
}

/// 竖屏内容区：页签条在底部（开关关）——开启时它升到顶栏，底部只剩传输行。
class _PortraitContent extends StatelessWidget {
  final bool tabDots;
  final ColorScheme colorScheme;

  const _PortraitContent({required this.tabDots, required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Container(
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Icon(
                Icons.music_note,
                size: 20,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        // 传输行
        _TransportRow(colorScheme: colorScheme),
        // 页签条：关闭时留在底部，开启时升到顶栏（此处不渲染）
        if (!tabDots) _TabStrip(dots: false, colorScheme: colorScheme),
      ],
    );
  }
}

/// 宽屏内容区：左 = 歌词/歌单栏，右 = 控制栏（或独立「控制」页签）。
///
/// 左右栏宽度比与播放页同源：按 [PlayerWidePane.leftPaneFraction] 取占比
/// （对称 5:5、非对称 4:6），保证演示卡随「横屏左右对称分栏」开关反映真实形态。
class _WideContent extends StatelessWidget {
  final bool detached;

  /// 宽屏左右分栏是否对称，口径同 `PlayerWidePane.leftPaneFraction`。
  final bool symmetric;
  final bool tabDots;

  /// 宽屏左栏内衬覆盖值（dp）。null = 自动口径（框宽 × 5% 夹 12–24 的示意值）；
  /// 非 null 完全取代比例算法，0 = 最小内衬。口径同 `PlayerWidePane.gutter`。
  final double? widePaneMargin;
  final ColorScheme colorScheme;

  const _WideContent({
    required this.detached,
    required this.symmetric,
    required this.tabDots,
    this.widePaneMargin,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    // 分栏占比与播放页同源：0.5 → 5:5，0.4 → 4:6（flex 只收整数，×10 取整）
    final leftFlex = (PlayerWidePane.leftPaneFraction(symmetric) * 10).round();
    final rightFlex = 10 - leftFlex;
    return LayoutBuilder(
      builder: (context, box) {
        // 左右内衬按 PlayerWidePane.gutter 口径绘制：与真实播放页同一函数取值，
        // 覆盖值（含 0 = 最小；真实播放页挖孔机型还会另加挖孔避让）在演示卡上如实反映。
        final gutter = PlayerWidePane.gutter(
          box.maxWidth,
          override: widePaneMargin,
        );
        return Padding(
          padding: EdgeInsets.fromLTRB(gutter, 6, gutter, 6),
          child: Row(
            children: [
              // 左栏：歌词 / 歌单
              Expanded(
                flex: leftFlex,
                child: Container(
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Icon(
                    Icons.music_note,
                    size: 18,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 5),
              // 右栏：独立页开启时 = 「歌词 | 控制」两枚页签 + 内容；关闭时 = 控件常驻 + 页签条
              Expanded(
                flex: rightFlex,
                child: Container(
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: colorScheme.outlineVariant),
                  ),
                  padding: const EdgeInsets.all(3),
                  child: Column(
                    children: [
                      if (detached) ...[
                        // 独立控制页：右栏顶部出现两枚页签
                        Row(
                          children: [
                            _MiniTab(
                              label: '歌词',
                              active: true,
                              colorScheme: colorScheme,
                            ),
                            _MiniTab(
                              label: '控制',
                              active: false,
                              colorScheme: colorScheme,
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Expanded(
                          child: Container(
                            decoration: BoxDecoration(
                              color: colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                      ] else ...[
                        // 常驻控制带：进度 + 传输键
                        _TransportRow(compact: true, colorScheme: colorScheme),
                        const Spacer(),
                        _TabStrip(dots: tabDots, colorScheme: colorScheme),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _TransportRow extends StatelessWidget {
  final bool compact;
  final ColorScheme colorScheme;

  const _TransportRow({this.compact = false, required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: compact ? 14 : 16,
      margin: EdgeInsets.symmetric(horizontal: compact ? 0 : 6, vertical: 2),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (final icon in const [
            Icons.skip_previous,
            Icons.play_arrow,
            Icons.skip_next,
          ])
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Icon(
                icon,
                size: compact ? 9 : 11,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

/// 页签条：图标 + 指示线（默认）或一排圆点（开关开启时）。
class _TabStrip extends StatelessWidget {
  final bool dots;
  final ColorScheme colorScheme;

  const _TabStrip({required this.dots, required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    if (dots) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < 4; i++)
              Container(
                width: 4,
                height: 4,
                margin: const EdgeInsets.symmetric(horizontal: 2),
                decoration: BoxDecoration(
                  color: i == 0
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                  shape: BoxShape.circle,
                ),
              ),
          ],
        ),
      );
    }
    // 图标 + 指示线：3 个页签，首个带下划线
    return Container(
      height: 16,
      margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (final entry in const [
            (Icons.album_outlined, true),
            (Icons.lyrics_outlined, false),
            (Icons.playlist_play, false),
          ])
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(entry.$1, size: 8, color: colorScheme.onSurfaceVariant),
                const SizedBox(height: 1),
                Container(
                  width: 8,
                  height: 1.5,
                  color: entry.$2
                      ? colorScheme.primary
                      : Colors.transparent,
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _MiniTab extends StatelessWidget {
  final String label;
  final bool active;
  final ColorScheme colorScheme;

  const _MiniTab({
    required this.label,
    required this.active,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 4),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: active ? colorScheme.primaryContainer : colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 6,
          color: active
              ? colorScheme.onPrimaryContainer
              : colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
