import 'package:flutter_test/flutter_test.dart';
// 页面用 material_ui 的 Scaffold/MaterialApp（其本地化检查认自家类型），测试宿主
// 必须同样用 material_ui 的 MaterialApp（不 import flutter/material）。
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:md3music/data/db/listen_stats_db.dart';
import 'package:md3music/modules/user/local_listen_stats_view.dart';
import 'package:md3music/providers/local_listen_stats_provider.dart';

/// 无 IO 桩库：widget 测试不走 sqflite/path_provider（FakeAsync 下真实
/// 异步 IO 不可靠），直接按 ListenStatsDb 的查询签名返回内存假数据。
class _FakeStatsDb extends ListenStatsDb {
  _FakeStatsDb({this.empty = false}) : super(dbPath: 'unused');

  /// true 时模拟本地无任何播放记录。
  final bool empty;

  @override
  Future<int> countByUser({required bool validOnly}) async =>
      empty ? 0 : 3;

  @override
  Future<List<Map<String, Object?>>> topTracks({
    int? startMs,
    int? endMs,
    int limit = 10,
    bool validOnly = true,
  }) async => empty
      ? const <Map<String, Object?>>[]
      : <Map<String, Object?>>[
          {
            'key': '歌一',
            'count': 12,
            'playedMs': 5400000,
            'repTitle': '歌一',
            'repArtist': '歌手A',
            'isUnknown': false,
          },
          {
            'key': '歌二',
            'count': 8,
            'playedMs': 1600000,
            'repTitle': '歌二',
            'repArtist': '歌手B',
            'isUnknown': false,
          },
          {
            'key': '歌三',
            'count': 5,
            'playedMs': 900000,
            'repTitle': '歌三',
            'repArtist': null,
            'isUnknown': false,
          },
        ];

  @override
  Future<List<Map<String, Object?>>> topArtists({
    int? startMs,
    int? endMs,
    int limit = 10,
    bool validOnly = true,
  }) async => empty
      ? const <Map<String, Object?>>[]
      : <Map<String, Object?>>[
          {
            'key': '歌手A',
            'count': 12,
            'playedMs': 5400000,
            'repTitle': '歌一',
            'repArtist': '歌手A',
            'isUnknown': false,
          },
          {
            'key': '未知艺人',
            'count': 5,
            'playedMs': 900000,
            'repTitle': '歌三',
            'repArtist': null,
            'isUnknown': true,
          },
        ];

  @override
  Future<List<Map<String, Object?>>> topAlbums({
    int? startMs,
    int? endMs,
    int limit = 10,
    bool validOnly = true,
  }) async => empty
      ? const <Map<String, Object?>>[]
      : <Map<String, Object?>>[
          {
            'key': '专辑A',
            'count': 15,
            'playedMs': 6200000,
            'repTitle': '歌一',
            'repArtist': '歌手A',
            'isUnknown': false,
          },
        ];

  @override
  Future<
      ({
        int plays,
        int playedMs,
        int activeDays,
        int distinctTracks,
        int distinctArtists,
      })> overview({
    int? startMs,
    int? endMs,
    bool validOnly = true,
  }) async => (
        plays: empty ? 0 : 42,
        playedMs: empty ? 0 : 5400000, // 1小时30分
        activeDays: empty ? 0 : 6,
        distinctTracks: empty ? 0 : 12,
        distinctArtists: empty ? 0 : 5,
      );

  @override
  Future<List<({int month, int count, int playedMs})>> monthlyTrends({
    int? startMs,
    int? endMs,
    bool validOnly = true,
  }) async => empty
      ? const <({int month, int count, int playedMs})>[]
      : const <({int month, int count, int playedMs})>[
          (month: 202609, count: 20, playedMs: 2600000),
          (month: 202610, count: 22, playedMs: 2800000),
        ];
}

/// 本地听歌统计视图（widget）：渲染、范围切换、空态。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeStatsDb db;
  late LocalListenStatsProvider provider;

  tearDown(() {
    provider.dispose();
  });

  Future<void> pumpView(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<LocalListenStatsProvider>.value(
        value: provider,
        child: const MaterialApp(
          home: Scaffold(body: LocalListenStatsView()),
        ),
      ),
    );
    // postFrame 触发 force load → 桩库微任务级返回 → 两拍内收敛
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('渲染概览卡 + 三个榜单 + 月度趋势（条目数与格式正确）',
      (tester) async {
    db = _FakeStatsDb();
    provider = LocalListenStatsProvider(db: db);
    await pumpView(tester);

    // 概览卡：次数 / 净时长（x小时y分）/ 活跃天数 / 曲目/艺人
    expect(find.text('42 次'), findsOneWidget);
    expect(find.text('1小时30分'), findsOneWidget);
    expect(find.text('6 天'), findsOneWidget);
    expect(find.text('12 / 5'), findsOneWidget);
    // 三个榜单段标题
    expect(find.text('Top 歌曲'), findsOneWidget);
    expect(find.text('Top 艺人'), findsOneWidget);
    expect(find.text('Top 专辑'), findsOneWidget);
    // 歌曲榜 3 条（名次 1..3）
    expect(find.text('歌一'), findsOneWidget);
    expect(find.text('歌二'), findsOneWidget);
    expect(find.text('歌三'), findsOneWidget);
    // 名次列（'1'/'2' 在歌曲/艺人/专辑多个榜单重复出现，'3' 仅歌曲榜第三名）
    expect(find.text('1'), findsWidgets);
    expect(find.text('2'), findsWidgets);
    expect(find.text('3'), findsOneWidget);
    // 艺人榜 2 条（含代表作副标题与未知归桶）。'歌手A' 在歌曲榜副标题
    // （歌一 repArtist）中重复出现，共 2 处。
    expect(find.text('歌手A'), findsNWidgets(2));
    expect(find.text('未知艺人'), findsOneWidget);
    expect(find.text('代表作 歌一'), findsOneWidget);
    // 专辑榜 1 条
    expect(find.text('专辑A'), findsOneWidget);
    // 月度趋势：段标题 + 柱顶数值 + 月份标签
    expect(find.text('月度趋势'), findsOneWidget);
    expect(find.text('20'), findsOneWidget);
    expect(find.text('22'), findsOneWidget);
    expect(find.text('9月'), findsOneWidget);
    expect(find.text('10月'), findsOneWidget);
  });

  testWidgets('切换时间范围触发 provider.setRange（UI 与 provider 状态一致）',
      (tester) async {
    db = _FakeStatsDb();
    provider = LocalListenStatsProvider(db: db);
    await pumpView(tester);
    expect(provider.selectedRange, LocalListenStatsRange.month);

    await tester.tap(find.text('今年'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(provider.selectedRange, LocalListenStatsRange.year);

    await tester.tap(find.text('全部'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(provider.selectedRange, LocalListenStatsRange.all);
    // 切换收敛后榜单仍正常渲染
    expect(find.text('Top 歌曲'), findsOneWidget);
  });

  testWidgets('本地无任何播放记录：显示引导空态，不渲染榜单', (tester) async {
    db = _FakeStatsDb(empty: true);
    provider = LocalListenStatsProvider(db: db);
    await pumpView(tester);

    expect(find.text('暂无播放记录，听完一首歌再来吧'), findsOneWidget);
    expect(find.text('Top 歌曲'), findsNothing);
    expect(find.text('月度趋势'), findsNothing);
  });
}
