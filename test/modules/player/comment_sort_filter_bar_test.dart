import 'package:flutter_test/flutter_test.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:md3music/modules/player/comment_sort_filter_bar.dart';
import 'package:md3music/services/kugou_api/comment_sort.dart';
import 'package:material_ui/material_ui.dart';

/// 固定宽度的顶栏宿主：让三控件在一行里排开，避免宽度约束干扰高度测量。
class _Host extends StatelessWidget {
  const _Host({required this.isAmStyle, this.showComposeButton = true});

  final bool isAmStyle;
  final bool showComposeButton;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            // 400 而不是 360：三控件自然宽约 192.6 + 100 + 8 + 32 = 332.6，
            // 360 宽扣掉左右 16 padding 只剩 328，会溢出 4.6px 让测试因
            // RenderFlex overflow 失败，而本任务只关心高度是否相等。
            // 真机窄屏的溢出是另一个问题，见 Task 8 的验证清单。
            width: 400,
            child: CommentSortFilterBar(
              sortMode: CommentSortMode.hottest,
              onSortModeChanged: (_) {},
              scope: CommentScope.all,
              scopeItems: const [
                M3EDropdownItem(
                  label: '全部',
                  value: CommentScope.all,
                  selected: true,
                ),
                M3EDropdownItem(label: '歌手', value: CommentScope.singer),
                M3EDropdownItem(label: '我的', value: CommentScope.mine),
              ],
              onScopeChanged: (_) {},
              isAmStyle: isAmStyle,
              showComposeButton: showComposeButton,
              onCompose: () {},
            ),
          ),
        ),
      ),
    );
  }
}

void main() {
  group('CommentSortFilterBar 高度', () {
    testWidgets('MD3 皮肤：排序分段 / 范围下拉 / 写评论三者等高', (tester) async {
      await tester.pumpWidget(const _Host(isAmStyle: false));

      expect(
        tester.getSize(find.byType(M3EToggleButtonGroup)).height,
        kCommentBarControlHeight,
      );
      expect(
        tester
            .getSize(find.byType(M3EDropdownMenu<CommentScope>))
            .height,
        kCommentBarControlHeight,
      );
      expect(
        tester.getSize(find.byType(M3EFilledButton)).height,
        kCommentBarControlHeight,
      );
    });

    testWidgets('AM 皮肤：三者也必须等高（AM 走自定义文字样式）', (tester) async {
      await tester.pumpWidget(const _Host(isAmStyle: true));

      expect(
        tester.getSize(find.byType(M3EToggleButtonGroup)).height,
        kCommentBarControlHeight,
      );
      expect(
        tester
            .getSize(find.byType(M3EDropdownMenu<CommentScope>))
            .height,
        kCommentBarControlHeight,
      );
      expect(
        tester.getSize(find.byType(M3EFilledButton)).height,
        kCommentBarControlHeight,
      );
    });

    testWidgets('写评论按钮与排序分段垂直居中对齐', (tester) async {
      await tester.pumpWidget(const _Host(isAmStyle: false));

      final sort = tester.getRect(find.byType(M3EToggleButtonGroup));
      final compose = tester.getRect(find.byType(M3EFilledButton));
      expect(sort.height, compose.height);
      expect(compose.center.dy, closeTo(sort.center.dy, 0.01));
    });

    testWidgets('showComposeButton = false 时不显示写评论按钮（评论托盘内联输入框）', (
      tester,
    ) async {
      await tester.pumpWidget(
        const _Host(isAmStyle: false, showComposeButton: false),
      );

      expect(find.byType(M3EFilledButton), findsNothing);
      expect(find.byType(M3EToggleButtonGroup), findsOneWidget);
      expect(
        tester
            .getSize(find.byType(M3EDropdownMenu<CommentScope>))
            .height,
        kCommentBarControlHeight,
      );
    });
  });
}