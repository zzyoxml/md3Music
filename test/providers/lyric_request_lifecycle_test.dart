import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/providers/lyric_request_lifecycle.dart';
import 'package:md3music/services/kugou_api/lyric_lookup_result.dart';

void main() {
  group('LyricRequestKey', () {
    test('normalizes identity, format, and query', () {
      final first = LyricRequestKey.forRequest(
        identity: ' HASH-A ',
        format: ' LRC ',
        songName: ' Song Name ',
      );
      final second = LyricRequestKey.forRequest(
        identity: 'hash-a',
        format: 'lrc',
        songName: 'song name',
      );

      expect(first, second);
    });

    test('keeps format and local file identity separate', () {
      LyricRequestKey key(String identity, String format) =>
          LyricRequestKey.forRequest(
            identity: identity,
            format: format,
            songName: '同名歌曲',
          );

      expect(
        key('local:C:/music/a.flac', 'lrc'),
        isNot(key('local:C:/music/b.flac', 'lrc')),
      );
      expect(key('hash-a', 'lrc'), isNot(key('hash-a', 'krc')));
    });
  });

  group('LyricRequestDeduplicator', () {
    test(
      'concurrent identical requests share one future and one load',
      () async {
        final deduplicator = LyricRequestDeduplicator<String>();
        final gate = Completer<String>();
        var loads = 0;
        final key = LyricRequestKey.forRequest(
          identity: 'hash-a',
          format: 'lrc',
          songName: 'Song',
        );

        final first = deduplicator.run(key, () {
          loads++;
          return gate.future;
        });
        final second = deduplicator.run(key, () {
          loads++;
          return Future.value('unexpected');
        });

        expect(identical(first, second), isTrue);
        expect(loads, 1);
        gate.complete('lyrics');
        expect(await Future.wait([first, second]), ['lyrics', 'lyrics']);
      },
    );

    test('removes a completed request so a later refresh can reload', () async {
      final deduplicator = LyricRequestDeduplicator<int>();
      final key = LyricRequestKey.forRequest(
        identity: 'hash-a',
        format: 'lrc',
        songName: 'Song',
      );
      var loads = 0;

      expect(await deduplicator.run(key, () async => ++loads), 1);
      expect(await deduplicator.run(key, () async => ++loads), 2);
    });

    test(
      'removes a failed request so a transient failure can be retried',
      () async {
        final deduplicator = LyricRequestDeduplicator<String>();
        final key = LyricRequestKey.forRequest(
          identity: 'hash-a',
          format: 'lrc',
          songName: 'Song',
        );

        await expectLater(
          deduplicator.run(key, () async => throw StateError('temporary')),
          throwsA(isA<StateError>()),
        );
        expect(
          await deduplicator.run(key, () async => 'recovered'),
          'recovered',
        );
      },
    );
  });

  group('LyricNotFoundCache', () {
    LyricRequestKey key(String identity) => LyricRequestKey.forRequest(
      identity: identity,
      format: 'lrc',
      songName: null,
    );

    test('expires entries at the TTL boundary using the injected clock', () {
      var now = DateTime(2026, 9, 24);
      final cache = LyricNotFoundCache(
        ttl: const Duration(minutes: 5),
        capacity: 4,
        clock: () => now,
      );
      final song = key('hash-a');

      cache.put(song);
      expect(cache.contains(song), isTrue);
      now = now.add(const Duration(minutes: 5));
      expect(cache.contains(song), isFalse);
    });

    test('refreshes LRU order and evicts the oldest entry at capacity', () {
      var now = DateTime(2026, 9, 24);
      final cache = LyricNotFoundCache(
        ttl: const Duration(minutes: 5),
        capacity: 2,
        clock: () => now,
      );
      final first = key('hash-a');
      final second = key('hash-b');
      final third = key('hash-c');

      cache.put(first);
      now = now.add(const Duration(seconds: 1));
      cache.put(second);
      expect(cache.contains(first), isTrue); // 访问后移到队尾
      now = now.add(const Duration(seconds: 1));
      cache.put(third);

      expect(cache.contains(first), isTrue);
      expect(cache.contains(second), isFalse);
      expect(cache.contains(third), isTrue);
    });

    test('remove and clear invalidate entries immediately', () {
      final cache = LyricNotFoundCache(
        ttl: const Duration(minutes: 5),
        capacity: 2,
        clock: () => DateTime(2026, 9, 24),
      );
      final first = key('hash-a');
      final second = key('hash-b');
      cache.put(first);
      cache.put(second);

      cache.remove(first);
      expect(cache.contains(first), isFalse);
      cache.clear();
      expect(cache.contains(second), isFalse);
    });
  });

  group('LyricRetryPolicy', () {
    test('confirmed notFound uses the negative-cache cooldown', () {
      expect(
        LyricRetryPolicy.delayFor(LyricLookupStatus.notFound, 1),
        const Duration(minutes: 5),
      );
    });

    test('transient and invalid outcomes use bounded exponential backoff', () {
      expect(
        LyricRetryPolicy.delayFor(LyricLookupStatus.transientFailure, 1),
        const Duration(milliseconds: 250),
      );
      expect(
        LyricRetryPolicy.delayFor(LyricLookupStatus.invalidData, 2),
        const Duration(milliseconds: 500),
      );
      expect(
        LyricRetryPolicy.delayFor(LyricLookupStatus.transientFailure, 20),
        const Duration(seconds: 10),
      );
    });

    test('found and canceled outcomes do not schedule retries', () {
      expect(
        LyricRetryPolicy.delayFor(LyricLookupStatus.found, 1),
        Duration.zero,
      );
      expect(
        LyricRetryPolicy.delayFor(LyricLookupStatus.canceled, 1),
        Duration.zero,
      );
    });
  });
}
