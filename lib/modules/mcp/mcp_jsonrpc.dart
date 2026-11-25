import 'dart:math';

import 'mcp_prompt.dart';
import 'mcp_resource.dart';
import 'mcp_tool.dart';

/// JSON-RPC 2.0 标准错误码。MCP 在此基础上保留 -32000 段给业务错误，
/// 本计划的工具错误不走错误码，而是走 `isError: true` 的 content。
const int kJsonRpcParseError = -32700;
const int kJsonRpcInvalidRequest = -32600;
const int kJsonRpcMethodNotFound = -32601;
const int kJsonRpcInvalidParams = -32602;
const int kJsonRpcInternalError = -32603;
const int kJsonRpcResourceNotFound = -32002;

class JsonRpcError implements Exception {
  const JsonRpcError(this.code, this.message, [this.data]);

  final int code;
  final String message;
  final Object? data;

  Map<String, Object?> toJson() => <String, Object?>{
        'code': code,
        'message': message,
        if (data != null) 'data': data,
      };
}

class JsonRpcResponse {
  const JsonRpcResponse.result(this.id, this.result) : error = null;
  const JsonRpcResponse.error(this.id, this.error) : result = null;

  final Object? id;
  final Object? result;
  final JsonRpcError? error;

  Map<String, Object?> toJson() => <String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        if (error != null) 'error': error!.toJson() else 'result': result,
      };
}

/// MCP 消息分发器：输入已解码的 JSON，输出待序列化的响应体。
///
/// 不持有 socket、不依赖 dart:io，便于纯单测覆盖协议行为。
class McpDispatcher {
  McpDispatcher({
    required this.serverName,
    required this.serverVersion,
    required this.tools,
    this.instructions,
    this.resources = const <McpResource>[],
    this.prompts = const <McpPrompt>[],
  });

  static const List<String> supportedProtocolVersions = <String>[
    '2025-06-18',
    '2025-03-26',
    '2024-11-05',
  ];
  static const String latestProtocolVersion = '2025-06-18';

  final String serverName;
  final String serverVersion;
  final McpToolRegistry tools;
  final String? instructions;
  final List<McpResource> resources;
  final List<McpPrompt> prompts;

  String _protocolVersion = latestProtocolVersion;

  /// 最近一次 initialize 协商出的版本（HTTP 层写 MCP-Protocol-Version 头用）。
  String get protocolVersion => _protocolVersion;

  String? _session;

  /// 当前会话 id（initialize 时生成；HTTP 层把它写进 Mcp-Session-Id 响应头后
  /// 会调 [clearSession] 交出所有权，会话登记转由 HTTP 层维护）。
  String? get session => _session;

  void clearSession() => _session = null;

