import 'package:md3music/modules/mcp/mcp_ports.dart';
import 'package:md3music/modules/mcp/mcp_tool.dart';

/// 曲库写操作工具（group = library_write，全部 requiresConfirmation）。
///
/// 上游酷狗不存在"收藏单曲"模块（Task 11 研究门控结论，见
/// `tmp/collect-research.md`），故无收藏类工具；本组只含歌单写两件。
/// 歌名详情取数在工具层完成：detail 缺失时直接返回可读错误，不惊动写端口。
List<McpTool> buildLibraryWriteTools({
  required McpLibraryWriteSource write,
  required McpLibrarySource library,
}) =>
    <McpTool>[
      McpTool(
        name: 'md3_add_song_to_playlist',
        description: '把指定 hash 的歌曲加入指定歌单。listid 为歌单数字 ID'
            '（用户歌单接口返回的 listid 字段）；成功回执含歌名与歌单 id。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'hash': <String, Object?>{'type': 'string', 'description': '歌曲 hash'},
            'listid': <String, Object?>{
              'type': 'string',
              'description': '歌单数字 ID（listid）',
            },
          },
          'required': <Object?>['hash', 'listid'],
        },
        isMutating: true,
        group: kMcpGroupLibraryWrite,
        requiresConfirmation: true,
        handler: (args) async {
          final hash = requireString(args, 'hash');
          final listid = requireString(args, 'listid');
          // 加歌 data 需要"名称|hash|专辑id|mixsongid"：detail 缺失时提前
          // 返回可读错误，避免写端口拿到空名称再失败（双保险，写源内部同判）。
          final detail = await library.getSongDetail(hash);
          if (detail == null) {
            return McpToolResult.error('未找到 hash 为 $hash 的歌曲，无法加入歌单');
          }
          final song = detail.toSong();
          await write.addSongToPlaylist(hash, listid);
          return McpToolResult(<String, Object?>{
            'added': true,
            'title': song.title,
            'artist': song.artist,
            'hash': hash,
            'listid': listid,
          });
        },
      ),
      McpTool(
        name: 'md3_create_playlist',
        description: '创建一个新歌单（需要登录）。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'name': <String, Object?>{'type': 'string', 'description': '歌单名'},
          },
          'required': <Object?>['name'],
        },
        isMutating: true,
        group: kMcpGroupLibraryWrite,
        requiresConfirmation: true,
        handler: (args) async {
          final name = requireString(args, 'name');
          await write.createPlaylist(name);
          return McpToolResult(<String, Object?>{
            'created': true,
            'name': name,
          });
        },
      ),
    ];
