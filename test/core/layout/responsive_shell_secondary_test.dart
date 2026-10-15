import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/layout/adaptive_navigator.dart';
import 'package:md3music/core/layout/responsive_shell.dart';
import 'package:md3music/providers/tab_config_provider.dart';

/// 底栏收起的判据回归：底栏挂在壳层之外，只有 [ResponsiveShell] 看得见各 tab 的
/// 内层路由栈与详情面板形态，所以「是否停在二级页面（及以后）」由它用唯一判据
/// `isPrimaryNavTab` 定级后上报，主布局据此收起 NavigationBar。
///
/// 定级收口在同一处意味着：悬浮播放条按二级处理（用悬浮条而非固定在菜单栏上方的
/// 常驻条）的页面，底栏收起的认定必然一致，反之亦然。
void main() {
  // 标题左对齐（pinnedTitle）才算一级；标题居中的 tab 与播放条一样按二级处理。
  const pinnedTab = TabItem(id: 'testtab', label: 'T', pinnedTitle: true);
  const centeredTab = TabItem(id: 'testtab', label: 'T');

  /// 手机窄宽：低于双栏断点，详情面板会铺满整宽。
  const phoneSize = Size(400, 800);

  Future<List<bool>> pumpShell(
    WidgetTester tester,
    TabItem tab,
    Widget Function(String) page,
  ) async {
    tester.view.physicalSize = phoneSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final reports = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: ResponsiveShell(
          visibleTabs: [tab],
          selectedIndex: 0,
          onSecondaryRouteChanged: reports.add,
          pageBuilder: page,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return reports;
  }

  testWidgets('一级页面（固定标题 + 栈底）不上报二级', (tester) async {
    final reports = await pumpShell(tester, pinnedTab, _centralEntryPage);
    expect(reports, isEmpty);
    expect(find.text('push'), findsOneWidget);
  });

  testWidgets('中央栈 push 出二级页上报 true，返回后上报 false', (tester) async {
    final reports = await pumpShell(tester, pinnedTab, _centralEntryPage);

    await tester.tap(find.text('push'));
    await tester.pumpAndSettle();
    expect(reports.last, isTrue, reason: '二级页在栈顶时应上报，底栏据此收起');

    await tester.tap(find.text('back'));
    await tester.pumpAndSettle();
    expect(reports.last, isFalse, reason: '回到栈底后底栏要恢复');
  });

  // 二级态翻转必须等路由转场收敛再上报：底栏在转场途中收起/恢复会当场改变
  // Tab 栈高度，框架 Hero 的飞行盒子按起飞那一刻的 navigatorSize 换算，
  // 高度差会整段加在飞行封面上（真机实测：一级页进详情底栏收起、封面拉长）。
  // 用 10s 长时长的路由把「转场中」窗口放大到可断言：测试环境里 FakeAsync 的
  // ticker 时间戳会让常规 MaterialPageRoute 偶发瞬间收敛，钉不住时机。
  testWidgets('二级上报推迟到路由转场收敛，转场中底栏保持原形态', (tester) async {
    final reports = await pumpShell(tester, pinnedTab, _slowCentralEntryPage);

    await tester.tap(find.text('push'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(reports, isEmpty,
        reason: '转场未收敛不上报：此刻收底栏会把飞行中的封面拉长');

    await tester.pump(const Duration(seconds: 10));
    expect(reports.last, isTrue, reason: '转场收敛后补报二级态，底栏再收起');
  });

  // LaunchPad 隐藏 tab / 快捷方式入口只能从主布局编程式推栈（手里只有壳层句柄，
  // 没有页内 context）。必须与页内 push 落在同一个中央栈上：深度观察者上报二级态，
  // 底栏才有收起动画；推根 Navigator 会整页盖住壳层，收起链路全程不触发。
  testWidgets('pushCurrentTabRoute 推中央栈上报二级，返回后恢复', (tester) async {
    final reports = await pumpShell(tester, pinnedTab, _centralEntryPage);
    final shell = tester.state<ResponsiveShellState>(
      find.byType(ResponsiveShell),
    );

    final pushed = shell.pushCurrentTabRoute<void>((_) => const _Two());
    expect(pushed, isNotNull, reason: 'shell 已构建时必须返回推栈 Future');
    await tester.pumpAndSettle();
    expect(find.text('back'), findsOneWidget, reason: '新页面应落在中央栈顶');
    expect(
      reports.last,
      isTrue,
      reason: '编程式推栈与页内 push 同一条上报链路，底栏据此收起',
    );

    await tester.tap(find.text('back'));
    await tester.pumpAndSettle();
    expect(reports.last, isFalse, reason: '回到栈底后底栏要恢复');
  });

  testWidgets('标题居中的主导航 tab 在栈底仍保留底栏', (
    tester,
  ) async {
    final reports = await pumpShell(tester, centeredTab, _centralEntryPage);
    expect(
      reports,
      isEmpty,
      reason: '主导航入口的底栏不应由标题对齐决定',
    );
  });

  // 「收藏 → 歌单详情」的二级上报回归：单栏几何下 AdaptiveNav.openDetail 把详情
  // 推到中央栈，中央栈的深度观察者直接上报二级（与 A 类 tab 同链路）；双栏几何下
  // 详情挂在详情面板自己的 Navigator 上，中央观察者看不见，由
  // onDetailFullscreenChanged（_detailExclusive）补报。两条链路都收口在
  // ResponsiveShell 的同一次定级上报里。
  testWidgets('双栏 tab 单栏态下打开详情上报 true，返回后上报 false', (
    tester,
  ) async {
    final reports = await pumpShell(tester, _favoritesTab, _detailEntryPage);
    expect(reports, isEmpty, reason: '收藏是固定标题的一级 tab，栈底不该收起底栏');

    await tester.tap(find.text('openDetail'));
    await tester.pumpAndSettle();
    expect(
      reports.last,
      isTrue,
      reason: '详情面板独占整宽 = 二级页面，底栏要收起',
    );

    await tester.tap(find.text('back'));
    await tester.pumpAndSettle();
    expect(reports.last, isFalse, reason: '回到左栏列表即恢复底栏');
  });

  // 托盘/对话框这类遮罩弹层（PopupRoute）不是页面层级变化：下方一级页面仍在场、
  // 可点遮罩关闭，不应把底栏收起来（2026-10-05 用户报告：本地音乐右下角 ➕
  // 弹出扫描托盘时底栏收起、关闭又展开，弹层期间让出的空间无内容承接）。
  testWidgets('一级页面弹出底部托盘不上报二级，关闭后也不上报', (tester) async {
    final reports = await pumpShell(tester, pinnedTab, _sheetEntryPage);
    expect(reports, isEmpty, reason: '初始为一级页面，不该有任何上报');

    await tester.tap(find.text('sheet'));
    await tester.pumpAndSettle();
    expect(find.text('sheetContent'), findsOneWidget);
    expect(reports, isEmpty, reason: '托盘在栈顶时底栏必须保持展开');

    // 点托盘上方的遮罩区域关闭（400×800，托盘高 120，顶部为空白 barrier）
    await tester.tapAt(const Offset(200, 100));
    await tester.pumpAndSettle();
    expect(find.text('sheetContent'), findsNothing);
    expect(reports, isEmpty, reason: '关闭托盘同样不该触发收起/展开');
  });

  testWidgets('一级页面弹出对话框不上报二级', (tester) async {
    final reports = await pumpShell(tester, pinnedTab, _dialogEntryPage);

    await tester.tap(find.text('dialog'));
    await tester.pumpAndSettle();
    expect(find.text('dialogContent'), findsOneWidget);
    expect(reports, isEmpty, reason: 'DialogRoute 同为 PopupRoute，不算二级');
  });

  testWidgets('二级页上叠加托盘再关闭，二级判定不回摆', (tester) async {
    final reports = await pumpShell(tester, pinnedTab, _centralEntryPage2);

    await tester.tap(find.text('push'));
    await tester.pumpAndSettle();
    expect(reports.last, isTrue, reason: 'push 出二级页应上报收起底栏');
    final lengthAfterPush = reports.length;

    await tester.tap(find.text('sheet'));
    await tester.pumpAndSettle();
    expect(find.text('sheetContent'), findsOneWidget);

    await tester.tapAt(const Offset(200, 100));
    await tester.pumpAndSettle();
    expect(
      reports.length,
      lengthAfterPush,
      reason: '二级页之上弹层开/关都不产生额外上报（_reportedSecondary 去重）',
    );
    expect(reports.last, isTrue, reason: '弹层关闭后二级页仍在栈顶，底栏保持收起');

    await tester.tap(find.text('back'));
    await tester.pumpAndSettle();
    expect(reports.last, isFalse, reason: '回到栈底即恢复底栏');
  });
}

const _favoritesTab = TabItem(id: 'favorites', label: '收藏', pinnedTitle: true);

/// 普通页面：入口按钮直接 push 到当前 tab 的中央 Navigator。
Widget _centralEntryPage(String id) => Scaffold(
  body: Center(
    child: Builder(
      builder: (context) => TextButton(
        onPressed: () => Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const _Two())),
        child: const Text('push'),
      ),
    ),
  ),
);

/// 同 _centralEntryPage，但 push 一条 10s 长时长的路由：把「转场中」窗口放大，
/// 供上报时机用例断言（见「二级上报推迟到路由转场收敛」）。
Widget _slowCentralEntryPage(String id) => Scaffold(
  body: Center(
    child: Builder(
      builder: (context) => TextButton(
        onPressed: () => Navigator.of(context).push(
          PageRouteBuilder<void>(
            transitionDuration: const Duration(seconds: 10),
            reverseTransitionDuration: const Duration(seconds: 10),
            pageBuilder: (_, _, _) => const _Two(),
          ),
        ),
        child: const Text('push'),
      ),
    ),
  ),
);

/// 双栏 tab 页面（收藏 / 本地音乐等）：详情入口统一走 AdaptiveNav.openDetail，
/// 在壳层里会被分派到详情面板的 Navigator。
Widget _detailEntryPage(String id) => Scaffold(
  body: Center(
    child: Builder(
      builder: (context) => TextButton(
        onPressed: () =>
            AdaptiveNav.openDetail<void>(context, (_) => const _Two()),
        child: const Text('openDetail'),
      ),
    ),
  ),
);

class _Two extends StatelessWidget {
  const _Two();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('back'),
        ),
      ),
    );
  }
}

