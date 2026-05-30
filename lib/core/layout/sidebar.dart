import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/kugou_provider.dart';

class Sidebar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  const Sidebar({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
  });

  @override
  Widget build(BuildContext context) {
    final kugou = Provider.of<KugouProvider>(context);
    final isLoggedIn = kugou.isLoggedIn;
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      width: 230,
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(color: cs.onSurfaceVariant.withValues(alpha: 0.07)),
        ),
      ),
      child: Column(
        children: [
          _buildHeader(context, cs, textTheme, isLoggedIn, kugou),
          _buildNavMenu(context, cs, textTheme),
          _buildPlaylistSection(cs, textTheme),
          const Spacer(),
        ],
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    ColorScheme cs,
    TextTheme textTheme,
    bool isLoggedIn,
    KugouProvider kugou,
  ) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: cs.surfaceContainerHighest.withValues(alpha: 0.3),
          border: Border.all(
            color: cs.onSurfaceVariant.withValues(alpha: 0.08),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: () {},
                borderRadius: BorderRadius.circular(14),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: cs.primary.withValues(alpha: 0.1),
                        ),
                        child: Icon(Icons.person, color: cs.primary, size: 18),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              isLoggedIn
                                  ? kugou.userInfo?.nickname ?? '用户'
                                  : '未登录',
                              style: textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: cs.primary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              isLoggedIn
                                  ? 'Lv.${kugou.userInfo?.rawData?['level'] ?? 0}'
                                  : '点击登录',
                              style: textTheme.labelSmall?.copyWith(
                                color: cs.onSurfaceVariant.withValues(
                                  alpha: 0.6,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: () => Navigator.pushNamed(context, '/settings'),
              icon: Icon(Icons.settings, size: 19, color: cs.onSurfaceVariant),
              padding: const EdgeInsets.all(8),
              constraints: const BoxConstraints(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavMenu(
    BuildContext context,
    ColorScheme cs,
    TextTheme textTheme,
  ) {
    final menuGroups = [
      {
        'title': '发现音乐',
        'items': [
          {'name': '为你推荐', 'path': '/', 'icon': Icons.auto_awesome},
          {'name': '探索发现', 'path': '/explore', 'icon': Icons.explore},
        ],
      },
      {
        'title': '我的乐库',
        'items': [
          {'name': '我最喜爱', 'path': '/favorites', 'icon': Icons.favorite},
          {'name': '私人 FM', 'path': '/personal_fm', 'icon': Icons.radio},
          {'name': '我的云盘', 'path': '/cloud', 'icon': Icons.cloud},
          {'name': '播放历史', 'path': '/history', 'icon': Icons.history},
        ],
      },
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: menuGroups.map((group) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: 8,
                  horizontal: 14,
                ),
                child: Text(
                  style: textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.08,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.54),
                  ),
                  group['title'] as String,
                ),
              ),
              ...(group['items'] as List<Map<String, dynamic>>).map((item) {
                final isActive =
                    selectedIndex == _getIndexForPath(item['path'] as String);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: InkWell(
                    onTap: () {
                      if (item['path'] == '/personal_fm') {
                        Navigator.pushNamed(context, '/personal_fm');
                      } else if (item['path'] == '/') {
                        onDestinationSelected(0);
                      }
                    },
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: isActive
                          ? BoxDecoration(
                              borderRadius: BorderRadius.circular(14),
                              color: cs.primary.withValues(alpha: 0.12),
                            )
                          : null,
                      child: Row(
                        children: [
                          Icon(
                            item['icon'] as IconData,
                            size: 18,
                            color: isActive
                                ? cs.primary
                                : cs.onSurfaceVariant.withValues(alpha: 0.6),
                          ),
                          const SizedBox(width: 14),
                          Text(
                            item['name']!,
                            style: textTheme.titleSmall?.copyWith(
                              fontWeight: isActive
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                              color: isActive ? cs.primary : cs.onSurface,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
              const SizedBox(height: 8),
            ],
          );
        }).toList(),
      ),
    );
  }

  Widget _buildPlaylistSection(ColorScheme cs, TextTheme textTheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                '自建歌单',
                style: textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                ),
              ),
              const Spacer(),
              Icon(
                Icons.add,
                size: 14,
                color: cs.onSurfaceVariant.withValues(alpha: 0.6),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 16),
            alignment: Alignment.center,
            child: Text(
              '暂无自建歌单',
              style: textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant.withValues(alpha: 0.4),
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ],
      ),
    );
  }

  int _getIndexForPath(String path) {
    switch (path) {
      case '/':
        return 0;
      case '/charts':
        return 1;
      case '/user':
        return 2;
      case '/more':
        return 3;
      default:
        return -1;
    }
  }
}
