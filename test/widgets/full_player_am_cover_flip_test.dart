import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' as services;
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/data/repositories/history_repository.dart';
import 'package:md3music/modules/player/full_player_am.dart';
import 'package:md3music/modules/player/full_player_route.dart';
import 'package:md3music/modules/player/widgets/cover_flip_crossfade.dart';
import 'package:md3music/modules/player/widgets/low_res_blur.dart';
import 'package:md3music/providers/comment_display_provider.dart';
import 'package:md3music/providers/device_provider.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/providers/listen_together_provider.dart';
import 'package:md3music/providers/local_favorites_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/controlled_audio_service.dart';

/// 造一张最小 PNG（1×1）落到临时目录，返回 `file://` URI。
///
/// 就绪门控（CoverFlipCrossfade.readinessProbe → isPlayerArtworkReady）按
/// 同键 provider 探测：只有真实可加载的封面才会放行翻转。用占位 http URI
/// 会被探测判为「未就绪/失败」而走不演过渡的直换路径（那正是要修的 bug），
/// 所以这里给真实文件。
String _writeCoverFile(String name) {
  const pngBase64 =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
  final dir = Directory.systemTemp.createTempSync('md3_cover_flip');
  addTearDown(() => dir.deleteSync(recursive: true));
  final file = File('${dir.path}/$name.png')
    ..writeAsBytesSync(base64Decode(pngBase64));
  return Uri.file(file.path).toString();
}

Song _song(int index, {String? artworkUri}) => Song(
  id: 'am-flip-$index',
  title: 'AM Flip $index',
  artist: 'Flip Artist',
  album: 'Flip Album',
  duration: const Duration(minutes: 3),
  url: 'https://audio.invalid/track-$index.mp3',
  artworkUri: artworkUri ?? 'https://image.invalid/cover-$index.jpg',
  isOnline: true,
);

void _mockPlatformChannels() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockStreamHandler(
    const services.EventChannel(
      'dev.fluttercommunity.plus/connectivity_status',
    ),
    MockStreamHandler.inline(
      onListen: (_, events) => events.success(<String>['wifi']),
    ),
  );
  messenger.setMockMethodCallHandler(
    const services.MethodChannel('com.md3music.md3music/home_widget'),
    (_) async => null,
  );
  messenger.setMockMethodCallHandler(
    services.SystemChannels.platform,
    (_) async => null,
  );
  messenger.setMockMethodCallHandler(
    const services.MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => switch (call.method) {
      'getTemporaryDirectory' ||
      'getApplicationSupportDirectory' ||
      'getApplicationDocumentsDirectory' ||
      'getDownloadsDirectory' => Directory.systemTemp.path,
      _ => null,
    },
  );
}

Widget _host(PlayerProvider player, KugouProvider kugou) => MultiProvider(
  providers: [
    ChangeNotifierProvider<PlayerProvider>.value(value: player),
    ChangeNotifierProvider<KugouProvider>.value(value: kugou),
    ChangeNotifierProvider(create: (_) => DeviceProvider()),
    ChangeNotifierProvider(create: (_) => ThemeProvider()),
    ChangeNotifierProvider(create: (_) => FavoritesProvider(syncOnStart: false)),
    ChangeNotifierProvider(create: (_) => LocalFavoritesProvider()),
    ChangeNotifierProvider(create: (_) => CommentDisplayProvider()),
    ChangeNotifierProvider(create: (_) => ListenTogetherProvider()),
  ],
  child: const MaterialApp(home: AmStyleFullPlayer()),
);

