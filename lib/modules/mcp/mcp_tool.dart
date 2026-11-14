import 'dart:convert';

import 'mcp_confirmation.dart';

/// 工具执行结果。
///
/// - 正常返回用 [McpToolResult.new]：把 [data] JSON 序列化为唯一的 text content。
/// - 错误用 [McpToolResult.error]：`isError=true` 且文本为可读原因（不包 JSON，
///   便于模型直接读懂并自我纠正）。
class McpToolResult {
  const McpToolResult(this.data) : message = null, isError = false;

  const McpToolResult.text(this.message) : data = null, isError = false;

  const McpToolResult.error(this.message) : data = null, isError = true;

  final Object? data;
  final String? message;
  final bool isError;

  String get text => message ?? jsonEncode(data);
}

typedef McpToolHandler = Future<McpToolResult> Function(Map<String, Object?> args);

/// 工具分组（设置页可按组开关）。
const String kMcpGroupPlayer = 'player';
const String kMcpGroupDiscovery = 'discovery';
const String kMcpGroupLibraryWrite = 'library_write';
const String kMcpGroupAppFeatures = 'app_features';

const Set<String> kAllMcpGroups = <String>{
  kMcpGroupPlayer,
  kMcpGroupDiscovery,
  kMcpGroupLibraryWrite,
  kMcpGroupAppFeatures,
};

/// 同一写工具两次调用之间的最小间隔（防 AI 客户端重试风暴/多客户端打架）。
const int kMcpMutatingDebounceMs = 400;

class McpTool {
  const McpTool({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.handler,
    this.isMutating = false,
    this.group = kMcpGroupPlayer,
    this.requiresConfirmation = false, // Task 4 使用，本任务先带上默认值
  });

  final String name;
  final String description;

  /// JSON Schema（object 形式），直接透传给 `tools/list`。
  final Map<String, Object?> inputSchema;
  final McpToolHandler handler;

  /// true = 会改变播放状态/队列；只读模式下被注册表拦截。
  final bool isMutating;

  /// 所属分组，注册表按 [McpToolRegistry.enabledGroups] 过滤。
  final String group;

  /// true = 执行前需要 App 内二次确认（Task 4 接入执行）。
  final bool requiresConfirmation;

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'description': description,
        'inputSchema': inputSchema,
      };
}

class McpToolRegistry {
  McpToolRegistry(
    List<McpTool> tools, {
    this.onCall,
    this.confirmations,
    DateTime Function()? clock,
  })  : _all = List<McpTool>.unmodifiable(tools),
        _now = clock ?? DateTime.now;

  final List<McpTool> _all;

  /// 每次执行完成后的回调（成功/失败都会触发），供 McpService 记录调用日志。
  /// [argsSummary] 是参数 JSON 摘要（≤160 字符，无参数时为 null）。
  final void Function(String tool, bool ok, String? argsSummary)? onCall;

  final DateTime Function() _now;

  /// 同一写工具最近一次被调用的时间（含被拦截的调用），用于 400ms 防抖。
  final Map<String, DateTime> _lastMutatingAt = <String, DateTime>{};

  /// 写操作二次确认中枢；null 且工具要求确认 → 一律拒绝（保守默认）。
  ///
  /// 非 final：`McpService.start()` 按设置项（requireConfirm）在装配时注入，
  /// 与 [readOnly] / [enabledGroups] 同为运行期可变开关。
  McpConfirmationBroker? confirmations;

  /// 二次确认总开关：false 时 [McpTool.requiresConfirmation] 工具**跳过确认直接执行**
  /// （用户显式关闭确认 = 接受 AI 直操，不是拒绝执行）。null broker + 开关开 = 拒绝。
  bool confirmationEnabled = true;

  /// 只读模式：隐藏并拒绝所有 [McpTool.isMutating] 工具。
  bool readOnly = false;

  /// 启用的工具分组；不在集合内的组在 tools/list 隐藏且调用被拒。
  Set<String> enabledGroups = Set<String>.unmodifiable(kAllMcpGroups);

  List<McpTool> visibleTools() => _all
      .where((t) =>
          (!readOnly || !t.isMutating) && enabledGroups.contains(t.group))
      .toList(growable: false);

