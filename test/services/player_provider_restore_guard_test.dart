import 'package:flutter_test/flutter_test.dart';

import '../../lib/data/models/song.dart';
import '../../lib/providers/player_provider.dart';

/// 外部歌曲恢复守卫测试。
///
/// 背景：外部调用歌曲的 localPath 指向私有缓存拷贝，缓存文件可能被清理。
/// 冷启动 _restoreState 恢复这类歌曲前必须校验文件存在，否则出现
/// 无法播放的「幽灵歌曲」（主页显示歌曲、点播放无声/报错）。
void main() {
  group('shouldSkipRestoredSong', () {
    test('外部歌曲文件缺失 → 跳过恢复', () {
      const song = Song(
        id: 'external_abc123',
        title: 't',
        artist: 'a',
        album: 'b',
        duration: Duration(seconds: 60),
        localPath: '/nonexistent_dir_md3music/x.mp3',
      );
      expect(shouldSkipRestoredSong(song), isTrue);
    });

    test('外部歌曲路径为空 → 跳过恢复', () {
      const song = Song(
        id: 'external_abc123',
        title: 't',
        artist: 'a',
        album: 'b',
        duration: Duration(seconds: 60),
      );
      expect(shouldSkipRestoredSong(song), isTrue);
    });

    test('在线歌曲永不跳过（URL 时效问题由既有逻辑处理）', () {
      const song = Song(
        id: 'external_abc123',
        title: 't',
        artist: 'a',
        album: 'b',
        duration: Duration(seconds: 60),
        isOnline: true,
      );
      expect(shouldSkipRestoredSong(song), isFalse);
    });

    test('普通本地歌曲保持既有行为（文件缺失也不跳过）', () {
      // 普通本地歌曲被用户删除是既有容忍场景（恢复后手动重选即可），
      // 守卫只针对外部歌曲，避免扩大行为变更面
      const song = Song(
        id: '12345',
        title: 't',
        artist: 'a',
        album: 'b',
        duration: Duration(seconds: 60),
        localPath: '/nonexistent_dir_md3music/y.mp3',
      );
      expect(shouldSkipRestoredSong(song), isFalse);
    });
  });
}