/// 翻转组件下是否挂着模糊层（翻转进行中的判据）。
///
/// 两种形态都算「在糊」：低分辨率快照就绪前是阶梯 [ImageFiltered] 兜底，
/// 就绪后换成 [LowResBlurPainter] 的 CustomPaint α 叠层——真文件封面在
/// runAsync 窗口里解析很快，两种形态出现的先后取决于调度时序，判据必须
/// 同时接受，否则轮询会错过窄窗口误报「未进入过渡」。
bool _flipBlurring(WidgetTester tester) {
  bool blurred(Iterable<Element> candidates) => candidates.isNotEmpty;
  return blurred(
    find
        .descendant(
          of: find.byType(CoverFlipCrossfade),
          matching: find.byType(ImageFiltered),
        )
        .evaluate(),
  ) ||
      blurred(
        find
            .descendant(
              of: find.byType(CoverFlipCrossfade),
              matching: find.byWidgetPredicate(
                (w) => w is CustomPaint && w.painter is LowResBlurPainter,
              ),
            )
            .evaluate(),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ControlledAudioService audio;
  late PlayerProvider player;
  late KugouProvider kugou;

  /// 已发生的切歌次数：第 N 次切歌对应 harness 的第 N+1 次装载
  /// （第 0 次是起播时的初始装载）。completeSourceLoad 的序号必须跟着自增，
  /// 复用旧序号会让「已 complete 的 Completer 再次 complete」或让本次装载
  /// 永不完成（provider 不 notify，页面状态不更新）。
  /// 每个用例的 audio 都是新的（setUp 重建），计数必须随之归零。
  var switchCount = 0;

  setUp(() async {
    switchCount = 0;
    // 频谱动态取色默认 true（settings_repository.dart#getSpectrumDynamicColor
    // 的 `?? true`），开启时 _loadSpectrumSetting 会触发 PaletteGenerator
    // 15s 超时定时器；本用例只关心翻转过渡，显式关掉避开该定时器
    // （ artworkUri 不能置 null——两张不同封面正是触发翻转的前提）。
    SharedPreferences.setMockInitialValues({
      'use_am_style_player': true,
      'settings_spectrum_dynamic_color': false,
    });
    _mockPlatformChannels();
    // 本地 API 服务置为启动失败：曲目链接/歌词的兜底请求立即被拒绝，
    // 不会挂在「等本地服务就绪」的 8s 计时器上（widget 测试里没有 Rust 服务）。
    KugouApiClient.markServerStartFailed(KugouApiClient.markServerStarting());
    KugouProvider.restoreLyric = (_) async => const KugouLyric(
      content: '[00:00.00]test lyric',
      decodedContent: '[00:00.00]test lyric',
    );
    audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
  });

  tearDown(() async {
    AudioServiceLoader.setTestOverride(null);
    KugouProvider.restoreLyric = null;
    await audio.dispose();
  });

  /// 起一台 AM 播放页（窄屏、停在封面 tab）。
  Future<(PlayerProvider, KugouProvider)> pumpAmPlayer(
    WidgetTester tester, {
    required List<Song> songs,
  }) async {
    final originalSize = tester.view.physicalSize;
    final originalDpr = tester.view.devicePixelRatio;
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.physicalSize = originalSize;
      tester.view.devicePixelRatio = originalDpr;
    });
    // 窄屏 tab 顺序 [播放列表, 封面, 歌词, ...]：封面 tab 下标 1，
    // 不显式钉住会依赖上一个用例留下的全局值。
    final originalTab = playerTabIndex.value;
    playerTabIndex.value = 1;
    addTearDown(() => playerTabIndex.value = originalTab);

    kugou = KugouProvider(registerDeviceOnStart: false);
    await tester.runAsync(() async {
      player = PlayerProvider();
      await player.audioReady.timeout(const Duration(seconds: 10));
      final load = player.playPlaylist(songs, 0);
      await audio.waitForPlaylistLoads(1);
      await audio.completeSourceLoad(0);
      await load;
      audio.emitPlaying(true);
    });
    await tester.pumpWidget(_host(player, kugou));
    // 本页有 AnimatedScale / 频谱设置读取等异步，不用 pumpAndSettle
    // （AM 页在歌词 tab 时 pumpAndSettle 不收敛；封面 tab 也可能挂
    // PlayerFrameDriver）。有界推进即可。
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(AmStyleFullPlayer), findsOneWidget);
    return (player, kugou);
  }

  /// 用例收尾：拆页面、dispose provider、冲历史（与 full_player_cover_switch_test
  /// 的 finally 结构一致；歌曲会进历史库，不冲会污染后续用例）。
  Future<void> tearDownPlayer(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      player.dispose();
      kugou.dispose();
      await HistoryRepository().flush();
    });
  }

  /// 切歌并等翻转进入「旧封面在糊」阶段。
  ///
  /// 就绪探测走真实文件 IO + ticker 首帧计时，启动比切换晚几帧——
  /// 轮询等待而不是钉死某一帧（真实时间用 runAsync 推进）。
  Future<void> switchSongAndAwaitFlip(
    WidgetTester tester, {
    bool forward = true,
  }) async {
    final loadIndex = ++switchCount; // 本次切歌的装载序号
    await tester.runAsync(() async {
      // 不 await next()/previous()：其内部可能等待音频装载完成，与下面的
      // completeSourceLoad 形成死锁（与 full_player_cover_switch_test
      // 拖动切歌的驱动方式一致：触发后只等装载）。
      // ignore: discarded_futures
      if (forward) {
        player.next();
      } else {
        player.previous();
      }
      await audio.waitForPlaylistLoads(loadIndex + 1);
      await audio.completeSourceLoad(loadIndex);
    });
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump(const Duration(milliseconds: 25));
      if (_flipBlurring(tester)) return;
    }
    fail('翻转未在 500ms 内进入过渡阶段');
  }

  /// 旧封面层的旋转矩阵 sin 分量（entry(0,2)）：符号即翻转方向。
  ///
  /// 必须限定在 CoverFlipCrossfade 子树内——播放页树里还有别的 Transform，
  /// 全局 find 会先命中它们。
  double oldLayerSin(WidgetTester tester) {
    final transforms = find.descendant(
      of: find.byType(CoverFlipCrossfade),
      matching: find.byType(Transform),
    );
    expect(transforms.evaluate(), isNotEmpty, reason: '翻转层不在树上');
    return tester.widget<Transform>(transforms.first).transform.entry(0, 2);
  }

  testWidgets('切歌（封面图变化）：封面进入模糊+翻转过渡', (tester) async {
    final coverA = _writeCoverFile('a');
    final coverB = _writeCoverFile('b');
    await pumpAmPlayer(
      tester,
      songs: [_song(0, artworkUri: coverA), _song(1, artworkUri: coverB)],
    );
    try {
      // 静止态：翻转组件下没有任何滤镜/变换
      expect(_flipBlurring(tester), isFalse);

      await switchSongAndAwaitFlip(tester);

      // 推进过整个过渡：滤镜撤掉，树上回到单层
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(_flipBlurring(tester), isFalse);
    } finally {
      await tearDownPlayer(tester);
    }
  });

  testWidgets('整段形态一致：快照路径下翻转全程不出现滤镜（无中途替换跳变）', (
    tester,
  ) async {
    // 回归守卫（真机反馈「先变高斯模糊、再被替换成 alpha」）：快照在
    // 启动前备齐后，可解析的封面对整段过渡都应是「清晰 + α 叠层」形态,
    // ImageFiltered 一次都不该出现；旧/新两层交接帧也不得出现「清晰层
    // 裸奔」（交接瞬间投影宽度为零,观感无碍,但形态判据要覆盖中段）。
    final coverA = _writeCoverFile('form-a');
    final coverB = _writeCoverFile('form-b');
    await pumpAmPlayer(
      tester,
      songs: [_song(0, artworkUri: coverA), _song(1, artworkUri: coverB)],
    );
    try {
      await switchSongAndAwaitFlip(tester);
      bool sawFilter = false;
      bool sawProxyOverlay = false;
      for (var i = 0; i < 24; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        if (find
            .descendant(
              of: find.byType(CoverFlipCrossfade),
              matching: find.byType(ImageFiltered),
            )
            .evaluate()
            .isNotEmpty) {
          sawFilter = true;
        }
        if (find
            .descendant(
              of: find.byType(CoverFlipCrossfade),
              matching: find.byWidgetPredicate(
                (w) => w is CustomPaint && w.painter is LowResBlurPainter,
              ),
            )
            .evaluate()
            .isNotEmpty) {
          sawProxyOverlay = true;
        }
      }
      // 快照路径：有叠层、无滤镜（若环境里快照构建失败则本用例退化为
      // 全程滤镜，同样不允许两种形态并存——由下一条断言兜住）。
      expect(sawProxyOverlay, isTrue, reason: '未走低分辨率快照路径');
      expect(sawFilter, isFalse, reason: '翻转中途出现滤镜↔叠层形态替换');
    } finally {
      await tearDownPlayer(tester);
    }
  });

  testWidgets('切歌但封面图不变：不演过渡（与参考视频一致）', (tester) async {
    final shared = _writeCoverFile('shared');
    await pumpAmPlayer(
      tester,
      songs: [
        _song(0, artworkUri: shared),
        _song(1, artworkUri: shared),
      ],
    );
    try {
      switchCount++;
      await tester.runAsync(() async {
        // 同 driving 方式：不 await next()（防死锁）
        // ignore: discarded_futures
        player.next();
        await audio.waitForPlaylistLoads(switchCount + 1);
        await audio.completeSourceLoad(switchCount);
      });
      // 同一张图：翻转组件自始至终不挂滤镜
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        await tester.pump(const Duration(milliseconds: 25));
      }
      expect(_flipBlurring(tester), isFalse);
    } finally {
      await tearDownPlayer(tester);
    }
  });

  testWidgets('上一曲/下一曲翻转方向相反', (tester) async {
    // 三首歌：两首歌时「1→0」既是上一曲也是「末首绕回」，下标判定有环形歧义
    // （coverSlideDirectionForIndexChange 优先判绕回），三首歌则无歧义。
    final coverA = _writeCoverFile('dir-a');
    final coverB = _writeCoverFile('dir-b');
    final coverC = _writeCoverFile('dir-c');
    await pumpAmPlayer(
      tester,
      songs: [
        _song(0, artworkUri: coverA),
        _song(1, artworkUri: coverB),
        _song(2, artworkUri: coverC),
      ],
    );
    try {
      // 下一曲（下标 0→1）：direction=+1 → 旧层 entry(0,2)=sin(angle) > 0
      await switchSongAndAwaitFlip(tester, forward: true);
      await tester.pump(const Duration(milliseconds: 60));
      expect(oldLayerSin(tester), greaterThan(0));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(_flipBlurring(tester), isFalse);

      // 上一曲（下标 1→0）：direction=-1 → entry(0,2) < 0
      await switchSongAndAwaitFlip(tester, forward: false);
      await tester.pump(const Duration(milliseconds: 60));
      expect(oldLayerSin(tester), lessThan(0));
    } finally {
      await tearDownPlayer(tester);
    }
  });
}
