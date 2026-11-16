import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'remote_storage_config.dart';

/// 远程存储配置仓库：元数据存 prefs，密码存 secure storage。
///
/// 密码不进入配置 JSON（见 [RemoteStorageConfig.toJson]），按 id 单独加密。
/// 播放器在同步函数 `_createAudioSource` 里取鉴权头，因此配置需有进程内缓存。
class RemoteStorageRepository {
  static const String _configsKey = 'remote_storage_configs';
  static const String _pwdPrefix = 'remote_storage_pwd_';

  /// 进程内配置缓存（含密码回填），CRUD 时刷新。
  /// 播放器同步取鉴权头用；App 重启后由 [getConfigs] 首次加载重建。
  static final Map<String, RemoteStorageConfig> _cache = {};

  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  /// 同步读取缓存中的配置（播放器取 Basic 头，不触发 IO）。
  /// 缓存未命中返回 null，调用方按"无鉴权"处理。
  static RemoteStorageConfig? peekConfig(String? id) {
    if (id == null) return null;
    return _cache[id];
  }

  /// 测试/诊断用：清空进程内缓存。
  static void clearCache() => _cache.clear();

  Future<List<RemoteStorageConfig>> getConfigs() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_configsKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      final result = <RemoteStorageConfig>[];
      for (final e in list) {
        final cfg = RemoteStorageConfig.fromJson(e as Map<String, dynamic>);
        // 回填加密密码
        final pwd = await _storage.read(key: _pwdPrefix + cfg.id);
        final withPwd = cfg.copyWith(password: pwd ?? '');
        result.add(withPwd);
        _cache[cfg.id] = withPwd;
      }
      return result;
    } catch (e) {
      return [];
    }
  }

  Future<void> saveConfig(RemoteStorageConfig cfg) async {
    final list = await getConfigs();
    final idx = list.indexWhere((c) => c.id == cfg.id);
    if (idx >= 0) {
      list[idx] = cfg;
    } else {
      list.add(cfg);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _configsKey,
      jsonEncode(list.map((c) => c.toJson()).toList()),
    );
    if (cfg.password.isNotEmpty) {
      await _storage.write(key: _pwdPrefix + cfg.id, value: cfg.password);
    }
    _cache[cfg.id] = cfg;
  }

  Future<void> deleteConfig(String id) async {
    final list = await getConfigs();
    list.removeWhere((c) => c.id == id);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _configsKey,
      jsonEncode(list.map((c) => c.toJson()).toList()),
    );
    await _storage.delete(key: _pwdPrefix + id);
    _cache.remove(id);
  }

  /// 生成唯一 id（简单时间戳 + 随机后缀，避免引入 uuid 依赖）。
  static String newId() =>
      'cfg${DateTime.now().millisecondsSinceEpoch}_${_rand4()}';

  static String _rand4() {
    final n = DateTime.now().microsecondsSinceEpoch % 100000;
    return n.toString().padLeft(5, '0');
  }
}