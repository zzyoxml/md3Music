import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/repositories/local_music_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 本地音乐「扫描文件夹 / 排除文件夹」的持久化回归。
///
/// **背景**：Windows 上用户反馈"不能像安卓一样持久化文件夹"。
/// 实查SharedPreferences 发现**其实存住了**：
/// `local_music_scan_folders = ['C:\Users\Administrator\Music']`。
/// 真正的缺口在 UI —— 「添加扫描文件夹」只有添加入口、没有列表，
/// 加完看不到加了哪些、也无法移除，于是"看不见"被当成"没存住"。
///
/// 本测试锁住持久化本身（防止将来被误改），UI 可见性由
/// `test/modules/library/` 侧的结构测试覆盖。
void main() {
  const winFolder = r'C:\Users\Administrator\Music';
  const winFolder2 = r'D:\Audio\Jazz';
  const androidFolder = '/storage/emulated/0/Music/md3Music';

  late LocalMusicRepository repo;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repo = LocalMusicRepository();
  });

  group('扫描文件夹持久化', () {
    test('未配置时返回空列表', () async {
      expect(await repo.getSavedFolders(), isEmpty);
    });

    test('添加后能读回（模拟重启：新 repository 实例读取同一存储）', () async {
      await repo.addFolder(winFolder);

      // 关键：换一个实例读取，模拟 App 重启后重新加载。
      // 若持久化真的失效，这里的 rebuilt 会是空的。
      final rebuilt = LocalMusicRepository();
      expect(await rebuilt.getSavedFolders(), [winFolder]);
    });

    test('多个文件夹全部保留', () async {
      await repo.addFolder(winFolder);
      await repo.addFolder(winFolder2);

      final rebuilt = LocalMusicRepository();
      expect(
        await rebuilt.getSavedFolders(),
        containsAll([winFolder, winFolder2]),
      );
    });

    test('重复添加同一路径不产生重复项', () async {
      await repo.addFolder(winFolder);
      await repo.addFolder(winFolder);

      expect(await repo.getSavedFolders(), [winFolder]);
    });

    test('Android 风格路径同样可持久化', () async {
      await repo.addFolder(androidFolder);
      final rebuilt = LocalMusicRepository();
      expect(await rebuilt.getSavedFolders(), [androidFolder]);
    });

    test('移除后不再读回', () async {
      await repo.addFolder(winFolder);
      await repo.addFolder(winFolder2);
      await repo.removeFolder(winFolder);

      final rebuilt = LocalMusicRepository();
      final folders = await rebuilt.getSavedFolders();
      expect(folders, isNot(contains(winFolder)));
      expect(folders, contains(winFolder2));
    });

    test('重新添加曾被移除的文件夹可恢复', () async {
      await repo.addFolder(winFolder);
      await repo.removeFolder(winFolder);
      await repo.addFolder(winFolder);

      expect(await repo.getSavedFolders(), [winFolder]);
    });
  });

  group('排除文件夹持久化', () {
    test('未配置时返回空列表', () async {
      expect(await repo.getExcludedFolders(), isEmpty);
    });

    test('添加后重启仍可读回', () async {
      await repo.addExcludedFolder(winFolder);

      final rebuilt = LocalMusicRepository();
      expect(await rebuilt.getExcludedFolders(), [winFolder]);
    });

    test('排除后添加同一路径为扫描目录会解除排除', () async {
      // 业务约定：重新添加为扫描目录意味着用户想扫它，
      // addFolder 内部会先 removeExcludedFolder。
      await repo.addExcludedFolder(winFolder);
      await repo.addFolder(winFolder);

      final rebuilt = LocalMusicRepository();
      expect(await rebuilt.getExcludedFolders(), isEmpty);
      expect(await rebuilt.getSavedFolders(), [winFolder]);
    });

    test('移除排除后不再读回', () async {
      await repo.addExcludedFolder(winFolder);
      await repo.removeExcludedFolder(winFolder);
      expect(await repo.getExcludedFolders(), isEmpty);
    });
  });

  group('排除判定跨平台', () {
    test('Windows 反斜杠路径命中排除', () {
      expect(
        LocalMusicRepository.isExcluded(r'C:\Music\recordings\a.mp3', [r'C:\Music\recordings']),
        isTrue,
      );
    });

    test('排除父目录时子文件也被排除', () {
      expect(
        LocalMusicRepository.isExcluded(
          r'C:\Music\recordings\voice\a.mp3',
          [r'C:\Music\recordings'],
        ),
        isTrue,
      );
    });

    test('Android 正斜杠路径命中排除', () {
      expect(
        LocalMusicRepository.isExcluded(
          '/storage/emulated/0/Recordings/a.mp3',
          ['/storage/emulated/0/Recordings'],
        ),
        isTrue,
      );
    });

    test('不在排除列表内则不过滤', () {
      expect(
        LocalMusicRepository.isExcluded(r'C:\Music\songs\a.mp3', [r'C:\Music\recordings']),
        isFalse,
      );
    });
  });
}