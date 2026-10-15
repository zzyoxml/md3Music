// 测试 harness 口径：必须导入 material_ui（而非 flutter/material.dart），
// 否则 MaterialApp 的 Material 类型与页面组件不匹配（见 local_music_menu_focus_test）。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/data/repositories/song_match_repository.dart';
import 'package:md3music/modules/library/song_match_sheet.dart';
import 'package:md3music/providers/song_match_provider.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Song _localSong() {
  return const Song(
    id: 'local_/music/demo.flac',
    title: 'demo.flac',
    artist: '测试歌手',
    album: '',
    duration: Duration(seconds: 182),
    localPath: '/music/demo.flac',
  );
}

KugouSongDetail _candidate(String hash, String name) {
  return KugouSongDetail(
    hash: hash,
    songName: name,
    artistName: '在线歌手',
    albumName: '在线专辑',
    duration: 182,
    albumAudioId: '100200300',
  );
}

Widget _harness(SongMatchProvider provider, Song song) {
  // Provider 必须包在 MaterialApp 之上：弹层走根 Navigator，
  // MultiProvider 放在 MaterialApp 之下时弹层子树读不到 Provider
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<SongMatchProvider>.value(value: provider),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              onPressed: () => showSongMatchSheet(ctx, song),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const toastChannel = MethodChannel('PonnamKarthik/fluttertoast');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SongMatchRepository.debugResetForTest();
    SongMatchProvider.debugSearchOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(toastChannel, (call) async => true);
  });

  tearDown(() {
    SongMatchProvider.debugSearchOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(toastChannel, null);
  });

  testWidgets('打开弹层自动搜索并展示候选；点选记忆为手动匹配', (tester) async {
    final provider = SongMatchProvider(autoStartOnCreate: false);
    addTearDown(provider.dispose);
    final song = _localSong();
    SongMatchProvider.debugSearchOverride = (keywords) async {
      return KugouSearchResult(
        songs: [_candidate('h_cand1', '在线歌名甲'), _candidate('h_cand2', '在线歌名乙')],
        total: 2,
      );
    };

    await tester.pumpWidget(_harness(provider, song));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 初始关键词 = 「歌名 歌手」（find.text 可匹配 EditableText 的当前值）
    expect(find.text('demo 测试歌手'), findsOneWidget);
    expect(find.text('在线歌名甲'), findsOneWidget);
    expect(find.text('在线歌名乙'), findsOneWidget);

    // 点选第一个候选 → 手动匹配落库 + 弹层关闭
    await tester.tap(find.text('在线歌名甲'));
    await tester.pump();
    // Fluttertoast.showToast 内部有 1s Timer，显式推进消化（避免挂起 Timer 断言）
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    final repo = SongMatchRepository();
    expect(repo.isMatched(song.id), isTrue);
    final info = repo.get(song.id)!;
    expect(info.hash, 'h_cand1');
    expect(info.source, SongMatchSource.manual);
    expect(info.albumAudioId, '100200300');
    // testWidgets 结束会断言无挂起 Timer：清掉仓库防抖落盘的 5s Timer
    SongMatchRepository.debugResetForTest();
  });

  testWidgets('已匹配时显示「取消匹配」，取消后记录 dismissed', (tester) async {
    final provider = SongMatchProvider(autoStartOnCreate: false);
    addTearDown(provider.dispose);
    final song = _localSong();
    final repo = SongMatchRepository();
    await repo.ensureLoaded();
    await repo.put(
      SongMatchProvider.infoFromCandidate(
        song.id,
        _candidate('h_exist', '在线歌名甲'),
        SongMatchSource.auto,
      ),
    );

    SongMatchProvider.debugSearchOverride = (keywords) async =>
        KugouSearchResult(songs: [_candidate('h_cand1', '在线歌名甲')], total: 1);

    await tester.pumpWidget(_harness(provider, song));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('取消匹配'), findsOneWidget);
    expect(find.text('已匹配 · 在线歌手'), findsOneWidget);

    await tester.tap(find.text('取消匹配'));
    await tester.pump();
    // 消化 Fluttertoast 内部的 1s Timer
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    final info = repo.get(song.id);
    expect(info!.dismissed, isTrue);
    expect(repo.isMatched(song.id), isFalse);
    SongMatchRepository.debugResetForTest();
  });

  testWidgets('搜索无结果时显示空态文案', (tester) async {
    final provider = SongMatchProvider(autoStartOnCreate: false);
    addTearDown(provider.dispose);
    SongMatchProvider.debugSearchOverride = (keywords) async =>
        const KugouSearchResult(songs: [], total: 0);

    await tester.pumpWidget(_harness(provider, _localSong()));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('未找到候选，试试只搜歌名'), findsOneWidget);
  });

  testWidgets('单曲偏好开关：实时写回该歌的记录，其他歌曲不受影响', (tester) async {
    final provider = SongMatchProvider(autoStartOnCreate: false);
    addTearDown(provider.dispose);
    final song = _localSong();
    final other = const Song(
      id: 'local_/music/other.flac',
      title: 'other.flac',
      artist: '测试歌手',
      album: '',
      duration: Duration(seconds: 200),
      localPath: '/music/other.flac',
    );
    final repo = SongMatchRepository();
    await repo.ensureLoaded();
    await repo.put(SongMatchProvider.infoFromCandidate(
        song.id, _candidate('h_song', '在线歌名甲'), SongMatchSource.manual));
    await repo.put(SongMatchProvider.infoFromCandidate(
        other.id, _candidate('h_other', '在线歌名乙'), SongMatchSource.manual));
    SongMatchProvider.debugSearchOverride = (keywords) async =>
        KugouSearchResult(songs: [_candidate('h_cand1', '在线歌名甲')], total: 1);

    await tester.pumpWidget(_harness(provider, song));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 两个开关出现且默认关
    expect(find.text('使用在线歌词（覆盖内嵌）'), findsOneWidget);
    expect(find.text('使用在线封面（覆盖内嵌）'), findsOneWidget);
    expect(repo.get(song.id)!.preferOnlineLyrics, isFalse);

    // 打开歌词偏好 → 只写这首歌
    await tester.tap(find.text('使用在线歌词（覆盖内嵌）'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(repo.get(song.id)!.preferOnlineLyrics, isTrue);
    expect(repo.get(song.id)!.preferOnlineCover, isFalse);
    expect(repo.get(other.id)!.preferOnlineLyrics, isFalse);

    // 打开封面偏好
    await tester.tap(find.text('使用在线封面（覆盖内嵌）'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(repo.get(song.id)!.preferOnlineCover, isTrue);
    expect(repo.get(other.id)!.preferOnlineCover, isFalse);

    SongMatchRepository.debugResetForTest();
  });
}
