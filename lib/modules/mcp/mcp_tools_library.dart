import 'dart:async';

import 'package:md3music/modules/mcp/mcp_ports.dart';
import 'package:md3music/modules/mcp/mcp_tool.dart';
import 'package:md3music/modules/mcp/mcp_tools_app.dart';
import 'package:md3music/modules/mcp/mcp_tools_library_write.dart';
import 'package:md3music/modules/mcp/mcp_tools_player.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';

/// 歌词返回上限：超出部分截断，避免单条工具结果吃掉整轮上下文。
const int kMcpLyricMaxChars = 8000;

/// 无参数工具的空 schema（与 mcp_tools_player.dart 同形）。
const Map<String, Object?> _emptySchema = <String, Object?>{
  'type': 'object',
  'properties': <String, Object?>{},
};

/// 歌曲结果投影：酷狗原始响应字段极多，只保留 AI 决策需要的 5 个。
///
/// 走 `toSong()` 而非直接读字面字段，保证这里给出的 name 与
/// `md3_play_song` / `md3_play_keyword` 回执的曲名一致（`toSong` 会剥掉
/// "歌手 - 歌名" 形式的前缀）。
Map<String, Object?> _projectSong(KugouSongDetail s) {
  final song = s.toSong();
  return <String, Object?>{
    'hash': s.hash,
    'name': song.title,
    'artist': song.artist,
    'album': song.album,
    // KugouSongDetail.duration 单位是秒
    'duration_ms': song.duration.inMilliseconds,
  };
}

Map<String, Object?> _projectAlbum(KugouAlbumBrief a) => <String, Object?>{
      'id': a.id,
      'name': a.name,
      'artist': a.artistName,
      'year': a.year,
    };

Map<String, Object?> _projectArtist(KugouArtistBrief a) =>
    <String, Object?>{'id': a.id, 'name': a.name};

Map<String, Object?> _projectPlaylist(KugouPlaylistBrief p) =>
    <String, Object?>{
      'id': p.id,
      'name': p.name,
      'song_count': p.songCount,
      'global_collection_id': p.globalCollectionId,
      // md3_add_song_to_playlist 的入参；缺了它 AI 拿不到加歌所需的 listid
      'list_id': p.listId,
    };

/// user_listen 响应结构未文档化：在 data/info|lists|list|songs 数组里找带 hash
/// 的条目，能识别就投影，识别不了就交给上层回退原文。
/// **`lists` 为 2026-10-11 实机确认的真值键**（`/user/listen` 空响应样本
/// `data:{…, lists:[], …}`）；条目级字段尚无真实非空样本，保持别名兜底。
List<Map<String, Object?>> _extractListenEntries(Map<String, dynamic> raw) {
  final data = raw['data'];
  final scope = data is Map<String, dynamic> ? data : raw;
  for (final key in const ['lists', 'info', 'list', 'songs', 'data']) {
    final v = scope[key];
    if (v is! List) continue;
    final out = <Map<String, Object?>>[];
    for (final item in v) {
      if (item is! Map) continue;
      final hash = (item['hash'] ?? '').toString();
      if (hash.isEmpty) continue;
      out.add(<String, Object?>{
        'hash': hash,
        'name': (item['filename'] ?? item['songname'] ?? item['name'] ?? '')
            .toString(),
        'timestamp': item['timestamp'],
      });
    }
    if (out.isNotEmpty) return out;
  }
  return const <Map<String, Object?>>[];
}

