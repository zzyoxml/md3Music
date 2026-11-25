// Windows 任务栏进度同步器的契约测试。
//
// 覆盖三件事，都是「改错了不会报错、只会静默失效」的类型：
// 1. **1s 节流**：位置高频变化只推 1 次，且窗口末尾补推末态（不丢最后一次）；
// 2. **语义事件立即生效**：播放/暂停、切歌、无歌/时长未知必须立刻推，不等节流；
// 3. **平台门控**：非 Windows 零通道调用（防止宿主平台泄漏进测试）。
//
// 用 `testWidgets` 而不是 `test`：同步器内部有 `Timer`，`testWidgets` 的假时钟
// 可以用 `tester.pump(时长)` 精确推进 —— 真时钟要么等满 1s（慢），要么靠
// `Future.delayed` 在假时钟里永远不完成（挂死）。
// `debugDefaultTargetPlatformOverride` **必须**在测试体内复位（框架在测试体
// 结束时校验 foundation debug 变量，放 setUp/tearDown 会直接判失败），
// 故统一走 [_onWindows] 包一层（与 windows_fullscreen_test.dart 同一手法）。
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/windows_taskbar_sync.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/providers/player_provider.dart';

/// 只暴露同步器真正读取的那几个成员，其余一律 noSuchMethod 兜住。
///
/// 用 `extends ChangeNotifier` 而不是自己实现 add/removeListener：
/// 同步器依赖 `notifyListeners` 的真实语义（监听者集合的增删）。
class _FakePlayer extends ChangeNotifier implements PlayerProvider {
  final ValueNotifier<Duration> _positionNotifier = ValueNotifier(
    Duration.zero,
  );

  @override
  ValueNotifier<Duration> get positionNotifier => _positionNotifier;

  Song? song;
  Duration currentPosition = Duration.zero;
  Duration? currentDuration;
  bool playing = false;

  @override
  Song? get currentSong => song;

  @override
  Duration get position => currentPosition;

  @override
  Duration? get duration => currentDuration;

  @override
  bool get isPlaying => playing;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  /// 模拟一次高频位置推进（只动 positionNotifier，不 notifyListeners ——
  /// 这正是 PlayerProvider 的真实行为）。
  void advanceTo(Duration value) {
    currentPosition = value;
    _positionNotifier.value = value;
  }

  /// 模拟一次语义事件（播放/暂停、切歌、时长回填）：走 notifyListeners。
  void emitSemantic({
    bool? playing,
    Duration? position,
    Duration? duration,
    Song? song,
  }) {
    if (playing != null) this.playing = playing;
    if (position != null) {
      currentPosition = position;
      _positionNotifier.value = position;
    }
    if (duration != null) currentDuration = duration;
    if (song != null) this.song = song;
    notifyListeners();
  }

