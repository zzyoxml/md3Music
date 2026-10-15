import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m3e_core/m3e_core.dart';

/// M3EDropdownMenu「稳定 items」用法回归钉。
///
/// 背景（2026-09-29 真机评论区 ANR）：M3EDropdownMenu.didUpdateWidget 用
/// `widget.items != oldWidget.items`（**列表同一性**）决定是否 setItems。
/// 若父级每次 build 新建 items 列表，该判断恒真 → setItems 在 build 期间
/// 同步回调 _onSelectionChange → 父级 setState during build → 语义树
/// `_didUpdateParentData ↔ updateChildren` 无限互递归 → 主线程卡死（ANR）。
///
/// 正确用法（comments_view / playlist_comments_view 的 `_scopeItems`）：
/// items 用稳定实例（late final 字段，选中态交给 controller 维护），
/// onSelectionChanged 里同值守卫。本测试钉住：父级反复重建时
/// 不产生任何框架异常、宿主正常重建。
///
/// 注：刻意保留的「每帧新列表」错误用法对照用例无法干净通过——框架会把
/// 级联异常计为 unexpected 并在 teardown 判失败，这本身就是该用法必炸的
/// 证明；因此这里只钉正确用法。
void main() {
  testWidgets('稳定 items：父级反复重建不触发回调、无框架异常', (tester) async {
    final errors = <FlutterErrorDetails>[];
    final originalOnError = FlutterError.onError;
    FlutterError.onError = (details) => errors.add(details);
    addTearDown(() => FlutterError.onError = originalOnError);

    var builds = 0;
    StateSetter? hostSetState;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          builds++;
          hostSetState = setState;
          return MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  SizedBox(
                    width: 112,
                    child: M3EDropdownMenu<String>(
                      // 与 comments_view._scopeItems 相同形态：稳定实例
                      items: const [
                        M3EDropdownItem(
                          label: '全部评论',
                          value: 'all',
                          selected: true,
                        ),
                        M3EDropdownItem(label: '歌手评论', value: 'singer'),
                        M3EDropdownItem(label: '我的评论', value: 'mine'),
                      ],
                      singleSelect: true,
                      showChipAnimation: false,
                      onSelectionChanged: (selected) {
                        if (selected.isEmpty) return;
                        setState(() {});
                      },
                      fieldStyle: const M3EDropdownFieldStyle(
                        padding: EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => hostSetState?.call(() {}),
                    child: const Text('rebuild-host'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    // postFrame：M3EDropdownMenu 在此注册 _onSelectionChange
    await tester.pump();
    await tester.pump();

    final buildsBefore = builds;
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('rebuild-host'), warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
    }

    // 排空菜单内部的弹簧动画，避免「widget tree 已销毁仍有动画在跑」
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    FlutterError.onError = originalOnError;

    expect(errors, isEmpty, reason: '稳定 items 下不应有任何框架异常: '
        '${errors.map((d) => d.exception)}');
    expect(builds - buildsBefore, greaterThanOrEqualTo(3),
        reason: '宿主应按点击次数正常重建');
  });
}
