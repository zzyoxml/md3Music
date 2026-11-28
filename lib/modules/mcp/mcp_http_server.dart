import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'mcp_jsonrpc.dart';

/// MCP Streamable HTTP 传输层。
///
/// 端点固定 `/mcp`：`POST` 处理 JSON-RPC；`GET`（带会话头）打开 SSE 下行；
/// `DELETE`（带会话头）注销会话并断流；`OPTIONS` → 204 + CORS。
/// 会话由 `initialize` 建立并经 `Mcp-Session-Id` 响应头下发。
class McpHttpServer {
  HttpServer? _server;

  /// 会话 id → 打开的 SSE 请求（null 表示会话存在但未开下行流）。
  final Map<String, HttpRequest?> _sessions = <String, HttpRequest?>{};

  /// 实际监听端口（start 成功后有效）。
  int get port => _server?.port ?? 0;

  bool get isRunning => _server != null;

  /// 启动。端口被占用时依次尝试 port+1..port+4，全部失败抛 [StateError]。
  Future<int> start({
    required McpDispatcher dispatcher,
    required int preferredPort,
    required bool bindLan,
    required String token,
    required bool requireAuth,
  }) async {
    await stop();
    HttpServer? bound;
    StateError? lastError;
    for (var i = 0; i < 5; i++) {
      // preferredPort == 0 表示让系统分配，重试没有意义（每次都是新端口）。
      final candidate = preferredPort == 0 ? 0 : preferredPort + i;
      try {
        bound = await HttpServer.bind(
          bindLan ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4,
          candidate,
          shared: false,
        );
        break;
      } on SocketException catch (e) {
        lastError = StateError('端口 $candidate 绑定失败：$e');
        if (preferredPort == 0) break;
      }
    }
    if (bound == null) throw lastError ?? StateError('无法绑定 MCP 端口');
    _server = bound;
    bound.listen(
      (req) => _handle(req, dispatcher, token: token, requireAuth: requireAuth),
      onError: (Object _) {},
      cancelOnError: false,
    );
    return bound.port;
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    for (final id in _sessions.keys.toList(growable: false)) {
      await _closeSession(id);
    }
    _sessions.clear();
    if (server != null) {
      await server.close(force: true);
    }
  }

  /// 向所有打开了 SSE 下行的会话广播一条通知。
  void notifyToolsListChanged() {
    const frame = 'event: message\n'
        'data: {"jsonrpc":"2.0","method":"notifications/tools/list_changed"}\n\n';
    for (final entry in _sessions.entries) {
      final req = entry.value;
      if (req != null) {
        req.response.write(frame);
        unawaited(req.response.flush().catchError((Object _) {}));
      }
    }
  }

  /// 注销会话：从会话表移除并关闭其打开的 SSE 下行。
  Future<void> _closeSession(String session) async {
    final req = _sessions.remove(session);
    final stream = req?.response;
    if (stream != null) {
      try {
        await stream.close();
      } catch (_) {}
    }
  }

