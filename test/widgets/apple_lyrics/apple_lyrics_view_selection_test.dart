import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/apple_lyrics_view.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import 'package:md3music/widgets/apple_lyrics/selection/lyric_selection_state.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_aux_scope.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// AppleLyricsView 长按选择模式 widget 测试
///
/// 覆盖：长按进入选择模式、拖动扩展选中区间、点按切换选中、
/// 切歌（lines 变化）自动退出。复制/操作栏见 Task 5（同文件追加）。
void main() {
  final lines = <LyricLine>[
    for (int i = 0; i < 12; i++)
      LyricLine(startTime: i * 1000, duration: 1000, text: '第${i + 1}行歌词'),
  ];

  /// 泵出 400x600 的歌词视图并等首次定位收敛（initState 即启动驱动源，
  /// eco Timer / Ticker 都由 pump 的 fake time 推进，isPlaying=false 也可）。
  Future<void> pumpView(
    WidgetTester tester, {
    List<LyricLine> testLines = const [],
    bool doubleTapToJump = false,
  }) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: 400,
              height: 600,
              child: AppleLyricsView(
                lines: testLines.isEmpty ? lines : testLines,
                currentTimeMs: 0,
                doubleTapToJump: doubleTapToJump,
              ),
            ),
          ),
        ),
      ),
    );
    // 等弹簧首次定位收敛（当前行 0 的中心停在 35% 视口高度处）
    for (int i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  /// 当前行（行 0）中心：初始定位后落在视口 35% 高度处（与字号无关，
  /// 恒命中行 0，长按/点按定位都用它，避免依赖具体行高）
  Offset lineZeroCenter(WidgetTester tester) {
    final viewTop = tester.getTopLeft(find.byType(AppleLyricsView)).dy;
    return Offset(
      tester.getCenter(find.byType(AppleLyricsView)).dx,
      viewTop + 600 * 0.35,
    );
  }

  LyricSelectionState selectionOf(WidgetTester tester) =>
      (tester.state(find.byType(AppleLyricsView)) as dynamic)
          .selectionStateForTest as LyricSelectionState;

  testWidgets('长按歌词行进入选择模式并选中该行', (tester) async {
    await pumpView(tester);
    expect(selectionOf(tester).isActive, isFalse);

    await tester.longPressAt(lineZeroCenter(tester));
    await tester.pump(const Duration(milliseconds: 16));

    final s = selectionOf(tester);
    expect(s.isActive, isTrue, reason: '长按应进入选择模式');
    expect(s.anchorIndex, 0);
    expect(s.selected, {0});

    // AppHaptics 每次触感挂一个 300ms watchdog Timer，测试结束前必须让它
    // 触发，否则 flutter_test 报 pending Timer（同 apple_lyrics_view_test 惯例）。
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('长按拖动向下扩展连续选中区间', (tester) async {
    await pumpView(tester);
    final start = lineZeroCenter(tester);

    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 600)); // 超过长按时限
    await gesture.moveBy(const Offset(0, 70));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 16));

    final s = selectionOf(tester);
    expect(s.isActive, isTrue);
    expect(s.anchorIndex, 0);
    expect(s.selected.contains(0), isTrue);
    expect(s.selected.length, greaterThan(1),
        reason: '下拖 70px 应至少跨过 1 行，选中连续区间');

    // AppHaptics 300ms watchdog Timer 触发后再结束，避免 pending Timer 断言。
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('选择模式下点按切换单行选中', (tester) async {
    await pumpView(tester);
    await tester.longPressAt(lineZeroCenter(tester));
    await tester.pump(const Duration(milliseconds: 16));
    final before = selectionOf(tester).selected.length; // 行 0，=1

    // 点按行 0 中心下方 110px：测试环境行高 76.8、行 0 顶部约在中心上方
    // 约 10px 处，64px 仍落在行 0 内（会把行 0 移出选择）；110px 必越过
    // 行 0 底部落到下一个未选中行，且两次点按落同一行。
    final center = lineZeroCenter(tester);
    await tester.tapAt(Offset(center.dx, center.dy + 110));
    await tester.pump(const Duration(milliseconds: 16));
    expect(selectionOf(tester).selected.length, before + 1,
        reason: '点按未选中行应加入选择');

    await tester.tapAt(Offset(center.dx, center.dy + 110));
    await tester.pump(const Duration(milliseconds: 16));
    expect(selectionOf(tester).selected.length, before,
        reason: '再次点按同一行应移出选择');

    // AppHaptics 300ms watchdog Timer 触发后再结束，避免 pending Timer 断言。
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('切歌（lines 引用变化）自动退出选择模式', (tester) async {
    await pumpView(tester);
    await tester.longPressAt(lineZeroCenter(tester));
    await tester.pump(const Duration(milliseconds: 16));
    expect(selectionOf(tester).isActive, isTrue);

    await pumpView(
      tester,
      testLines: [
        ...lines,
        const LyricLine(startTime: 12000, duration: 1000, text: '新行'),
      ],
    );
    await tester.pump(const Duration(milliseconds: 16));
    expect(selectionOf(tester).isActive, isFalse, reason: '切歌应退出选择模式');
  });

  group('选择模式渲染与边缘滚动', () {
    testWidgets('进入选择模式后行块层渲染不崩溃', (tester) async {
      await pumpView(tester);
      // 长按行 0（恒命中）进入选择模式
      await tester.longPressAt(lineZeroCenter(tester));
      await tester.pump(const Duration(milliseconds: 16));
      // 行块 painter 渲染若干帧不抛异常
      for (int i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(tester.takeException(), isNull);
      expect(selectionOf(tester).isActive, isTrue);

      // AppHaptics 300ms watchdog Timer 与行块过渡 Timer 触发后再结束，
      // 避免 pending Timer 断言（同上方既有用例惯例）。
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('点按切换选中后过渡渲染不崩溃', (tester) async {
      await pumpView(tester);
      await tester.longPressAt(lineZeroCenter(tester));
      await tester.pump(const Duration(milliseconds: 16));
      // 点按另一行（toggle 加入选择）→ 触发 220ms 填充过渡，渲染若干帧
      // （+110 必越过行 0 底部落到下一个未选中行，口径同上方既有用例）
      final center = lineZeroCenter(tester);
      await tester.tapAt(Offset(center.dx, center.dy + 110));
      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(tester.takeException(), isNull);
      expect(selectionOf(tester).selected.length, 2);
    });

    testWidgets('双击跳转开启时选择模式点按仍可 toggle 选中', (tester) async {
      // 回归：双击跳转设置曾把单击吞掉（onTap* 未注册），真机上表现为
      // "点击不选择"。选择模式下必须动态注册 onTap* 并暂停双击识别。
      await pumpView(tester, doubleTapToJump: true);
      await tester.longPressAt(lineZeroCenter(tester));
      await tester.pump(const Duration(milliseconds: 16));
      expect(selectionOf(tester).isActive, isTrue);

      final center = lineZeroCenter(tester);
      await tester.tapAt(Offset(center.dx, center.dy + 110));
      await tester.pump(const Duration(milliseconds: 400));
      expect(selectionOf(tester).selected.length, 2,
          reason: '双击跳转开启时单击仍应加入选择');
    });

    test('selectionEdgeScrollDelta 边缘带速度曲线', () {
      // 非法视口
      expect(AppleLyricsView.selectionEdgeScrollDelta(10, 0), 0);
      // 视口内非边缘带
      expect(AppleLyricsView.selectionEdgeScrollDelta(300, 600), 0);
      // 顶部边缘带：越贴边越快，方向为正（看前面的行）
      final top = AppleLyricsView.selectionEdgeScrollDelta(0, 600);
      expect(top, greaterThan(0));
      expect(AppleLyricsView.selectionEdgeScrollDelta(60, 600), lessThan(top));
      // 底部边缘带：方向为负（看后面的行）
      expect(AppleLyricsView.selectionEdgeScrollDelta(599, 600), lessThan(0));
    });
  });

  group('选择模式操作栏与复制', () {
    String? clipboardText;
    String? toastText;

    /// 捕获剪贴板与 Toast（测试环境无插件实现，channel 名以 pubspec.lock
    /// 中 fluttertoast 版本为准，'PonnamKarthik/fluttertoast' 为该插件长期命名）
    void mockClipboardAndToast(WidgetTester tester) {
      clipboardText = null;
      toastText = null;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardText = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('PonnamKarthik/fluttertoast'),
        (call) async {
          if (call.method == 'showToast') {
            toastText = (call.arguments as Map)['msg'] as String?;
          }
          return true;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('PonnamKarthik/fluttertoast'),
          null,
        );
      });
    }

    /// 泵出视图并长按行 0 进入选择模式
    Future<void> pumpAndSelect(WidgetTester tester) async {
      await pumpView(tester);
      mockClipboardAndToast(tester);
      await tester.longPressAt(lineZeroCenter(tester));
      await tester.pump(const Duration(milliseconds: 16));
    }

    testWidgets('顶栏显示已选择行数与字数计数', (tester) async {
      await pumpAndSelect(tester);
      expect(find.text('已选择 1 行'), findsOneWidget);
      expect(find.textContaining('个字符'), findsOneWidget);

      // AppHaptics 300ms watchdog Timer 触发后再结束，避免 pending Timer
      // 断言（同上方既有用例惯例）。
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('复制歌词写入剪贴板并退出选择模式', (tester) async {
      await pumpAndSelect(tester);

      await tester.tap(find.text('复制歌词'));
      await tester.pump(const Duration(milliseconds: 16));

      expect(clipboardText, '第1行歌词');
      expect(toastText, '已复制 1 行歌词');
      expect(selectionOf(tester).isActive, isFalse,
          reason: '复制后自动退出选择模式');

      // AppHaptics 300ms watchdog 与 fluttertoast 内部 1s delayed Timer
      // 都触发后再结束，避免 pending Timer 断言（同上方既有用例惯例）。
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('全选/清除切换选中集合', (tester) async {
      await pumpAndSelect(tester);

      await tester.tap(find.text('全选'));
      await tester.pump(const Duration(milliseconds: 16));
      expect(selectionOf(tester).selectedCount, lines.length);
      expect(find.text('清除'), findsOneWidget, reason: '全选后按钮翻转为清除');

      await tester.tap(find.text('清除'));
      await tester.pump(const Duration(milliseconds: 16));
      expect(selectionOf(tester).selectedCount, 0);
      expect(selectionOf(tester).isActive, isTrue,
          reason: '清除只清集合不退出模式');

      // AppHaptics 300ms watchdog Timer 触发后再结束，避免 pending Timer
      // 断言（同上方既有用例惯例）。
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('顶栏关闭按钮退出选择模式', (tester) async {
      // 底栏已移除，复制按钮上移到顶栏；退出走顶栏左上角 X
      await pumpAndSelect(tester);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump(const Duration(milliseconds: 16));
      expect(selectionOf(tester).isActive, isFalse);

      // AppHaptics 300ms watchdog Timer 触发后再结束，避免 pending Timer
      // 断言（同上方既有用例惯例）。
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('顶栏复制按钮随选中状态可用并写入剪贴板', (tester) async {
      await pumpAndSelect(tester);

      // 顶栏复制按钮：进入选择模式即选中 1 行 → 可用
      await tester.tap(find.byIcon(Icons.copy_rounded));
      await tester.pump(const Duration(milliseconds: 1000));

      expect(clipboardText, '第1行歌词');
      expect(selectionOf(tester).isActive, isFalse);
    });

    testWidgets('复制带翻译的行时翻译一并写入剪贴板', (tester) async {
      await pumpView(
        tester,
        testLines: [
          const LyricLine(
            startTime: 0,
            duration: 1000,
            text: 'Main line',
            translation: '主行翻译',
          ),
        ],
      );
      mockClipboardAndToast(tester);
      await tester.longPressAt(lineZeroCenter(tester));
      await tester.pump(const Duration(milliseconds: 16));

      await tester.tap(find.text('复制歌词'));
      await tester.pump(const Duration(milliseconds: 1000));

      expect(clipboardText, 'Main line\n主行翻译');
    });

    testWidgets('副行显示范围不影响复制（仅当前行下仍复制所有行翻译）', (tester) async {
      // 用户诉求：「副行显示范围=仅当前行」只是渲染展开范围，复制仍带上
      // 所有选中行的翻译（复制口径不跟随渲染展开范围）。
      SharedPreferences.setMockInitialValues({});
      await LyricPreferences.instance.setAuxScope(LyricAuxScope.currentLine);
      addTearDown(() => LyricPreferences.instance.reset());

      final translatedLines = [
        const LyricLine(
          startTime: 0,
          duration: 1000,
          text: 'First',
          translation: '第一行翻译',
        ),
        const LyricLine(
          startTime: 1000,
          duration: 1000,
          text: 'Second',
          translation: '第二行翻译',
        ),
      ];
      await pumpView(tester, testLines: translatedLines);
      mockClipboardAndToast(tester);
      await tester.longPressAt(lineZeroCenter(tester));
      await tester.pump(const Duration(milliseconds: 16));

      // 全选两行（含非当前行的翻译）再复制
      await tester.tap(find.text('全选'));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.tap(find.text('复制歌词'));
      await tester.pump(const Duration(milliseconds: 1000));

      expect(clipboardText, 'First\n第一行翻译\nSecond\n第二行翻译');
    });

    testWidgets('副行显示关闭时不显示也不复制翻译', (tester) async {
      // 用户诉求：右下角按钮关闭副行显示 = 「不显示、不复制翻译」的模式——
      // 选择模式行块不再画翻译副行，复制内容只有主行。
      SharedPreferences.setMockInitialValues({});
      await LyricPreferences.instance.setShowTranslation(false);
      addTearDown(() => LyricPreferences.instance.reset());

      await pumpView(
        tester,
        testLines: [
          const LyricLine(
            startTime: 0,
            duration: 1000,
            text: 'Main line',
            translation: '主行翻译',
          ),
        ],
      );
      mockClipboardAndToast(tester);
      await tester.longPressAt(lineZeroCenter(tester));
      await tester.pump(const Duration(milliseconds: 16));
      // 渲染若干帧（副行绘制路径关闭态）不崩溃
      for (int i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('复制歌词'));
      await tester.pump(const Duration(milliseconds: 1000));

      expect(clipboardText, 'Main line');
    });
  });
}
