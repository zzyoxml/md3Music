import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/data/repositories/local_music_repository.dart';
import 'package:md3music/providers/library_provider.dart';

class _ScanRepository extends LocalMusicRepository {
  final result = Completer<List<Song>>();
  int calls = 0;
  @override
  Future<List<Song>> scanSongs({List<String>? customFolders, List<String>? excludedFolders}) {
    calls++;
    return result.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('重复点击扫描不会启动第二次任务，失败后退出扫描态并可重试', () async {
    final repo = _ScanRepository();
    final provider = LibraryProvider(repository: repo);
    final first = provider.loadLocalMusic();
    await provider.loadLocalMusic();
    for (var i = 0; i < 20 && repo.calls == 0; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(repo.calls, 1);
    expect(provider.isScanning, isTrue);
    repo.result.completeError(StateError('bad scan fixture'));
    await first;
    expect(provider.isScanning, isFalse);
    expect(provider.error, contains('bad scan fixture'));
    await provider.loadLocalMusic();
    expect(repo.calls, 2);
    provider.dispose();
  });
}
