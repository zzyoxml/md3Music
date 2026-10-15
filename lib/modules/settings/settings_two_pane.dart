// 设置页 Pad 双列容器（列表-详情）。
//
// 左列固定宽 AppLayout.twoPaneMasterWidth，承载分类/搜索列表；右列弹性伸展，
// 内容约束到 AppLayout.twoPaneDetailMaxWidth 居中，避免宽屏拉伸 ListTile。
// 中间 1dp outlineVariant 分隔线，与 ResponsiveScaffold 侧栏分隔一致。
//
// 纯布局容器：master/detail 由 SettingsPage 提供（复用其全部状态与构建方法），
// 空态占位复用 core/layout/adaptive_navigator.dart 的 DetailEmptyState。
import 'package:material_ui/material_ui.dart';

import '../../core/theme/app_dimens.dart';

class SettingsTwoPaneBody extends StatelessWidget {
  const SettingsTwoPaneBody({
    super.key,
    required this.master,
    required this.detail,
  });

  /// 左列内容（分类列表 / 搜索结果）。
  final Widget master;

  /// 右列内容（当前选中分类/子页，或空态占位）。
  final Widget detail;

  @override
  Widget build(BuildContext context) {
    final dividerColor = Theme.of(context).colorScheme.outlineVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: AppLayout.twoPaneMasterWidth,
          child: master,
        ),
        VerticalDivider(thickness: 1, width: 1, color: dividerColor),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: AppLayout.twoPaneDetailMaxWidth,
              ),
              child: detail,
            ),
          ),
        ),
      ],
    );
  }
}