  McpTool? find(String name) {
    for (final t in _all) {
      if (t.name == name) return t;
    }
    return null;
  }

  /// 统一出口：未知工具 / 只读拦截 / 参数错误 / 执行异常都收敛成 isError 结果。
  Future<McpToolResult> execute(String name, Map<String, Object?> args) async {
    final tool = find(name);
    McpToolResult result;
    if (tool == null) {
      result = McpToolResult.error('未知工具：$name');
    } else if (readOnly && tool.isMutating) {
      result = McpToolResult.error('只读模式已开启，工具 $name 被禁用');
    } else if (!enabledGroups.contains(tool.group)) {
      result = McpToolResult.error('工具 $name 所属分组未启用');
    } else if (tool.isMutating && _isDebounced(tool.name)) {
      result = McpToolResult.error(
          '操作过于频繁，请稍后再试（${kMcpMutatingDebounceMs}ms 内仅一次）');
    } else if (tool.requiresConfirmation && confirmationEnabled) {
      final broker = confirmations;
      final approved = broker == null
          ? false
          : await broker.confirm(
              tool.name,
              '外部 AI 客户端请求执行「${tool.name}」，是否允许？',
            );
      if (!approved) {
        result = McpToolResult.error('用户未确认该操作（拒绝或超时）：$name');
      } else {
        try {
          result = await tool.handler(args);
        } on ArgumentError catch (e) {
          result = McpToolResult.error('参数错误：${e.message}');
        } catch (e) {
          result = McpToolResult.error('执行失败：$e');
        }
      }
    } else {
      try {
        result = await tool.handler(args);
      } on ArgumentError catch (e) {
        result = McpToolResult.error('参数错误：${e.message}');
      } catch (e) {
        result = McpToolResult.error('执行失败：$e');
      }
    }
    onCall?.call(name, !result.isError, _summarizeArgs(args));
    return result;
  }

  /// 写工具防抖：[kMcpMutatingDebounceMs] 内的重复调用直接拒绝（时间戳在
  /// 判定时就刷新，连续风暴调用会持续延后放行点）。
  bool _isDebounced(String name) {
    final last = _lastMutatingAt[name];
    final now = _now();
    _lastMutatingAt[name] = now;
    return last != null &&
        now.difference(last).inMilliseconds < kMcpMutatingDebounceMs;
  }

  /// 参数 JSON 摘要（≤160 字符），供调用日志复盘 AI 传入的参数；无参数返回 null。
  String? _summarizeArgs(Map<String, Object?> args) {
    if (args.isEmpty) return null;
    final s = jsonEncode(args);
    return s.length <= 160 ? s : '${s.substring(0, 160)}…';
  }
}

String requireString(Map<String, Object?> args, String key) {
  final v = args[key];
  if (v is! String || v.trim().isEmpty) {
    throw ArgumentError('参数 "$key" 必须是非空字符串');
  }
  return v;
}

int requireInt(Map<String, Object?> args, String key, {int? min, int? max}) {
  final v = args[key];
  final n = switch (v) {
    int() => v,
    num() => v.round(),
    _ => null,
  };
  if (n == null) throw ArgumentError('参数 "$key" 必须是整数');
  if (min != null && n < min) throw ArgumentError('参数 "$key" 不能小于 $min');
  if (max != null && n > max) throw ArgumentError('参数 "$key" 不能大于 $max');
  return n;
}

double requireDouble(Map<String, Object?> args, String key,
    {double? min, double? max}) {
  final v = args[key];
  final n = switch (v) {
    num() => v.toDouble(),
    _ => null,
  };
  if (n == null) throw ArgumentError('参数 "$key" 必须是数字');
  if (min != null && n < min) throw ArgumentError('参数 "$key" 不能小于 $min');
  if (max != null && n > max) throw ArgumentError('参数 "$key" 不能大于 $max');
  return n;
}

int optionalInt(Map<String, Object?> args, String key,
    {required int fallback, int? min, int? max}) {
  if (!args.containsKey(key) || args[key] == null) return fallback;
  return requireInt(args, key, min: min, max: max);
}

bool requireBool(Map<String, Object?> args, String key) {
  final v = args[key];
  if (v is! bool) {
    throw ArgumentError('参数 "$key" 必须是布尔值');
  }
  return v;
}
