import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/services/kugou_api/lyric_lookup_result.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';

void main() {
  test('only a clean completed search with no candidate is notFound', () {
    expect(LyricLookupResult.noMatch().status, LyricLookupStatus.notFound);
  });

  test(
    'transport failure takes priority over malformed fallback responses',
    () {
      expect(
        LyricLookupResult.noMatch(
          sawTransientFailure: true,
          sawInvalidData: true,
        ).status,
        LyricLookupStatus.transientFailure,
      );
    },
  );

  test('malformed responses are invalidData rather than notFound', () {
    expect(
      LyricLookupResult.noMatch(sawInvalidData: true).status,
      LyricLookupStatus.invalidData,
    );
  });

  test('found result retains lyrics and canceled result has no payload', () {
    const lyric = KugouLyric(content: '[00:00.00]歌词');
    final found = LyricLookupResult.found(lyric);
    const canceled = LyricLookupResult.canceled();

    expect(found.status, LyricLookupStatus.found);
    expect(found.isFound, isTrue);
    expect(found.lyric, same(lyric));
    expect(canceled.status, LyricLookupStatus.canceled);
    expect(canceled.lyric, isNull);
  });
}
