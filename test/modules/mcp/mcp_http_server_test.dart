import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/mcp/mcp_http_server.dart';
import 'package:md3music/modules/mcp/mcp_jsonrpc.dart';
import 'package:md3music/modules/mcp/mcp_tool.dart';

McpDispatcher _dispatcher() {
  final registry = McpToolRegistry(<McpTool>[
    McpTool(
      name: 'md3_ping_tool',
      description: 'ping',
      inputSchema: <String, Object?>{'type': 'object', 'properties': <String, Object?>{}},
      handler: (_) async => const McpToolResult.text('pong'),
    ),
  ]);
  return McpDispatcher(
    serverName: 'MD3MusicTest',
    serverVersion: '0.0.1',
    tools: registry,
  );
}

Future<HttpClientResponse> _post(
  HttpClient client,
  Uri uri, {
  required String body,
  String? token,
  String accept = 'application/json, text/event-stream',
}) async {
  final req = await client.postUrl(uri);
  req.headers.contentType = ContentType.json;
  req.headers.set('Accept', accept);
  if (token != null) req.headers.set('Authorization', 'Bearer $token');
  req.write(body);
  return req.close();
}

/// 错误分支也必须回 JSON-RPC 信封，否则严格校验的客户端会静默丢弃。
Future<Map<String, Object?>> _errorEnvelope(HttpClientResponse res) async {
  final body = jsonDecode(await res.transform(utf8.decoder).join()) as Map;
  expect(body['jsonrpc'], '2.0');
  expect(body['error'], isA<Map>());
  expect((body['error']! as Map)['code'], -32000);
  return Map<String, Object?>.from(body);
}

void main() {
  late McpHttpServer server;
  late HttpClient client;
  late Uri uri;

  setUp(() async {
    server = McpHttpServer();
    final port = await server.start(
      dispatcher: _dispatcher(),
      preferredPort: 0,
      bindLan: false,
      token: 'tok',
      requireAuth: false,
    );
    client = HttpClient();
    uri = Uri.parse('http://127.0.0.1:$port/mcp');
  });

  tearDown(() async {
    client.close();
    await server.stop();
  });

  test('initialize 走完整 HTTP 往返并带协议头', () async {
    final res = await _post(client, uri, body: jsonEncode(<String, Object?>{
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': <String, Object?>{'protocolVersion': '2025-06-18'},
    }));
    expect(res.statusCode, 200);
    expect(res.headers.value('mcp-protocol-version'), '2025-06-18');
    final body = jsonDecode(await res.transform(utf8.decoder).join()) as Map;
    expect((body['result'] as Map)['serverInfo'], isNotNull);
  });

  test('通知返回 202 空包', () async {
    final res = await _post(client, uri, body: jsonEncode(<String, Object?>{
      'jsonrpc': '2.0',
      'method': 'notifications/initialized',
    }));
    expect(res.statusCode, 202);
    expect(await res.transform(utf8.decoder).join(), isEmpty);
  });

  test('Accept 不含受支持类型时返回 406', () async {
    final res = await _post(client, uri, accept: 'text/html',
        body: jsonEncode(<String, Object?>{'jsonrpc': '2.0', 'id': 1, 'method': 'ping'}));
    expect(res.statusCode, 406);
    await _errorEnvelope(res);
  });

  test('无会话 id 的 GET /mcp 返回 400', () async {
    final req = await client.getUrl(uri);
    req.headers.set('Accept', 'application/json, text/event-stream');
    final res = await req.close();
    expect(res.statusCode, 400);
  });

  test('DELETE /mcp 返回 204', () async {
    final req = await client.deleteUrl(uri);
    final res = await req.close();
    expect(res.statusCode, 204);
  });

  test('OPTIONS /mcp 返回 204 并带 CORS 头', () async {
    final req = await client.openUrl('OPTIONS', uri);
    req.headers.set('Origin', 'http://localhost:5173');
    final res = await req.close();
    expect(res.statusCode, 204);
    expect(res.headers.value('access-control-allow-origin'), 'http://localhost:5173');
    expect(res.headers.value('access-control-allow-methods'), contains('POST'));
  });

  test('未知路径返回 404', () async {
    final res = await _post(client, Uri.parse('http://127.0.0.1:${uri.port}/mcp/other'),
        body: '{}');
    expect(res.statusCode, 404);
    await _errorEnvelope(res);
  });

  test('强制鉴权时缺失 token 返回 401', () async {
    await server.stop();
    final port = await server.start(
      dispatcher: _dispatcher(),
      preferredPort: 0,
      bindLan: true,
      token: 'tok',
      requireAuth: true,
    );
    final authed = Uri.parse('http://127.0.0.1:$port/mcp');
    final noToken = await _post(client, authed,
        body: jsonEncode(<String, Object?>{'jsonrpc': '2.0', 'id': 1, 'method': 'ping'}));
    expect(noToken.statusCode, 401);
    expect(noToken.headers.value('www-authenticate'), contains('Bearer'));
    await _errorEnvelope(noToken);

    final withToken = await _post(client, authed, token: 'tok',
        body: jsonEncode(<String, Object?>{'jsonrpc': '2.0', 'id': 1, 'method': 'ping'}));
    expect(withToken.statusCode, 200);
  });
}
