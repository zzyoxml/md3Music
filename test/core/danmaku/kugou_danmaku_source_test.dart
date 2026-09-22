import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/danmaku/danmaku_entry.dart';
import 'package:md3music/core/danmaku/danmaku_source.dart';

void main() {
  const duration = Duration(seconds: 100);

  test('fetch 抛异常 → 空列表', () async {
    final source = KugouDanmakuSource(
      fetch: (_, _) async => throw Exception('boom'),
      idOrHash: '123',
      duration: duration,
    );
    expect(await source.load(), isEmpty);
  });

  test('fetch 返回 null → 空列表', () async {
    final source = KugouDanmakuSource(
      fetch: (_, _) async => null,
      idOrHash: '123',
      duration: duration,
    );
    expect(await source.load(), isEmpty);
  });

  test('fetch 返回乱序两条 → 结果按时间升序', () async {
    final unordered = [
      DanmakuEntry(time: const Duration(seconds: 75), text: 'late'),
      DanmakuEntry(time: const Duration(seconds: 25), text: 'early'),
    ];
    final source = KugouDanmakuSource(
      fetch: (_, _) async => unordered,
      idOrHash: '123',
      duration: duration,
    );
    final loaded = await source.load();
    expect(loaded, hasLength(2));
    expect(loaded[0].time, const Duration(seconds: 25));
    expect(loaded[1].time, const Duration(seconds: 75));
    // load() 返回的是新列表，不应修改传入的列表
    expect(unordered[0].time, const Duration(seconds: 75));
  });
}
