import 'package:md3music/data/models/song.dart';
import 'package:md3music/modules/mcp/mcp_ports.dart';
import 'package:md3music/providers/player_provider.dart';

/// [McpPlayerControl] 的真实实现：全部调用都转发给 [PlayerProvider]。
///
/// 位置/播放态一律取 `platformPosition` / `platformIsPlaying`（平台真实值），
/// 不用 `_position` / `isPlaying` 这两个乐观缓存（项目铁律 19 / 28）。
class PlayerProviderBackedControl implements McpPlayerControl {
  PlayerProviderBackedControl(this._player);

  final PlayerProvider _player;

  /// 控制命令的兜底超时。PlayerProvider 的 pause/resume/next 等内部有
  /// 「await 平台 ready」的分支：冷启动恢复播放卡住时会陷入 15s 一轮的
  /// 加载重试风暴（Windows 实测），这些 await 无限挂起会把 MCP HTTP 请求
  /// 一起拖死、殃及后续所有工具调用。用户意图（乐观态、取消在途请求）在
  /// 命令开头已同步下发，风暴期间超时返回不改变意图本身——实际状态由
  /// md3_get_player_state 如实查询。
  static const Duration _controlTimeout = Duration(seconds: 5);

  /// 带超时转发；超时静默成功（意图已下发），防风暴拖垮传输层。
  static Future<void> _withControlTimeout(
    Future<void> Function() command, {
      Duration timeout = _controlTimeout,
    }) async {
    await command().timeout(timeout, onTimeout: () {});
  }

  @override
  McpPlayerSnapshot snapshot() {
    final song = _player.currentSong;
    return McpPlayerSnapshot(
      song: song,
      playing: _player.platformIsPlaying,
      positionMs: _player.platformPosition.inMilliseconds,
      durationMs: song?.duration.inMilliseconds ?? 0,
      volume: _player.volume,
      loopMode: _player.loopMode.name,
      shuffle: _player.shuffleEnabled,
      queueLength: _player.playlist.length,
      currentIndex: _player.currentIndex,
    );
  }

  @override
  List<Map<String, Object?>> queue({int limit = 20}) {
    final list = _player.playlist;
    final start = _player.currentIndex < 0 ? 0 : _player.currentIndex;
    final end = (start + limit).clamp(0, list.length);
    final out = <Map<String, Object?>>[];
    for (var i = start; i < end; i++) {
      out.add(<String, Object?>{
        'index': i,
        'title': list[i].title,
        'artist': list[i].artist,
        'album': list[i].album,
      });
    }
    return out;
  }

  @override
  Future<void> resume() => _withControlTimeout(() => _player.resume());

  @override
  Future<void> pause() => _withControlTimeout(() => _player.pause());

  @override
  Future<void> next() => _withControlTimeout(() => _player.next());

  @override
  Future<void> previous() => _withControlTimeout(() => _player.previous());

  @override
  Future<void> seek(Duration position) =>
      _withControlTimeout(() => _player.seek(position));

  @override
  Future<void> setVolume(double volume) => _withControlTimeout(
      () => _player.setVolume(volume.clamp(0.0, 1.0)));

  // playSong / playOnlinePlaylist 不套超时：工具层对它们本来就是 unawaited
  // 触发（长链路立即返回），不阻塞 HTTP；这里 await 的是入队/落盘等快操作。
  @override
  Future<void> playSong(Song song) =>
      song.isOnline ? _player.playOnlineSong(song) : _player.playSong(song);

  @override
  Future<void> enqueue(Song song) =>
      _withControlTimeout(() => _player.insertAfterCurrent(<Song>[song]));

  @override
  Future<void> setLoopMode(String mode) {
    final AppLoopMode m = switch (mode) {
      'one' => AppLoopMode.one,
      'all' => AppLoopMode.all,
      _ => AppLoopMode.off,
    };
    return _withControlTimeout(() => _player.setLoopMode(m));
  }

  @override
  Future<void> setShuffle(bool enabled) =>
      _withControlTimeout(() => _player.setShuffle(enabled));

  @override
  Future<void> playAt(int index) =>
      _withControlTimeout(() => _player.playSongAt(index));

  @override
  Future<void> removeFromQueue(int index) =>
      _withControlTimeout(() => _player.removeFromPlaylist(index));

  @override
  Future<void> reorderQueue(int from, int to) =>
      _withControlTimeout(() => _player.reorderPlaylist(from, to));

  @override
  Future<void> clearQueue() => _withControlTimeout(_player.clearPlaylist);

  @override
  Future<void> playOnlinePlaylist(List<Song> songs, int startIndex) =>
      _player.playOnlinePlaylist(songs, startIndex);

  @override
  Future<String?> waitForEvent(McpWatchEvent event, Duration timeout) async {
    final base = snapshot();
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final now = snapshot();
      switch (event) {
        case McpWatchEvent.trackChange:
          if (now.song?.id != base.song?.id) return 'track_changed';
        case McpWatchEvent.play:
          if (!base.playing && now.playing) return 'playback_started';
        case McpWatchEvent.pause:
          if (base.playing && !now.playing) return 'playback_paused';
      }
    }
    return null;
  }
}