  String _newSessionId() {
    final rnd = Random.secure();
    return List.generate(
            16, (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// 返回待序列化响应体：`Map`（单条）/ `List`（批量）/ `null`（通知，202 空包）。
  Future<Object?> handle(Object? message) async {
    if (message is List) {
      final out = <Object?>[];
      for (final item in message) {
        final one = await _handleOne(item);
        if (one != null) out.add(one.toJson());
      }
      return out.isEmpty ? null : out;
    }
    return (await _handleOne(message))?.toJson();
  }

  Future<JsonRpcResponse?> _handleOne(Object? message) async {
    if (message is! Map) {
      return const JsonRpcResponse.error(
        null,
        JsonRpcError(kJsonRpcInvalidRequest, 'Request must be a JSON object'),
      );
    }
    final map = message as Map<String, dynamic>;
    final id = map['id'];
    final method = map['method'];
    if (method is! String) {
      return JsonRpcResponse.error(
        id,
        const JsonRpcError(kJsonRpcInvalidRequest, 'Missing "method"'),
      );
    }
    try {
      final result = await _dispatch(method, map['params']);
      if (id == null) return null; // 通知不回包
      return JsonRpcResponse.result(id, result);
    } on JsonRpcError catch (e) {
      return id == null ? null : JsonRpcResponse.error(id, e);
    } catch (e) {
      return id == null
          ? null
          : JsonRpcResponse.error(
              id,
              JsonRpcError(kJsonRpcInternalError, 'Internal error', e.toString()),
            );
    }
  }

  Future<Object?> _dispatch(String method, Object? params) async {
    switch (method) {
      case 'initialize':
        return _initialize(params);
      case 'ping':
        return <String, Object?>{};
      case 'tools/list':
        return _toolsList();
      case 'tools/call':
        return _toolsCall(params);
      case 'resources/list':
        return <String, Object?>{
          'resources': resources.map((r) => r.toJson()).toList(growable: false),
        };
      case 'resources/read':
        return _resourcesRead(params);
      case 'prompts/list':
        return <String, Object?>{
          'prompts': prompts.map((p) => p.toJson()).toList(growable: false),
        };
      case 'prompts/get':
        return _promptsGet(params);
      case 'notifications/initialized':
      case 'notifications/cancelled':
      case 'notifications/progress':
        return null;
      default:
        throw const JsonRpcError(kJsonRpcMethodNotFound, 'Method not found');
    }
  }

  Map<String, Object?> _initialize(Object? params) {
    final requested =
        params is Map ? params['protocolVersion'] as String? : null;
    _protocolVersion = requested != null && supportedProtocolVersions.contains(requested)
        ? requested
        : latestProtocolVersion;
    // 同一 dispatcher 实例只发一次；server 每次重启新建 dispatcher，
    // 等效每服务周期新会话空间。
    _session ??= _newSessionId();
    return <String, Object?>{
      'protocolVersion': _protocolVersion,
      'capabilities': <String, Object?>{
        'tools': <String, Object?>{'listChanged': false},
        if (resources.isNotEmpty) 'resources': <String, Object?>{},
        if (prompts.isNotEmpty) 'prompts': <String, Object?>{},
      },
      'serverInfo': <String, Object?>{
        'name': serverName,
        'version': serverVersion,
      },
      if (instructions != null) 'instructions': instructions,
    };
  }

  Map<String, Object?> _toolsList() => <String, Object?>{
        'tools': tools
            .visibleTools()
            .map((t) => t.toJson())
            .toList(growable: false),
      };

  Future<Map<String, Object?>> _toolsCall(Object? params) async {
    final p = params is Map ? params as Map<String, dynamic> : null;
    final name = p?['name'] as String?;
    final rawArgs = p?['arguments'];
    final args = rawArgs is Map
        ? Map<String, Object?>.from(rawArgs)
        : <String, Object?>{};
    if (name == null) {
      throw const JsonRpcError(kJsonRpcInvalidParams, 'Missing "name"');
    }
    final result = await tools.execute(name, args);
    return <String, Object?>{
      'content': <Object?>[
        <String, Object?>{'type': 'text', 'text': result.text},
      ],
      'isError': result.isError,
    };
  }

  Future<Map<String, Object?>> _resourcesRead(Object? params) async {
    final uri = params is Map ? params['uri'] as String? : null;
    if (uri == null) {
      throw const JsonRpcError(kJsonRpcInvalidParams, 'Missing "uri"');
    }
    for (final r in resources) {
      if (r.uri == uri) {
        return <String, Object?>{
          'contents': <Object?>[
            <String, Object?>{
              'uri': r.uri,
              'mimeType': r.mimeType,
              'text': await r.read(),
            },
          ],
        };
      }
    }
    throw JsonRpcError(kJsonRpcResourceNotFound, 'Resource not found: $uri');
  }

  Map<String, Object?> _promptsGet(Object? params) {
    // 计划原文写 `params['arguments']`：params 是 Object? 不会被提升，编译不过；
    // 与 _toolsCall 一致先收窄成局部 map 再取值。
    final map = params is Map ? params as Map<String, dynamic> : null;
    final name = map?['name'] as String?;
    if (name == null) {
      throw const JsonRpcError(kJsonRpcInvalidParams, 'Missing "name"');
    }
    for (final p in prompts) {
      if (p.name == name) {
        final raw = map?['arguments'];
        final args = <String, String>{
          if (raw is Map)
            for (final e in raw.entries)
              if (e.value != null) e.key.toString(): e.value.toString(),
        };
        for (final a in p.arguments) {
          if (a.required && (args[a.name] == null || args[a.name]!.isEmpty)) {
            throw JsonRpcError(
                kJsonRpcInvalidParams, 'Missing argument "${a.name}"');
          }
        }
        return <String, Object?>{
          'description': p.description,
          'messages': p.messages(args),
        };
      }
    }
    throw JsonRpcError(kJsonRpcInvalidParams, 'Unknown prompt: $name');
  }
}