  Future<void> _handle(
    HttpRequest req,
    McpDispatcher dispatcher, {
    required String token,
    required bool requireAuth,
  }) async {
    final response = req.response;
    _applyCors(req, response);

    if (req.method == 'OPTIONS') {
      response.statusCode = HttpStatus.noContent;
      await response.close();
      return;
    }

    // 路径精确匹配 /mcp：既不接受 /mcp/ 也不接受子路径，避免内部端点被误暴露。
    if (req.uri.path != '/mcp') {
      await _writeJsonRpcError(response, HttpStatus.notFound,
          const JsonRpcError(-32000, 'Not Found'));
      return;
    }

    final reqSession = req.headers.value('mcp-session-id');

    if (req.method == 'DELETE') {
      // 注销会话并断开其 SSE 下行（无会话头时保持旧行为：204 空操作）。
      if (reqSession != null) {
        await _closeSession(reqSession);
      }
      response.statusCode = HttpStatus.noContent;
      await response.close();
      return;
    }

    if (req.method == 'GET') {
      if (reqSession == null) {
        await _writeJsonRpcError(response, HttpStatus.badRequest,
            const JsonRpcError(-32000, 'Missing Mcp-Session-Id header'));
        return;
      }
      // GET 分支在既有分支顺序里位于统一鉴权之前，SSE 下行不能绕过 Bearer
      // 校验，这里补一次与 POST 相同的鉴权。
      if (requireAuth && !_authorized(req, token)) {
        response.headers.set('WWW-Authenticate', 'Bearer realm="md3music-mcp"');
        await _writeJsonRpcError(response, HttpStatus.unauthorized,
            const JsonRpcError(-32000, 'Unauthorized'));
        return;
      }
      if (!_sessions.containsKey(reqSession)) {
        await _writeJsonRpcError(
          response,
          HttpStatus.notFound,
          const JsonRpcError(-32000, 'Session not found'),
        );
        return;
      }
      response.statusCode = HttpStatus.ok;
      response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      response.headers.set('Cache-Control', 'no-cache');
      response.headers.set('Connection', 'keep-alive');
      // dart:io 在写出首个 body chunk 之前不会真正把响应头推到网络上，
      // 先写一条 SSE 注释行（keepalive，客户端按规范忽略）确保响应头
      // 立刻可达，客户端不必等到第一条通知才能确认流已建立。
      response.write(': open\n\n');
      await response.flush();
      _sessions[reqSession] = req;
      // 挂住响应直到客户端断开（done future 完成即清理）。
      unawaited(response.done.whenComplete(() {
        if (_sessions[reqSession] == req) _sessions[reqSession] = null;
      }));
      return;
    }

    if (req.method != 'POST') {
      await _writeJsonRpcError(response, HttpStatus.methodNotAllowed,
          const JsonRpcError(-32000, 'Only POST is supported on /mcp'));
      return;
    }

    if (!_acceptIsSupported(req)) {
      await _writeJsonRpcError(
        response,
        HttpStatus.notAcceptable,
        const JsonRpcError(
            -32000, 'Accept must include application/json or text/event-stream'),
      );
      return;
    }

    if (requireAuth && !_authorized(req, token)) {
      response.headers.set('WWW-Authenticate', 'Bearer realm="md3music-mcp"');
      await _writeJsonRpcError(response, HttpStatus.unauthorized,
          const JsonRpcError(-32000, 'Unauthorized'));
      return;
    }

    if (reqSession != null && !_sessions.containsKey(reqSession)) {
      await _writeJsonRpcError(
        response,
        HttpStatus.notFound,
        const JsonRpcError(-32000, 'Session not found'),
      );
      return;
    }

    // dart:io 的 HttpRequest 是 Stream<Uint8List>，不能直接喂给 Utf8Decoder.transform。
    final body = await utf8.decoder.bind(req).join();
    Object? message;
    try {
      message = jsonDecode(body);
    } catch (_) {
      await _writeJsonRpcError(response, HttpStatus.badRequest,
          const JsonRpcError(kJsonRpcParseError, 'Parse error'));
      return;
    }

    final result = await dispatcher.handle(message);
    if (result == null) {
      // 通知：202 + 空包
      response.statusCode = HttpStatus.accepted;
      await response.close();
      return;
    }

    // 无会话头的 initialize 会生成新会话：下发 Mcp-Session-Id 并登记，
    // 之后 clearSession 交出所有权（带会话头的请求不覆盖既有会话）。
    if (reqSession == null && dispatcher.session != null) {
      response.headers.set('Mcp-Session-Id', dispatcher.session!);
      _sessions[dispatcher.session!] = null;
      dispatcher.clearSession();
    }

    response.statusCode = HttpStatus.ok;
    response.headers.contentType = ContentType.json;
    if (_requiresProtocolHeader(dispatcher.protocolVersion)) {
      response.headers.set('MCP-Protocol-Version', dispatcher.protocolVersion);
    }
    response.write(jsonEncode(result));
    await response.close();
  }

  bool _acceptIsSupported(HttpRequest req) {
    final accept = req.headers.value('accept');
    if (accept == null || accept.trim().isEmpty) return true;
    final lower = accept.toLowerCase();
    return lower.contains('application/json') ||
        lower.contains('text/event-stream') ||
        lower.contains('*/*');
  }

  bool _authorized(HttpRequest req, String token) {
    final header = req.headers.value('authorization');
    if (header == null) return false;
    final lower = header.toLowerCase();
    if (!lower.startsWith('bearer ')) return false;
    return header.substring(7).trim() == token;
  }

  void _applyCors(HttpRequest req, HttpResponse response) {
    final origin = req.headers.value('origin');
    response.headers.set('Access-Control-Allow-Origin', origin ?? '*');
    response.headers.set('Access-Control-Allow-Methods', 'POST, GET, DELETE, OPTIONS');
    response.headers.set('Access-Control-Allow-Headers', 'Content-Type, Authorization, MCP-Protocol-Version');
    response.headers.set('Access-Control-Max-Age', '86400');
  }

  /// 2025-06-18 起，服务端必须在响应中回带 MCP-Protocol-Version。
  bool _requiresProtocolHeader(String version) {
    final parts = version.split('-');
    if (parts.length < 3) return false;
    final year = int.tryParse(parts[0]) ?? 0;
    final month = int.tryParse(parts[1]) ?? 0;
    return year > 2025 || (year == 2025 && month >= 6);
  }

  Future<void> _writeJsonRpcError(
    HttpResponse response,
    int status,
    JsonRpcError error,
  ) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    // 统一走 JsonRpcResponse 组装信封，避免各错误分支手写出不同形状。
    response.write(jsonEncode(JsonRpcResponse.error(null, error).toJson()));
    await response.close();
  }
}
