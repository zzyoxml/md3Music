import 'dart:io';

// 页面用 material_ui 的 Scaffold/AppBar（其本地化检查认自家类型），测试宿主
// 必须同样用 material_ui 的 MaterialApp（不 import flutter/material）。
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:md3music/data/db/listen_stats_db.dart';
import 'package:md3music/modules/user/listen_wrapped_page.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';

import '../../test_helpers/fake_secure_storage.dart';

/// Wrapped 年度总结页（listen_wrapped_page.dart）widget 测试。
///
/// 注入临时目录的 [ListenStatsDb]（与 listen_stats_db_test 同套路：
/// dbPath 注入绕开 path_provider，未登录态 user_id 为空串），
/// 预置当年流水后断言：卡片数量与顺序、封面数值、Top 榜第一名、空态。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmpDir;
  late String dbPath;
  late ListenStatsDb db;

  final now = DateTime.now();
  final year = now.year;

  /// 当年某月某日中午（本地时区毫秒），保证落在该年的月度聚合格里。
  int atMs(int month, int day) =>
      DateTime(year, month, day, 12).millisecondsSinceEpoch;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    // 清登录态：未登录时 user_id 恒为空串，写入/查询口径一致
    final client = KugouApiClient();
    await client.clearCookies();
    tmpDir = await Directory.systemTemp.createTemp('wrapped_page_test');
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

  /// 预置当年流水（全部有效，每条 10 分钟）：
  /// - 周杰伦 5 次（晴天 3 + 稻香 2）→ 年度艺人第一名、年度歌曲第一名"晴天"；
  /// - 五月天 2 次 → 艺人第二名；
  /// - 专辑：叶惠美 3 次第一名；
  /// - 晴天 1/2 → 1/20 → 3/5、稻香 2/3 → 2/20 间隔 ≥7 天 → 重逢 3 次；
  /// - 4/1、4/2 连续两天 → 最长连续 2 天；活跃 7 天；
  /// - 总计 7 次 × 10 分钟 = 70 分钟 = 1小时10分。
  /// - 再埋一条无效记录，验证不计入统计。
  Future<void> seedCurrentYear() async {
    await db.insertRecord(
      title: '晴天',
      artist: '周杰伦',
      album: '叶惠美',
      playedMs: 600000,
      playedAt: atMs(1, 2),
      valid: true,
    );
    await db.insertRecord(
      title: '晴天',
      artist: '周杰伦',
      album: '叶惠美',
      playedMs: 600000,
      playedAt: atMs(1, 20),
      valid: true,
    );
    await db.insertRecord(
      title: '晴天',
      artist: '周杰伦',
      album: '叶惠美',
      playedMs: 600000,
      playedAt: atMs(3, 5),
      valid: true,
    );
    await db.insertRecord(
      title: '稻香',
      artist: '周杰伦',
      album: '魔杰座',
      playedMs: 600000,
      playedAt: atMs(2, 3),
      valid: true,
    );
    await db.insertRecord(
      title: '稻香',
      artist: '周杰伦',
      album: '魔杰座',
      playedMs: 600000,
      playedAt: atMs(2, 20),
      valid: true,
    );
    await db.insertRecord(
      title: '突然好想你',
      artist: '五月天',
      album: '后青春期的诗',
      playedMs: 600000,
      playedAt: atMs(4, 1),
      valid: true,
    );
    await db.insertRecord(
      title: '倔强',
      artist: '五月天',
      album: '后青春期的诗',
      playedMs: 600000,
      playedAt: atMs(4, 2),
      valid: true,
    );
    // 无效播放（时长过短）：不计入任何卡片
    await db.insertRecord(
      title: '无效歌',
      playedMs: 1000,
      playedAt: atMs(5, 1),
      valid: false,
    );
  }

  /// 等页面加载完成：Wrapped 加载走真实 sqflite ffi 异步链路，
  /// FakeAsync 下用 runAsync 让真事件循环把 isolate 回包冲进来，
  /// 再 pump 推进 FakeAsync 帧，直到 [finder] 命中（或空态用例直到消失）。
  Future<void> pumpUntil(
    WidgetTester tester,
    Finder finder, {
    int maxLoops = 60,
    bool expectAbsent = false,
  }) async {
    var loops = 0;
    while (loops < maxLoops) {
      final hit = finder.evaluate().isNotEmpty;
      if (hit != expectAbsent) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      loops++;
    }
    fail('等待超时：${expectAbsent ? "应消失" : "未出现"} $finder');
  }

  /// 泵起页面并冲刷加载 Future。
  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(home: ListenWrappedPage(db: db)),
    );
    await tester.pump(); // postFrameCallback 触发 _load
  }

  /// 派发一次鼠标滚轮事件并推过 320ms 翻页动画
  /// （照 coverflow_wheel_test.scroll 先例：TestPointer.mouse + scroll）。
  ///
  /// 必须先 pump() 一次再 pump(settle)：AnimationController 驱动的翻页
  /// Ticker 要先有一帧注册，单帧大跳时动画首帧都不推进。
  Future<void> scrollWheel(WidgetTester tester, double dy,
      {Duration settle = const Duration(milliseconds: 400)}) async {
    final pointer = TestPointer(1, PointerDeviceKind.mouse)
      ..hover(tester.getCenter(find.byType(PageView)));
    // sendEventToBinding 是 guarded API，必须 await
    await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
    await tester.pump();
    await tester.pump(settle);
  }

  /// 快速连滚：间隔 50ms（Windows 连滚真实节奏），不打断翻页动画。
  /// 事件间隔 < 120ms（滚轮空闲阈值）→ 基址不清，步数一路累加。
  Future<void> scrollWheelFast(WidgetTester tester, List<double> dys) async {
    for (final dy in dys) {
      final pointer = TestPointer(1, PointerDeviceKind.mouse)
        ..hover(tester.getCenter(find.byType(PageView)));
      await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    // 滚轮停后：推过空闲阈值（120ms）+ 翻页动画（320ms）
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('预置当年流水：7 张卡片、顺序正确、封面数值渲染', (tester) async {
    await tester.runAsync(seedCurrentYear);
    await pumpPage(tester);
    await pumpUntil(tester, find.byKey(const ValueKey('wrapped_page_cover')));
    await tester.pump();

    // 卡片数量 = 7（PageView children 委托直接检查，不受懒加载影响）
    final pageView = tester.widget<PageView>(find.byType(PageView));
    final delegate = pageView.childrenDelegate as SliverChildListDelegate;
    expect(delegate.children.length, 7);
    // 顺序：封面 → 艺人 → 歌曲 → 专辑 → 月度 → 习惯 → 结尾
    expect(
      [
        for (final c in delegate.children) (c.key! as ValueKey<String>).value,
      ],
      <String>[
        'wrapped_page_cover',
        'wrapped_page_artists',
        'wrapped_page_tracks',
        'wrapped_page_albums',
        'wrapped_page_monthly',
        'wrapped_page_habits',
        'wrapped_page_ending',
      ],
    );

    // 封面卡（当前页）：年份标题 + 总次数 7 + 净听 1小时10分
    expect(find.text('我的 $year 听歌年度总结'), findsOneWidget);
    expect(find.text('共播放 7 次'), findsOneWidget);
    expect(find.text('净听 1小时10分'), findsOneWidget);

    // 页码指示
    expect(find.text('1 / 7'), findsOneWidget);
  });

  testWidgets('Top 艺人卡：第一名"周杰伦"大字 + 第二名"五月天"', (tester) async {
    await tester.runAsync(seedCurrentYear);
    await pumpPage(tester);
    await pumpUntil(tester, find.byKey(const ValueKey('wrapped_page_cover')));

    final pageView = tester.widget<PageView>(find.byType(PageView));
    pageView.controller!.jumpToPage(1);
    await tester.pump();
    await tester.pump();

    expect(find.text('年度最爱艺人'), findsWidgets);
    expect(find.text('周杰伦'), findsOneWidget);
    expect(find.text('5 次'), findsOneWidget);
    expect(find.text('五月天'), findsOneWidget);
    expect(find.text('2次'), findsOneWidget);
  });

  testWidgets('Top 歌曲卡与专辑卡：晴天 3 次、叶惠美第一', (tester) async {
    await tester.runAsync(seedCurrentYear);
    await pumpPage(tester);
    await pumpUntil(tester, find.byKey(const ValueKey('wrapped_page_cover')));

    final pageView = tester.widget<PageView>(find.byType(PageView));
    // 第 3 页：年度歌曲
    pageView.controller!.jumpToPage(2);
    await tester.pump();
    await tester.pump();
    expect(find.text('年度最常播放'), findsWidgets);
    expect(find.text('晴天'), findsOneWidget);
    expect(find.text('3次'), findsOneWidget);
    expect(find.text('突然好想你'), findsOneWidget);

    // 第 4 页：年度专辑
    pageView.controller!.jumpToPage(3);
    await tester.pump();
    await tester.pump();
    expect(find.text('年度专辑'), findsWidgets);
    expect(find.text('叶惠美'), findsOneWidget);
    expect(find.text('后青春期的诗'), findsOneWidget);
  });

  testWidgets('月度节奏卡：1 月计数 3、4 月计数 2 渲染', (tester) async {
    await tester.runAsync(seedCurrentYear);
    await pumpPage(tester);
    await pumpUntil(tester, find.byKey(const ValueKey('wrapped_page_cover')));

    final pageView = tester.widget<PageView>(find.byType(PageView));
    pageView.controller!.jumpToPage(4);
    await tester.pump();
    await tester.pump();

    expect(find.text('月度节奏'), findsWidgets);
    // 柱顶计数：1 月 2 次、2 月 2 次、3 月 1 次、4 月 2 次，其余月份为空串
    expect(find.text('2'), findsNWidgets(3));
    expect(find.text('1'), findsOneWidget);
    // 月份轴标签
    expect(find.text('1月'), findsOneWidget);
    expect(find.text('12月'), findsOneWidget);
  });

  testWidgets('听歌习惯卡：活跃 7 天、连续 2 天、重逢 3 次', (tester) async {
    await tester.runAsync(seedCurrentYear);
    await pumpPage(tester);
    await pumpUntil(tester, find.byKey(const ValueKey('wrapped_page_cover')));

    final pageView = tester.widget<PageView>(find.byType(PageView));
    pageView.controller!.jumpToPage(5);
    await tester.pump();
    await tester.pump();

    expect(find.text('听歌习惯'), findsWidgets);
    expect(find.text('7'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('今年有播放记录的日子'), findsOneWidget);
    expect(find.text('最长连续收听天数'), findsOneWidget);
    expect(find.text('重逢老歌（时隔一周以上再听）'), findsOneWidget);
  });

  testWidgets('结尾卡：文案含年度第一名艺人', (tester) async {
    await tester.runAsync(seedCurrentYear);
    await pumpPage(tester);
    await pumpUntil(tester, find.byKey(const ValueKey('wrapped_page_cover')));

    final pageView = tester.widget<PageView>(find.byType(PageView));
    pageView.controller!.jumpToPage(6);
    await tester.pump();
    await tester.pump();

    expect(
      find.textContaining('你把最多的时间给了「周杰伦」'),
      findsOneWidget,
    );
    expect(find.textContaining('共收听 7 次'), findsOneWidget);
  });

  testWidgets('无任何播放记录：整页空态', (tester) async {
    await pumpPage(tester);
    await pumpUntil(
      tester,
      find.text('今年还没有播放记录'),
      expectAbsent: false,
    );
    expect(find.byType(PageView), findsNothing);
  });

  testWidgets('仅往年有数据：年份胶囊回落到最近有数据的年份', (tester) async {
    // 流水埋在去年
    final lastYear = year - 1;
    int lastYearMs(int month, int day) =>
        DateTime(lastYear, month, day, 12).millisecondsSinceEpoch;
    await tester.runAsync(() async {
      await db.insertRecord(
        title: '老歌',
        artist: '老艺人',
        playedMs: 600000,
        playedAt: lastYearMs(6, 1),
        valid: true,
      );
    });
    await pumpPage(tester);
    await pumpUntil(
      tester,
      find.text('我的 $lastYear 听歌年度总结'),
    );
    // 年份胶囊展示的是去年而非当年
    expect(find.text('$lastYear'), findsOneWidget);
    expect(find.byType(PageView), findsOneWidget);
  });

  group('鼠标滚轮翻页（Windows 桌面，W8）', () {
    testWidgets('滚轮向下翻到下一页', (tester) async {
      await tester.runAsync(seedCurrentYear);
      await pumpPage(tester);
      await pumpUntil(tester, find.byKey(const ValueKey('wrapped_page_cover')));
      expect(find.text('1 / 7'), findsOneWidget);

      await scrollWheel(tester, 100);
      expect(find.text('2 / 7'), findsOneWidget);
    });

    testWidgets('滚轮向上翻回封面页', (tester) async {
      await tester.runAsync(seedCurrentYear);
      await pumpPage(tester);
      await pumpUntil(tester, find.byKey(const ValueKey('wrapped_page_cover')));

      await scrollWheel(tester, 100);
      expect(find.text('2 / 7'), findsOneWidget);
      await scrollWheel(tester, -100);
      expect(find.text('1 / 7'), findsOneWidget);
    });

    testWidgets('封面页再向上滚：边界夹住不越界', (tester) async {
      await tester.runAsync(seedCurrentYear);
      await pumpPage(tester);
      await pumpUntil(tester, find.byKey(const ValueKey('wrapped_page_cover')));

      await scrollWheel(tester, -100);
      expect(find.text('1 / 7'), findsOneWidget);
    });

    testWidgets('触控板小步长增量累积到一格才翻页', (tester) async {
      await tester.runAsync(seedCurrentYear);
      await pumpPage(tester);
      await pumpUntil(tester, find.byKey(const ValueKey('wrapped_page_cover')));

      // 30px × 4 次在第 4 次凑满一格（100px）翻页
      await scrollWheel(tester, 30);
      expect(find.text('1 / 7'), findsOneWidget);
      await scrollWheel(tester, 30);
      expect(find.text('1 / 7'), findsOneWidget);
      await scrollWheel(tester, 30);
      expect(find.text('1 / 7'), findsOneWidget);
      await scrollWheel(tester, 30);
      expect(find.text('2 / 7'), findsOneWidget);
    });

    testWidgets('快速连滚 4 格：目标基址累加不丢步', (tester) async {
      await tester.runAsync(seedCurrentYear);
      await pumpPage(tester);
      await pumpUntil(tester, find.byKey(const ValueKey('wrapped_page_cover')));

      // 50ms 间隔连滚 4 格：事件间隔 < 120ms 空闲阈值，基址一路累加，
      // 翻页动画（320ms）尚在中途也不丢步
      await scrollWheelFast(tester, [100, 100, 100, 100]);
      expect(find.text('5 / 7'), findsOneWidget);
    });

    testWidgets('滚轮停止 120ms 后基址作废：下次从静止位置重新计步', (tester) async {
      await tester.runAsync(seedCurrentYear);
      await pumpPage(tester);
      await pumpUntil(tester, find.byKey(const ValueKey('wrapped_page_cover')));

      // 滚 2 格，scrollWheel 已推 400ms > 120ms，基址已清
      await scrollWheel(tester, 100);
      await scrollWheel(tester, 100);
      expect(find.text('3 / 7'), findsOneWidget);

      // 再滚 1 格：基址若未清会从 2 跳到 3+1=4；清了则从 3 起步到 4
      await scrollWheel(tester, 100);
      expect(find.text('4 / 7'), findsOneWidget);
    });

    testWidgets('结尾页再向下滚：边界夹住不越界', (tester) async {
      await tester.runAsync(seedCurrentYear);
      await pumpPage(tester);
      await pumpUntil(tester, find.byKey(const ValueKey('wrapped_page_cover')));

      // 先滚到结尾页（6 格），再多滚 2 格验证钳位
      await scrollWheelFast(
          tester, [for (var i = 0; i < 8; i++) 100.0]);
      expect(find.text('7 / 7'), findsOneWidget);
    });
  });
}
