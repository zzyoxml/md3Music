/// 逐字动画平滑时钟（[_smoothPosMs]）不回退回归测试。
///
/// 背景：字内渐变（classic maskX / sweep 扫光）的进度由平滑时钟驱动。
/// positionStream 约 200ms 才给一个权威位置，平滑时钟在这段间隔内先行推进，
/// 收到权威值时权威值常略小于平滑值（采样相位差）。旧实现无条件指数校正 /
/// 暂停时硬吸附，导致暂停与播放中偶发「进度回退一截」。
///
/// 本文件钉住：死区（200ms）内的小幅回退不采纳；真实 seek 大回退仍生效。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/apple_lyrics_view.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // 逐字行：让歌词视图走 WordRenderer 路径（字内渐变 / 扫光的消费方）。
  List<LyricLine> wordTimedLines() => <LyricLine>[
    LyricLine(
      startTime: 0,
      duration: 20000,
      text: '逐字歌词测试',
      words: const <LyricWord>[
        LyricWord(startTime: 0, duration: 2000, text: '逐'),
        LyricWord(startTime: 2000, duration: 2000, text: '字'),
        LyricWord(startTime: 4000, duration: 2000, text: '歌'),
        LyricWord(startTime: 6000, duration: 2000, text: '词'),
        LyricWord(startTime: 8000, duration: 12000, text: '测试'),
      ],
    ),
  ];

  Future<void> mount(
    WidgetTester tester,
    ValueNotifier<Duration> pos, {
    required bool isPlaying,
  }) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 600,
            child: AppleLyricsView(
              lines: wordTimedLines(),
              currentTimeMs: 0,
              positionListenable: pos,
              isPlaying: isPlaying,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> pumpFrames(WidgetTester tester, int frames) async {
    for (int i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  /// 模拟真实播放：每帧同时推进帧时钟与权威位置（200ms 采样在真实环境里
  /// 也是持续前进的，权威值静止会触发「平滑值漂移裁剪」分支，不是本用例目标）。
  Future<void> pumpPlaying(
    WidgetTester tester,
    ValueNotifier<Duration> pos,
    int frames,
  ) async {
    for (int i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      pos.value += const Duration(milliseconds: 16);
    }
  }

  double smoothOf(WidgetTester tester) {
    final state = tester.state(find.byType(AppleLyricsView)) as dynamic;
    return state.smoothPosMsForTest as double;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await LyricPreferences.instance.reset();
    await LyricPreferences.instance.setEcoMode(false);
  });

  tearDown(() async {
    await LyricPreferences.instance.reset();
  });

  testWidgets('播放中权威位置小幅回退（死区内）不拉低平滑时钟', (tester) async {
    final pos = ValueNotifier<Duration>(Duration.zero);
    addTearDown(pos.dispose);
    await mount(tester, pos, isPlaying: true);
    await pumpPlaying(tester, pos, 30); // 平滑时钟约推进 480ms

    final double before = smoothOf(tester);
    expect(before, greaterThan(200.0), reason: '前置：平滑时钟应已推进');

    // 权威位置比平滑时钟小约 100ms（采样相位差的典型形态）。
    pos.value = Duration(milliseconds: (before - 100).round());
    await pumpFrames(tester, 1);

    expect(
      smoothOf(tester),
      greaterThanOrEqualTo(before),
      reason: '死区内的小幅回退不得让字内渐变进度倒退',
    );
  });

  testWidgets('暂停瞬间权威位置小幅回退不拉低平滑时钟', (tester) async {
    final pos = ValueNotifier<Duration>(Duration.zero);
    addTearDown(pos.dispose);
    await mount(tester, pos, isPlaying: true);
    await pumpPlaying(tester, pos, 30);

    final double before = smoothOf(tester);
    expect(before, greaterThan(200.0), reason: '前置：平滑时钟应已推进');

    // 暂停，同时权威位置回退 150ms（小于 seek 阈值）。
    await mount(tester, pos, isPlaying: false);
    pos.value = Duration(milliseconds: (before - 150).round());
    await pumpFrames(tester, 3);

    expect(
      smoothOf(tester),
      greaterThanOrEqualTo(before),
      reason: '暂停时应冻结在已推进位置，不得回退一截',
    );
  });

  testWidgets('真实 seek 大回退仍吸附到权威位置', (tester) async {
    final pos = ValueNotifier<Duration>(const Duration(seconds: 8));
    addTearDown(pos.dispose);
    await mount(tester, pos, isPlaying: true);
    await pumpFrames(tester, 5);

    final double before = smoothOf(tester);
    expect(before, greaterThan(7000.0), reason: '前置：大跳变应吸附到 8s');

    // seek 回退 3s（超过 500ms 大跳变阈值）。
    pos.value = const Duration(seconds: 5);
    await pumpFrames(tester, 2);

    expect(
      smoothOf(tester),
      lessThan(before - 1000),
      reason: '真实 seek 回退必须生效，不能被回退死区拦住',
    );
  });

  testWidgets('播放中正常前进不受回退死区影响', (tester) async {
    final pos = ValueNotifier<Duration>(Duration.zero);
    addTearDown(pos.dispose);
    await mount(tester, pos, isPlaying: true);
    await pumpFrames(tester, 5);

    final double a = smoothOf(tester);
    pos.value = Duration(milliseconds: a.round() + 200);
    await pumpFrames(tester, 5);
    final double b = smoothOf(tester);

    expect(b, greaterThan(a), reason: '权威位置前进时平滑时钟必须继续推进');
  });
}
