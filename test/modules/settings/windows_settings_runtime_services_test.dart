import 'dart:io';
import 'package:flutter/services.dart' as services;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/data/repositories/settings_repository.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/modules/mcp/mcp_ports.dart';
import 'package:md3music/modules/mcp/mcp_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../support/controlled_audio_service.dart';

class _NoopPlayerControl implements McpPlayerControl {
  @override
  McpPlayerSnapshot snapshot() => McpPlayerSnapshot.empty();

  @override
  Future<void> resume() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> next() async {}

  @override
  Future<void> previous() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> playSong(Song song) async {}

  @override
  Future<void> enqueue(Song song) async {}

  @override
  Future<void> setLoopMode(String mode) async {}

  @override
  Future<void> setShuffle(bool enabled) async {}

  @override
  Future<void> playAt(int index) async {}

  @override
  Future<void> removeFromQueue(int index) async {}

  @override
  Future<void> reorderQueue(int from, int to) async {}

  @override
  Future<void> clearQueue() async {}

  @override
  Future<void> playOnlinePlaylist(List<Song> songs, int startIndex) async {}

  @override
  Future<String?> waitForEvent(McpWatchEvent event, Duration timeout) async =>
      null;

  @override
  List<Map<String, Object?>> queue({int limit = 20}) =>
      const <Map<String, Object?>>[];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('Windows 重置刷新播放偏好但不重新播放或移动进度', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const services.MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (call) async => call.method == 'check' ? <String>['wifi'] : null,
    );
    messenger.setMockStreamHandler(
      const services.EventChannel(
        'dev.fluttercommunity.plus/connectivity_status',
      ),
      MockStreamHandler.inline(
        onListen: (_, events) => events.success(<String>['wifi']),
      ),
    );
    final repo = SettingsRepository();
    await repo.setMvAudioFallbackEnabled(true);
    await repo.setCloseLocalMusicComments(false);
    await repo.setCrossfadeEnabled(true);
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final player = PlayerProvider();
    try {
      await player.audioReady.timeout(const Duration(seconds: 10));
      await player.setMvAudioFallbackEnabled(true);
      await player.setCloseLocalMusicComments(false);
      await player.refreshCrossfadeSettings();
      await player.setVolume(0.3);
      expect(player.mvAudioFallbackEnabled, isTrue);
      expect(player.closeLocalMusicComments, isFalse);
      expect(player.crossfadeEnabled, isTrue);
      final commands = (
        audio.playCommandCount,
        audio.pauseCommandCount,
        audio.seekCount,
      );
      await repo.resetAllSettingsToDefaults();
      await player.reloadWindowsSettings();
      expect(
        player.mvAudioFallbackEnabled,
        await repo.getMvAudioFallbackEnabled(),
      );
      expect(
        player.closeLocalMusicComments,
        await repo.getCloseLocalMusicComments(),
      );
      expect(player.crossfadeEnabled, await repo.getCrossfadeEnabled());
      expect(player.volume, 1.0);
      expect((
        audio.playCommandCount,
        audio.pauseCommandCount,
        audio.seekCount,
      ), commands);
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  }, skip: !Platform.isWindows);

  test('Windows 重置同时关闭 MCP 服务并刷新设置页面使用的配置', () async {
    final repo = SettingsRepository();
    await repo.setMcpPort(0);
    await repo.setMcpEnabled(true);
    final service = McpService(playerControl: _NoopPlayerControl());
    try {
      await service.settingsReady;
      expect(service.isRunning, isTrue);
      await repo.resetAllSettingsToDefaults();
      await service.reloadWindowsSettings();
      expect(service.isRunning, isFalse);
      expect(service.settings!.enabled, isFalse);
      expect(service.settings!.port, await repo.getMcpPort());
      expect(service.endpointUrl, isEmpty);
    } finally {
      await service.dispose();
    }
  }, skip: !Platform.isWindows);
}
