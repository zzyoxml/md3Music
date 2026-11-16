import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mu;
import 'package:md3music/core/utils/app_text_context_menu.dart';

/// mock 剪贴板两个通道，并返回 toast 调用记录。
List<String> _mockClipboard(
  WidgetTester tester, {
  required bool hasStrings,
  String? clipText,
}) {
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final List<String> toasts = <String>[];
  messenger.setMockMethodCallHandler(SystemChannels.platform, (MethodCall call) async {
    switch (call.method) {
      case 'Clipboard.hasStrings':
        return <String, dynamic>{'value': hasStrings};
      case 'Clipboard.getData':
        // 真机上剪贴板为空时通道返回 null。
        return clipText == null ? null : <String, dynamic>{'text': clipText};
      default:
        return null;
    }
  });
  messenger.setMockMethodCallHandler(
    const MethodChannel('PonnamKarthik/fluttertoast'),
    (MethodCall call) async {
      if (call.method == 'showToast') {
        toasts.add((call.arguments as Map<Object?, Object?>?)?['msg'] as String? ?? '');
      }
      return null;
    },
  );
  addTearDown(() {
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    messenger.setMockMethodCallHandler(const MethodChannel('PonnamKarthik/fluttertoast'), null);
  });
  return toasts;
}

/// 在 Android 平台上跑一段用例。
///
/// debugDefaultTargetPlatformOverride **必须**在测试体内复位：
/// binding 的 _verifyInvariants 先于 addTearDown/setUp-setTearDown 链执行，
/// 用 addTearDown 复位会在用例末尾报
/// "The value of a foundation debug variable was changed by the test."
Future<void> _onAndroid(Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.android;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

Future<mu.TextEditingController> _pumpField(
  WidgetTester tester, {
  String text = '',
  bool readOnly = false,
}) async {
  final controller = mu.TextEditingController(text: text);
  await tester.pumpWidget(
    mu.MaterialApp(
      theme: mu.ThemeData(platform: TargetPlatform.android),
      home: mu.Scaffold(
        body: Center(
          child: mu.TextField(
            controller: controller,
            readOnly: readOnly,
            contextMenuBuilder: buildAppTextContextMenu,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

Future<void> _longPressField(WidgetTester tester) async {
  await tester.longPress(find.byType(mu.TextField));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  testWidgets('剪贴板探测不可用时，空输入框长按仍应给出「粘贴」', (tester) async {
    await _onAndroid(() async {
      _mockClipboard(tester, hasStrings: false, clipText: 'https://kugou.com');
      await _pumpField(tester);
      await _longPressField(tester);
      expect(find.text('粘贴'), findsOneWidget);
    });
  });

  testWidgets('点「粘贴」应把剪贴板文本插入并把光标置于其后', (tester) async {
    await _onAndroid(() async {
      _mockClipboard(tester, hasStrings: false, clipText: 'https://kugou.com');
      final controller = await _pumpField(tester);
      await _longPressField(tester);
      await tester.tap(find.text('粘贴'));
      await tester.pumpAndSettle();
      expect(controller.text, 'https://kugou.com');
    });
  });

  testWidgets('框架已给出粘贴项时不得重复追加', (tester) async {
    await _onAndroid(() async {
      _mockClipboard(tester, hasStrings: true, clipText: 'x');
      await _pumpField(tester, text: 'hello world');
      await _longPressField(tester);
      expect(find.text('粘贴'), findsOneWidget);
    });
  });

  testWidgets('只读输入框不应出现「粘贴」', (tester) async {
    await _onAndroid(() async {
      _mockClipboard(tester, hasStrings: false, clipText: 'x');
      await _pumpField(tester, readOnly: true);
      await _longPressField(tester);
      expect(find.text('粘贴'), findsNothing);
    });
  });

  testWidgets('剪贴板确实为空时点「粘贴」要给 toast，不能静默无响应', (tester) async {
    await _onAndroid(() async {
      final toasts = _mockClipboard(tester, hasStrings: false, clipText: null);
      final controller = await _pumpField(tester);
      await _longPressField(tester);
      await tester.tap(find.text('粘贴'));
      await tester.pumpAndSettle();
      expect(controller.text, isEmpty);
      expect(toasts, contains('剪贴板没有可粘贴的文本'));
      // fluttertoast 内部起了 1s 的 Future.delayed，不排干会报 "Timer is still pending"。
      await tester.pump(const Duration(seconds: 2));
    });
  });

  testWidgets('框架给出的按钮（粘贴/全选）显示中文而非英文', (tester) async {
    await _onAndroid(() async {
      // hasStrings:true 时粘贴项由框架自己生成（不是本 builder 补的那个），
      // 加上全选项，二者都走 contextMenuZhLabel 映射——UI 级锁死中文标签。
      _mockClipboard(tester, hasStrings: true, clipText: 'x');
      await _pumpField(tester, text: 'hello world');
      await _longPressField(tester);
      expect(find.text('粘贴'), findsOneWidget);
      expect(find.text('全选'), findsOneWidget);
      expect(find.text('Paste'), findsNothing);
      expect(find.text('Select all'), findsNothing);
      expect(find.text('Select All'), findsNothing);
    });
  });

  test('contextMenuZhLabel 为各按钮类型映射中文标签', () {
    expect(
      contextMenuZhLabel(
        ContextMenuButtonItem(type: ContextMenuButtonType.cut, onPressed: () {}),
      ),
      '剪切',
    );
    expect(
      contextMenuZhLabel(
        ContextMenuButtonItem(type: ContextMenuButtonType.copy, onPressed: () {}),
      ),
      '复制',
    );
    expect(
      contextMenuZhLabel(
        ContextMenuButtonItem(type: ContextMenuButtonType.paste, onPressed: () {}),
      ),
      '粘贴',
    );
    expect(
      contextMenuZhLabel(
        ContextMenuButtonItem(type: ContextMenuButtonType.selectAll, onPressed: () {}),
      ),
      '全选',
    );
    expect(
      contextMenuZhLabel(
        ContextMenuButtonItem(type: ContextMenuButtonType.delete, onPressed: () {}),
      ),
      '删除',
    );
    expect(
      contextMenuZhLabel(
        ContextMenuButtonItem(type: ContextMenuButtonType.lookUp, onPressed: () {}),
      ),
      '查询',
    );
    expect(
      contextMenuZhLabel(
        ContextMenuButtonItem(type: ContextMenuButtonType.searchWeb, onPressed: () {}),
      ),
      '网页搜索',
    );
    expect(
      contextMenuZhLabel(
        ContextMenuButtonItem(type: ContextMenuButtonType.share, onPressed: () {}),
      ),
      '分享',
    );
    expect(
      contextMenuZhLabel(
        ContextMenuButtonItem(type: ContextMenuButtonType.liveTextInput, onPressed: () {}),
      ),
      '扫描文本',
    );
    // custom 无 label：框架对该类型本就渲染空文本。
    expect(
      contextMenuZhLabel(
        ContextMenuButtonItem(onPressed: () {}),
      ),
      isNull,
    );
  });

  test('contextMenuZhLabel 不覆盖已有 label（系统文本处理动作名）', () {
    expect(
      contextMenuZhLabel(
        ContextMenuButtonItem(label: '翻译', onPressed: () {}),
      ),
      '翻译',
    );
  });
}
