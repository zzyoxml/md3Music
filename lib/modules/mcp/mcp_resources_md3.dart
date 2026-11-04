import 'dart:convert';

import 'package:md3music/modules/mcp/mcp_ports.dart';
import 'package:md3music/modules/mcp/mcp_resource.dart';

/// 内置资源：播放器状态 / 队列 / 当前曲目歌词。
List<McpResource> buildMcpResources({
  required McpPlayerControl control,
  required McpLibrarySource library,
}) =>
    <McpResource>[
      McpResource(
        uri: 'md3://player/state',
        name: '播放器状态',
        description: '当前播放状态（与 md3_get_player_state 同形）',
        mimeType: 'application/json',
        read: () async => jsonEncode(control.snapshot().toJson()),
      ),
      McpResource(
        uri: 'md3://player/queue',
        name: '播放队列',
        description: '当前播放队列（从当前曲目起最多 50 条）',
        mimeType: 'application/json',
        read: () async => jsonEncode(<String, Object?>{
              'current_index': control.snapshot().currentIndex,
              'items': control.queue(limit: 50),
            }),
      ),
      McpResource(
        uri: 'md3://player/lyric',
        name: '当前曲目歌词',
        description: '正在播放曲目的 LRC 歌词（无曲目或无歌词时为说明文本）',
        mimeType: 'text/plain',
        read: () async {
          final snap = control.snapshot();
          final hash = snap.hash;
          if (hash == null || hash.isEmpty) return '当前没有正在播放的在线曲目';
          return await library.getLyric(hash) ?? '当前曲目没有歌词';
        },
      ),
    ];
