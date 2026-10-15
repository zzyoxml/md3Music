// 钉住私人 FM 的反馈契约：cur_mark 回带 + 反馈请求必须免缓存。
//
// 为什么必须钉：上游 /v2/personal_recommend 的 action 回报靠 cur_mark 定位「这一条推荐」，
// 而它在批次响应里藏在 rec_song_info 内；一旦丢字段，红心/垃圾桶/播放完成全部静默失效
// （历史回归：KugouProvider._fillPersonalFmAlbumNames 用 copyWith 重建详情时把 curMark 丢了）。
// 另一半契约在本地服务端：Rust 的 apicache 按 URL 缓存成功响应 120s
// （kugou_api_server/rust/src/server.rs），[_onRequest] 只有在 extra['noCache'] 为真时才保留
// x-apicache-bypass 头并追加 t= 戳，否则同参数的反馈会被缓存原样回放、根本到不了上游。
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/services/kugou_api/kugou_endpoints.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../test_helpers/fake_secure_storage.dart';

/// 私人 FM 批次里的一首歌（上游形态：反馈令牌藏在 rec_song_info 内）
const _fmCurMark = '1728460123_3_20240917';
const _fmSongJson = <String, dynamic>{
  'hash': 'HASH_FM_1',
  'songname': '私人FM歌曲一',
  'duration': 210,
  'rec_song_info': <String, dynamic>{
    'cur_mark': _fmCurMark,
    'rec_desc': '根据你的口味推荐',
  },
};

