import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/mcp/mcp_http_server.dart';
import 'package:md3music/modules/mcp/mcp_jsonrpc.dart';
import 'package:md3music/modules/mcp/mcp_tool.dart';

Future<Map<String, dynamic>> _post(
  HttpClient client,
  int port,
  Map<String, dynamic> body, {
  String? session,
}) async {
  final req = await client.postUrl(Uri.parse('http://127.0.0.1:$port/mcp'));
  req.headers.contentType = ContentType.json;
  req.headers.set('Accept', 'application/json, text/event-stream');
  if (session != null) req.headers.set('Mcp-Session-Id', session);
  req.add(utf8.encode(jsonEncode(body)));
  final res = await req.close();
  final text = await res.transform(utf8.decoder).join();
  return <String, dynamic>{
    'status': res.statusCode,
    'session': res.headers.value('mcp-session-id'),
    'body': text.isEmpty ? null : jsonDecode(text),
  };
}

void main() {
  test('initialize 下发会话 id；SSE 流收到 tools/list_changed', () async {
    final server = McpHttpServer();
    final dispatcher = McpDispatcher(
      serverName: 'MD3Music',
      serverVersion: 'test',
      tools: McpToolRegistry(const []),
      resources: const [],
      prompts: const [],
    );
    final port = await server.start(
      dispatcher: dispatcher,
      preferredPort: 0,
      bindLan: false,
      token: '',
      requireAuth: false,
    );

    final client = HttpClient();
    final init = await _post(client, port, <String, dynamic>{
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': {
        'protocolVersion': '2025-06-18',
        'capabilities': {},
        'clientInfo': {'name': 't', 'version': '0'},
      },
    });
    final session = init['session'] as String?;
    expect(session, isNotNull);

    // 打开 SSE 下行
    final sseReq =
        await client.getUrl(Uri.parse('http://127.0.0.1:$port/mcp'));
    sseReq.headers.set('Accept', 'text/event-stream');
    sseReq.headers.set('Mcp-Session-Id', session!);
    final sseRes = await sseReq.close();
    expect(sseRes.statusCode, 200);
    expect(sseRes.headers.contentType?.mimeType, 'text/event-stream');

    // 收集下行流全部字节；流关闭后断言收到通知帧。
    // 环境注记：本机火绒网页防护（HipsDaemon）会缓冲回环 chunked 响应体直到
    // 连接关闭，实时逐块投递不可观测；改为"关流后整包断言"在有无该防护的
    // 环境下都成立（未缓冲环境帧实时到达并被收集，行为一致）。
    final received = StringBuffer();
    final sseDone = Completer<void>();
    sseRes.transform(utf8.decoder).listen(
          received.write,
          onDone: sseDone.complete,
          onError: (Object _) => sseDone.complete(),
        );

    // 给服务端一点时间完成注册
    await Future<void>.delayed(const Duration(milliseconds: 100));
    server.notifyToolsListChanged();

    // DELETE 注销会话 → SSE 关闭（注销走独立连接，关闭下行流）
    final delReq =
        await client.deleteUrl(Uri.parse('http://127.0.0.1:$port/mcp'));
    delReq.headers.set('Mcp-Session-Id', session);
    final del = await delReq.close();
    expect(del.statusCode, 204);

    await sseDone.future.timeout(const Duration(seconds: 5));
    expect(received.toString(), contains('notifications/tools/list_changed'));

    await server.stop();
    client.close(force: true);
  });

  test('无会话 id 的 GET /mcp 返回 400', () async {
    final server = McpHttpServer();
    final dispatcher = McpDispatcher(
      serverName: 'MD3Music',
      serverVersion: 'test',
      tools: McpToolRegistry(const []),
      resources: const [],
      prompts: const [],
    );
    final port = await server.start(
      dispatcher: dispatcher,
      preferredPort: 0,
      bindLan: false,
      token: '',
      requireAuth: false,
    );
    final client = HttpClient();
    final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port/mcp'));
    req.headers.set('Accept', 'text/event-stream');
    final res = await req.close();
    expect(res.statusCode, 400);
    await res.drain<void>();
    await server.stop();
    client.close(force: true);
  });
}
