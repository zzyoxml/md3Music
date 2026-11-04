import 'package:md3music/data/models/song.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';

/// 循环模式占位名，对齐 `AppLoopMode.off.name`（见 providers/player_provider.dart）。
///
/// 这里刻意不导入 provider：本文件被工具层与测试共同引用，引入 provider 会把
/// audio_service / just_audio 的整条依赖链拖进纯逻辑层。
const String kDefaultLoopModeName = 'off';

/// 播放器状态快照（工具层唯一允许读取的播放器视图）。
///
/// 只暴露 AI 需要的字段，避免把 Song 的全部内部字段倒进上下文。
class McpPlayerSnapshot {
  const McpPlayerSnapshot({
    required this.song,
    required this.playing,
    required this.positionMs,
    required this.durationMs,
    required this.volume,
    required this.loopMode,
    required this.shuffle,
    required this.queueLength,
    required this.currentIndex,
  });

  factory McpPlayerSnapshot.empty() => McpPlayerSnapshot(
        song: null,
        playing: false,
        positionMs: 0,
        durationMs: 0,
        volume: 1.0,
        loopMode: kDefaultLoopModeName,
        shuffle: false,
        queueLength: 0,
        currentIndex: -1,
      );

  final Song? song;
  final bool playing;
  final int positionMs;
  final int durationMs;
  final double volume;
  final String loopMode;
  final bool shuffle;
  final int queueLength;
  final int currentIndex;

  /// 当前曲目 hash（在线曲目即 Song.id；本地曲目为 null）。
  String? get hash => (song?.isOnline ?? false) ? song?.id : null;

  /// 音质档位（如 128 / flac），无则 null。
  String? get quality => song?.quality;

  Map<String, Object?> toJson() => <String, Object?>{
        'title': song?.title,
        'artist': song?.artist,
        'album': song?.album,
        'hash': hash,
        'quality': quality,
        'playing': playing,
        'position_ms': positionMs,
        'duration_ms': durationMs,
        // 平台音量的浮点噪声（如 0.30000000000000004）没必要进模型上下文
        'volume': double.parse(volume.toStringAsFixed(2)),
        'loop_mode': loopMode,
        'shuffle': shuffle,
        'queue_length': queueLength,
        'current_index': currentIndex,
      };
}

/// 可等待的播放器事件。
enum McpWatchEvent { trackChange, play, pause }

/// 播放器控制端口。真实实现包装 PlayerProvider，测试用 FakePlayerControl。
abstract interface class McpPlayerControl {
  McpPlayerSnapshot snapshot();

  Future<void> resume();
  Future<void> pause();
  Future<void> next();
  Future<void> previous();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);

  /// 队列投影（每项含 index/title/artist/album），从当前曲目起最多 [limit] 条。
  List<Map<String, Object?>> queue({int limit = 20});

  /// 立即播放（真实实现里在线曲目走 playOnlineSong，本地曲目走 playSong）。
  Future<void> playSong(Song song);

  /// 插入到当前曲目之后。
  Future<void> enqueue(Song song);

  /// 设置循环模式（'off' | 'one' | 'all'，与快照 loop_mode 同名）。
  Future<void> setLoopMode(String mode);

  /// 设置随机播放。
  Future<void> setShuffle(bool enabled);

  /// 跳到队列第 [index] 首并播放。
  Future<void> playAt(int index);

  /// 移除队列第 [index] 首。
  Future<void> removeFromQueue(int index);

  /// 把第 [from] 首移动到第 [to] 的位置。
  Future<void> reorderQueue(int from, int to);

  /// 清空整个队列并停止播放。
  Future<void> clearQueue();

  /// 整单播放（在线歌单链路），从 [startIndex] 开始。
  Future<void> playOnlinePlaylist(List<Song> songs, int startIndex);

  /// 阻塞到事件发生或超时；发生返回事件描述（如 'track_changed'），超时返回 null。
  Future<String?> waitForEvent(McpWatchEvent event, Duration timeout);
}

/// 曲库检索端口。真实实现包装 KugouApiClient。
abstract interface class McpLibrarySource {
  Future<List<KugouSongDetail>> searchSongs(String keyword, {int limit = 10});

  /// 按 hash 取歌曲详情，用于 `md3_play_song` / `md3_enqueue_song`。
  Future<KugouSongDetail?> getSongDetail(String hash);

  /// 返回 LRC 明文；无歌词时返回 null。
  Future<String?> getLyric(String hash);

