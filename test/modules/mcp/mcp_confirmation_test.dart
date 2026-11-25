import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/mcp/mcp_confirmation.dart';
import 'package:md3music/modules/mcp/mcp_tool.dart';

void main() {
  test('confirm 挂起直到 resolve(true)', () async {
    final broker = McpConfirmationBroker();
    final future = broker.confirm('md3_clear_queue', '清空 12 首歌的队列');
    expect(broker.pending.value, isNotNull);
    broker.resolve(broker.pending.value!.id, true);
    expect(await future, isTrue);
    expect(broker.pending.value, isNull);
    broker.dispose();
  });

  test('超时视为拒绝', () async {
    final broker = McpConfirmationBroker();
    final future =
        broker.confirm('x', 'y', timeout: const Duration(milliseconds: 30));
    final ok = await future;
    expect(ok, isFalse);
    expect(broker.pending.value, isNull);
    broker.dispose();
  });

  test('已有挂起请求时新请求直接拒绝', () async {
    final broker = McpConfirmationBroker();
    final first = broker.confirm('a', 'b');
    final second = await broker.confirm('c', 'd');
    expect(second, isFalse);
    broker.resolve(broker.pending.value!.id, true);
    expect(await first, isTrue);
    broker.dispose();
  });

  test('registry 对 requiresConfirmation 工具先走确认', () async {
    const tool = McpTool(
      name: 'danger',
      description: 'd',
      inputSchema: {'type': 'object', 'properties': {}},
      handler: _okHandler,
      isMutating: true,
      requiresConfirmation: true,
    );
    final broker = McpConfirmationBroker();
    final registry = McpToolRegistry([tool], confirmations: broker);
    final future = registry.execute('danger', <String, Object?>{});
    broker.resolve(broker.pending.value!.id, false);
    final denied = await future;
    expect(denied.isError, isTrue);
    expect(denied.text, contains('未确认'));
    // 无 broker 时直接拒绝
    final noBroker = McpToolRegistry([tool]);
    expect(
        (await noBroker.execute('danger', <String, Object?>{})).isError, isTrue);
  });

  test('confirmationEnabled=false 时跳过确认直接执行', () async {
    const tool = McpTool(
      name: 'danger',
      description: 'd',
      inputSchema: {'type': 'object', 'properties': {}},
      handler: _okHandler,
      isMutating: true,
      requiresConfirmation: true,
    );
    final registry = McpToolRegistry([tool])..confirmationEnabled = false;
    final res = await registry.execute('danger', <String, Object?>{});
    expect(res.isError, isFalse);
    expect(res.text, 'ok');
  });
}

Future<McpToolResult> _okHandler(Map<String, Object?> args) async =>
    const McpToolResult.text('ok');
