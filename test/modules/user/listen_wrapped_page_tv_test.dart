// Wrapped 年度总结页 TV 焦点/翻页契约测试（阶段 F）。
//
// 覆盖 listen_wrapped_page.dart 的 TV 接线（照 docs/agents/tv-development.md
// §12.7 验收口径的最小集）：
//   - 进入页面 autofocus 落在故事区（整页单停点），无焦点死区；
//   - 左右键翻页、OK 下一页（裸 Focus.onKeyEvent， artist_photo_banner 先例）；
//   - 年份胶囊 DpadFocusable 可达、OK 切年（TvScrollRegion memoryKey 横向带）。
//
// kTvBuild 是编译期常量（普通 flutter test 里恒 false），两组用例用 skip 互斥
// （同 test/core/remote/tv_card_focus_test.dart 先例），TV 契约需单跑：
//   flutter test test/modules/user/listen_wrapped_page_tv_test.dart \
//     --dart-define=MD3_TV=true
//
// 测试宿主与 listen_wrapped_page_test 同套路：注入临时目录 ListenStatsDb；
// 宿主必须用 material_ui 的 MaterialApp（页面用其 Scaffold/AppBar，
// 本地化检查认自家类型），TV 组再挂 Dpad.wrap 遍历引擎。

import 'dart:io';

import 'package:dpad/dpad.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:md3music/core/build_flags.dart';
import 'package:md3music/data/db/listen_stats_db.dart';
import 'package:md3music/modules/user/listen_wrapped_page.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';

import '../../test_helpers/fake_secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmpDir;
  late String dbPath;
  late ListenStatsDb db;

  final now = DateTime.now();
  final year = now.year;
  final prevYear = year - 1;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    // 清登录态：未登录时 user_id 恒为空串，写入/查询口径一致
    final client = KugouApiClient();
    await client.clearCookies();
    tmpDir = await Directory.systemTemp.createTemp('wrapped_page_tv_test');
    dbPath = '${tmpDir.path}${Platform.pathSeparator}listen_stats.db';
    db = ListenStatsDb(dbPath: dbPath);
  });

  tearDown(() async {
    // Windows 文件锁：先关库再删临时目录
    await db.close();
    uninstallFakeSecureStorage();
    try {
      await tmpDir.delete(recursive: true);
    } catch (_) {
      // 清理失败不影响测试结论
    }
  });

  /// 预置两个年份的流水：当年（默认展示）+ 去年（供胶囊切年断言）。
  Future<void> seedTwoYears() async {
    await db.insertRecord(
      title: '晴天',
      artist: '周杰伦',
      album: '叶惠美',
      playedMs: 600000,
      playedAt: DateTime(year, 1, 2, 12).millisecondsSinceEpoch,
      valid: true,
    );
    await db.insertRecord(
      title: '稻香',
      artist: '周杰伦',
      album: '魔杰座',
      playedMs: 600000,
      playedAt: DateTime(year, 2, 3, 12).millisecondsSinceEpoch,
      valid: true,
    );
    await db.insertRecord(
      title: '去年之歌',
      artist: '去年歌手',
      album: '去年专辑',
      playedMs: 600000,
      playedAt: DateTime(prevYear, 6, 1, 12).millisecondsSinceEpoch,
      valid: true,
    );
  }

  /// 等页面加载完成（Wrapped 加载走真实 sqflite ffi 异步链路，
  /// FakeAsync 下用 runAsync 让真事件循环把 isolate 回包冲进来，
  /// 再 pump 推进 FakeAsync 帧，直到 finder 命中）。
  Future<void> pumpUntil(
    WidgetTester tester,
    Finder finder, {
    int maxLoops = 60,
  }) async {
    var loops = 0;
    while (loops < maxLoops) {
      if (finder.evaluate().isNotEmpty) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      loops++;
    }
    fail('等待超时：未出现 $finder');
  }

  /// 泵起页面并冲刷加载 Future（TV 组挂 Dpad.wrap 遍历引擎）。
  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: Dpad.wrap(theme: const DpadThemeData()),
        home: ListenWrappedPage(db: db),
      ),
    );
    await tester.pump(); // postFrameCallback 触发 _load
  }

  /// 当前焦点向上回溯到的第一颗年份胶囊（DpadFocusable），不在胶囊上返回 null。
  DpadFocusable? focusedYearPill() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context is! Element) return null;
    DpadFocusable? found;
    context.visitAncestorElements((Element e) {
      final w = e.widget;
      if (w is DpadFocusable &&
          (w.debugLabel?.startsWith('wrapped/year-') ?? false)) {
        found = w;
        return false;
      }
      return true;
    });
    return found;
  }

  group('非 TV 构建（普通 flutter test）', () {
    testWidgets('裸 Focus 不含 TV 停点，桌面键盘左右键翻页', (tester) async {
      await tester.runAsync(seedTwoYears);
      await pumpPage(tester);
      await pumpUntil(tester, find.text('1 / 7'));

      // kTvBuild 为 const false：TV 停点/区域不得进入元素树
      expect(find.byType(DpadFocusable), findsNothing);
      expect(find.byType(DpadRegion), findsNothing);

      // 桌面键盘（顺带行为）：autofocus 落故事区，左右键直接翻页
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(find.text('2 / 7'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(find.text('1 / 7'), findsOneWidget);

      // 左边界：夹取不回绕（线性叙事，非轮播）
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(find.text('1 / 7'), findsOneWidget);
    }, skip: kTvBuild);
  });

  group('TV 构建（MD3_TV=true）', () {
    testWidgets('autofocus 落故事区（无焦点死区），左右键翻页', (tester) async {
      await tester.runAsync(seedTwoYears);
      await pumpPage(tester);
      await pumpUntil(tester, find.text('1 / 7'));

      // 焦点死区检查：进入页面后 primaryFocus 必须在故事区 Focus 上——
      // 否则左右键翻不了页（翻页处理挂在故事区 onKeyEvent）。
      // 翻到第 2 页即证明焦点确实落在故事区（胶囊聚焦时左右键只会换胶囊）。
      expect(FocusManager.instance.primaryFocus, isNotNull,
          reason: '进入页面后必须有焦点落点（无死区）');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(find.text('2 / 7'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(find.text('1 / 7'), findsOneWidget);
    });

    testWidgets('年份胶囊可达且 OK 切年：切到去年后回到封面页', (tester) async {
      await tester.runAsync(seedTwoYears);
      await pumpPage(tester);
      await pumpUntil(tester, find.text('1 / 7'));

      // 故事区上键 → 光束遍历进入年份胶囊带（TvScrollRegion 横向带）
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(focusedYearPill(), isNotNull,
          reason: '故事区按上键必须落到年份胶囊（无死区、胶囊可达）');

      // 在带内移动到「去年」胶囊（带只有两颗，最多两步；wrap 边缘也不出带）
      for (var i = 0; i < 2; i++) {
        if (focusedYearPill()?.debugLabel == 'wrapped/year-$prevYear') break;
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
      }
      expect(focusedYearPill()?.debugLabel, 'wrapped/year-$prevYear',
          reason: '胶囊带内左右键必须能精确到达每颗胶囊（DpadFocusable 单停点）');

      // OK 切年：重新聚合后默认回到封面页（1 / 7），封面年份为去年
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await pumpUntil(tester, find.text('我的 $prevYear 听歌年度总结'));
      expect(find.text('1 / 7'), findsOneWidget);
    });
  }, skip: !kTvBuild);
}
