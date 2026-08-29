import 'dart:math' as math;

import 'package:flutter/material.dart';

/// SharedPreferences 持久化 key：标记用户是否已完成引导。
const String kOnboardingCompletedKey = 'onboarding_completed';

/// 引导页单页内容数据模型。
class OnboardingPageData {
  final IconData icon;
  final String title;
  final String description;
  final List<String> highlights;

  /// 是否为播放器风格选择页（交互式特殊页面）。
  final bool isPlayerStylePicker;

  /// 是否为播放页隐藏操作页（交互式特殊页面）。
  final bool isHiddenOpsPage;

  /// 是否为主题色选择页（交互式特殊页面）。
  final bool isColorPicker;

  const OnboardingPageData({
    required this.icon,
    required this.title,
    required this.description,
    this.highlights = const [],
    this.isPlayerStylePicker = false,
    this.isHiddenOpsPage = false,
    this.isColorPicker = false,
  });
}

/// 8 页引导内容静态配置。
const List<OnboardingPageData> onboardingPages = [
  OnboardingPageData(
    icon: Icons.explore,
    title: '发现你的音乐',
    description: '在「发现」页浏览每日推荐、新歌速递，点击搜索图标即可搜索全网歌曲。',
    highlights: ['每日推荐', '搜索发现', '新歌速递'],
  ),
  OnboardingPageData(
    icon: Icons.play_circle_fill,
    title: '播放与歌词',
    description: '点击任意歌曲弹出迷你播放条，点击展开全屏播放器，享受逐字歌词体验。',
    highlights: ['全屏播放器', '逐字歌词', '桌面歌词'],
  ),
  OnboardingPageData(
    icon: Icons.touch_app,
    title: '播放页隐藏操作',
    description: '播放页藏着许多快捷功能，长按图标即可解锁。',
    isHiddenOpsPage: true,
  ),
  OnboardingPageData(
    icon: Icons.radio,
    title: '私人 FM 与收藏',
    description: '私人 FM 为你智能推荐歌曲，点击心形图标收藏喜欢的音乐和歌单。',
    highlights: ['智能推荐', '一键收藏', '歌单管理'],
  ),
  OnboardingPageData(
    icon: Icons.delete_sweep,
    title: '长按批量管理',
    description: '长按歌曲或歌单进入批量管理模式，勾选多个项目后一键删除或移除。',
    highlights: ['长按触发', '多选删除', '歌单清理'],
  ),
  OnboardingPageData(
    icon: Icons.palette,
    title: '个性化你的体验',
    description: '8 种主题色、动态取色、OLED 纯黑模式，打造属于你的视觉风格。',
    highlights: ['Material 3 主题', '动态色', 'OLED 纯黑'],
    isColorPicker: true,
  ),
  OnboardingPageData(
    icon: Icons.style,
    title: '选择播放器风格',
    description: '挑选你喜欢的播放器界面，随时可在设置中切换。',
    isPlayerStylePicker: true,
  ),
  OnboardingPageData(
    icon: Icons.rocket_launch,
    title: '开始你的音乐之旅',
    description: '一切准备就绪，随时可在设置页的「关于」分区重新查看本教程。',
    highlights: [],
  ),
];

// ─────────────────────────────────────────────────────────────────────
// 插画组件
// ─────────────────────────────────────────────────────────────────────

/// 引导页插画组件：根据 [pageIndex] 和 [animation]（0→1 活跃度）绘制不同插画。
///
/// 所有颜色取自 [ColorScheme]，确保浅色/深色/OLED/动态色模式下均正确显示。
/// 使用 [RepaintBoundary] 包裹以隔离重绘区域。
class OnboardingIllustration extends StatelessWidget {
  final int pageIndex;
  final Animation<double> animation;

