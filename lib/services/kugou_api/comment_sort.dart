import 'kugou_models.dart';

/// 评论排序方式。
enum CommentSortMode {
  /// 最热：按点赞数降序（歌曲评论有原生 topliked 接口时优先用接口）。
  hottest,

  /// 时间降序：最新的在前。
  timeDesc,

  /// 时间升序：最早的在前。
  timeAsc,
}

/// 按排序方式对评论做**客户端**排序，返回新列表（不修改入参）。
///
/// - [CommentSortMode.hottest]：点赞数降序，同赞数保持接口返回的相对顺序
///   （`List.sort` 不稳定，用原始下标做次级比较键固定顺序）；
/// - [CommentSortMode.timeDesc] / [CommentSortMode.timeAsc]：按发布时间排。
///
/// 说明：歌单/专辑的 cmtlist 上游是加权混排、歌曲的 cmtlist 与点赞无关，
/// 所以时间/点赞排序都在客户端对**已加载**的评论做；翻页追加后排序仍全局成立。
List<KugouComment> sortCommentsForDisplay(
  List<KugouComment> comments,
  CommentSortMode mode,
) {
  final indexed = <(int, KugouComment)>[
    for (var i = 0; i < comments.length; i++) (i, comments[i]),
  ];
  int cmp(int a, int b) => a.compareTo(b);

  switch (mode) {
    case CommentSortMode.hottest:
      indexed.sort((x, y) {
        final byLikes = y.$2.likes.compareTo(x.$2.likes);
        return byLikes != 0 ? byLikes : cmp(x.$1, y.$1);
      });
    case CommentSortMode.timeDesc:
      indexed.sort((x, y) {
        final byTime = y.$2.time.compareTo(x.$2.time);
        return byTime != 0 ? byTime : cmp(x.$1, y.$1);
      });
    case CommentSortMode.timeAsc:
      indexed.sort((x, y) {
        final byTime = x.$2.time.compareTo(y.$2.time);
        return byTime != 0 ? byTime : cmp(x.$1, y.$1);
      });
  }
  return [for (final e in indexed) e.$2];
}