  @override
  void dispose() {
    _positionNotifier.dispose();
    super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('md3music/window_tray');

  final calls = <Map<Object?, Object?>>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'setTaskbarState') {
            calls.add(Map<Object?, Object?>.from(call.arguments as Map));
            return true;
          }
          return false;
        });
  });

  tearDown(() {
    WindowsTaskbarSync.instance.detach();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Song makeSong(String id) => Song(
    id: id,
    title: 't$id',
    artist: 'a',
    album: 'al',
    duration: const Duration(seconds: 200),
  );

  testWidgets('attach 立即推一拍，无歌时 visible=false', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final player = _FakePlayer();
      addTearDown(player.dispose);
      WindowsTaskbarSync.instance.attach(player);
      await tester.pump();
      expect(calls, hasLength(1));
      expect(calls.single['visible'], isFalse);
      expect(calls.single['isPlaying'], isFalse);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('有歌 + 有时长 → visible=true 且带上位置/时长', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final player = _FakePlayer()
        ..song = makeSong('s1')
        ..currentDuration = const Duration(seconds: 200);
      addTearDown(player.dispose);
      WindowsTaskbarSync.instance.attach(player);
      player.emitSemantic(
        playing: true,
        position: const Duration(seconds: 12),
      );
      await tester.pump();
      final last = calls.last;
      expect(last['visible'], isTrue);
      expect(last['isPlaying'], isTrue);
      expect(last['position'], 12000);
      expect(last['duration'], 200000);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('时长未知（0）时 visible=false，不留 0% 假进度', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final player = _FakePlayer()
        ..song = makeSong('s1')
        ..currentDuration = Duration.zero;
      addTearDown(player.dispose);
      WindowsTaskbarSync.instance.attach(player);
      player.emitSemantic(playing: true);
      await tester.pump();
      expect(calls.last['visible'], isFalse);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('位置高频更新 1s 内只推 1 次，窗口末尾补推末态', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final player = _FakePlayer()
        ..song = makeSong('s1')
        ..currentDuration = const Duration(seconds: 200);
      addTearDown(player.dispose);
      WindowsTaskbarSync.instance.attach(player);
      await tester.pump();
      calls.clear();

      // 节流窗口内的 5 次位置推进：只应产生 1 次立即推送。
      for (var i = 1; i <= 5; i++) {
        player.advanceTo(Duration(milliseconds: i * 200));
      }
      await tester.pump();
      expect(calls, hasLength(1));
      expect(calls.single['position'], 200);

      // 窗口结束后补推末态（1000ms），而不是停在 200ms。
      await tester.pump(WindowsTaskbarSync.minInterval);
      await tester.pump();
      expect(calls, hasLength(2));
      expect(calls.last['position'], 1000);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('播放/暂停立即推送并重置节流窗口', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final player = _FakePlayer()
        ..song = makeSong('s1')
        ..currentDuration = const Duration(seconds: 200);
      addTearDown(player.dispose);
      WindowsTaskbarSync.instance.attach(player);
      await tester.pump();

      player.advanceTo(const Duration(seconds: 1));
      await tester.pump();
      calls.clear();

      // 节流窗口内暂停：必须立刻推，不能等到 1s 后。
      player.emitSemantic(playing: false, position: const Duration(seconds: 2));
      await tester.pump();
      expect(calls, hasLength(1));
      expect(calls.single['isPlaying'], isFalse);
      expect(calls.single['position'], 2000);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('切歌立即推送', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final player = _FakePlayer()
        ..song = makeSong('s1')
        ..currentDuration = const Duration(seconds: 200);
      addTearDown(player.dispose);
      WindowsTaskbarSync.instance.attach(player);
      await tester.pump();
      player.advanceTo(const Duration(seconds: 1));
      await tester.pump();
      calls.clear();

      player.emitSemantic(
        song: makeSong('s2'),
        duration: const Duration(seconds: 180),
        position: Duration.zero,
      );
      await tester.pump();
      expect(calls, hasLength(1));
      expect(calls.single['duration'], 180000);
      expect(calls.single['position'], 0);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('detach 后不再推送', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final player = _FakePlayer()
        ..song = makeSong('s1')
        ..currentDuration = const Duration(seconds: 200);
      addTearDown(player.dispose);
      WindowsTaskbarSync.instance.attach(player);
      WindowsTaskbarSync.instance.detach();
      await tester.pump();
      calls.clear();

      player.advanceTo(const Duration(seconds: 5));
      player.emitSemantic(playing: true);
      await tester.pump(WindowsTaskbarSync.minInterval);
      await tester.pump();
      expect(calls, isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('非 Windows 平台零通道调用', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final player = _FakePlayer()
        ..song = makeSong('s1')
        ..currentDuration = const Duration(seconds: 200);
      addTearDown(player.dispose);
      WindowsTaskbarSync.instance.attach(player);
      player.advanceTo(const Duration(seconds: 5));
      player.emitSemantic(playing: true);
      await tester.pump(WindowsTaskbarSync.minInterval);
      await tester.pump();
      expect(calls, isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
