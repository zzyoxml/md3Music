import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/core/layout/page_title_alignment.dart';
import 'package:md3music/providers/tab_config_provider.dart';

/// 一级 / 二级页面只允许有一条判据：悬浮播放条走 [isPrimaryNavPage]（有
/// BuildContext），底部导航栏走壳层等价的 [isPrimaryNavTab]（主布局看不见各 tab
/// 的内层路由栈，只能拿 ResponsiveShell 上报的路由事实）。
///
/// 两处一旦漂移就会出现「底栏按一级留着、播放条却按二级悬浮并随滚动收缩」的矛盾
/// 状态，标题居中的可见 tab（本地音乐 / 排行榜 / 搜索）正是历史分歧点。
void main() {
  const pinnedTab = TabItem(id: 'discover', label: '发现', pinnedTitle: true);
  const centeredTab = TabItem(id: 'library', label: '本地音乐');

  group('isPrimaryNavTab（壳层侧：底栏显隐用）', () {
    test('本地音乐默认入口保留底栏，进入详情后才算二级', () {
      final library = kDefaultTabs.singleWhere((tab) => tab.id == 'library');
      expect(isPrimaryNavTab(library, pushedRoute: false), isTrue);
      expect(isPrimaryNavTab(library, pushedRoute: true), isFalse);
    });
    test('导航栏可见 + 标题左对齐 + 停在栈底才算一级', () {
      expect(isPrimaryNavTab(pinnedTab, pushedRoute: false), isTrue);
    });

    test('内层 push 出栈底即降为二级', () {
      expect(isPrimaryNavTab(pinnedTab, pushedRoute: true), isFalse);
    });

    test('标题居中的可见 tab 算二级（与播放条判据的历史分歧点）', () {
      expect(isPrimaryNavTab(centeredTab, pushedRoute: false), isFalse);
    });

    test('不在导航栏里的页面（tab 查不到）算二级', () {
      expect(isPrimaryNavTab(null, pushedRoute: false), isFalse);
    });
  });

  testWidgets('同一页面在两条路径下得到同一结论', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final reported = <String, bool>{};

    Widget probe(String key, String tabId) => Builder(
      builder: (context) {
        reported[key] = isPrimaryNavPage(context, tabId);
        return const SizedBox.shrink();
      },
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<TabConfigProvider>(
        create: (_) => TabConfigProvider(),
        child: MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                probe('bottom-discover', 'discover'),
                probe('bottom-library', 'library'),
                Align(
                  alignment: Alignment.bottomRight,
                  child: Builder(
                    builder: (context) => TextButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => Scaffold(
                            body: probe('pushed-discover', 'discover'),
                          ),
                        ),
                      ),
                      child: const Text('push'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 栈底：发现与本地音乐都是固定导航入口。
    expect(reported['bottom-discover'], isTrue);
    expect(reported['bottom-library'], isTrue);
    // push 出来的同名页面降为二级（tab 可见但已不在栈底）。
    await tester.tap(find.text('push'));
    await tester.pumpAndSettle();
    expect(reported['pushed-discover'], isFalse);

    expect(
      reported['bottom-discover'],
      isPrimaryNavTab(pinnedTab, pushedRoute: false),
      reason: '播放条侧与壳层侧必须给出同样的答案',
    );
    expect(
      reported['bottom-library'],
      isPrimaryNavTab(
        kDefaultTabs.singleWhere((tab) => tab.id == 'library'),
        pushedRoute: false,
      ),
    );
    expect(
      reported['pushed-discover'],
      isPrimaryNavTab(pinnedTab, pushedRoute: true),
    );
  });
}
