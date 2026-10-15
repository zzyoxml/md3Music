import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/repositories/home_discover_progress_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // 顺带把仓库的内存态清掉：load() 在一次进程内只读一次（这是它本来的语义），
    // 不清的话各用例会串味。clear() 正是"丢数据 + 丢内存态"的那一个出口。
    await const HomeDiscoverProgressStore().clear();
  });

  group('刷歌断点读写', () {
    test('空初始值回落 cursor=0 / seen 为空', () async {
      final store = const HomeDiscoverProgressStore();
      final loaded = await store.load();
      expect(loaded.cursor, 0);
      expect(loaded.seen, isEmpty);
    });

    test('存进去能原样取回', () async {
      await const HomeDiscoverProgressStore().save(
        HomeDiscoverProgress(cursor: 57, seen: <String>{'a', 'b', 'c'}),
      );

      final loaded = await const HomeDiscoverProgressStore().load();
      expect(loaded.cursor, 57);
      expect(loaded.seen, <String>{'a', 'b', 'c'});
    });

    test('seen 超上限时截尾，保留最新的那些', () async {
      // 顺序即消费先后：h0 最旧、h599 最新。
      final seen = <String>{for (var i = 0; i < 600; i++) 'h$i'};
      await const HomeDiscoverProgressStore().save(
        HomeDiscoverProgress(cursor: 600, seen: seen),
      );

      final loaded = await const HomeDiscoverProgressStore().load();
      expect(loaded.seen.length, HomeDiscoverProgressStore.seenLimit);
      expect(loaded.seen.length, 500);
      expect(loaded.seen, <String>{for (var i = 100; i < 600; i++) 'h$i'});
      expect(loaded.seen.first, 'h100', reason: '丢的是最旧的 100 条');
      expect(loaded.seen.last, 'h599', reason: '最新的必须留着');
      expect(loaded.cursor, 600, reason: '截断只动 seen，不动游标');
    });

    test('历史脏数据（存了超长集合）读回来时也会再截一次', () async {
      SharedPreferences.setMockInitialValues({
        HomeDiscoverProgressStore.prefKey:
            '{"cursor": 3, "seen": [${List.generate(700, (i) => '"d$i"').join(',')}]}',
      });

      final loaded = await const HomeDiscoverProgressStore().load();
      expect(loaded.seen.length, 500);
      expect(loaded.seen.first, 'd200');
      expect(loaded.seen.last, 'd699');
    });

    test('数据不是 JSON 时安全回落，不抛', () async {
      SharedPreferences.setMockInitialValues({
        HomeDiscoverProgressStore.prefKey: 'not json',
      });

      final loaded = await const HomeDiscoverProgressStore().load();
      expect(loaded.cursor, 0);
      expect(loaded.seen, isEmpty);
    });

    test('字段类型不对时同样安全回落，不抛', () async {
      SharedPreferences.setMockInitialValues({
        HomeDiscoverProgressStore.prefKey: '{"cursor": "x", "seen": 5}',
      });

      final loaded = await const HomeDiscoverProgressStore().load();
      expect(loaded.cursor, 0);
      expect(loaded.seen, isEmpty);
    });

    test('seen 里混了非字符串元素也按损坏处理', () async {
      SharedPreferences.setMockInitialValues({
        HomeDiscoverProgressStore.prefKey: '{"cursor": 1, "seen": ["a", 7]}',
      });

      final loaded = await const HomeDiscoverProgressStore().load();
      expect(loaded.cursor, 0);
      expect(loaded.seen, isEmpty);
    });

    test('顶层不是对象时安全回落', () async {
      SharedPreferences.setMockInitialValues({
        HomeDiscoverProgressStore.prefKey: '[1, 2, 3]',
      });

      final loaded = await const HomeDiscoverProgressStore().load();
      expect(loaded.cursor, 0);
      expect(loaded.seen, isEmpty);
    });

    test('clear 之后读回空', () async {
      final store = const HomeDiscoverProgressStore();
      await store.save(
        const HomeDiscoverProgress(cursor: 42, seen: <String>{'x', 'y'}),
      );
      expect((await store.load()).cursor, 42, reason: '前置条件：确实写进去了');

      await store.clear();

      final loaded = await store.load();
      expect(loaded.cursor, 0);
      expect(loaded.seen, isEmpty);
    });

    test('load 幂等：并发两次调用合流成同一个 Future', () async {
      final store = const HomeDiscoverProgressStore();
      final first = store.load();
      final second = store.load();
      expect(second, same(first), reason: '应当共用同一次读盘 Future');
      expect(await second, await first);
      expect((await first).cursor, 0);
    });
  });
}
