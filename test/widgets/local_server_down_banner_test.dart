import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/core/widgets/local_server_down_banner.dart';

void main() {
  testWidgets('服务失败提示可触发单次重试并显示进行中状态', (tester) async {
    final retry = Completer<void>();
    var retryCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LocalServerDownBanner(
            onRetry: () {
              retryCount++;
              return retry.future;
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('重试本地接口'));
    await tester.pump();
    expect(retryCount, 1);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNull,
    );

    retry.complete();
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('重试异常后提示仍可再次操作', (tester) async {
    var retryCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LocalServerDownBanner(
            onRetry: () async {
              retryCount++;
              throw StateError('offline');
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('重试本地接口'));
    await tester.pumpAndSettle();
    expect(retryCount, 1);
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNotNull,
    );
  });
}
