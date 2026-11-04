import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/startup_auto_play.dart';
import 'package:md3music/data/repositories/settings_repository.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('启动自动播放的持久化', () {
    test('总开关默认关闭：不主动开启就不该改启动行为', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await SettingsRepository().getStartupAutoPlayEnabled(), isFalse);
    });

    test('音源默认「继续上次播放」：唯一不依赖登录与网络的音源', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await SettingsRepository().getStartupAutoPlaySource(), 'resume');
    });

    test('自动打开播放页默认开启', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await SettingsRepository().getStartupAutoPlayOpenPage(), isTrue);
    });

    test('三项均可写入并读回', () async {
      SharedPreferences.setMockInitialValues({});
      final repo = SettingsRepository();
      await repo.setStartupAutoPlayEnabled(true);
      await repo.setStartupAutoPlaySource('fmNiche');
      await repo.setStartupAutoPlayOpenPage(false);
      expect(await repo.getStartupAutoPlayEnabled(), isTrue);
      expect(await repo.getStartupAutoPlaySource(), 'fmNiche');
      expect(await repo.getStartupAutoPlayOpenPage(), isFalse);
    });

    test('持久化 key 固定为 settings_startup_auto_play*', () async {
      SharedPreferences.setMockInitialValues({});
      final repo = SettingsRepository();
      await repo.setStartupAutoPlayEnabled(true);
      await repo.setStartupAutoPlaySource('daily');
      await repo.setStartupAutoPlayOpenPage(false);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('settings_startup_auto_play'), isTrue);
      expect(prefs.getString('settings_startup_auto_play_source'), 'daily');
      expect(prefs.getBool('settings_startup_auto_play_open_page'), isFalse);
    });
  });

  group('StartupAutoPlaySource', () {
    test('每个 value 都能被反解回自己', () {
      for (final source in StartupAutoPlaySource.values) {
        expect(StartupAutoPlaySource.fromValue(source.value), source);
      }
    });

    test('非法/空值回落到「继续上次播放」，不让启动流程崩在开机第一步', () {
      expect(StartupAutoPlaySource.fromValue(null), StartupAutoPlaySource.resume);
      expect(StartupAutoPlaySource.fromValue(''), StartupAutoPlaySource.resume);
      expect(StartupAutoPlaySource.fromValue('nope'), StartupAutoPlaySource.resume);
      // 清数据后重装 / 手工改过 preferences 都可能塞进旧值
      expect(StartupAutoPlaySource.fromValue('fmHeart_v1'),
          StartupAutoPlaySource.resume);
    });

    test('只有「继续上次播放」不依赖登录', () {
      expect(StartupAutoPlaySource.resume.needsLogin, isFalse);
      for (final source in StartupAutoPlaySource.values) {
        if (source == StartupAutoPlaySource.resume) continue;
        expect(source.needsLogin, isTrue, reason: '${source.value} 应需要登录');
      }
    });

    test('FM 四档对齐 kFmStations 的下标（红心 0 / 探索 1 / 小众 2 / 电台 3）', () {
      expect(StartupAutoPlaySource.fmHeart.fmStationIndex, 0);
      expect(StartupAutoPlaySource.fmExplore.fmStationIndex, 1);
      expect(StartupAutoPlaySource.fmNiche.fmStationIndex, 2);
      expect(StartupAutoPlaySource.fmRadio.fmStationIndex, 3);
      expect(StartupAutoPlaySource.resume.fmStationIndex, isNull);
      expect(StartupAutoPlaySource.daily.fmStationIndex, isNull);
      expect(StartupAutoPlaySource.homeDiscover.fmStationIndex, isNull);
    });

    test('value 唯一且非空，label 唯一（设置页下拉依赖这两条）', () {
      final values = StartupAutoPlaySource.values.map((e) => e.value).toSet();
      final labels = StartupAutoPlaySource.values.map((e) => e.label).toSet();
      expect(values.length, StartupAutoPlaySource.values.length);
      expect(labels.length, StartupAutoPlaySource.values.length);
      for (final source in StartupAutoPlaySource.values) {
        expect(source.value, isNotEmpty);
        expect(source.label, isNotEmpty);
      }
    });

    test('共 7 个音源', () {
      expect(StartupAutoPlaySource.values, hasLength(7));
    });
  });

  // 用普通 test 而非 testWidgets：KugouProvider 构造即 _autoConnect() 打本地
  // API 服务器，测试环境没有服务器、它会挂着重试定时器；testWidgets 的
  // "无遗留 Timer" 断言会因此失败，与本用例要验的东西无关。
  test('关闭时 maybeAutoPlay 不碰播放器、不发请求，直接报未起播', () async {
    SharedPreferences.setMockInitialValues({});
    StartupAutoPlay.debugReset();
    // 真实的 provider 实例：若关闭分支里解引用了它们或触发了起播，
    // 这条用例会因网络调用 / 播放状态变化而失败。
    final kugou = KugouProvider();
    final player = PlayerProvider();
    try {
      final result = await StartupAutoPlay.maybeAutoPlay(
        kugou: kugou,
        player: player,
      );
      expect(result.started, isFalse);
      expect(result.openPlayerPage, isFalse);
      expect(player.isPlaying, isFalse);
      // 音源列表也没被动过（没走 getRecommendDaily / getPersonalFm）
      expect(kugou.personalFmSongs, isEmpty);
      expect(kugou.recommendSongs, isEmpty);

      // 一次性保护：热重载 / 重复首帧回调再来一次同样不参与
      final again = await StartupAutoPlay.maybeAutoPlay(
        kugou: kugou,
        player: player,
      );
      expect(again.started, isFalse);
    } finally {
      kugou.dispose();
      player.dispose();
    }
  });
}
