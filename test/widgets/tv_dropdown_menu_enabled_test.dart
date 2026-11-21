/// TvDropdownMenu.enabled 契约：禁用态必须同时拦交互并灰显。
///
/// 「歌词位置」下拉在男女对唱优化开启时靠这个参数禁用；触屏分支必须把
/// enabled 透传给 M3EDropdownMenu（只拦交互不改外观），灰显由包装器补上。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m3e_core/m3e_core.dart';

import 'package:md3music/widgets/tv_dropdown_menu.dart';

void main() {
  const items = <M3EDropdownItem<String>>[
    M3EDropdownItem(label: '置左', value: 'left', selected: true),
    M3EDropdownItem(label: '居中', value: 'center'),
  ];

  Future<void> pumpMenu(WidgetTester tester, {required bool enabled}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvDropdownMenu<String>(
            items: items,
            enabled: enabled,
            singleSelect: true,
            showChipAnimation: false,
            onSelectionChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Finder dimLayer() => find.byWidgetPredicate(
        (w) => w is Opacity && w.opacity == 0.38,
      );

  testWidgets('enabled=true：透传可用且不套灰显层', (tester) async {
    await pumpMenu(tester, enabled: true);
    final menu = tester.widget<M3EDropdownMenu<String>>(
      find.byType(M3EDropdownMenu<String>),
    );
    expect(menu.enabled, isTrue);
    expect(menu.onSelectionChanged, isNotNull);
    expect(dimLayer(), findsNothing);
  });

  testWidgets('enabled=false：拦交互 + 灰显 + 回调置空', (tester) async {
    await pumpMenu(tester, enabled: false);
    final menu = tester.widget<M3EDropdownMenu<String>>(
      find.byType(M3EDropdownMenu<String>),
    );
    expect(menu.enabled, isFalse);
    expect(menu.onSelectionChanged, isNull);
    expect(dimLayer(), findsOneWidget);
  });
}