/// 一级页入口：按钮弹出底部托盘（与本地音乐页 `_showScanMenu` 同族路由：
/// showM3EModalBottomSheet 内部即 showModalBottomSheet）。
Widget _sheetEntryPage(String id) => Scaffold(
  body: Center(
    child: Builder(
      builder: (context) => TextButton(
        onPressed: () => showModalBottomSheet<void>(
          context: context,
          builder: (_) => const SizedBox(
            height: 120,
            child: Center(child: Text('sheetContent')),
          ),
        ),
        child: const Text('sheet'),
      ),
    ),
  ),
);

/// 一级页入口：按钮弹出对话框（DialogRoute 同为 PopupRoute）。
/// useRootNavigator: false 让它落在 tab 内层 Navigator——showDialog 默认落根
/// Navigator，观察者根本看不见，用例就修不修判据都恒绿、钉不住现状误判。
Widget _dialogEntryPage(String id) => Scaffold(
  body: Center(
    child: Builder(
      builder: (context) => TextButton(
        onPressed: () => showDialog<void>(
          context: context,
          useRootNavigator: false,
          builder: (_) => const AlertDialog(
            content: Text('dialogContent'),
          ),
        ),
        child: const Text('dialog'),
      ),
    ),
  ),
);

/// 同 _centralEntryPage，但二级页带「弹托盘」按钮，用于「二级判定不回摆」用例。
Widget _centralEntryPage2(String id) => Scaffold(
  body: Center(
    child: Builder(
      builder: (context) => TextButton(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const _TwoWithSheet()),
        ),
        child: const Text('push'),
      ),
    ),
  ),
);

class _TwoWithSheet extends StatelessWidget {
  const _TwoWithSheet();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Builder(
              builder: (context) => TextButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  builder: (_) => const SizedBox(
                    height: 120,
                    child: Center(child: Text('sheetContent')),
                  ),
                ),
                child: const Text('sheet'),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('back'),
            ),
          ],
        ),
      ),
    );
  }
}