  const OnboardingIllustration({
    super.key,
    required this.pageIndex,
    required this.animation,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return RepaintBoundary(
      child: SizedBox(
        width: 260,
        height: 260,
        child: AnimatedBuilder(
          animation: animation,
          builder: (context, _) {
            switch (pageIndex) {
              case 0:
                return _DiscoverIllustration(
                  colorScheme: colorScheme,
                  progress: animation.value,
                );
              case 1:
                return _PlayLyricsIllustration(
                  colorScheme: colorScheme,
                  progress: animation.value,
                );
              // case 2 是播放页隐藏操作页，不使用插画（交互式列表）
              case 3:
                return _FmFavoritesIllustration(
                  colorScheme: colorScheme,
                  progress: animation.value,
                );
              case 4:
                return _LongPressDeleteIllustration(
                  colorScheme: colorScheme,
                  progress: animation.value,
                );
              // case 5 是主题色选择页，不使用插画（交互式取色网格）
              // case 6 是播放器风格选择页，不使用插画（交互式卡片）
              case 7:
                return _GetStartedIllustration(
                  colorScheme: colorScheme,
                  progress: animation.value,
                );
              default:
                return const SizedBox.shrink();
            }
          },
        ),
      ),
    );
  }
}

// ── Page 0: 发现音乐 ──────────────────────────────────────────────────

class _DiscoverIllustration extends StatelessWidget {
  final ColorScheme colorScheme;
  final double progress;

  const _DiscoverIllustration({
    required this.colorScheme,
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    // 3 层同心圆扩散，半径随 progress 增大、透明度递减
    return Stack(
      alignment: Alignment.center,
      children: [
        // 外层扩散圆环
        for (int i = 0; i < 3; i++)
          Transform.scale(
            scale: 0.6 + (progress * 0.4) + i * 0.15,
            child: Container(
              width: 180,
              height: 180,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: colorScheme.primary.withValues(
                    alpha: (0.3 - i * 0.08) * progress,
                  ),
                  width: 2,
                ),
              ),
            ),
          ),
        // 中心圆 + 图标
        Container(
          width: 120,
          height: 120,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: colorScheme.primaryContainer,
          ),
          child: Icon(
            Icons.explore,
            size: 56,
            color: colorScheme.onPrimaryContainer,
          ),
        ),
        // 四周散布的小音符
        ..._buildFloatingNotes(),
      ],
    );
  }

  List<Widget> _buildFloatingNotes() {
    final angles = [0.0, math.pi / 2, math.pi, 3 * math.pi / 2];
    final radius = 110.0;
    return angles.asMap().entries.map((entry) {
      final i = entry.key;
      final angle = entry.value + i * 0.3;
      final dx = math.cos(angle) * radius;
      final dy = math.sin(angle) * radius;
      final delay = i * 0.15;
      final itemProgress = ((progress - delay) / (1 - delay)).clamp(0.0, 1.0);
      return Positioned(
        left: 130 + dx - 14,
        top: 130 + dy - 14,
        child: Opacity(
          opacity: itemProgress,
          child: Transform.scale(
            scale: 0.5 + itemProgress * 0.5,
            child: Icon(
              Icons.music_note,
              size: 24,
              color: colorScheme.tertiary,
            ),
          ),
        ),
      );
    }).toList();
  }
}

// ── Page 1: 播放与歌词 ────────────────────────────────────────────────

class _PlayLyricsIllustration extends StatelessWidget {
  final ColorScheme colorScheme;
  final double progress;

