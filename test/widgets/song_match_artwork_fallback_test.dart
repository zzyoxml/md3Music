import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/data/repositories/song_match_repository.dart';
import 'package:md3music/providers/song_match_provider.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SongMatchRepository.debugResetForTest();
  });

  tearDown(() {
    SongMatchRepository.debugResetForTest();
  });

  testWidgets('无 SongMatchProvider 环境返回 null（保持原行为）', (tester) async {
    SongMatchInfo? resolved;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) {
            // helper 带 listen:true，必须在 build 期调用（与封面组件一致）
            resolved = matchedInfoForLocal(ctx, 'local_/a.mp3');
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(resolved, isNull);
  });

  testWidgets('已匹配的本地歌曲返回自己的匹配记录（含单曲偏好位）', (tester) async {
    final provider = SongMatchProvider(autoStartOnCreate: false);
    addTearDown(provider.dispose);
    final repo = SongMatchRepository();
    await repo.ensureLoaded();
    await repo.put(
      SongMatchProvider.infoFromCandidate(
        'local_/matched.mp3',
        KugouSongDetail(
          hash: 'h_cover',
          songName: '歌名',
          artistName: '歌手',
          artworkUri: 'https://img.example/cover.jpg',
        ),
        SongMatchSource.auto,
      ).copyWith(preferOnlineCover: true),
    );

    SongMatchInfo? resolved;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SongMatchProvider>.value(value: provider),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (ctx) {
              resolved = matchedInfoForLocal(ctx, 'local_/matched.mp3');
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    expect(resolved, isNotNull);
    expect(resolved!.artworkUri, 'https://img.example/cover.jpg');
    expect(resolved!.preferOnlineCover, isTrue);
    // 未匹配的歌曲查不到记录
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SongMatchProvider>.value(value: provider),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (ctx) {
              resolved = matchedInfoForLocal(ctx, 'local_/other.mp3');
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    expect(resolved, isNull);
    // testWidgets 结束会断言无挂起 Timer：清掉仓库防抖落盘的 5s Timer
    SongMatchRepository.debugResetForTest();
  });
}
