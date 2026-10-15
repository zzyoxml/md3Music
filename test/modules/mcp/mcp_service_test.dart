import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/modules/mcp/mcp_ports.dart';
import 'package:md3music/modules/mcp/mcp_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 什么都不做的播放器端口实现：用于验证 service 自身的启停语义。
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

  test('默认配置下不启动、不监听端口', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 令牌已迁移到 secure storage，测试需注入 mock 平台实现
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    final service = McpService(playerControl: _NoopPlayerControl());
    // 让构造函数里的异步 _autoStart 跑完
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(service.status, McpStatus.stopped);
    expect(service.port, 0);
    expect(service.isRunning, isFalse);
    expect(service.endpointUrl, isEmpty);
    // 未启用时也不应该有任何调用日志
    expect(service.log, isEmpty);
    await service.dispose();
  });

  test('显式启用后才监听端口', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'settings_mcp_enabled': true,
      'settings_mcp_port': 0, // 0 = 让系统分配，避免测试环境端口冲突
    });
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    final service = McpService(playerControl: _NoopPlayerControl());
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(service.status, McpStatus.running);
    expect(service.isRunning, isTrue);
    expect(service.port, greaterThan(0));
    expect(service.endpointUrl, contains('/mcp'));
    await service.dispose();
  });

  test('关停后端端口释放且回到 stopped', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'settings_mcp_enabled': true,
      'settings_mcp_port': 0,
    });
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    final service = McpService(playerControl: _NoopPlayerControl());
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(service.status, McpStatus.running);

    await service.stop();
    expect(service.status, McpStatus.stopped);
    expect(service.port, 0);
    expect(service.endpointUrl, isEmpty);
    await service.dispose();
  });

  test('update 关闭开关会停服', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'settings_mcp_enabled': true,
      'settings_mcp_port': 0,
    });
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    final service = McpService(playerControl: _NoopPlayerControl());
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(service.isRunning, isTrue);

    final current = service.settings!;
    await service.update(current.copyWith(enabled: false));
    expect(service.status, McpStatus.stopped);
    expect(service.port, 0);
    await service.dispose();
  });
}
