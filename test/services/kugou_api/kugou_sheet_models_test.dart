import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';

/// 曲谱模型解析测试：键名按 2026-10-24 实测响应截样（tmp/sheet_song_68435136.txt、
/// tmp/sheet_tags.txt、tmp/sheet_explore.txt），与上游 opern 服务真实字段对齐。
void main() {
  test('KugouSheetInfo 解析 /sheet/song 列表项（AI弹唱谱，musicxml）', () {
    final item = KugouSheetInfo.fromJson({
      'opern_id': '68435136_7_335924',
      'mixsongid': 68435136,
      'jump_url':
          'https://h5.kugou.com/voo/v-73bc3efd/xml.html?isHideTitleBar=1&mixsongid=68435136&opernid=68435136_7_335924',
      'original_tune': 'D',
      'instruments': 1,
      'opern_level': 2,
      'opern_name': 'AI弹唱谱',
      'opern_author': '',
      'opern_type_name': 'AI弹唱谱',
      'opern_draw_type_name': '六线谱/和弦谱',
      'status': 1,
    });
    expect(item.opernId, '68435136_7_335924');
    expect(item.jumpUrl, contains('xml.html'));
    expect(item.instruments, 1);
    expect(item.opernLevel, 2);
    expect(item.opernTypeName, 'AI弹唱谱');
    expect(item.opernDrawTypeName, '六线谱/和弦谱');
    expect(item.originalTune, 'D');
    // opern_author 为空串 → 语义上是"无作者"
    expect(item.opernAuthor, '');
  });

  test('KugouSheetInfo 解析 explore 列表项（人工谱，PDF）', () {
    final item = KugouSheetInfo.fromJson({
      'opern_id': '255787453_3_852',
      'mixsongid': 255787453,
      'jump_url':
          'https://h5.kugou.com/voo/v-73bc3efd/opern.html?opernid=255787453_3_852',
      'original_tune': 'C',
      'instruments': 1,
      'opern_level': 0,
      'opern_name': '弹唱谱',
      'opern_author': '南风古灶',
      'opern_type_name': '弹唱谱',
      'opern_draw_type_name': '和弦谱',
    });
    expect(item.opernId, '255787453_3_852');
    expect(item.opernAuthor, '南风古灶');
    expect(item.opernTypeName, '弹唱谱');
    expect(item.originalTune, 'C');
  });

  test('KugouSheetInfo 解析外层歌曲壳的歌名/歌手（2026-10-24 explore 实测键）', () {
    final shell = KugouSheetInfo.fromJson({
      'mixsongid': 255787453,
      'song_name': '专属味道',
      'song_cover': 'http://imge.kugou.com/stdmusic/{size}/x.jpg',
      'singer_name': '汪苏泷、林希儿',
      'opern_nums': 2,
    });
    expect(shell.songName, '专属味道');
    expect(shell.singerName, '汪苏泷、林希儿');
    expect(shell.coverUrl, isNotNull);
  });

  test('KugouSheetInfo 内层谱目无歌名时 songName/singerName 为 null', () {
    final item = KugouSheetInfo.fromJson({
      'opern_id': '255787453_7_346448',
      'instruments': 1,
      'opern_level': 2,
      'opern_name': 'AI弹唱谱',
    });
    expect(item.songName, isNull);
    expect(item.singerName, isNull);
    expect(item.opernTypeName, 'AI弹唱谱');
  });

  test('KugouSheetInfo 旧键兜底与缺失字段防御', () {
    final item = KugouSheetInfo.fromJson({
      'id': 'legacy-id',
      'name': 'legacy-name',
      'cover': 'http://imge.kugou.com/stdmusic/{size}/x.jpg',
      'songcount': 3,
    });
    expect(item.id, 'legacy-id');
    expect(item.name, 'legacy-name');
    expect(item.coverUrl, isNotNull);
    expect(item.songCount, 3);
    // opern 字段缺失 → 默认值，不抛
    expect(item.opernId, '');
    expect(item.jumpUrl, isNull);
    expect(item.instruments, 0);
    expect(item.opernLevel, 0);
    expect(item.opernTypeName, isNull);
  });

  test('KugouSheetTag 解析 tagid/tagname（实测键名）', () {
    final tag = KugouSheetTag.fromJson({'tagid': 87898, 'tagname': '国语流行'});
    expect(tag.id, '87898');
    expect(tag.name, '国语流行');
  });

  test('KugouSheetTag 兜底键与类型转换', () {
    final tag = KugouSheetTag.fromJson({'id': '1', 'name': '民谣'});
    expect(tag.id, '1');
    expect(tag.name, '民谣');
    // 数字 id 转 string
    final tag2 = KugouSheetTag.fromJson({'id': 2, 'name': '摇滚'});
    expect(tag2.id, '2');
  });
}
