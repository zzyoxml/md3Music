import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一起听听众起播闸门（PlayerProvider._roomGuestPlayGate）的行为测试。
///
/// 关键不变量：
///  - 未注册钩子 / 同步判定 false → 走同步快路径，**不调用**异步确认钩子；
///  - 确认钩子返回 false → 本次起播被完整拦下（播放态一字未改）；
///  - playSong 委派 playOnlineSong 时**只确认一次**（不得双重弹窗）。
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

  const onlineSong = Song(
    id: 'HASH1',
    title: '在线歌',
    artist: '歌手',
    album: '',
    duration: Duration(seconds: 60),
    isOnline: true,
  );

  testWidgets('未注册钩子 → 直通，正常起播', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final player = PlayerProvider();
    try {
      await player.playPlaylist(makeSongs(3), 1);
      expect(player.currentSong?.id, 's1');
    } finally {
      player.dispose();
      await tester.pump(const Duration(seconds: 5));
    }
  });

  testWidgets('同步判定 false → 不调用异步确认，直通', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final player = PlayerProvider();
    var confirmCalls = 0;
    player.shouldConfirmRoomGuestPlay = (_) => false;
    player.onRoomGuestPlayConfirm = (_) async {
      confirmCalls++;
      return false;
    };
    try {
      await player.playPlaylist(makeSongs(3), 0);
      expect(confirmCalls, 0, reason: '同步判定为 false 时不得进入弹窗');
      expect(player.currentSong?.id, 's0');
    } finally {
      player.dispose();
      await tester.pump(const Duration(seconds: 5));
    }
  });

  testWidgets('同步判定 true + 确认返回 true → 正常起播', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final player = PlayerProvider();
    var confirmCalls = 0;
    player.shouldConfirmRoomGuestPlay = (_) => true;
    player.onRoomGuestPlayConfirm = (_) async {
      confirmCalls++;
      return true;
    };
    try {
      await player.playPlaylist(makeSongs(3), 1);
      expect(confirmCalls, 1);
      expect(player.currentSong?.id, 's1');
    } finally {
      player.dispose();
      await tester.pump(const Duration(seconds: 5));
    }
  });

  testWidgets('确认返回 false → 起播被完整拦下，播放态一字未改', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final player = PlayerProvider();
    final beforeSong = player.currentSong;
    final beforeList = player.playlist.map((s) => s.id).toList();
    player.shouldConfirmRoomGuestPlay = (_) => true;
    player.onRoomGuestPlayConfirm = (_) async => false;
    try {
      await player.playPlaylist(makeSongs(3), 1);
      expect(player.currentSong, same(beforeSong), reason: '取消后不得改动当前歌');
      expect(
        player.playlist.map((s) => s.id).toList(),
        beforeList,
        reason: '取消后不得加载歌单',
      );
    } finally {
      player.dispose();
      await tester.pump(const Duration(seconds: 5));
    }
  });

  testWidgets('取消一次后仍能正常起播（闸门不粘滞）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final player = PlayerProvider();
    final beforeSong = player.currentSong;
    var allow = false;
    player.shouldConfirmRoomGuestPlay = (_) => true;
    player.onRoomGuestPlayConfirm = (_) async => allow;
    try {
      await player.playPlaylist(makeSongs(3), 0);
      expect(player.currentSong, same(beforeSong), reason: '首次取消不得起播');
      allow = true;
      await player.playPlaylist(makeSongs(3), 2);
      expect(player.currentSong?.id, 's2', reason: '用户点「脱离/直接播放」后必须能起播');
    } finally {
      player.dispose();
      await tester.pump(const Duration(seconds: 5));
    }
  });

  testWidgets('playSong 委派 playOnlineSong 时只确认一次', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final player = PlayerProvider();
    var shouldCalls = 0;
    var confirmCalls = 0;
    player.shouldConfirmRoomGuestPlay = (_) {
      shouldCalls++;
      return true;
    };
    player.onRoomGuestPlayConfirm = (_) async {
      confirmCalls++;
      return true;
    };
    try {
      // 本用例只校验闸门记账：两个判定都必须发生在任何网络/平台调用之前，
      // 因此即便 playOnlineSong 因未登录（或测试环境缺平台实现）提前返回，
      // 计数结论依然成立。网络层异常与本次断言无关，吞掉即可。
      try {
        await player.playSong(onlineSong);
      } catch (_) {}
      expect(shouldCalls, 1, reason: 'playSong → playOnlineSong 不得重复判定');
      expect(confirmCalls, 1, reason: 'playSong → playOnlineSong 不得重复弹窗');
    } finally {
      player.dispose();
      await tester.pump(const Duration(seconds: 5));
    }
  });
}
