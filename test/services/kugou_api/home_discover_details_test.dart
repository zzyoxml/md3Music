import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpClientAdapter original;
  late _Adapter adapter;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final api = KugouApiClient();
    original = api.dio.httpClientAdapter;
    adapter = _Adapter();
    api.dio.httpClientAdapter = adapter;
    KugouApiClient.markServerReady(KugouApiClient.markServerStarting());
  });
  tearDown(() => KugouApiClient().dio.httpClientAdapter = original);

  test('刷歌按发行编号补齐歌手专辑 ID，保留原推荐内容与顺序', () async {
    final songs = (await KugouApiClient().getHomeDiscover(noCache: true))!;
    final first = songs.first.toSong();
    expect(first.albumId, '2530746');
    expect(first.artistId, '3063');
    expect(first.id, 'HASH_ONE');
    expect(first.title, '推荐标题');
    expect(first.artist, '推荐歌手');
    expect(first.albumAudioId, '63603775');
    expect(songs[1].artistId, '9002');
    expect(songs[1].albumId, '2002');
    expect(adapter.metadataRequests, 1);
    expect(adapter.ids, '63603775,222');
  });

  test('补全失败保留推荐和原专辑 ID，不重试不阻止播放', () async {
    adapter.fail = true;
    final songs = (await KugouApiClient().getHomeDiscover(noCache: true))!;
    expect(songs, hasLength(2));
    expect(songs.first.albumId, '2530746');
    expect(songs.first.hash, 'HASH_ONE');
    expect(songs.first.artistId, isNull);
    expect(adapter.metadataRequests, 1);
  });

  test('已有 ID 不覆盖，无发行编号不乱匹配也不额外请求', () async {
    adapter.complete = true;
    final songs = (await KugouApiClient().getHomeDiscover(noCache: true))!;
    expect(songs.first.albumId, '99');
    expect(songs.first.artistId, '88');
    expect(songs[1].artistId, isNull);
    expect(adapter.metadataRequests, 0);
  });
}

class _Adapter implements HttpClientAdapter {
  bool fail = false;
  bool complete = false;
  int metadataRequests = 0;
  String? ids;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    Object data = {};
    if (options.path == '/home/discover') {
      data = {
        'items': [
          {
            'song_info': {
              'hash': 'HASH_ONE',
              'songname': '推荐标题',
              'author_name': '推荐歌手',
              'ori_album_id': 2530746,
              'album_audio_id': 63603775,
              if (complete) 'album_id': '99',
              if (complete) 'artist_id': '88',
            },
          },
          {
            'song_info': {
              'hash': 'HASH_TWO',
              'songname': '同名歌',
              if (!complete) 'album_audio_id': 222,
            },
          },
        ],
      };
    } else if (options.path == '/krm/audio') {
      metadataRequests++;
      ids = options.queryParameters['album_audio_id']?.toString();
      expect(options.queryParameters['fields'], 'album_info,base,authors.base');
      if (fail) {
        return ResponseBody.fromString(
          '{"status":0}',
          500,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        );
      }
      data = [
        {
          'base': {'album_audio_id': 222, 'album_id': 2002},
          'authors': [
            {
              'base': {'author_id': 9002, 'author_name': '歌手二'},
            },
          ],
        },
        {
          'base': {'album_audio_id': 63603775, 'album_id': 9999},
          'authors': [
            {
              'base': {'author_id': 3063, 'author_name': '详情歌手'},
            },
          ],
        },
        {
          'base': {'album_audio_id': 555, 'album_id': 555},
          'authors': [
            {
              'base': {'author_id': 555},
            },
          ],
        },
      ];
    }
    return ResponseBody.fromString(
      jsonEncode({'status': 1, 'data': data}),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