/// 检索 / 歌词 / 按标识播放类工具（依赖 [McpLibrarySource] + [McpPlayerControl]）。
List<McpTool> buildLibraryTools({
  required McpLibrarySource library,
  required McpPlayerControl control,
}) =>
    <McpTool>[
      McpTool(
        name: 'md3_search_songs',
        description: '按关键词搜索歌曲，返回匹配歌曲的 hash、歌名、歌手、专辑与时长（毫秒）。'
            'hash 可用于 md3_play_song / md3_enqueue_song / md3_get_lyric。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'keyword': <String, Object?>{'type': 'string', 'description': '搜索关键词'},
            'limit': <String, Object?>{
              'type': 'integer',
              'description': '返回条数，1-30，默认 10',
            },
          },
          'required': <Object?>['keyword'],
        },
        group: kMcpGroupDiscovery,
        handler: (args) async {
          final keyword = requireString(args, 'keyword');
          final limit = optionalInt(args, 'limit', fallback: 10, min: 1, max: 30);
          final songs = await library.searchSongs(keyword, limit: limit);
          return McpToolResult(<String, Object?>{
            'keyword': keyword,
            'count': songs.length,
            'items': songs.map(_projectSong).toList(growable: false),
          });
        },
      ),
      McpTool(
        name: 'md3_search_albums',
        description: '按关键词搜索专辑，返回 id/name/artist/year。name 可用于继续搜索该专辑的歌曲。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'keyword': <String, Object?>{'type': 'string', 'description': '搜索关键词'},
            'limit': <String, Object?>{'type': 'integer', 'description': '返回条数，1-20，默认 10'},
          },
          'required': <Object?>['keyword'],
        },
        group: kMcpGroupDiscovery,
        handler: (args) async {
          final keyword = requireString(args, 'keyword');
          final limit = optionalInt(args, 'limit', fallback: 10, min: 1, max: 20);
          final albums = await library.searchAlbums(keyword, limit: limit) ?? const [];
          return McpToolResult(<String, Object?>{
            'keyword': keyword,
            'count': albums.length,
            'items': albums.map(_projectAlbum).toList(growable: false),
          });
        },
      ),
      McpTool(
        name: 'md3_search_artists',
        description: '按关键词搜索歌手，返回 id/name。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'keyword': <String, Object?>{'type': 'string', 'description': '搜索关键词'},
            'limit': <String, Object?>{'type': 'integer', 'description': '返回条数，1-20，默认 10'},
          },
          'required': <Object?>['keyword'],
        },
        group: kMcpGroupDiscovery,
        handler: (args) async {
          final keyword = requireString(args, 'keyword');
          final limit = optionalInt(args, 'limit', fallback: 10, min: 1, max: 20);
          final artists = await library.searchArtists(keyword, limit: limit) ?? const [];
          return McpToolResult(<String, Object?>{
            'keyword': keyword,
            'count': artists.length,
            'items': artists.map(_projectArtist).toList(growable: false),
          });
        },
      ),
      McpTool(
        name: 'md3_search_playlists',
        description: '按关键词搜索歌单，返回 id/name/song_count/global_collection_id。'
            'global_collection_id 可用于 md3_get_playlist_songs / md3_play_playlist。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'keyword': <String, Object?>{'type': 'string', 'description': '搜索关键词'},
            'limit': <String, Object?>{'type': 'integer', 'description': '返回条数，1-20，默认 10'},
          },
          'required': <Object?>['keyword'],
        },
        group: kMcpGroupDiscovery,
        handler: (args) async {
          final keyword = requireString(args, 'keyword');
          final limit = optionalInt(args, 'limit', fallback: 10, min: 1, max: 20);
          final playlists =
              await library.searchPlaylists(keyword, limit: limit) ?? const [];
          return McpToolResult(<String, Object?>{
            'keyword': keyword,
            'count': playlists.length,
            'items': playlists.map(_projectPlaylist).toList(growable: false),
          });
        },
      ),
      McpTool(
        name: 'md3_get_song_detail',
        description: '按 hash 取歌曲完整详情（歌名/歌手/专辑/时长/封面）。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'hash': <String, Object?>{'type': 'string', 'description': '歌曲 hash'},
          },
          'required': <Object?>['hash'],
        },
        group: kMcpGroupDiscovery,
        handler: (args) async {
          final hash = requireString(args, 'hash');
          final detail = await library.getSongDetail(hash);
          if (detail == null) return McpToolResult.error('未找到 hash 为 $hash 的歌曲');
          final song = detail.toSong();
          return McpToolResult(<String, Object?>{
            'hash': detail.hash,
            'name': song.title,
            'artist': song.artist,
            'album': song.album,
            'duration_ms': song.duration.inMilliseconds,
            'artwork': detail.artworkUri,
          });
        },
      ),
      McpTool(
        name: 'md3_get_playlist_songs',
        description: '按歌单 global_collection_id（来自 md3_search_playlists）读取歌单内歌曲列表。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'global_collection_id': <String, Object?>{
              'type': 'string',
              'description': '歌单 ID（md3_search_playlists 返回的 global_collection_id）',
            },
            'limit': <String, Object?>{'type': 'integer', 'description': '返回条数，1-30，默认 30'},
          },
          'required': <Object?>['global_collection_id'],
        },
        group: kMcpGroupDiscovery,
        handler: (args) async {
          final gcId = requireString(args, 'global_collection_id');
          final limit = optionalInt(args, 'limit', fallback: 30, min: 1, max: 30);
          final data = await library.getPlaylistSongs(gcId, limit: limit);
          final songs = data?.songs ?? const <KugouSongDetail>[];
          return McpToolResult(<String, Object?>{
            'global_collection_id': gcId,
            'total': data?.total ?? songs.length,
            'count': songs.length,
            'items': songs.map(_projectSong).toList(growable: false),
          });
        },
      ),
      McpTool(
        name: 'md3_play_playlist',
        description: '播放整个歌单（取前 30 首，从第一首开始）。立即返回，成败用 md3_get_player_state 查询。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'global_collection_id': <String, Object?>{'type': 'string', 'description': '歌单 ID'},
          },
          'required': <Object?>['global_collection_id'],
        },
        isMutating: true,
        group: kMcpGroupDiscovery,
        handler: (args) async {
          final gcId = requireString(args, 'global_collection_id');
          final data = await library.getPlaylistSongs(gcId, limit: 30);
          final songs = data?.songs ?? const <KugouSongDetail>[];
          if (songs.isEmpty) {
            return McpToolResult.error('歌单 $gcId 没有可播放的歌曲');
          }
          // 与 md3_play_song 同理：播放链路长（可达 60s+），必须立即返回，
          // 否则客户端超时重试会把队列重复整单覆盖。
          unawaited(control.playOnlinePlaylist(
              songs.map((s) => s.toSong()).toList(growable: false), 0));
          return McpToolResult(<String, Object?>{
            'playing': true,
            'queued': songs.length,
          });
        },
      ),
      McpTool(
        name: 'md3_get_daily_recommend',
        description: '获取每日推荐歌曲（需要登录）。返回 count 与歌曲投影列表。',
        inputSchema: _emptySchema,
        group: kMcpGroupDiscovery,
        handler: (args) async {
          final songs = await library.getDailyRecommend() ?? const <KugouSongDetail>[];
          if (songs.isEmpty) {
            return const McpToolResult.error('获取每日推荐失败（可能未登录）');
          }
          return McpToolResult(<String, Object?>{
            'count': songs.length,
            'items': songs.map(_projectSong).toList(growable: false),
          });
        },
      ),
      McpTool(
        name: 'md3_play_daily_recommend',
        description: '播放每日推荐歌曲（取前 30 首，从第一首开始）。立即返回，成败用 md3_get_player_state 查询。',
        inputSchema: _emptySchema,
        isMutating: true,
        group: kMcpGroupDiscovery,
        handler: (args) async {
          final songs = await library.getDailyRecommend() ?? const <KugouSongDetail>[];
          final playable = songs.take(30).toList(growable: false);
          if (playable.isEmpty) {
            return const McpToolResult.error('获取每日推荐失败（可能未登录）');
          }
          unawaited(control.playOnlinePlaylist(
              playable.map((s) => s.toSong()).toList(growable: false), 0));
          return McpToolResult(<String, Object?>{'playing': true, 'queued': playable.length});
        },
      ),
      McpTool(
        name: 'md3_play_personal_fm',
        description: '播放一轮私人 FM 歌曲（需要登录）。立即返回，成败用 md3_get_player_state 查询。',
        inputSchema: _emptySchema,
        isMutating: true,
        group: kMcpGroupDiscovery,
        handler: (args) async {
          final songs = await library.getPersonalFm() ?? const <KugouSongDetail>[];
          if (songs.isEmpty) {
            return const McpToolResult.error('私人 FM 返回为空（可能未登录）');
          }
          unawaited(control.playOnlinePlaylist(
              songs.map((s) => s.toSong()).toList(growable: false), 0));
          return McpToolResult(<String, Object?>{'playing': true, 'queued': songs.length});
        },
      ),
      McpTool(
        name: 'md3_get_toplist',
        description: '获取全部音乐榜单（TOPList），返回 id/name/song_count。id 可用于 md3_play_rank。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'limit': <String, Object?>{'type': 'integer', 'description': '返回条数，1-30，默认 20'},
          },
        },
        group: kMcpGroupDiscovery,
        handler: (args) async {
          final limit = optionalInt(args, 'limit', fallback: 20, min: 1, max: 30);
          final data = await library.getRankList();
          final ranks = (data?.ranks ?? const <KugouRank>[]).take(limit).toList(growable: false);
          return McpToolResult(<String, Object?>{
            'count': ranks.length,
            'items': ranks
                .map((r) => <String, Object?>{
                      'id': r.id,
                      'name': r.name,
                      'song_count': r.songCount,
                    })
                .toList(growable: false),
          });
        },
      ),
      McpTool(
        name: 'md3_play_rank',
        description: '播放指定榜单（rank_id 来自 md3_get_toplist），取前 30 首整单播放。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'rank_id': <String, Object?>{'type': 'string', 'description': '榜单 ID'},
            'limit': <String, Object?>{'type': 'integer', 'description': '取曲数，1-30，默认 30'},
          },
          'required': <Object?>['rank_id'],
        },
        isMutating: true,
        group: kMcpGroupDiscovery,
        handler: (args) async {
          final rankId = requireString(args, 'rank_id');
          final limit = optionalInt(args, 'limit', fallback: 30, min: 1, max: 30);
          final songs = await library.getRankAudio(rankId, limit: limit) ?? const [];
          if (songs.isEmpty) {
            return McpToolResult.error('榜单 $rankId 没有取到歌曲');
          }
          unawaited(control.playOnlinePlaylist(
              songs.map((s) => s.toSong()).toList(growable: false), 0));
          return McpToolResult(<String, Object?>{'playing': true, 'queued': songs.length});
        },
      ),
      McpTool(
        name: 'md3_get_listen_history',
        description: '读取听歌列表（最近播放）。上游响应结构未文档化：能识别时返回'
            '标准投影条目；识别不了时在 raw_truncated 返回截断原文（≤6000 字符）。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'limit': <String, Object?>{'type': 'integer', 'description': '返回条数，1-30，默认 10'},
          },
        },
        group: kMcpGroupDiscovery,
        handler: (args) async {
          final limit = optionalInt(args, 'limit', fallback: 10, min: 1, max: 30);
          final raw = await library.getUserListen();
          if (raw == null) return const McpToolResult.error('获取听歌列表失败（可能未登录）');
          final items = _extractListenEntries(raw).take(limit).toList(growable: false);
          final result = <String, Object?>{
            'count': items.length,
            'items': items,
          };
          if (items.isEmpty) {
            final rawText = raw.toString();
            result['raw_truncated'] = rawText.length <= 6000
                ? rawText
                : rawText.substring(0, 6000);
          }
          return McpToolResult(result);
        },
      ),
      McpTool(
        name: 'md3_get_lyric',
        description: '按歌曲 hash 取 LRC 歌词明文（带时间轴），最长 8000 字符。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'hash': <String, Object?>{'type': 'string', 'description': '歌曲 hash'},
          },
          'required': <Object?>['hash'],
        },
        group: kMcpGroupDiscovery,
        handler: (args) async {
          final hash = requireString(args, 'hash');
          final lyric = await library.getLyric(hash);
          if (lyric == null) return const McpToolResult.error('未找到该歌曲的歌词');
          final text = lyric.length > kMcpLyricMaxChars
              ? lyric.substring(0, kMcpLyricMaxChars)
              : lyric;
          return McpToolResult(<String, Object?>{
            'hash': hash,
            'truncated': text.length < lyric.length,
            'lyric': text,
          });
        },
      ),
      McpTool(
        name: 'md3_play_song',
        description: '按歌曲 hash 立即播放该歌曲（在线曲目会先解析播放链接）。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'hash': <String, Object?>{'type': 'string', 'description': '歌曲 hash'},
          },
          'required': <Object?>['hash'],
        },
        isMutating: true,
        handler: (args) async {
          final hash = requireString(args, 'hash');
          final detail = await library.getSongDetail(hash);
          if (detail == null) return McpToolResult.error('未找到 hash 为 $hash 的歌曲');
          final song = detail.toSong();
          // 播放是长链路（URL 解析 + flac 加载，实测可达 60s+）。若在工具调用里
          // await 到播放就绪，MCP 客户端会先超时并**重试同一调用**，导致正在播的
          // 歌被切回开头（实测复现）。因此这里只触发、立即返回，成败由
          // md3_get_player_state 查询。
          unawaited(control.playSong(song));
          return McpToolResult(<String, Object?>{
            'playing': true,
            'title': song.title,
            'artist': song.artist,
          });
        },
      ),
      McpTool(
        name: 'md3_play_keyword',
        description: '搜索关键词并立即播放最匹配的第一首歌。等价于先 md3_search_songs 再 md3_play_song。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'keyword': <String, Object?>{'type': 'string', 'description': '搜索关键词'},
          },
          'required': <Object?>['keyword'],
        },
        isMutating: true,
        handler: (args) async {
          final keyword = requireString(args, 'keyword');
          final songs = await library.searchSongs(keyword, limit: 1);
          if (songs.isEmpty) return McpToolResult.error('没有搜索到与「$keyword」匹配的歌曲');
          final song = songs.first.toSong();
          // 播放是长链路（URL 解析 + flac 加载，实测可达 60s+）。若在工具调用里
          // await 到播放就绪，MCP 客户端会先超时并**重试同一调用**，导致正在播的
          // 歌被切回开头（实测复现）。因此这里只触发、立即返回，成败由
          // md3_get_player_state 查询。
          unawaited(control.playSong(song));
          return McpToolResult(<String, Object?>{
            'playing': true,
            'title': song.title,
            'artist': song.artist,
            'hash': songs.first.hash,
          });
        },
      ),
      McpTool(
        name: 'md3_enqueue_song',
        description: '按歌曲 hash 把歌曲插入到当前曲目之后（不打断正在播放的歌）。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'hash': <String, Object?>{'type': 'string', 'description': '歌曲 hash'},
          },
          'required': <Object?>['hash'],
        },
        isMutating: true,
        handler: (args) async {
          final hash = requireString(args, 'hash');
          final detail = await library.getSongDetail(hash);
          if (detail == null) return McpToolResult.error('未找到 hash 为 $hash 的歌曲');
          final song = detail.toSong();
          await control.enqueue(song);
          return McpToolResult(<String, Object?>{
            'enqueued': true,
            'title': song.title,
            'artist': song.artist,
          });
        },
      ),
    ];

