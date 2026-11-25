import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/data/repositories/favorite_lists_cache.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const collected = <String, dynamic>{
    'type': 1,
    'source': 2,
    'name': 'On an Island',
    'global_collection_id': 'collection_3_10086_45_0',
    'listid': 45,
    'musiclib_id': 623455,
    'list_create_listid': 623455,
  };

  test('收藏编号与专辑编号不同时使用具体专辑编号', () {
    final album = KugouPlaylistBrief.fromJson({
      ...collected,
      'specialid': 45,
      'albumid': 208239317,
    });
    expect(album.numericId, '623455');
    expect(album.toPlaylist().subscribedListId, '45');
  });

  test('缺少 musiclib_id 时读取原始专辑编号', () {
    final json = {...collected}..remove('musiclib_id');
    expect(KugouPlaylistBrief.fromJson(json).numericId, '623455');
  });

  test('缓存中的收藏编号不能覆盖专辑编号', () {
    final album = KugouPlaylistBrief.fromJson(
      {...collected, 'specialid': 'collection_3_10086_45_0', 'albumid': 623455}
        ..remove('musiclib_id'),
    );
    expect(album.numericId, '623455');
  });

  test('同歌手同名专辑的不同发行版本经过缓存仍保留各自编号', () async {
    SharedPreferences.setMockInitialValues({});
    final version = {
      ...collected,
      'name': 'A Live Record',
      'list_create_userid': 1001,
      'musiclib_id': 698345,
      'list_create_listid': 698345,
    };
    final albums = [
      KugouPlaylistBrief.fromJson(version),
      KugouPlaylistBrief.fromJson({
        ...version,
        'listid': 46,
        'global_collection_id': 'collection_3_10086_46_0',
        'musiclib_id': 48176730,
        'list_create_listid': 48176730,
      }),
    ];
    await FavoriteListsCache.saveAlbums(albums);
    final cached = await FavoriteListsCache.readAlbums();
    expect(cached.map((album) => album.numericId), ['698345', '48176730']);
  });

  test('普通歌单仍使用 specialid，不能将创建者的 listid 当作专辑编号', () {
    final playlist = KugouPlaylistBrief.fromJson({
      ...collected,
      'source': 1,
      'specialid': 777,
    });
    expect(playlist.numericId, '777');
  });
}
