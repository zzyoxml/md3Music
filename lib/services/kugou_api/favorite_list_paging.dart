import 'dart:convert';

/// 完整拉取收藏列表：先合并原始分页，再交给 UI 区分歌单、专辑、歌手。
/// 后续页失败不能把截断结果当完整列表写入离线缓存。
Future<Map<String, dynamic>?> loadFavoritePages({
  required Future<Map<String, dynamic>?> Function(int page) fetch,
  required int pageSize,
  required List<String> listKeys,
  required String Function(Map<String, dynamic>) identity,
}) async {
  final items = <Map<String, dynamic>>[];
  final seen = <String>{};
  Map<String, dynamic>? first;
  for (var page = 1; page <= 1000; page++) {
    final result = await fetch(page);
    if (result == null) {
      if (first == null) return null;
      throw StateError('收藏分页请求失败，page=$page');
    }
    if (result['status'] != null && '${result['status']}' != '1') {
      throw StateError('收藏接口返回失败，page=$page');
    }
    first ??= result;
    final data = result['data'];
    List<dynamic>? batch = data is List ? data : null;
    if (data is Map) {
      for (final key in listKeys) {
        if (data[key] is List) {
          batch = data[key] as List;
          break;
        }
      }
    }
    if (batch == null) throw const FormatException('收藏响应缺少列表');
    final before = items.length;
    for (final row in batch) {
      if (row is! Map) throw const FormatException('收藏条目格式错误');
      final item = Map<String, dynamic>.from(row);
      final key = identity(item);
      if (seen.add(key.isEmpty ? jsonEncode(item) : key)) items.add(item);
    }
    final totalValue = (data is Map ? data['total'] ?? data['total_num'] : null)
        ?? result['total'];
    final parsedTotal = int.tryParse('$totalValue');
    final total = parsedTotal != null && parsedTotal > 0 ? parsedTotal : null;
    final moreValue = data is Map ? data['has_more'] ?? data['hasmore'] : null;
    bool? hasMore;
    if (moreValue == true || '$moreValue' == '1' || '$moreValue' == 'true') hasMore = true;
    if (moreValue == false || '$moreValue' == '0' || '$moreValue' == 'false') hasMore = false;
    final complete = total != null
        ? items.length >= total
        : hasMore != null ? !hasMore : batch.length != pageSize;
    if (complete) {
      final firstData = first['data'];
      final merged = firstData is Map
          ? Map<String, dynamic>.from(firstData)
          : <String, dynamic>{};
      merged[listKeys.first] = items;
      return {...first, 'data': merged};
    }
    // 防止上游忽略 page 或重复回包造成无限请求、重复收藏、错误覆盖缓存。
    if (batch.isEmpty || items.length == before) {
      throw StateError('收藏分页没有前进，page=$page，loaded=${items.length}，total=$total');
    }
  }
  throw StateError('收藏分页超过安全上限');
}
