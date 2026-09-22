import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/cover_prefetch_queue.dart';

void main() {
  test('带宽忙时挂起出队，空闲后恢复', () async {
    var busy = true;
    final fetched = <String>[];
    final q = CoverPrefetchQueue(
      isBandwidthBusy: () => busy,
      fetch: (url) async => fetched.add(url),
      pauseInterval: Duration.zero,
    );
    q.enqueueAll(['a', 'b']);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(fetched, isEmpty); // busy 时不下载
    busy = false;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(fetched, ['a', 'b']); // 空闲后按序补齐
    q.dispose();
  });

  test('prioritize 将目标移到队首', () async {
    var busy = true;
    final fetched = <String>[];
    final q = CoverPrefetchQueue(
      isBandwidthBusy: () => busy,
      fetch: (url) async => fetched.add(url),
      pauseInterval: Duration.zero,
    );
    q.enqueueAll(['a', 'b', 'c']);
    q.prioritize('c'); // 当前歌插队
    busy = false;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(fetched.first, 'c');
    q.dispose();
  });

  test('重复 URL 去重只取一次', () async {
    final fetched = <String>[];
    final q = CoverPrefetchQueue(
      fetch: (url) async => fetched.add(url),
      pauseInterval: Duration.zero,
    );
    q.enqueueAll(['a', 'a', 'a']);
    q.enqueueAll(['a']);
    q.prioritize('a'); // 已完成：不再重复下载
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(fetched, ['a']);
    q.dispose();
  });

  test('失败重试 maxRetries 次后放弃，并允许将来重新入队', () async {
    var calls = 0;
    final q = CoverPrefetchQueue(
      fetch: (url) async {
        calls++;
        throw Exception('net');
      },
      pauseInterval: Duration.zero,
      maxRetries: 2,
    );
    q.enqueueAll(['bad']);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(calls, 3); // 首次 + 2 次重试
    q.enqueueAll(['bad']); // 已从去重集合移除：可再次入队
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(calls, 6);
    q.dispose();
  });

  test('队列长度截断到 maxQueueLength', () async {
    final fetched = <String>[];
    final block = Completer<void>();
    final q = CoverPrefetchQueue(
      fetch: (url) async {
        await block.future;
        fetched.add(url);
      },
      pauseInterval: Duration.zero,
      maxQueueLength: 3,
    );
    q.enqueueAll(['a']); // 立即出队并被 fetch 卡住
    q.enqueueAll(['1', '2', '3', '4', '5']); // 截断到 3 个：4/5 被丢
    block.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(fetched.contains('4'), false);
    expect(fetched.contains('5'), false);
    expect(fetched, containsAll(['a', '1', '2', '3']));
    q.dispose();
  });

  test('dispose 后不再出队', () async {
    var busy = true;
    final fetched = <String>[];
    final q = CoverPrefetchQueue(
      isBandwidthBusy: () => busy,
      fetch: (url) async => fetched.add(url),
      pauseInterval: Duration.zero,
    );
    q.enqueueAll(['a']);
    q.dispose();
    busy = false;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(fetched, isEmpty);
  });
}
