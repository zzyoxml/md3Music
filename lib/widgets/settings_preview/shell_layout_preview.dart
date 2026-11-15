import 'package:flutter/material.dart';

import '../../../core/layout/responsive_layout.dart';
import 'settings_preview_frame.dart';

/// 「导航与布局」三级子页的演示卡。
///
/// 两个并排手机框，演三件事：
/// 1. 底部导航栏标签按 [navLabelMode] 显隐（0 始终显示 / 1 仅当前页 /
///    2 始终不显示）；
/// 2. 播放条形态（见下方 [_PageContent] 的判据注释）；
/// 3. 桌面布局打开时把手机框里的底栏换成左侧边栏（读 [kDesktopModeEnabled]）。
///
/// 布局类设置是「改完不知道改了什么」的重灾区：用户得退出设置页才看到效果，
/// 改错还要再进来。这张卡让它在原地就能看见。
///
/// ## 只订阅读侧 notifier，绝不在这里写
///
/// 写入口只有设置页的开关本身，否则会出现「演示卡改了真值源」这种隐蔽副作用。
class ShellLayoutPreview extends StatelessWidget {
  /// 底部导航栏标签模式：0 始终显示 / 1 仅当前页 / 2 始终不显示。
  final int navLabelMode;

  /// 二级页面是否隐藏底栏（读 [kHideNavBarOnSecondaryPages]）。
  final bool hideNavBarOnSecondary;

  /// Windows 设置页启用时，在本演示卡里动画展示双栏开关效果。
  final bool showWindowsTwoPanePreview;

  const ShellLayoutPreview({
    super.key,
    required this.navLabelMode,
    required this.hideNavBarOnSecondary,
    this.showWindowsTwoPanePreview = false,
  });

  @override
  Widget build(BuildContext context) {
    if (showWindowsTwoPanePreview) {
      return ValueListenableBuilder<bool>(
        valueListenable: kWindowsTwoPaneEnabled,
        builder: (context, twoPaneEnabled, _) =>
            _buildPreview(context, twoPaneEnabled),
      );
    }
    return _buildPreview(context, null);
  }