/// 造一份「data 里挂 listKey 数组」的批次响应体
String _fmBody(
  String listKey, [
  List<Map<String, dynamic>> songs = const [_fmSongJson],
]) {
  return jsonEncode({
    'status': 1,
    'error_code': 0,
    'data': {listKey: songs},
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late KugouApiClient client;
  late HttpClientAdapter originalAdapter;
  late String originalBaseUrl;
  final captured = <RequestOptions>[];
  late _RecordingFmAdapter adapter;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    KugouApiClient.markServerReady();
    client = KugouApiClient();
    await client.clearCookies();
    captured.clear();
    // KugouApiClient 是私有单例，无法注入 mock，按仓内既有手法整体替换
    // dio.httpClientAdapter（见 test/services/kugou_api/top_song_query_test.dart），
    // 并在 tearDown 里还原，防污染其他测试。
    originalAdapter = client.dio.httpClientAdapter;
    adapter = _RecordingFmAdapter(captured);
    client.dio.httpClientAdapter = adapter;
    originalBaseUrl = KugouEndpoints.baseUrl;
    client.updateBaseUrl('http://personal-fm-feedback-fixture.invalid');
  });

  tearDown(() {
    client.dio.httpClientAdapter = originalAdapter;
    client.updateBaseUrl(originalBaseUrl);
    uninstallFakeSecureStorage();
  });

  group('KugouSongDetail 私人 FM 反馈令牌解析', () {
    test('cur_mark 藏在 rec_song_info 里时也能取出', () {
      final detail = KugouSongDetail.fromJson(_fmSongJson);

      expect(detail.curMark, _fmCurMark);
      expect(detail.hash, 'HASH_FM_1');
    });

    test('cur_mark 平铺在顶层时直接命中', () {
      final detail = KugouSongDetail.fromJson({
        'hash': 'HASH_FLAT',
        'songname': '平铺歌曲',
        'cur_mark': 'CUR_FLAT',
      });

      expect(detail.curMark, 'CUR_FLAT');
    });

    test('驼峰写法 curMark 同样识别', () {
      final detail = KugouSongDetail.fromJson({
        'hash': 'HASH_CAMEL',
        'songname': '驼峰歌曲',
        'curMark': 'CUR_CAMEL',
      });

      expect(detail.curMark, 'CUR_CAMEL');
    });

    test('整型 cur_mark 归一化为字符串形式', () {
      // 上游历史上给过纯数字令牌；回报时必须是字符串，不能带类型
      final detail = KugouSongDetail.fromJson({
        'hash': 'HASH_INT',
        'songname': '整型令牌歌曲',
        'cur_mark': 1728460123,
      });

      expect(detail.curMark, '1728460123');
    });

    test('空串 cur_mark 视为无令牌', () {
      final detail = KugouSongDetail.fromJson({
        'hash': 'HASH_EMPTY',
        'songname': '无令牌歌曲',
        'cur_mark': '',
      });

      // 空串回报上游只会得到参数错误，必须归一化成 null
      expect(detail.curMark, isNull);
    });

    test('顶层 cur_mark 优先于 rec_song_info 里的同名值', () {
      final detail = KugouSongDetail.fromJson({
        'hash': 'HASH_WIN',
        'songname': '顶层优先',
        'rec_song_info': <String, dynamic>{'cur_mark': 'CUR_NESTED'},
        'cur_mark': 'CUR_TOP',
      });

      expect(detail.curMark, 'CUR_TOP');
    });

    test('copyWith 只补专辑名时保留 cur_mark', () {
      // 核心回归点：富化专辑名会整对象重建，丢了令牌就等于废掉后续反馈
      final detail = KugouSongDetail.fromJson(_fmSongJson);
      final patched = detail.copyWith(albumName: '补全后的专辑');

      expect(patched.albumName, '补全后的专辑');
      expect(patched.curMark, _fmCurMark);
      expect(patched.hash, detail.hash);
    });

    test('copyWith 显式传入 curMark 时覆盖原值', () {
      final detail = KugouSongDetail.fromJson(_fmSongJson);
      final patched = detail.copyWith(curMark: 'CUR_REPLACED');

      expect(patched.curMark, 'CUR_REPLACED');
    });
  });

  group('getPersonalFm 反馈参数下发', () {
    test('请求命中 /personal/fm 路径', () async {
      await client.getPersonalFm(hash: 'HASH_A');

      expect(captured, hasLength(1));
      expect(captured.single.path, KugouEndpoints.personalFm);
      expect(KugouEndpoints.personalFm, '/personal/fm');
    });

    test('反馈参数齐发时 action/cur_mark/hash/songid/playtime/is_overplay 原样进 query', () async {
      await client.getPersonalFm(
        mode: 'song',
        songPoolId: 14400,
        hash: 'HASH_A',
        songId: '999',
        action: 'click_red',
        curMark: 'CUR_MARK_A',
        playtime: 87,
        isOverplay: true,
      );

      final q = captured.single.queryParameters;
      expect(q['action'], 'click_red');
      expect(q['cur_mark'], 'CUR_MARK_A');
      expect(q['hash'], 'HASH_A');
      expect(q['songid'], '999');
      expect(q['playtime'], '87');
      expect(q['is_overplay'], '1');
      expect(q['mode'], 'song');
      expect(q['song_pool_id'], '14400');
    });

    test('is_overplay 为 false 时上报字符串 0 而不是省略', () async {
      await client.getPersonalFm(
        hash: 'HASH_A',
        action: 'play_finished',
        isOverplay: false,
      );

      expect(captured.single.queryParameters['is_overplay'], '0');
    });

    test('未提供的反馈参数整个键都不出现在 query 里', () async {
      // 空串/占位值会让上游按「有反馈」处理，必须完全不下发
      await client.getPersonalFm(hash: 'HASH_A');

      final q = captured.single.queryParameters;
      expect(q.containsKey('cur_mark'), isFalse);
      expect(q.containsKey('playtime'), isFalse);
      expect(q.containsKey('is_overplay'), isFalse);
      expect(q.containsKey('action'), isFalse);
      expect(q.containsKey('mode'), isFalse);
      expect(q.containsKey('song_pool_id'), isFalse);
    });

    test('默认拉取走服务端缓存：既无旁路头也无 t= 戳', () async {
      await client.getPersonalFm(hash: 'HASH_A');

      final options = captured.single;
      expect(options.extra['noCache'], isFalse);
      expect(options.headers.containsKey('x-apicache-bypass'), isFalse);
      expect(options.queryParameters.containsKey('t'), isFalse);
    });

    test('批次响应按 data.song_list 解析且 cur_mark 随映射保留', () async {
      final songs = await client.getPersonalFm(
        action: 'garbage',
        curMark: _fmCurMark,
      );

      expect(songs, isNotNull);
      expect(songs, hasLength(1));
      expect(songs!.single.hash, 'HASH_FM_1');
      expect(songs.single.curMark, _fmCurMark);
    });

    test('song_list 缺失时依次回退 songs / list / info', () async {
      for (final key in const ['songs', 'list', 'info']) {
        captured.clear();
        adapter.body = _fmBody(key);

        final songs = await client.getPersonalFm();
        expect(songs, hasLength(1), reason: '回退键 $key 应能解析出批次');
        expect(songs!.single.curMark, _fmCurMark, reason: '回退键 $key 应保留令牌');
      }
    });

    test('响应体形态异常时返回 null 而不是抛异常', () async {
      // 反馈是后台 ping，解析崩了不能把调用方整页顶成错误态
      adapter.body = jsonEncode({
        'status': 1,
        'data': {'song_list': '不是数组'},
      });

      expect(await client.getPersonalFm(action: 'click_red'), isNull);
    });
  });

  group('reportPersonalFmAction 强制免缓存', () {
    test('反馈请求必带 x-apicache-bypass 头与 t= 时间戳', () async {
      await client.reportPersonalFmAction(
        action: 'click_red',
        hash: 'HASH_A',
        curMark: 'CUR_MARK_A',
      );

      final options = captured.single;
      expect(options.extra['noCache'], isTrue);
      expect(options.headers['x-apicache-bypass'], '1');
      // t= 戳防的是「cache 命中时跳过参数比对」那条路径，缺了就会被回放
      expect(options.queryParameters['t'], isA<int>());
    });

    test('反馈参数与 getPersonalFm 同一套装配口径', () async {
      await client.reportPersonalFmAction(
        action: 'play_finished',
        mode: 'song',
        songPoolId: 14400,
        hash: 'HASH_A',
        songId: '999',
        curMark: 'CUR_MARK_A',
        playtime: 120,
        isOverplay: true,
      );

      expect(captured, hasLength(1));
      final q = captured.single.queryParameters;
      expect(q['action'], 'play_finished');
      expect(q['cur_mark'], 'CUR_MARK_A');
      expect(q['hash'], 'HASH_A');
      expect(q['songid'], '999');
      expect(q['playtime'], '120');
      expect(q['is_overplay'], '1');
      expect(q['mode'], 'song');
      expect(q['song_pool_id'], '14400');
    });

    test('is_overplay 缺省按未播完上报 0', () async {
      // 与 getPersonalFm 的「null 即省略」不同：反馈语义下未播完是确定事实
      await client.reportPersonalFmAction(action: 'click_red', hash: 'HASH_A');

      expect(captured.single.queryParameters['is_overplay'], '0');
    });

    test('垃圾桶回报透传服务端给的替换批次', () async {
      adapter.body = _fmBody(
        'song_list',
        const [
          <String, dynamic>{
            'hash': 'HASH_FM_2',
            'songname': '私人FM歌曲二',
            'rec_song_info': <String, dynamic>{'cur_mark': 'CUR_MARK_2'},
          },
        ],
      );

      final songs = await client.reportPersonalFmAction(
        action: 'garbage',
        hash: 'HASH_FM_1',
        curMark: _fmCurMark,
      );

      expect(songs, isNotNull);
      expect(songs!.single.hash, 'HASH_FM_2');
      expect(songs.single.curMark, 'CUR_MARK_2');
    });
  });
}

/// 记录型假适配器：存下每次 fetch 的 RequestOptions，默认回一条私人 FM 批次
/// （令牌藏在 rec_song_info 里，与上游形态一致）。statusCode / body 可按用例改写。
class _RecordingFmAdapter implements HttpClientAdapter {
  _RecordingFmAdapter(this.captured);

  final List<RequestOptions> captured;

  int statusCode = 200;

  String body = _fmBody('song_list');

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    captured.add(options);
    return ResponseBody.fromString(body, statusCode, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}
