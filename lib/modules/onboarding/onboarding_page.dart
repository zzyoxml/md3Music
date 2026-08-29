import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/motion_constants.dart';
import '../../providers/theme_provider.dart';
import 'onboarding_content.dart';

/// 首次启动引导页。
///
/// [isReview] 为 true 时表示从设置页进入（完成后 pop 返回），
/// 为 false 时表示首次启动（完成后 pushNamedAndRemoveUntil 进入主应用）。
class OnboardingPage extends StatefulWidget {
  final bool isReview;

  const OnboardingPage({super.key, this.isReview = false});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage>
    with TickerProviderStateMixin {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  late final AnimationController _pageAnimController;

  /// 播放器风格选择：false = MD3Music（默认），true = AppleMusic。
  bool _useAmStylePlayer = false;

  @override
  void initState() {
    super.initState();
    _pageAnimController = AnimationController(
      vsync: this,
      duration: M3ExpressiveMotion.emphasisDuration,
      value: 1.0, // 首页初始为完全活跃
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    _pageAnimController.dispose();
    super.dispose();
  }

  void _onPageChanged(int index) {
    setState(() => _currentPage = index);
    _pageAnimController.value = 0.0;
    _pageAnimController.forward();
  }

  void _nextPage() {
    if (_currentPage < onboardingPages.length - 1) {
      _pageController.nextPage(
        duration: M3ExpressiveMotion.emphasisDuration,
        curve: M3ExpressiveMotion.emphasizedEasing,
      );
    }
  }

  void _skip() {
    _pageController.animateToPage(
      onboardingPages.length - 1,
      duration: M3ExpressiveMotion.emphasisDuration,
      curve: M3ExpressiveMotion.emphasizedEasing,
    );
  }

  Future<void> _completeOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kOnboardingCompletedKey, true);

    // 将播放器风格选择应用到 ThemeProvider
    if (mounted) {
      final themeProvider = context.read<ThemeProvider>();
      await themeProvider.setUseAmStylePlayer(_useAmStylePlayer);
    }

    if (!mounted) return;
    if (widget.isReview) {
      Navigator.of(context).pop();
    } else {
      Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;

    return PopScope(
      canPop: widget.isReview,
      onPopInvokedWithResult: (didPop, result) {
        // 首次启动模式：拦截返回键，不退出应用
      },
      child: Scaffold(
        backgroundColor: colorScheme.surface,
        body: SafeArea(
          child: isLandscape
              ? _buildLandscapeLayout(colorScheme)
              : _buildPortraitLayout(colorScheme),
        ),
      ),
    );
  }

  // ── 竖屏布局 ──────────────────────────────────────────────────────────

  Widget _buildPortraitLayout(ColorScheme colorScheme) {
    return Column(
      children: [
        _buildTopBar(colorScheme),
        Expanded(
          flex: 3,
          child: _buildPageView(isLandscape: false),
        ),
        Expanded(
          flex: 1,
          child: _buildBottomControls(colorScheme),
        ),
      ],
    );
  }

  // ── 横屏布局 ──────────────────────────────────────────────────────────

  Widget _buildLandscapeLayout(ColorScheme colorScheme) {
    return Column(
      children: [
        _buildTopBar(colorScheme),
        Expanded(
          child: _buildPageView(isLandscape: true),
        ),
        _buildBottomControls(colorScheme),
      ],
    );
  }

  // ── 顶部栏 ────────────────────────────────────────────────────────────

  Widget _buildTopBar(ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 16),
            child: Text(
              'MD3Music',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
          if (_currentPage < onboardingPages.length - 1)
            TextButton(
              onPressed: _skip,
              child: const Text('跳过'),
            ),
        ],
      ),
    );
  }

  // ── PageView ──────────────────────────────────────────────────────────

  Widget _buildPageView({required bool isLandscape}) {
    return PageView.builder(
      controller: _pageController,
      itemCount: onboardingPages.length,
      onPageChanged: _onPageChanged,
      itemBuilder: (context, index) {
        final page = onboardingPages[index];
        final animation = Tween<double>(begin: 0.0, end: 1.0).animate(
          CurvedAnimation(
            parent: _pageAnimController,
            curve: M3ExpressiveMotion.expressiveEasing,
          ),
        );

        // 播放器风格选择页：交互式特殊渲染
        if (page.isPlayerStylePicker) {
          return _buildPlayerStylePickerPage(page, animation, isLandscape: isLandscape);
        }

        // 播放页隐藏操作页：交互式列表渲染
        if (page.isHiddenOpsPage) {
          return _buildHiddenOpsPage(page, animation, isLandscape: isLandscape);
        }

        // 主题色选择页：交互式取色网格渲染
        if (page.isColorPicker) {
          return _buildColorPickerPage(page, animation, isLandscape: isLandscape);
        }

        if (isLandscape) {
          return _buildLandscapePage(page, index, animation);
        }
        return _buildPortraitPage(page, index, animation);
      },
    );
  }

  Widget _buildPortraitPage(
    OnboardingPageData page,
    int index,
    Animation<double> animation,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          OnboardingIllustration(pageIndex: index, animation: animation),
          const SizedBox(height: 40),
          _buildTitle(page.title, animation, isCenter: true),
          const SizedBox(height: 16),
          _buildDescription(page.description, animation, isCenter: true),
          if (page.highlights.isNotEmpty) ...[
            const SizedBox(height: 24),
            _buildHighlights(page.highlights),
          ],
        ],
      ),
    );
  }

  Widget _buildLandscapePage(
    OnboardingPageData page,
    int index,
    Animation<double> animation,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 48),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          OnboardingIllustration(pageIndex: index, animation: animation),
          const SizedBox(width: 48),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildTitle(page.title, animation, isCenter: false),
                const SizedBox(height: 16),
                _buildDescription(page.description, animation, isCenter: false),
                if (page.highlights.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  _buildHighlights(page.highlights, isCenter: false),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── 播放页隐藏操作页（交互式列表） ──────────────────────────────────

  Widget _buildHiddenOpsPage(
    OnboardingPageData page,
    Animation<double> animation, {
    required bool isLandscape,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    final ops = [
      _HiddenOp(
        icon: Icons.album,
        gesture: '点击',
        target: '歌曲封面下文字',
        action: '跳转专辑详情',
        color: colorScheme.primary,
        onColor: colorScheme.onPrimary,
      ),
      _HiddenOp(
        icon: Icons.lyrics,
        gesture: '长按',
        target: '歌词图标',
        action: '呼出悬浮窗歌词',
        color: colorScheme.secondary,
        onColor: colorScheme.onSecondary,
      ),
      _HiddenOp(
        icon: Icons.translate,
        gesture: '长按',
        target: '翻译图标',
        action: '切换罗马音和翻译',
        color: colorScheme.primary,
        onColor: colorScheme.onPrimary,
      ),
      _HiddenOp(
        icon: Icons.volume_up,
        gesture: '长按',
        target: '右上角音质选项',
        action: '调节应用内音量',
        color: colorScheme.tertiary,
        onColor: colorScheme.onTertiary,
      ),
      _HiddenOp(
        icon: Icons.album,
        gesture: '长按',
        target: '专辑封面',
        action: '进入 / 退出 Zen 沉浸模式',
        color: colorScheme.secondary,
        onColor: colorScheme.onSecondary,
      ),
      _HiddenOp(
        icon: Icons.favorite,
        gesture: '长按',
        target: '收藏红心',
        action: '查看 AI 推荐歌曲',
        color: colorScheme.tertiary,
        onColor: colorScheme.onTertiary,
      ),
    ];

    Widget listWidget = FadeTransition(
      opacity: animation,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (int i = 0; i < ops.length; i++) ...[
            _buildHiddenOpItem(ops[i], colorScheme, i),
            if (i < ops.length - 1)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Divider(
                  height: 1,
                  color: colorScheme.outlineVariant
                      .withValues(alpha: 0.5),
                ),
              ),
          ],
        ],
      ),
    );

    if (isLandscape) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 48),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildTitle(page.title, animation, isCenter: false),
                  const SizedBox(height: 8),
                  _buildDescription(
                    page.description, animation, isCenter: false),
                ],
              ),
            ),
            const SizedBox(width: 32),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 340),
              child: listWidget,
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _buildTitle(page.title, animation, isCenter: true),
          const SizedBox(height: 8),
          _buildDescription(page.description, animation, isCenter: true),
          const SizedBox(height: 24),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: listWidget,
          ),
        ],
      ),
    );
  }

  Widget _buildHiddenOpItem(
    _HiddenOp op,
    ColorScheme colorScheme,
    int index,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          // 图标圆形背景
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: op.color,
            ),
            child: Icon(op.icon, size: 20, color: op.onColor),
          ),
          const SizedBox(width: 14),
          // 文字区
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // 手势标签
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: colorScheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        op.gesture,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: colorScheme.onSecondaryContainer,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        op.target,
                        style: TextStyle(
                          fontSize: 13,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  op.action,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: colorScheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
          // 长按手势指示
          Icon(
            Icons.touch_app,
            size: 18,
            color: colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
          ),
        ],
      ),
    );
  }

  // ── 主题色选择页（交互式取色） ────────────────────────────────────────

  Widget _buildColorPickerPage(
    OnboardingPageData page,
    Animation<double> animation, {
    required bool isLandscape,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    // 监听 ThemeProvider：取色结果与设置页共用同一 Provider，自动同步持久化
    final themeProvider = context.watch<ThemeProvider>();
    final current = themeProvider.manualSeedColor ?? AppTheme.defaultSeedColor;

    Widget colorGrid = FadeTransition(
      opacity: animation,
      child: Wrap(
        spacing: 18,
        runSpacing: 18,
        alignment: WrapAlignment.center,
        children: [
          for (final color in AppTheme.presetSeedColors)
            GestureDetector(
              onTap: () {
                HapticFeedback.lightImpact();
                // 写入 ThemeProvider（内部持久化 + notifyListeners），设置页「主题色」随之同步
                themeProvider.setManualSeedColor(color);
              },
              child: AnimatedContainer(
                duration: M3ExpressiveMotion.defaultDuration,
                curve: M3ExpressiveMotion.expressiveEasing,
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color,
                  border: Border.all(
                    color: color.toARGB32() == current.toARGB32()
                        ? colorScheme.onSurface
                        : colorScheme.outlineVariant,
                    width: color.toARGB32() == current.toARGB32() ? 3 : 1,
                  ),
                ),
                child: color.toARGB32() == current.toARGB32()
                    ? const Icon(Icons.check, color: Colors.white, size: 22)
                    : null,
              ),
            ),
        ],
      ),
    );

    Widget hint = Opacity(
      opacity: animation.value,
      child: Text(
        '点击色块立即更换主题色，与「设置 → 外观 → 主题色」同步',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
      ),
    );

    if (isLandscape) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 48),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildTitle(page.title, animation, isCenter: false),
                  const SizedBox(height: 12),
                  _buildDescription(page.description, animation, isCenter: false),
                  if (page.highlights.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    _buildHighlights(page.highlights, isCenter: false),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 32),
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                colorGrid,
                const SizedBox(height: 12),
                SizedBox(width: 200, child: hint),
              ],
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _buildTitle(page.title, animation, isCenter: true),
          const SizedBox(height: 12),
          _buildDescription(page.description, animation, isCenter: true),
          const SizedBox(height: 28),
          colorGrid,
          const SizedBox(height: 12),
          hint,
          if (page.highlights.isNotEmpty) ...[
            const SizedBox(height: 20),
            _buildHighlights(page.highlights),
          ],
        ],
      ),
    );
  }

  // ── 播放器风格选择页（交互式） ────────────────────────────────────────

  Widget _buildPlayerStylePickerPage(
    OnboardingPageData page,
    Animation<double> animation, {
    required bool isLandscape,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: isLandscape ? 48 : 32,
      ),
      child: isLandscape
          ? Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildTitle(page.title, animation, isCenter: false),
                      const SizedBox(height: 12),
                      _buildDescription(
                        page.description, animation, isCenter: false),
                    ],
                  ),
                ),
                const SizedBox(width: 32),
                _buildStyleCards(colorScheme, animation),
              ],
            )
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildTitle(page.title, animation, isCenter: true),
                const SizedBox(height: 12),
                _buildDescription(page.description, animation, isCenter: true),
                const SizedBox(height: 32),
                _buildStyleCards(colorScheme, animation),
              ],
            ),
    );
  }

  Widget _buildStyleCards(ColorScheme colorScheme, Animation<double> animation) {
    return FadeTransition(
      opacity: animation,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _buildStyleCard(
            colorScheme: colorScheme,
            title: 'MD3Music',
            subtitle: 'Material 3 风格',
            isSelected: !_useAmStylePlayer,
            onTap: () => setState(() => _useAmStylePlayer = false),
            preview: _Md3StylePreview(colorScheme: colorScheme),
          ),
          const SizedBox(width: 16),
          _buildStyleCard(
            colorScheme: colorScheme,
            title: 'Apple Music',
            subtitle: '模糊封面 + 逐字歌词',
            isSelected: _useAmStylePlayer,
            onTap: () => setState(() => _useAmStylePlayer = true),
            preview: _AmStylePreview(colorScheme: colorScheme),
          ),
        ],
      ),
    );
  }

  Widget _buildStyleCard({
    required ColorScheme colorScheme,
    required String title,
    required String subtitle,
    required bool isSelected,
    required VoidCallback onTap,
    required Widget preview,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: M3ExpressiveMotion.defaultDuration,
        curve: M3ExpressiveMotion.expressiveEasing,
        width: 130,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? colorScheme.primary : colorScheme.outlineVariant,
            width: isSelected ? 2.5 : 1,
          ),
        ),
        child: Column(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                height: 160,
                width: double.infinity,
                child: preview,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              title,
              style: TextStyle(
                fontSize: 14,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                color: isSelected
                    ? colorScheme.primary
                    : colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: 11,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            if (isSelected) ...[
              const SizedBox(height: 6),
              Icon(
                Icons.check_circle,
                size: 20,
                color: colorScheme.primary,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTitle(
    String title,
    Animation<double> animation, {
    required bool isCenter,
  }) {
    return FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: Offset(0, isCenter ? 0.3 : 0.0),
          end: Offset.zero,
        ).animate(animation),
        child: Text(
          title,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurface,
              ),
          textAlign: isCenter ? TextAlign.center : TextAlign.start,
        ),
      ),
    );
  }

  Widget _buildDescription(
    String description,
    Animation<double> animation, {
    required bool isCenter,
  }) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(
          parent: _pageAnimController,
          curve: const Interval(0.2, 1.0),
        ),
      ),
      child: Text(
        description,
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
        textAlign: isCenter ? TextAlign.center : TextAlign.start,
      ),
    );
  }

  Widget _buildHighlights(List<String> highlights, {bool isCenter = true}) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: isCenter ? WrapAlignment.center : WrapAlignment.start,
      children: highlights.map((label) {
        return Chip(
          label: Text(label),
          backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
          labelStyle: TextStyle(
            color: Theme.of(context).colorScheme.onSecondaryContainer,
          ),
          side: BorderSide.none,
          visualDensity: VisualDensity.compact,
        );
      }).toList(),
    );
  }

  // ── 底部控制区 ────────────────────────────────────────────────────────

  Widget _buildBottomControls(ColorScheme colorScheme) {
    final isLastPage = _currentPage == onboardingPages.length - 1;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _buildPageIndicator(colorScheme),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            height: 56,
            child: FilledButton(
              onPressed: isLastPage ? _completeOnboarding : _nextPage,
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: AnimatedSwitcher(
                duration: M3ExpressiveMotion.defaultDuration,
                child: Text(
                  isLastPage
                      ? (widget.isReview ? '完成' : '开始使用')
                      : '下一步',
                  key: ValueKey(isLastPage),
                  style: const TextStyle(fontSize: 16),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPageIndicator(ColorScheme colorScheme) {
    return AnimatedBuilder(
      animation: _pageController,
      builder: (context, _) {
        double page = _pageController.hasClients
            ? _pageController.page ?? 0.0
            : _currentPage.toDouble();
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(onboardingPages.length, (index) {
            final distance = (page - index).abs();
            final isActive = distance < 0.5;
            final activeness = (1.0 - distance.clamp(0.0, 1.0)).clamp(0.0, 1.0);

            return AnimatedContainer(
              duration: M3ExpressiveMotion.defaultDuration,
              curve: M3ExpressiveMotion.expressiveEasing,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              width: isActive ? lerpDouble(8, 24, activeness)! : 8,
              height: 8,
              decoration: BoxDecoration(
                color: isActive
                    ? Color.lerp(
                        colorScheme.outline,
                        colorScheme.primary,
                        activeness,
                      )
                    : colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(4),
              ),
            );
          }),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// 播放器风格预览组件
// ─────────────────────────────────────────────────────────────────────

/// MD3Music 风格播放器预览：简洁的 Material 3 卡片布局。
class _Md3StylePreview extends StatelessWidget {
  final ColorScheme colorScheme;

  const _Md3StylePreview({required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: colorScheme.surface,
      child: Column(
        children: [
          // 顶栏
          Container(
            height: 32,
            color: colorScheme.surfaceContainer,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.centerLeft,
            child: Row(
              children: [
                Icon(Icons.keyboard_arrow_down,
                    size: 16, color: colorScheme.onSurfaceVariant),
                const Spacer(),
                Icon(Icons.more_horiz,
                    size: 14, color: colorScheme.onSurfaceVariant),
              ],
            ),
          ),
          // 封面
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  // 专辑封面
                  Expanded(
                    flex: 3,
                    child: Container(
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(
                        child: Icon(
                          Icons.music_note,
                          size: 36,
                          color: colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  // 歌曲名
                  Container(
                    height: 6,
                    width: 60,
                    decoration: BoxDecoration(
                      color: colorScheme.onSurface,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(height: 3),
                  // 歌手名
                  Container(
                    height: 4,
                    width: 40,
                    decoration: BoxDecoration(
                      color: colorScheme.onSurfaceVariant,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 6),
                  // 进度条
                  Container(
                    height: 3,
                    decoration: BoxDecoration(
                      color: colorScheme.primary,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 6),
                  // 控件
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      Icon(Icons.skip_previous,
                          size: 18, color: colorScheme.onSurface),
                      Icon(Icons.play_arrow,
                          size: 22, color: colorScheme.primary),
                      Icon(Icons.skip_next,
                          size: 18, color: colorScheme.onSurface),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Apple Music 风格播放器预览：模糊封面背景 + 逐字歌词。
class _AmStylePreview extends StatelessWidget {
  final ColorScheme colorScheme;

  const _AmStylePreview({required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            colorScheme.primary.withValues(alpha: 0.6),
            colorScheme.surface,
          ],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          children: [
            // 顶栏
            Row(
              children: [
                Icon(Icons.keyboard_arrow_down,
                    size: 16, color: colorScheme.onSurface),
                const Spacer(),
                Icon(Icons.more_horiz,
                    size: 14, color: colorScheme.onSurface),
              ],
            ),
            const SizedBox(height: 8),
            // 逐字歌词区域
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // 上一句歌词（暗淡）
                  _buildLyricBar(50, colorScheme.onSurface, 0.2),
                  const SizedBox(height: 6),
                  // 当前歌词（高亮，较长）
                  _buildLyricBar(80, colorScheme.primary, 1.0),
                  const SizedBox(height: 6),
                  // 下一句歌词（暗淡）
                  _buildLyricBar(45, colorScheme.onSurface, 0.2),
                  const SizedBox(height: 6),
                  // 下下句歌词（更暗）
                  _buildLyricBar(35, colorScheme.onSurface, 0.1),
                ],
              ),
            ),
            const SizedBox(height: 8),
            // 底部封面 + 控件
            Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: colorScheme.primary.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Icon(
                    Icons.music_note,
                    size: 14,
                    color: colorScheme.onPrimary,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        height: 5,
                        width: 45,
                        decoration: BoxDecoration(
                          color: colorScheme.onSurface,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Container(
                        height: 3,
                        width: 30,
                        decoration: BoxDecoration(
                          color: colorScheme.onSurfaceVariant,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.play_arrow,
                    size: 18, color: colorScheme.onSurface),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLyricBar(double width, Color color, double opacity) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        height: 7,
        width: width,
        decoration: BoxDecoration(
          color: color.withValues(alpha: opacity),
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// 播放页隐藏操作数据模型
// ─────────────────────────────────────────────────────────────────────

class _HiddenOp {
  final IconData icon;
  final String gesture;
  final String target;
  final String action;
  final Color color;
  final Color onColor;

  const _HiddenOp({
    required this.icon,
    required this.gesture,
    required this.target,
    required this.action,
    required this.color,
    required this.onColor,
  });
}