  const _PlayLyricsIllustration({
    required this.colorScheme,
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    final slideUp = (1 - progress) * 20;
    return Stack(
      alignment: Alignment.center,
      children: [
        // 上方：全屏播放器 mockup（半透明卡片 + 3 行歌词）
        Transform.translate(
          offset: Offset(0, -50 - slideUp),
          child: Opacity(
            opacity: progress,
            child: Container(
              width: 180,
              height: 100,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildLyricLine('上一句歌词', false),
                  const SizedBox(height: 6),
                  _buildLyricLine('当前歌词高亮', true),
                  const SizedBox(height: 6),
                  _buildLyricLine('下一句歌词', false),
                ],
              ),
            ),
          ),
        ),
        // 中间：向上箭头
        Opacity(
          opacity: progress,
          child: Icon(
            Icons.keyboard_arrow_up,
            size: 32,
            color: colorScheme.primary,
          ),
        ),
        // 下方：迷你播放条 mockup
        Transform.translate(
          offset: Offset(0, 70 + slideUp),
          child: Opacity(
            opacity: progress,
            child: Container(
              width: 200,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: colorScheme.primary,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Icon(
                      Icons.music_note,
                      size: 20,
                      color: colorScheme.onPrimary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          height: 8,
                          width: 80,
                          decoration: BoxDecoration(
                            color: colorScheme.onSurfaceVariant,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Container(
                          height: 3,
                          decoration: BoxDecoration(
                            color: colorScheme.primary,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.play_arrow, size: 24, color: colorScheme.onSurface),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLyricLine(String text, bool isHighlighted) {
    return Container(
      height: 10,
      width: isHighlighted ? 120 : 80,
      decoration: BoxDecoration(
        color: isHighlighted
            ? colorScheme.primary
            : colorScheme.onSecondaryContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(5),
      ),
    );
  }
}

// ── Page 3: 私人FM与收藏 ─────────────────────────────────────────────

class _FmFavoritesIllustration extends StatelessWidget {
  final ColorScheme colorScheme;
  final double progress;

  const _FmFavoritesIllustration({
    required this.colorScheme,
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        // 中心圆 + FM 图标
        Transform.scale(
          scale: 0.7 + progress * 0.3,
          child: Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: colorScheme.primaryContainer,
            ),
            child: Icon(
              Icons.radio,
              size: 56,
              color: colorScheme.onPrimaryContainer,
            ),
          ),
        ),
        // 左上角心形
        Positioned(
          left: 40,
          top: 50,
          child: Transform.scale(
            scale: 0.3 + progress * 0.7,
            child: Opacity(
              opacity: progress,
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colorScheme.primary,
                ),
                child: Icon(
                  Icons.favorite,
                  size: 24,
                  color: colorScheme.onPrimary,
                ),
              ),
            ),
          ),
        ),
        // 右下角心形
        Positioned(
          right: 40,
          bottom: 50,
          child: Transform.scale(
            scale: 0.3 + progress * 0.7,
            child: Opacity(
              opacity: progress,
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colorScheme.tertiary,
                ),
                child: Icon(
                  Icons.favorite,
                  size: 20,
                  color: colorScheme.onTertiary,
                ),
              ),
            ),
          ),
        ),
        // 装饰：音波线条
        ..._buildSoundWaves(),
      ],
    );
  }

  List<Widget> _buildSoundWaves() {
    return List.generate(5, (i) {
      final delay = i * 0.1;
      final itemProgress = ((progress - delay) / (1 - delay)).clamp(0.0, 1.0);
      final isLeft = i < 2;
      final offset = (i + 1) * 18.0;
      return Positioned(
        left: isLeft ? 30 - offset : null,
        right: !isLeft ? 30 - offset : null,
        top: 130 - (i % 2) * 10,
        child: Opacity(
          opacity: itemProgress * 0.5,
          child: Icon(
            Icons.graphic_eq,
            size: 24,
            color: colorScheme.primary,
          ),
        ),
      );
    });
  }
}

// ── Page 4: 长按批量管理 ─────────────────────────────────────────────

class _LongPressDeleteIllustration extends StatelessWidget {
  final ColorScheme colorScheme;
  final double progress;

