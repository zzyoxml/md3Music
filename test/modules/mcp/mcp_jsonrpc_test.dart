import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/mcp/mcp_jsonrpc.dart';
import 'package:md3music/modules/mcp/mcp_prompt.dart';
import 'package:md3music/modules/mcp/mcp_resource.dart';
import 'package:md3music/modules/mcp/mcp_tool.dart';

McpDispatcher _dispatcher({bool readOnly = false}) {
  final registry = McpToolRegistry(<McpTool>[
    McpTool(
      name: 'md3_echo',
      description: '回显文本',
      inputSchema: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'text': <String, Object?>{'type': 'string'},
        },
        'required': <Object?>['text'],
      },
      handler: (args) async =>
          McpToolResult(<String, Object?>{'echo': args['text']}),
    ),
    McpTool(
      name: 'md3_pause',
      description: '暂停播放',
      inputSchema: <String, Object?>{'type': 'object', 'properties': <String, Object?>{}},
      isMutating: true,
      handler: (_) async => const McpToolResult.text('paused'),
    ),
  ]);
  registry.readOnly = readOnly;
  return McpDispatcher(
    serverName: 'MD3MusicTest',
    serverVersion: '0.0.1',
    tools: registry,
  );
}

void main() {
  group('initialize', () {
    test('协商已知版本时原样回显', () async {
      final d = _dispatcher();
      final res = await d.handle(jsonDecode(
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":'
        '{"protocolVersion":"2025-03-26","capabilities":{},'
        '"clientInfo":{"name":"c","version":"1"}}}',
      )) as Map<String, Object?>;
      expect(res['id'], 1);
      final result = res['result'] as Map<String, Object?>;
      expect(result['protocolVersion'], '2025-03-26');
      expect(d.protocolVersion, '2025-03-26');
      expect((result['capabilities'] as Map)['tools'], isNotNull);
      expect((result['serverInfo'] as Map)['name'], 'MD3MusicTest');
    });

    test('未知版本回落到最新', () async {
      final d = _dispatcher();
      final res = await d.handle(jsonDecode(
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}',
      )) as Map<String, Object?>;
      expect((res['result'] as Map)['protocolVersion'], '2025-06-18');
    });
  });

  test('通知（无 id）返回 null，传输层用 202 空包', () async {
    final d = _dispatcher();
    final res = await d.handle(jsonDecode(
      '{"jsonrpc":"2.0","method":"notifications/initialized"}',
    ));
    expect(res, isNull);
  });

  test('tools/list 在只读模式下隐藏写工具', () async {
    final d = _dispatcher(readOnly: true);
    final res = await d.handle(jsonDecode('{"jsonrpc":"2.0","id":2,"method":"tools/list"}'))
        as Map<String, Object?>;
    final tools = (res['result'] as Map)['tools'] as List;
    expect(tools.map((t) => (t as Map)['name']), ['md3_echo']);
  });

  test('只读模式下调用写工具返回 isError 内容', () async {
    final d = _dispatcher(readOnly: true);
    final res = await d.handle(jsonDecode(
      '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"md3_pause","arguments":{}}}',
    )) as Map<String, Object?>;
    final result = res['result'] as Map<String, Object?>;
    expect(result['isError'], isTrue);
    expect((result['content'] as List).first, containsPair('type', 'text'));
  });

  test('未知方法返回 -32601', () async {
    final d = _dispatcher();
    final res = await d.handle(jsonDecode('{"jsonrpc":"2.0","id":4,"method":"nope"}'))
        as Map<String, Object?>;
    expect((res['error'] as Map)['code'], -32601);
  });

  test('批量请求返回数组', () async {
    final d = _dispatcher();
    final res = await d.handle(jsonDecode(
      '[{"jsonrpc":"2.0","id":1,"method":"ping"},'
      '{"jsonrpc":"2.0","method":"notifications/cancelled"}]',
    )) as List;
    expect(res, hasLength(1));
  });

  group('McpToolResult', () {
    test('data 结果序列化为 JSON 文本', () {
      expect(const McpToolResult({'a': 1}).text, '{"a":1}');
    });

    test('error 结果 isError 为真且保留原文', () {
      const r = McpToolResult.error('参数缺失');
      expect(r.isError, isTrue);
      expect(r.text, '参数缺失');
    });
  });

  group('参数校验助手', () {
    test('requireString 拒绝空串', () {
      expect(() => requireString(<String, Object?>{}, 'k'), throwsArgumentError);
      expect(() => requireString(<String, Object?>{'k': '  '}, 'k'), throwsArgumentError);
      expect(requireString(<String, Object?>{'k': 'x'}, 'k'), 'x');
    });

    test('requireInt 接受 num 并做区间裁剪校验', () {
      expect(requireInt(<String, Object?>{'k': 2.4}, 'k'), 2);
      expect(() => requireInt(<String, Object?>{'k': -1}, 'k', min: 0), throwsArgumentError);
      expect(() => requireInt(<String, Object?>{'k': 99}, 'k', max: 30), throwsArgumentError);
    });

    test('optionalInt 缺失时回落默认值', () {
      expect(optionalInt(<String, Object?>{}, 'k', fallback: 10), 10);
      expect(optionalInt(<String, Object?>{'k': 3}, 'k', fallback: 10), 3);
    });
  });

  group('resources', () {
    test('resources/list 列出全部资源', () async {
      final dispatcher = McpDispatcher(
        serverName: 'MD3Music',
        serverVersion: 'test',
        tools: McpToolRegistry(const []),
        resources: [
          McpResource(
            uri: 'md3://player/state',
            name: '播放器状态',
            description: '当前播放状态 JSON',
            mimeType: 'application/json',
            read: () async => '{}',
          ),
        ],
      );
      final res = await dispatcher.handle(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'resources/list',
      });
      final list = (res as Map)['result']['resources'] as List;
      expect((list.first as Map)['uri'], 'md3://player/state');
    });

    test('resources/read 返回 contents 文本', () async {
      final dispatcher = McpDispatcher(
        serverName: 'MD3Music',
        serverVersion: 'test',
        tools: McpToolRegistry(const []),
        resources: [
          McpResource(
            uri: 'md3://x',
            name: 'x',
            description: 'd',
            mimeType: 'text/plain',
            read: () async => 'hello',
          ),
        ],
      );
      final res = await dispatcher.handle(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'resources/read',
        'params': {'uri': 'md3://x'},
      });
      final contents = (res as Map)['result']['contents'] as List;
      expect((contents.first as Map)['text'], 'hello');
    });

    test('resources/read 未知 uri 报 -32002', () async {
      final dispatcher = McpDispatcher(
        serverName: 'MD3Music',
        serverVersion: 'test',
        tools: McpToolRegistry(const []),
        resources: const [],
      );
      final res = await dispatcher.handle(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'resources/read',
        'params': {'uri': 'md3://nope'},
      });
      expect((res as Map)['error']['code'], -32002);
    });

    test('initialize capabilities 带 resources 与 prompts', () async {
      final dispatcher = McpDispatcher(
        serverName: 'MD3Music',
        serverVersion: 'test',
        tools: McpToolRegistry(const []),
        // 注：计划原文此处写 `resources: const []` 却断言 capabilities 带
        // resources，与实现（非空才声明）自相矛盾；按测试名语义改为带一个资源。
        resources: [
          McpResource(
            uri: 'md3://player/state',
            name: '播放器状态',
            description: 'd',
            mimeType: 'application/json',
            read: () async => '{}',
          ),
        ],
        prompts: buildMcpPrompts(),
      );
      final res = await dispatcher.handle(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 4,
        'method': 'initialize',
        'params': {
          'protocolVersion': '2025-06-18',
          'capabilities': {},
          'clientInfo': {'name': 't', 'version': '0'},
        },
      });
      final caps = (res as Map)['result']['capabilities'] as Map;
      expect(caps.containsKey('resources'), isTrue);
      expect(caps.containsKey('prompts'), isTrue);
    });

    test('jsonEncode 一次完整信封（防回归）', () async {
      // 保证 handle 输出可直接 jsonEncode（信封形状不回归）。
      final dispatcher = McpDispatcher(
        serverName: 'MD3Music',
        serverVersion: 'test',
        tools: McpToolRegistry(const []),
        resources: const [],
      );
      final res = await dispatcher.handle(<String, dynamic>{
        'jsonrpc': '2.0', 'id': 5, 'method': 'ping',
      });
      expect(jsonEncode(res), contains('"result"'));
    });
  });

  group('prompts', () {
    test('prompts/list 与 prompts/get', () async {
      final dispatcher = McpDispatcher(
        serverName: 'MD3Music',
        serverVersion: 'test',
        tools: McpToolRegistry(const []),
        resources: const [],
        prompts: buildMcpPrompts(),
      );
      final list = await dispatcher.handle(<String, dynamic>{
        'jsonrpc': '2.0', 'id': 1, 'method': 'prompts/list',
      });
      final names = ((list as Map)['result']['prompts'] as List)
          .map((p) => (p as Map)['name'])
          .toList();
      expect(names, contains('sleep_assistant'));

      final got = await dispatcher.handle(<String, dynamic>{
        'jsonrpc': '2.0', 'id': 2, 'method': 'prompts/get',
        'params': {
          'name': 'sleep_assistant',
          'arguments': {'minutes': '45'},
        },
      });
      final messages = (got as Map)['result']['messages'] as List;
      expect(((messages.first as Map)['content'] as Map)['text'], contains('45'));
    });

    test('prompts/get 未知模板报 InvalidParams', () async {
      final dispatcher = McpDispatcher(
        serverName: 'MD3Music',
        serverVersion: 'test',
        tools: McpToolRegistry(const []),
        resources: const [],
        prompts: buildMcpPrompts(),
      );
      final res = await dispatcher.handle(<String, dynamic>{
        'jsonrpc': '2.0', 'id': 3, 'method': 'prompts/get',
        'params': {'name': 'nope'},
      });
      expect((res as Map)['error']['code'], -32602);
    });
  });
}
