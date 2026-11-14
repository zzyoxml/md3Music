import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/services/kugou_api/favorite_list_paging.dart';

void main() {
  Map<String, dynamic> response(List<int> ids, {int? total, String key = 'info'}) => {
    'status': 1,
    'data': {if (total != null) 'total': '$total', key: [for (final id in ids) {'id': id}]},
  };

  Future<Map<String, dynamic>?> load(Future<Map<String, dynamic>?> Function(int) fetch,
      {List<String> keys = const ['info', 'list']}) => loadFavoritePages(
    fetch: fetch, pageSize: 30, listKeys: keys, identity: (row) => '${row['id']}',
  );

  test('服务端限制单页大小时按 total 拉完，不能因短页漏掉后面的收藏', () async {
    final requested = <int>[];
    final result = await load((page) async {
      requested.add(page);
      return response(page == 1 ? [1, 2] : page == 2 ? [3, 4] : [5], total: 5);
    });
    expect(requested, [1, 2, 3]);
    expect((result!['data']['info'] as List).length, 5);
  });

  test('关注歌手兼容 lists 字段并拉取下一页', () async {
    final result = await load((page) async => response([page], total: 2, key: 'lists'),
        keys: const ['lists', 'info', 'list', 'fans']);
    expect((result!['data']['lists'] as List).length, 2);
  });

  test('跨页重复记录去重', () async {
    final result = await load((page) async => response(page == 1 ? [1, 2] : [2, 3], total: 3));
    expect((result!['data']['info'] as List).map((e) => e['id']), [1, 2, 3]);
  });

  test('后续页网络失败不能把半份列表当完整成功', () async {
    await expectLater(load((page) async => page == 1 ? response([1], total: 2) : null),
        throwsStateError);
  });

  test('上游忽略 page 时有限终止，不无限请求或重复追加', () async {
    var requests = 0;
    await expectLater(load((page) async {
      requests++;
      return response([1], total: 2);
    }), throwsStateError);
    expect(requests, 2);
  });

  test('合法空列表可替换旧收藏', () async {
    final result = await load((_) async => response([], total: 0));
    expect(result!['data']['info'], isEmpty);
  });

  test('total=0 只是未提供总数时不能截断满页', () async {
    final requested = <int>[];
    final result = await load((page) async {
      requested.add(page);
      return response(page == 1 ? List.generate(30, (i) => i) : [30], total: 0);
    });
    expect(requested, [1, 2]);
    expect((result!['data']['info'] as List).length, 31);
  });

  test('短页显式标记 has_more 时继续拉取', () async {
    final result = await load((page) async => {
      'data': {'has_more': page == 1, 'info': [{'id': page}]},
    });
    expect((result!['data']['info'] as List).length, 2);
  });

  test('满页显式标记 has_more=false 时不请求不存在的下一页', () async {
    var requests = 0;
    final result = await load((_) async {
      requests++;
      return {'data': {'has_more': false, 'info': [for (var i = 0; i < 30; i++) {'id': i}]}};
    });
    expect(requests, 1);
    expect((result!['data']['info'] as List).length, 30);
  });

  test('第一页离线返回 null，响应结构错误则失败而非清空缓存', () async {
    expect(await load((_) async => null), isNull);
    await expectLater(load((_) async => {'status': 1, 'data': {}}), throwsFormatException);
  });
}