  const _LongPressDeleteIllustration({
    required this.colorScheme,
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        // 列表 mockup
        Opacity(
          opacity: progress,
          child: Container(
            width: 200,
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 第1行：未选中
                _buildListItem(
                  colorScheme: colorScheme,
                  isSelected: false,
                  isDimmed: false,
                ),
                const Divider(height: 1),
                // 第2行：选中（高亮）
                _buildListItem(
                  colorScheme: colorScheme,
                  isSelected: true,
                  isDimmed: false,
                ),
                const Divider(height: 1),
                // 第3行：未选中
                _buildListItem(
                  colorScheme: colorScheme,
                  isSelected: false,
                  isDimmed: false,
                ),
              ],
            ),
          ),
        ),
        // 手指触摸指示（长按手势）
        Positioned(
          right: 30,
          top: 70,
          child: Transform.scale(
            scale: 0.3 + progress * 0.7,
            child: Opacity(
              opacity: progress,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colorScheme.primary.withValues(alpha: 0.2),
                  border: Border.all(
                    color: colorScheme.primary,
                    width: 2,
                  ),
                ),
                child: Icon(
                  Icons.touch_app,
                  size: 22,
                  color: colorScheme.primary,
                ),
              ),
            ),
          ),
        ),
        // 底部删除按钮提示
        Positioned(
          bottom: 10,
          child: Transform.scale(
            scale: 0.5 + progress * 0.5,
            child: Opacity(
              opacity: progress,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.delete_outline,
                      size: 18,
                      color: colorScheme.onErrorContainer,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '删除 (1)',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onErrorContainer,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildListItem({
    required ColorScheme colorScheme,
    required bool isSelected,
    required bool isDimmed,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          // 复选框
          isSelected
              ? Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: colorScheme.primary,
                  ),
                  child: Icon(
                    Icons.check,
                    size: 14,
                    color: colorScheme.onPrimary,
                  ),
                )
              : Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: colorScheme.outline,
                      width: 2,
                    ),
                  ),
                ),
          const SizedBox(width: 10),
          // 封面缩略
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: isSelected
                  ? colorScheme.primaryContainer
                  : colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              Icons.music_note,
              size: 16,
              color: isSelected
                  ? colorScheme.onPrimaryContainer
                  : colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 10),
          // 歌曲名占位条
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: 7,
                  width: 70,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 3),
                Container(
                  height: 4,
                  width: 45,
                  decoration: BoxDecoration(
                    color: colorScheme.onSurfaceVariant
                        .withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(2),
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

// ── Page 7: 开始使用 ─────────────────────────────────────────────────

class _GetStartedIllustration extends StatelessWidget {
  final ColorScheme colorScheme;
  final double progress;

  const _GetStartedIllustration({
    required this.colorScheme,
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        // 渐变圆背景
        Transform.scale(
          scale: 0.5 + progress * 0.5,
          child: Container(
            width: 140,
            height: 140,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  colorScheme.primaryContainer,
                  colorScheme.secondaryContainer,
                ],
              ),
            ),
          ),
        ),
        // 火箭图标
        Transform.translate(
          offset: Offset(0, -10 + (1 - progress) * 15),
          child: Icon(
            Icons.rocket_launch,
            size: 64,
            color: colorScheme.onPrimaryContainer,
          ),
        ),
        // 散布的星星
        ..._buildStars(),
      ],
    );
  }

  List<Widget> _buildStars() {
    final positions = [
      const Offset(50, 40),
      const Offset(200, 50),
      const Offset(40, 180),
      const Offset(210, 170),
      const Offset(130, 20),
      const Offset(120, 220),
    ];
    return positions.asMap().entries.map((entry) {
      final i = entry.key;
      final pos = entry.value;
      final delay = i * 0.1;
      final itemProgress = ((progress - delay) / (1 - delay)).clamp(0.0, 1.0);
      return Positioned(
        left: pos.dx,
        top: pos.dy,
        child: Opacity(
          opacity: itemProgress,
          child: Transform.scale(
            scale: 0.3 + itemProgress * 0.7,
            child: Icon(
              Icons.star,
              size: 16,
              color: colorScheme.tertiary,
            ),
          ),
        ),
      );
    }).toList();
  }
}
