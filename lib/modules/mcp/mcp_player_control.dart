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
  Future<void> resume() => _player.resume();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> next() => _player.next();

  @override
  Future<void> previous() => _player.previous();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setVolume(double volume) =>
      _player.setVolume(volume.clamp(0.0, 1.0));

  @override
  Future<void> playSong(Song song) =>
      song.isOnline ? _player.playOnlineSong(song) : _player.playSong(song);

  @override
  Future<void> enqueue(Song song) => _player.insertAfterCurrent(<Song>[song]);

  @override
  Future<void> setLoopMode(String mode) {
    final AppLoopMode m = switch (mode) {
      'one' => AppLoopMode.one,
      'all' => AppLoopMode.all,
      _ => AppLoopMode.off,
    };
    return _player.setLoopMode(m);
  }

  @override
  Future<void> setShuffle(bool enabled) => _player.setShuffle(enabled);

  @override
  Future<void> playAt(int index) => _player.playSongAt(index);

  @override
  Future<void> removeFromQueue(int index) => _player.removeFromPlaylist(index);

  @override
  Future<void> reorderQueue(int from, int to) =>
      _player.reorderPlaylist(from, to);

  @override
  Future<void> clearQueue() => _player.clearPlaylist();

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
