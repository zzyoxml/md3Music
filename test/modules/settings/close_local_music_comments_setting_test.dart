import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/data/models/song.dart';
import 'package:md3music/data/repositories/settings_repository.dart';
import 'package:md3music/providers/player_provider.dart';

Song _song({required bool isOnline}) => Song(
  id: isOnline ? 'kugouhash' : '/sdcard/Music/a.flac',
  title: 't',
  artist: 'a',
  album: 'b',
  duration: const Duration(seconds: 10),
  isOnline: isOnline,
);

void main() {
  test('未设置过时默认开启（本地歌曲不显示评论入口）', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await SettingsRepository().getCloseLocalMusicComments(), isTrue);
  });

  test('写入后可读回', () async {
    SharedPreferences.setMockInitialValues({});
    final repo = SettingsRepository();
    await repo.setCloseLocalMusicComments(false);
    expect(await repo.getCloseLocalMusicComments(), isFalse);
  });

  testWidgets('showsCommentsFor：在线歌曲恒提供评论入口', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final player = PlayerProvider();
    try {
      expect(player.showsCommentsFor(_song(isOnline: true)), isTrue);
    } finally {
      player.dispose();
      await tester.pump(const Duration(seconds: 5));
    }
  });

  testWidgets('showsCommentsFor：本地歌曲默认不提供，关掉开关后提供', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final player = PlayerProvider();
    try {
      expect(player.showsCommentsFor(_song(isOnline: false)), isFalse);
      await player.setCloseLocalMusicComments(false);
      expect(player.showsCommentsFor(_song(isOnline: false)), isTrue);
    } finally {
      player.dispose();
      await tester.pump(const Duration(seconds: 5));
    }
  });
}