  Widget _buildPreview(BuildContext context, bool? windowsTwoPaneEnabled) {
    final colorScheme = Theme.of(context).colorScheme;

    return SettingsPreviewFrame(
      title: '布局预览',
      subtitle: windowsTwoPaneEnabled == null
          ? '左 = 一级页面 · 右 = 二级页面'
          : windowsTwoPaneEnabled
          ? '双栏已开启 · 左右各占 50%'
          : '双栏已关闭 · 当前页面单栏显示',
      footnote: windowsTwoPaneEnabled == null
          ? '桌面布局与悬浮播放条的形态切换即时生效'
          : '上方“启用双栏布局”开关变化会在此处即时预览',
      height: 200,
      background: colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: windowsTwoPaneEnabled == null
            ? _buildExistingPreview()
            : _buildWindowsTwoPanePreview(windowsTwoPaneEnabled),
      ),
    );
  }

  Widget _buildExistingPreview() {
    return Row(
      children: [
        // ── 一级页面 ──
        Expanded(
          child: ValueListenableBuilder<bool>(
            valueListenable: kDesktopModeEnabled,
            builder: (context, desktopEnabled, _) => _PhoneFrame(
              label: desktopEnabled ? '侧栏布局' : '一级页面',
              showRail: desktopEnabled,
              child: _PageContent(
                showTabs: true,
                navLabelMode: navLabelMode,
                isSecondary: false,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        // ── 二级页面 ──
        Expanded(
          child: _PhoneFrame(
            label: hideNavBarOnSecondary ? '二级页面（底栏已收起）' : '二级页面',
            showRail: false,
            child: _PageContent(
              showTabs: !hideNavBarOnSecondary,
              navLabelMode: navLabelMode,
              isSecondary: true,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildWindowsTwoPanePreview(bool enabled) {
    final target = enabled ? 1.0 : 0.0;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: target, end: target),
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeInOutCubic,
      builder: (context, fraction, _) => LayoutBuilder(
        builder: (context, constraints) {
          final gap = 12 * fraction;
          final rightWidth = (constraints.maxWidth - 12) / 2 * fraction;
          return Row(
            children: [
              Expanded(
                child: ValueListenableBuilder<bool>(
                  valueListenable: kDesktopModeEnabled,
                  builder: (context, desktopEnabled, _) => _PhoneFrame(
                    key: const Key('settingsPreview.windowsTwoPane.left'),
                    label: desktopEnabled ? '一级页面 · 侧栏' : '一级页面',
                    showRail: desktopEnabled,
                    child: _PageContent(
                      showTabs: true,
                      navLabelMode: navLabelMode,
                      isSecondary: false,
                    ),
                  ),
                ),
              ),
              SizedBox(width: gap),
              ClipRect(
                child: SizedBox(
                  width: rightWidth,
                  child: _PhoneFrame(
                    key: const Key('settingsPreview.windowsTwoPane.right'),
                    label: '详情页面',
                    showRail: false,
                    child: _PageContent(
                      showTabs: !hideNavBarOnSecondary,
                      navLabelMode: navLabelMode,
                      isSecondary: true,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _PhoneFrame extends StatelessWidget {
  final String label;
  final bool showRail;
  final Widget child;

  const _PhoneFrame({
    super.key,
    required this.label,
    required this.showRail,
    required this.child,
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
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
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
            child: showRail ? _RailLayout(child: child) : child,
          ),
        ),
      ],
    );
  }
}

/// 桌面布局形态：左侧一条窄边栏 + 右侧内容。
class _RailLayout extends StatelessWidget {
  final Widget child;

  const _RailLayout({required this.child});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          width: 16,
          color: colorScheme.surfaceContainerHigh,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (var i = 0; i < 4; i++)
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: i == 0
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
            ],
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}

/// 测试用 key：区分两种播放条外观（Widget 是 private 类，测试无法直接 find 类型）。
const Key _kPreviewCapsule = Key('settingsPreview.capsule');
const Key _kPreviewPersistentBar = Key('settingsPreview.persistentBar');

/// 单个手机框内的内容：内容区 + 播放条 + 底部导航栏。
///
/// 播放条判据见 [_PlayerBarForm]（一级/二级不同，不能共用）。
class _PageContent extends StatelessWidget {
  final bool showTabs;
  final int navLabelMode;

  /// true = 演示二级页面；false = 一级页面。决定播放条判据（见 [_PlayerBarForm]）。
  final bool isSecondary;

  const _PageContent({
    required this.showTabs,
    required this.navLabelMode,
    required this.isSecondary,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Align(
              alignment: Alignment.bottomLeft,
              child: _PlayerBarForm(
                colorScheme: colorScheme,
                isSecondary: isSecondary,
              ),
            ),
          ),
        ),
        if (showTabs) _NavBar(colorScheme: colorScheme, navLabelMode: navLabelMode),
      ],
    );
  }
}

/// 播放条：胶囊（悬浮形态）与常驻条两种外观。
///
/// ## 判据（secondary_mini_player.dart:150-155、215-218）
///
/// - **二级页面**：总开关开 → **恒用悬浮胶囊**；总开关关 → 常驻条。
///   [kSecondaryPlayerOnPrimaryPages] 管不到二级页，它只决定一级页。
/// - **一级页面**：总开关关 → 常驻条；总开关开、onPrimaryPages 开 → 胶囊；
///   总开关开、onPrimaryPages 关 → **退回常驻条**。
///
/// 所以两个框必须用不同判据，不能共用一个 —— 共用的那个版本让二级框在
/// 「总开关开 + 一级开关关」时错误显示常驻条（真机反馈：打开迷你悬浮播放器
/// 时二级就该是悬浮，再打开一级开关才一二级都悬浮）。
class _PlayerBarForm extends StatelessWidget {
  final ColorScheme colorScheme;

  /// true = 演示二级页面；false = 一级页面。
  final bool isSecondary;

  const _PlayerBarForm({required this.colorScheme, required this.isSecondary});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: kSecondaryPlayerEnabled,
      builder: (context, floating, _) {
        // 二级页：只看总开关，悬浮胶囊与否与「一级页面用悬浮底栏」无关。
        // 一级页：还要看 onPrimaryPages（见其文档：关 → 一级退回常驻条）。
        final showCapsule = floating &&
            (isSecondary || kSecondaryPlayerOnPrimaryPages.value);
        if (!showCapsule) {
          return _PersistentBar(
            key: _kPreviewPersistentBar,
            colorScheme: colorScheme,
          );
        }
        return ValueListenableBuilder<bool>(
          valueListenable: kSecondaryPlayerProgressEnabled,
          builder: (context, showProgress, _) => _Capsule(
            key: _kPreviewCapsule,
            colorScheme: colorScheme,
            showProgress: showProgress,
          ),
        );
      },
    );
  }
}

/// 悬浮胶囊：圆角 + 可选外圈进度描边（口径同播放页包边式进度）。
class _Capsule extends StatelessWidget {
  final ColorScheme colorScheme;
  final bool showProgress;

  const _Capsule({
    super.key,
    required this.colorScheme,
    required this.showProgress,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 26,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(13),
        border: showProgress
            ? Border.all(color: colorScheme.primary, width: 2)
            : null,
      ),
      child: Row(
        children: [
          const SizedBox(width: 6),
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 4),
          Container(
            width: 26,
            height: 3,
            decoration: BoxDecoration(
              color: colorScheme.onSurfaceVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      ),
    );
  }
}

/// 底部常驻播放条：全宽、贴底栏上方。
class _PersistentBar extends StatelessWidget {
  final ColorScheme colorScheme;

  const _PersistentBar({super.key, required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 22,
      color: colorScheme.surfaceContainerHigh,
      child: Row(
        children: [
          const SizedBox(width: 6),
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Container(
              height: 3,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 6),
        ],
      ),
    );
  }
}

class _NavBar extends StatelessWidget {
  final ColorScheme colorScheme;
  final int navLabelMode;

  const _NavBar({required this.colorScheme, required this.navLabelMode});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 26,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: colorScheme.outlineVariant)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (final entry in const [
            ('首页', Icons.home_outlined),
            ('搜索', Icons.search),
            ('音乐库', Icons.library_music_outlined),
          ])
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    entry.$2,
                    size: 11,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  // 0 全部显示 / 1 仅当前（首个）显示 / 2 全不显示
                  if (navLabelMode == 0 ||
                      (navLabelMode == 1 && entry.$1 == '首页'))
                    Text(
                      entry.$1,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 7,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
