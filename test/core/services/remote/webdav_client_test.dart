import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/remote/remote_storage_config.dart';
import 'package:md3music/core/services/remote/webdav_client.dart';

void main() {
  const cfg = RemoteStorageConfig(
    id: 'cfg1',
    name: 'NAS',
    type: RemoteStorageType.webdav,
    host: '127.0.0.1',
    port: 5005,
    username: 'user',
    password: 'pass',
    rootPath: '/music',
  );

  test('ping 成功（207 响应）', () async {
    final client = WebDavClient(cfg)..adapter = _adapter(207, '');
    expect(await client.ping(), isTrue);
  });

  test('ping 成功（200 响应）', () async {
    final client = WebDavClient(cfg)..adapter = _adapter(200, '');
    expect(await client.ping(), isTrue);
  });

  test('ping 失败（404 响应）', () async {
    final client = WebDavClient(cfg)..adapter = _adapter(404, '');
    expect(await client.ping(), isFalse);
  });

  test('Basic 鉴权头正确（base64(user:pass)）', () async {
    String? authHeader;
    final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:5005'))
      ..httpClientAdapter = _CapturingAdapter((opts) {
        authHeader = opts.headers['Authorization'] as String?;
        return _resp(207, '');
      });
    final client = WebDavClient(cfg)..dio = dio;
    await client.ping();

    final expected = 'Basic ${base64Encode(utf8.encode('user:pass'))}';
    expect(authHeader, expected);
  });

  test('list 解析 PROPFIND：目录/文件/大小/中文解码/排除自身', () async {
    // 带 DAV: 命名空间前缀的响应（常见服务器）
    const xml = '''
<?xml version="1.0"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>http://127.0.0.1:5005/music/</D:href>
    <D:propstat>
      <D:prop>
        <D:resourcetype><D:collection/></D:resourcetype>
        <D:displayname>music</D:displayname>
      </D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>
  <D:response>
    <D:href>http://127.0.0.1:5005/music/sub/</D:href>
    <D:propstat>
      <D:prop>
        <D:resourcetype><D:collection/></D:resourcetype>
        <D:displayname>sub</D:displayname>
      </D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>
  <D:response>
    <D:href>http://127.0.0.1:5005/music/song.mp3</D:href>
    <D:propstat>
      <D:prop>
        <D:getcontentlength>10240</D:getcontentlength>
        <D:displayname>song.mp3</D:displayname>
      </D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>
  <D:response>
    <D:href>http://127.0.0.1:5005/music/cover.jpg</D:href>
    <D:propstat>
      <D:prop><D:displayname>cover.jpg</D:displayname></D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>
  <D:response>
    <D:href>http://127.0.0.1:5005/music/%E6%AD%8C%E6%9B%B2.mp3</D:href>
    <D:propstat>
      <D:prop><D:getcontentlength>2048</D:getcontentlength></D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>
</D:multistatus>''';
    final client = WebDavClient(cfg)..adapter = _adapter(207, xml);

    final entries = await client.list('/music');
    // 目录自身（/music/）被排除
    expect(entries, hasLength(4));

    final sub = entries.firstWhere((e) => e.name == 'sub');
    expect(sub.isDirectory, isTrue);
    expect(sub.path, '/music/sub');

    final song = entries.firstWhere((e) => e.name == 'song.mp3');
    expect(song.isDirectory, isFalse);
    expect(song.size, 10240);
    expect(song.path, '/music/song.mp3');

    final cover = entries.firstWhere((e) => e.name == 'cover.jpg');
    expect(cover.path, '/music/cover.jpg');

    // 中文/百分号编码需解码
    final chinese = entries.firstWhere((e) => e.name == '歌曲.mp3');
    expect(chinese.path, '/music/歌曲.mp3');
    expect(chinese.size, 2048);
  });

  test('list 容错：无命名空间的响应也能解析', () async {
    const xml = '''
<?xml version="1.0"?>
<multistatus>
  <response>
    <href>/music/</href>
    <propstat><prop><resourcetype><collection/></resourcetype></prop></propstat>
  </response>
  <response>
    <href>/music/a.flac</href>
    <propstat><prop><getcontentlength>4096</getcontentlength></prop></propstat>
  </response>
</multistatus>''';
    final client = WebDavClient(cfg)..adapter = _adapter(207, xml);

    final entries = await client.list('/music');
    expect(entries, hasLength(1));
    expect(entries.first.name, 'a.flac');
    expect(entries.first.size, 4096);
    expect(entries.first.isDirectory, isFalse);
  });

  test('list 请求带 Depth:1、method 为 PROPFIND、目标为目录 URL', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:5005'))
      ..httpClientAdapter = _CapturingAdapter((opts) {
        expect(opts.path, '/music/');
        expect(opts.headers['Depth'], '1');
        expect(opts.method, 'PROPFIND');
        return _resp(207, '');
      });
    final client = WebDavClient(cfg)..dio = dio;
    await client.list('/music');
  });
}

// ---- 测试辅助：可控 Dio adapter ----

class _CapturingAdapter implements HttpClientAdapter {
  final Response<dynamic> Function(RequestOptions) handler;
  _CapturingAdapter(this.handler);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final r = handler(options);
    return ResponseBody.fromString(
      r.data?.toString() ?? '',
      r.statusCode ?? 200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Response<dynamic> _resp(int code, String body) => Response(
      requestOptions: RequestOptions(path: ''),
      statusCode: code,
      data: body,
    );

HttpClientAdapter _adapter(int code, String body) {
  final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:5005'))
    ..httpClientAdapter = _CapturingAdapter((_) => _resp(code, body));
  return dio.httpClientAdapter;
}