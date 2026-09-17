import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../lib/data/models/song.dart';
import '../../lib/providers/player_provider.dart';

/// 歌单加载时的随机播放顺序测试。
///
/// Bug: 播放页开启随机播放后，歌单点击一首歌，播放列表仍是顺序播放。
/// 修复：playPlaylist/playOnlinePlaylist/playCloudPlaylist 加载歌单时按
/// _shuffleEnabled 打乱（点击曲目保持首曲，其余随机），关闭随机时原顺序。
void main() {
  List<Song> makeSongs(int n) => List.generate(
    n,
    (i) => Song(
      id: 's$i',
      title: 'song $i',
      artist: 'artist',
      album: 'album',
      duration: const Duration(seconds: 60),
    ),
  );

  testWidgets('随机播放开启时加载歌单：点击曲目保持首曲、其余打乱', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final player = PlayerProvider();
    try {
      await player.toggleShuffle(); // 开启随机播放

      final songs = makeSongs(10);
      await player.playPlaylist(songs, 3); // 点击第 4 首

      expect(player.currentSong?.id, 's3', reason: '应播放点击的歌曲');
      expect(player.currentIndex, 0, reason: '随机开启时点击曲目放首位，索引归 0');
      expect(player.playlist.first.id, 's3', reason: '播放列表首曲应是点击的歌曲');
      // 播放列表包含原歌单的全部歌曲（排列）
      expect(
        player.playlist.map((s) => s.id).toSet(),
        songs.map((s) => s.id).toSet(),
        reason: '随机开启时播放列表是原歌单的排列，不能丢歌',
      );
    } finally {
      player.dispose();
      await tester.pump(const Duration(seconds: 5));
    }
  });

  testWidgets('随机播放关闭时加载歌单：按原顺序播放', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final player = PlayerProvider();
    try {
      final songs = makeSongs(10);
      await player.playPlaylist(songs, 3);

      expect(player.currentSong?.id, 's3', reason: '应播放点击的歌曲');
      expect(player.currentIndex, 3, reason: '随机关闭时索引保持点击位置');
      expect(
        player.playlist.map((s) => s.id).toList(),
        songs.map((s) => s.id).toList(),
        reason: '随机关闭时播放列表保持原顺序',
      );
    } finally {
      player.dispose();
      await tester.pump(const Duration(seconds: 5));
    }
  });
}