  /// 按关键词搜索专辑（limit 钳制由实现方负责）。
  Future<List<KugouAlbumBrief>?> searchAlbums(String keyword, {int limit = 10});

  /// 按关键词搜索歌手。
  Future<List<KugouArtistBrief>?> searchArtists(String keyword, {int limit = 10});

  /// 按关键词搜索歌单。
  Future<List<KugouPlaylistBrief>?> searchPlaylists(String keyword, {int limit = 10});

  /// 按歌单 global_collection_id 取第 1 页歌曲（最多 [limit] 首）。
  Future<KugouPlaylistSongs?> getPlaylistSongs(String globalCollectionId,
      {int limit = 30});

  /// 每日推荐歌曲。
  Future<List<KugouSongDetail>?> getDailyRecommend();

  /// 私人 FM 一轮歌曲。
  Future<List<KugouSongDetail>?> getPersonalFm();

  /// 全部榜单（TOPList）。
  Future<KugouRankList?> getRankList();

  /// 指定榜单内歌曲。
  Future<List<KugouSongDetail>?> getRankAudio(String rankId, {int limit = 30});

  /// 听歌列表原始响应（酷狗侧结构文档缺失，交由工具层做防御式投影）。
  Future<Map<String, dynamic>?> getUserListen({int type = 0});
}

/// 本地曲库端口（真实实现包装 LibraryProvider；测试用假源）。
abstract interface class McpLocalLibrarySource {
  List<Song> search(String keyword, {int limit = 10});

  /// 按 Song.id 精确查找（本地曲库内）。
  Song? findById(String id);
}

/// 曲库写操作端口（真实实现包装 [KugouApiClient] 既有的歌单写方法）。
///
/// 歌曲"收藏/取消收藏"上游酷狗不存在对应模块（Task 11 研究门控结论，
/// 见 `tmp/collect-research.md`），故本端口不设收藏成员。
/// `buildMcpTools` 的 `libraryWrite` 为 null 时整组工具缺席（条件装配）。
abstract interface class McpLibraryWriteSource {
  /// 把 [hash] 对应的歌曲加入 [listid] 歌单（listid 为歌单数字 ID）。
  ///
  /// 上游 data 契约为 `名称|hash|专辑id|mixsongid`，歌名/专辑信息由实现方
  /// 经歌曲详情补齐；detail 拿不到或上游拒绝时抛异常（工具层转为可读错误）。
  Future<void> addSongToPlaylist(String hash, String listid);

  /// 新建名为 [name] 的歌单（需要登录）。
  Future<void> createPlaylist(String name);
}

/// App 功能快照（睡眠定时/均衡器/桌面歌词/输出模式）。
class McpAppFeaturesSnapshot {
  const McpAppFeaturesSnapshot({
    required this.sleepTimerMode,
    required this.sleepTimerRemainingMs,
    required this.eqEnabled,
    required this.eqPresets,
    required this.desktopLyricEnabled,
    required this.outputMode,
    required this.usbDeviceAvailable,
  });

  /// off | countdown | end_of_track
  final String sleepTimerMode;
  final int? sleepTimerRemainingMs;
  final bool eqEnabled;

  /// 可用预设名（系统 + 自定义）。
  final List<String> eqPresets;
  final bool desktopLyricEnabled;

  /// usbdevfs | direct_pcm | system（只读，MCP 不提供切换）。
  final String outputMode;
  final bool usbDeviceAvailable;

  Map<String, Object?> toJson() => <String, Object?>{
        'sleep_timer': <String, Object?>{
          'mode': sleepTimerMode,
          'remaining_ms': sleepTimerRemainingMs,
        },
        'eq': <String, Object?>{
          'enabled': eqEnabled,
          'presets': eqPresets,
        },
        'desktop_lyric_enabled': desktopLyricEnabled,
        'output_mode': outputMode,
        'usb_device_available': usbDeviceAvailable,
      };
}

/// App 功能控制端口（真实实现见 mcp_app_features.dart）。
abstract interface class McpAppFeaturesPort {
  McpAppFeaturesSnapshot snapshot();

  /// [duration] 为 null 表示取消（对齐 PlayerProvider.setSleepTimer）。
  Future<void> setSleepTimer(Duration? duration);
  Future<void> setEqEnabled(bool enabled);
  Future<void> applyEqPreset(String name);
  Future<void> setDesktopLyric(bool enabled);
}
