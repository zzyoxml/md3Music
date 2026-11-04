import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/player/full_player_route.dart';
import 'package:md3music/modules/player/lyric_flight_batcher.dart';

/// `LyricFlightBatcher` 的行为契约。
///
/// 这些语义来自真机两轮实测：歌词的几次 `setState` 原本砸在飞行帧里（`pageBuilds=5`、
/// `gapMax≈49ms`），排队之后又发现冲刷和**着陆那一帧**同帧（用户反馈「松手那一下顿」）。
/// 所以既测「飞行中不提交」，也测「落位那一帧仍不提交、让出一帧再提交」——
/// 后者才是本轮的修复点，回归时最容易丢。
void main() {
  // playerExpansion 是全局单例，每条用例结束必须复位，否则残留的中间值会污染其它用例
  tearDown(() => playerExpansion.value = 0.0);

  testWidgets('不在转场中（p=0 与 p=1）时 schedule 立即执行，不排队', (
    tester,
  ) async {
    final batcher = LyricFlightBatcher(isHostMounted: () => true);
    var count = 0;

    playerExpansion.value = 0.0;
    batcher.schedule(() => count++);
    expect(count, 1);

    playerExpansion.value = 1.0;
    batcher.schedule(() => count++);
    expect(count, 2);

    batcher.dispose();
  });

  testWidgets('飞行中不提交，落位那一帧也不提交，让出一帧后才提交', (
    tester,
  ) async {
    final batcher = LyricFlightBatcher(isHostMounted: () => true);
    var count = 0;

    playerExpansion.value = 0.5;
    batcher.schedule(() => count++);
    expect(count, 0, reason: '还在飞，必须压住');

    // 端点这一帧：ValueNotifier 同步通知，但冲刷只被安排到 post-frame。
    // 同帧冲刷会把整页重建压在着陆帧上（真机实测 gapMax 49.2ms / 57.9ms）。
    playerExpansion.value = 1.0;
    expect(count, 0, reason: '落位那一帧不能冲刷，着陆帧要保持干净');

    await tester.pump();
    expect(count, 1, reason: '让出一帧后提交，只多晚约 8ms');

    batcher.dispose();
  });

  testWidgets('转场中连续 schedule 多个动作，落位让帧后按调度顺序全部应用', (
    tester,
  ) async {
    final batcher = LyricFlightBatcher(isHostMounted: () => true);
    final order = <int>[];

    playerExpansion.value = 0.3;
    batcher.schedule(() => order.add(1));
    batcher.schedule(() => order.add(2));
    batcher.schedule(() => order.add(3));
    expect(order, isEmpty);

    playerExpansion.value = 0.0;
    await tester.pump();
    // 顺序即调度顺序，不能倒也不能合并不丢。
    expect(order, <int>[1, 2, 3]);

    batcher.dispose();
  });

  testWidgets('落位后立刻起新一段转场：提交不得打进飞行帧', (tester) async {
    final batcher = LyricFlightBatcher(isHostMounted: () => true);
    var count = 0;

    playerExpansion.value = 0.4;
    batcher.schedule(() => count++);

    playerExpansion.value = 1.0; // 落位，冲刷被排到 post-frame
    playerExpansion.value = 0.6; // 还没等到那一帧，新一段转场又起爆了

    await tester.pump(); // post-frame 触发时发现仍在飞行 → 本轮不提交
    expect(count, 0, reason: '绝不能把整页重建塞进新一段转场的飞行帧');

    playerExpansion.value = 1.0; // 第二次落位
    await tester.pump();
    expect(count, 1, reason: '监听必须仍挂着并重新排程，不能把提交丢掉');

    batcher.dispose();
  });

  testWidgets('提交时宿主已卸载（isHostMounted=false）则队列丢弃且不执行', (
    tester,
  ) async {
    var mounted = true;
    final batcher = LyricFlightBatcher(isHostMounted: () => mounted);
    final applied = <int>[];

    playerExpansion.value = 0.5;
    batcher.schedule(() => applied.add(1));
    mounted = false; // 模拟转场期间页面实例销毁

    playerExpansion.value = 1.0;
    await tester.pump();
    expect(applied, isEmpty, reason: '绝不能对已卸载宿主提交 setState');

    batcher.dispose();
  });

  testWidgets('dispose() 之后落位也不应用、不抛错（含已排定的下一帧回调）', (
    tester,
  ) async {
    final batcher = LyricFlightBatcher(isHostMounted: () => true);
    var count = 0;

    playerExpansion.value = 0.5;
    batcher.schedule(() => count++);
    batcher.dispose();

    playerExpansion.value = 1.0; // 监听必须已撤：无回调、无异常
    await tester.pump();
    expect(count, 0);
  });

  testWidgets('isInFlight 与转场窗口同源：端点为 false，开区间内为 true', (
    tester,
  ) async {
    // 宿主用它决定「现在就启动取词」还是「延到落位后」，所以这条边界是行为分叉点。
    final batcher = LyricFlightBatcher(isHostMounted: () => true);

    for (final endpoint in <double>[0.0, 1.0]) {
      playerExpansion.value = endpoint;
      expect(batcher.isInFlight, isFalse, reason: 'p=$endpoint 属端点');
    }
    for (final p in <double>[0.0001, 0.5, 0.9999]) {
      playerExpansion.value = p;
      expect(batcher.isInFlight, isTrue, reason: 'p=$p 属飞行中');
    }

    playerExpansion.value = 0.0;
    batcher.dispose();
  });

  testWidgets('落位后启动任务再 schedule 自己：走立即分支，不会二次排队或丢失', (
    tester,
  ) async {
    // 「转场期间不启动取词」的实现是：把 `_fetchLyrics` 本身排队，落位后它再进来。
    // 这条用例钉住那个递归不会死锁在队列里 —— 落位后 isInFlight 已为 false，
    // 重进的 schedule 必须立即执行。
    final batcher = LyricFlightBatcher(isHostMounted: () => true);
    var starts = 0;
    var reentrantRuns = 0;

    void fetch(String song) {
      starts++;
      if (batcher.isInFlight) {
        batcher.schedule(() => fetch(song));
        return;
      }
      reentrantRuns++;
    }

    playerExpansion.value = 0.6;
    fetch('a');
    expect(starts, 1, reason: '飞行中进来一次，但没真正启动');
    expect(reentrantRuns, 0, reason: '取词主体必须等到落位后才跑');

    playerExpansion.value = 1.0;
    await tester.pump();
    expect(reentrantRuns, 1, reason: '落位后真正执行，且只执行一次');
    expect(starts, 2, reason: '重进一次即可，不能反复排队');

    batcher.dispose();
  });

  testWidgets('转场中多个调用点重复排队同一首：全部在落位后依次执行', (
    tester,
  ) async {
    // 两页的 `_fetchLyrics` 各有 4 个调用点，转场中可能连着排好几个「同一首的启动」。
    // 排队器本身不去重（去重靠宿主的元数据键守卫），这里把职责边界钉住。
    final batcher = LyricFlightBatcher(isHostMounted: () => true);
    final started = <String>[];

    playerExpansion.value = 0.2;
    for (var i = 0; i < 3; i++) {
      batcher.schedule(() => started.add('a'));
    }
    expect(started, isEmpty);

    playerExpansion.value = 1.0;
    await tester.pump();
    expect(started, <String>['a', 'a', 'a'], reason: '三条都执行，由宿主判重决定是否真取词');

    batcher.dispose();
  });

  testWidgets('转场窗口是开区间 (0,1)：0.0/1.0 属端点立即执行，0.0001/0.9999 属窗口内排队', (
    tester,
  ) async {
    // 钉住与封面形变层绘制窗口同源的语义，防止日后改成 `>=0 && <=1` 把端点误判为转场中。
    final batcher = LyricFlightBatcher(isHostMounted: () => true);
    var count = 0;

    for (final endpoint in <double>[0.0, 1.0]) {
      playerExpansion.value = endpoint;
      batcher.schedule(() => count++);
    }
    expect(count, 2); // 端点立即执行

    for (final p in <double>[0.0001, 0.9999]) {
      playerExpansion.value = p;
      batcher.schedule(() => count++);
      expect(count, 2); // 窗口内只排队
    }

    playerExpansion.value = 0.0; // 落位
    await tester.pump();
    expect(count, 4); // 两条一起冲刷

    batcher.dispose();
  });
}
