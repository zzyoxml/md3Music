import 'kugou_models.dart';

/// 歌词查询结果分类。只有确认接口成功返回“没有候选”时才使用 notFound。
enum LyricLookupStatus {
  found,
  notFound,
  transientFailure,
  invalidData,
  canceled,
}

class LyricLookupResult {
  final LyricLookupStatus status;
  final KugouLyric? lyric;

  const LyricLookupResult._(this.status, this.lyric);

  const LyricLookupResult.found(KugouLyric lyric)
    : this._(LyricLookupStatus.found, lyric);

  const LyricLookupResult.notFound() : this._(LyricLookupStatus.notFound, null);

  const LyricLookupResult.transientFailure()
    : this._(LyricLookupStatus.transientFailure, null);

  const LyricLookupResult.invalidData()
    : this._(LyricLookupStatus.invalidData, null);

  const LyricLookupResult.canceled() : this._(LyricLookupStatus.canceled, null);

  factory LyricLookupResult.noMatch({
    bool sawTransientFailure = false,
    bool sawInvalidData = false,
  }) {
    if (sawTransientFailure) return const LyricLookupResult.transientFailure();
    if (sawInvalidData) return const LyricLookupResult.invalidData();
    return const LyricLookupResult.notFound();
  }

  bool get isFound => status == LyricLookupStatus.found && lyric != null;
}