/// 本地曲库工具（依赖 [McpLocalLibrarySource] + [McpPlayerControl]）。
List<McpTool> buildLocalTools({
  required McpLocalLibrarySource local,
  required McpPlayerControl control,
}) =>
    <McpTool>[
      McpTool(
        name: 'md3_search_local_songs',
        description: '在手机本地曲库中搜索歌曲（按歌名/歌手），返回 id/title/artist/album/duration_ms。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'keyword': <String, Object?>{'type': 'string', 'description': '搜索关键词'},
            'limit': <String, Object?>{'type': 'integer', 'description': '返回条数，1-30，默认 10'},
          },
          'required': <Object?>['keyword'],
        },
        group: kMcpGroupDiscovery,
        handler: (args) async {
          final keyword = requireString(args, 'keyword');
          final limit = optionalInt(args, 'limit', fallback: 10, min: 1, max: 30);
          final songs = local.search(keyword, limit: limit);
          return McpToolResult(<String, Object?>{
            'keyword': keyword,
            'count': songs.length,
            'items': songs
                .map((s) => <String, Object?>{
                      'id': s.id,
                      'title': s.title,
                      'artist': s.artist,
                      'album': s.album,
                      'duration_ms': s.duration.inMilliseconds,
                      'is_online': false,
                    })
                .toList(growable: false),
          });
        },
      ),
      McpTool(
        name: 'md3_play_local_song',
        description: '播放本地曲库中指定 id 的歌曲（id 来自 md3_search_local_songs）。',
        inputSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'id': <String, Object?>{'type': 'string', 'description': '本地歌曲 id'},
          },
          'required': <Object?>['id'],
        },
        isMutating: true,
        group: kMcpGroupDiscovery,
        handler: (args) async {
          final id = requireString(args, 'id');
          final song = local.findById(id);
          if (song == null) return McpToolResult.error('本地曲库中没有 id 为 $id 的歌曲');
          await control.playSong(song);
          return McpToolResult(<String, Object?>{
            'playing': true,
            'title': song.title,
            'artist': song.artist,
          });
        },
      ),
    ];

/// 全部工具的装配入口（播放器工具 + 检索工具 + 可选本地曲库/曲库写/App 功能工具），
/// 供 `McpService` 注入注册表。条件装配：`localLibrary` / `libraryWrite` /
/// `appFeatures` 为 null 即对应组缺席。
List<McpTool> buildMcpTools({
  required McpPlayerControl control,
  required McpLibrarySource library,
  McpLocalLibrarySource? localLibrary,
  McpLibraryWriteSource? libraryWrite,
  McpAppFeaturesPort? appFeatures,
}) =>
    <McpTool>[
      ...buildPlayerTools(control),
      ...buildLibraryTools(library: library, control: control),
      if (localLibrary != null) ...buildLocalTools(local: localLibrary, control: control),
      if (libraryWrite != null)
        ...buildLibraryWriteTools(write: libraryWrite, library: library),
      if (appFeatures != null) ...buildAppFeaturesTools(appFeatures),
    ];
