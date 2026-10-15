import 'package:md3music/modules/mcp/mcp_ports.dart';
import 'package:md3music/modules/mcp/mcp_tool.dart';

const Map<String, Object?> _emptySchema = <String, Object?>{
  'type': 'object',
  'properties': <String, Object?>{},
};

const Set<String> _loopModes = <String>{'off', 'one', 'all'};

/// 播放器状态与控制类工具（依赖 [McpPlayerControl]）。
List<McpTool> buildPlayerTools(McpPlayerControl control) => <McpTool>[
      McpTool(
        name: 'md3_get_player_state',
        description: '读取当前播放状态：曲目名/歌手/专辑、hash 与音质档位（仅在线曲目有）、'
            '是否播放、播放进度（毫秒）、总时长、音量、循环模式、随机播放、'
            '队列长度与当前索引。无曲目时曲目字段为空。'
            'loop_mode 取值：off（不循环）/ one（单曲循环）/ all（列表循环）。',
        inputSchema: _emptySchema,
        handler: (_) async => McpToolResult(control.snapshot().toJson()),
      ),
      McpTool(
        name: 'md3_get_queue',
        description: '读取当前播放队列（从当前曲目开始，最多 50 条）与当前所在索引。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'limit': <String, Object?>{
              'type': 'integer',
              'description': '返回条数，1-50，默认 20',
            },
          },
        },
        handler: (args) async {
          final limit = optionalInt(args, 'limit', fallback: 20, min: 1, max: 50);
          final snapshot = control.snapshot();
          return McpToolResult(<String, Object?>{
            'current_index': snapshot.currentIndex,
            'total': snapshot.queueLength,
            'items': control.queue(limit: limit),
          });
        },
      ),
      McpTool(
        name: 'md3_resume',
        description: '继续播放当前曲目。若当前没有任何曲目则返回错误。',
        inputSchema: _emptySchema,
        isMutating: true,
        handler: (_) async {
          if (control.snapshot().song == null) {
            return const McpToolResult.error('当前没有曲目，无法继续播放');
          }
          await control.resume();
          return const McpToolResult.text('已继续播放');
        },
      ),
      McpTool(
        name: 'md3_pause',
        description: '暂停当前播放。',
        inputSchema: _emptySchema,
        isMutating: true,
        handler: (_) async {
          await control.pause();
          return const McpToolResult.text('已暂停');
        },
      ),
      McpTool(
        name: 'md3_next',
        description: '切到下一首。',
        inputSchema: _emptySchema,
        isMutating: true,
        handler: (_) async {
          await control.next();
          return const McpToolResult.text('已切到下一首');
        },
      ),
      McpTool(
        name: 'md3_previous',
        description: '切到上一首。',
        inputSchema: _emptySchema,
        isMutating: true,
        handler: (_) async {
          await control.previous();
          return const McpToolResult.text('已切到上一首');
        },
      ),
      McpTool(
        name: 'md3_seek',
        description: '跳转到指定播放位置（绝对毫秒，从 0 开始）。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'position_ms': <String, Object?>{
              'type': 'integer',
              'description': '目标位置，单位毫秒，>= 0',
            },
          },
          'required': <Object?>['position_ms'],
        },
        isMutating: true,
        handler: (args) async {
          final ms = requireInt(args, 'position_ms', min: 0);
          await control.seek(Duration(milliseconds: ms));
          return McpToolResult.text('已跳转到 ${ms}ms');
        },
      ),
      McpTool(
        name: 'md3_set_volume',
        description: '设置播放音量，取值 0.0（静音）到 1.0（最大）。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'volume': <String, Object?>{
              'type': 'number',
              'description': '音量，0.0 - 1.0',
            },
          },
          'required': <Object?>['volume'],
        },
        isMutating: true,
        handler: (args) async {
          final v = requireDouble(args, 'volume', min: 0.0, max: 1.0);
          await control.setVolume(v);
          return McpToolResult.text('音量已设为 ${v.toStringAsFixed(2)}');
        },
      ),
      McpTool(
        name: 'md3_toggle',
        description: '播放/暂停二合一：正在播放则暂停，暂停中则继续。',
        inputSchema: _emptySchema,
        isMutating: true,
        handler: (_) async {
          if (control.snapshot().playing) {
            await control.pause();
            return const McpToolResult.text('已暂停');
          }
          await control.resume();
          return const McpToolResult.text('已继续播放');
        },
      ),
      McpTool(
        name: 'md3_set_loop_mode',
        description: '设置循环模式：off（不循环）/ one（单曲循环）/ all（列表循环）。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'mode': <String, Object?>{
              'type': 'string',
              'enum': <String>['off', 'one', 'all'],
              'description': '目标循环模式',
            },
          },
          'required': <Object?>['mode'],
        },
        isMutating: true,
        handler: (args) async {
          final mode = requireString(args, 'mode');
          if (!_loopModes.contains(mode)) {
            return McpToolResult.error(
                '参数 "mode" 只能是 off / one / all，收到 "$mode"');
          }
          await control.setLoopMode(mode);
          return McpToolResult.text('循环模式已设为 $mode');
        },
      ),
      McpTool(
        name: 'md3_set_shuffle',
        description: '开启/关闭随机播放。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'enabled': <String, Object?>{'type': 'boolean', 'description': '是否开启随机'},
          },
          'required': <Object?>['enabled'],
        },
        isMutating: true,
        handler: (args) async {
          final enabled = requireBool(args, 'enabled');
          await control.setShuffle(enabled);
          return McpToolResult.text(enabled ? '已开启随机播放' : '已关闭随机播放');
        },
      ),
      McpTool(
        name: 'md3_adjust_volume',
        description: '在当前音量基础上做增减，结果自动钳制到 0.0-1.0。'
            '适合"声音小一点"这类相对调整；超出范围的增量会收敛到边界值。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'delta': <String, Object?>{
              'type': 'number',
              'description': '音量增量，正数增大、负数减小（如 -0.1 / 0.2）',
            },
          },
          'required': <Object?>['delta'],
        },
        isMutating: true,
        handler: (args) async {
          final delta = requireDouble(args, 'delta');
          final target =
              (control.snapshot().volume + delta).clamp(0.0, 1.0).toDouble();
          await control.setVolume(target);
          return McpToolResult.text('音量已调整为 ${target.toStringAsFixed(2)}');
        },
      ),
      McpTool(
        name: 'md3_skip',
        description: '基于当前进度快进/快退指定秒数，结果钳制在曲目范围内。正数快进、负数快退。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'seconds': <String, Object?>{
              'type': 'integer',
              'description': '偏移秒数，-3600 到 3600',
            },
          },
          'required': <Object?>['seconds'],
        },
        isMutating: true,
        handler: (args) async {
          final seconds = requireInt(args, 'seconds', min: -3600, max: 3600);
          final snap = control.snapshot();
          if (snap.song == null) return const McpToolResult.error('当前没有曲目');
          final target = ((snap.positionMs + seconds * 1000).clamp(
                  0,
                  snap.durationMs == 0 ? snap.positionMs : snap.durationMs))
              .toInt();
          await control.seek(Duration(milliseconds: target));
          return McpToolResult.text('已跳转到 ${(target / 1000).round()} 秒处');
        },
      ),
      McpTool(
        name: 'md3_play_queue_index',
        description: '跳转到播放队列的第 index 首并播放。index 从 0 开始，'
            '可用 md3_get_queue 查看各条目的 index。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'index': <String, Object?>{'type': 'integer', 'description': '队列位置，从 0 开始'},
          },
          'required': <Object?>['index'],
        },
        isMutating: true,
        handler: (args) async {
          final index = requireInt(args, 'index', min: 0);
          final snap = control.snapshot();
          if (index >= snap.queueLength) {
            return McpToolResult.error(
                'index $index 超出队列范围（共 ${snap.queueLength} 条）');
          }
          await control.playAt(index);
          return McpToolResult.text('已跳转到队列第 $index 首');
        },
      ),
      McpTool(
        name: 'md3_remove_queue_item',
        description: '从播放队列移除第 index 首歌曲。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'index': <String, Object?>{'type': 'integer', 'description': '队列位置，从 0 开始'},
          },
          'required': <Object?>['index'],
        },
        isMutating: true,
        handler: (args) async {
          final index = requireInt(args, 'index', min: 0);
          final snap = control.snapshot();
          if (snap.queueLength == 0) {
            return const McpToolResult.error('队列为空，没有可移除的曲目');
          }
          if (index >= snap.queueLength) {
            return McpToolResult.error(
                'index $index 超出队列范围（共 ${snap.queueLength} 条）');
          }
          await control.removeFromQueue(index);
          return McpToolResult.text('已移除队列第 $index 首');
        },
      ),
      McpTool(
        name: 'md3_move_queue_item',
        description: '把队列第 from 首移动到第 to 的位置（用于调整播放顺序）。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'from': <String, Object?>{'type': 'integer', 'description': '原位置'},
            'to': <String, Object?>{'type': 'integer', 'description': '目标位置'},
          },
          'required': <Object?>['from', 'to'],
        },
        isMutating: true,
        handler: (args) async {
          final from = requireInt(args, 'from', min: 0);
          final to = requireInt(args, 'to', min: 0);
          final snap = control.snapshot();
          if (from >= snap.queueLength || to >= snap.queueLength) {
            return McpToolResult.error(
                'from/to 超出队列范围（共 ${snap.queueLength} 条）');
          }
          if (from == to) return const McpToolResult.text('位置未变化');
          await control.reorderQueue(from, to);
          return McpToolResult.text('已把第 $from 首移动到第 $to');
        },
      ),
      McpTool(
        name: 'md3_clear_queue',
        description: '清空整个播放队列并停止播放。该操作会丢弃当前队列且不可恢复。',
        inputSchema: _emptySchema,
        isMutating: true,
        requiresConfirmation: true,
        handler: (_) async {
          if (control.snapshot().queueLength == 0) {
            return const McpToolResult.text('队列已经是空的');
          }
          await control.clearQueue();
          return const McpToolResult.text('队列已清空');
        },
      ),
      McpTool(
        name: 'md3_wait_for_player_event',
        description: '阻塞等待播放器事件：track_change（切歌）/ play（开始播放）/ pause（暂停），'
            '发生即返回，超时返回 timed_out。适合"这首播完了告诉我"这类场景。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'event': <String, Object?>{
              'type': 'string',
              'enum': <String>['track_change', 'play', 'pause'],
              'description': '等待的事件',
            },
            'timeout_ms': <String, Object?>{
              'type': 'integer',
              'description': '最长等待毫秒，1000-55000，默认 30000',
            },
          },
          'required': <Object?>['event'],
        },
        handler: (args) async {
          final name = requireString(args, 'event');
          final timeoutMs =
              optionalInt(args, 'timeout_ms', fallback: 30000, min: 1000, max: 55000);
          final event = switch (name) {
            'track_change' => McpWatchEvent.trackChange,
            'play' => McpWatchEvent.play,
            'pause' => McpWatchEvent.pause,
            _ => null,
          };
          if (event == null) {
            return McpToolResult.error(
                '参数 "event" 只能是 track_change / play / pause，收到 "$name"');
          }
          final fired = await control.waitForEvent(
              event, Duration(milliseconds: timeoutMs));
          return McpToolResult(<String, Object?>{
            'timed_out': fired == null,
            'event': ?fired,
          });
        },
      ),
    ];
