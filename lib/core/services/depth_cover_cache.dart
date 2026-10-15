import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 深度分层结果缓存：key → 3 层 PNG。目录结构 `<base>/<key>/layer{0,1,2}.png`。
/// 编排入口 [requestLayers]：命中直接回调；未命中且模型就绪时调用原生推理，
/// 结果经 [addListener] 通知（首次请求返回 false，UI 先展示平面封面）。
class DepthCoverCache {
  DepthCoverCache({
    this.baseDirOverride,
    this.maxEntries = 40,
  });

  final String? baseDirOverride;
  final int maxEntries;

  final List<String> _lru = []; // 最近使用在前
  final Set<String> _inFlight = {}; // 记账语义：仅「已成功完成」进缓存
  final Map<String, VoidCallback> _listeners = {};
  int _listenerSeq = 0;

  /// 层就绪通知：key → 可移除的取消函数。UI 挂监听等待异步生成完成。
  VoidCallback addListener(String key, VoidCallback onReady) {
    final id = _listenerSeq++;
    _listeners['$key#$id'] = onReady;
    return () => _listeners.remove('$key#$id');
  }

  static String cacheKey(String artworkUri) =>
      md5.convert(artworkUri.codeUnits).toString();

  Future<String> _baseDir() async {
    final override = baseDirOverride;
    if (override != null) return override;
    final base =
        await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
    return '${base.path}${Platform.pathSeparator}stream_cache'
        '${Platform.pathSeparator}depth_cover';
  }

  /// 只读：命中返回 [bg, mid, fg] 绝对路径，未命中 null。
  Future<List<String>?> getCachedLayers(String key) async {
    final dir = Directory(_join(await _baseDir(), key));
    final paths = [0, 1, 2].map((i) => _join(dir.path, 'layer$i.png')).toList();
    if (paths.every((s) => File(s).existsSync())) {
      _touch(key);
      return paths;
    }
    return null;
  }

  /// 编排：命中→立即回调；未命中→模型就绪则发起原生推理。
  /// 返回值仅表示「当前是否有现成结果」，不代表流程结束。
  Future<bool> requestLayers({
    required String artworkUri,
    required Future<List<String>?> Function(String sourcePath, String outDir, String key)
        generate, // 封装 MethodChannel 调用，由上层注入（可测）
    required Future<String?> Function(String uri) resolveSource,
  }) async {
    final key = cacheKey(artworkUri);
    if (await getCachedLayers(key) != null) {
      _notify(key);
      return true;
    }
    if (_inFlight.contains(key)) return false;
    _inFlight.add(key);
    try {
      final source = await resolveSource(artworkUri);
      if (source == null) return false;
      final outDir = _join(await _baseDir(), key);
      final layers = await generate(source, outDir, key);
      if (layers == null || layers.length != 3) return false;
      await recordLayers(key, layers);
      _notify(key);
      return true;
    } finally {
      _inFlight.remove(key); // 失败不记账，允许下次重试
    }
  }

  /// 编排深度图生成：命中→立即回调；未命中→模型就绪则走 [generate]。
  /// 返回值仅表示「当前是否有现成结果」，不代表流程结束。
  /// [generate] 返回 {'depth': 路径, 'depthStd': double}；[coverPath] 取自本次
  /// [resolveSource] 解析出的源文件路径，随结果写入 depth.meta 供 shader 取原图纹理。
  Future<bool> requestDepth({
    required String artworkUri,
    required Future<Map<String, Object?>?> Function(
            String sourcePath, String outDir, String key)
        generate,
    required Future<String?> Function(String uri) resolveSource,
  }) async {
    final key = cacheKey(artworkUri);
    if (await getCachedDepth(key) != null) {
      _notify(key);
      return true;
    }
    if (_inFlight.contains(key)) return false;
    _inFlight.add(key);
    try {
      final source = await resolveSource(artworkUri);
      if (source == null) return false;
      final outDir = _join(await _baseDir(), key);
      final res = await generate(source, outDir, key);
      if (res == null) return false;
      await recordDepth(
        key,
        res['depth'] as String,
        res['depthStd'] as double,
        source,
        bgFillPath: res['bgFill'] as String?,
        inpaintSource: res['inpaint'] as String?,
      );
      _notify(key);
      return true;
    } finally {
      _inFlight.remove(key); // 失败不记账，允许下次重试
    }
  }

  /// 返回并确保 `<base>/<key>/` 目录存在（供 service 把封面源落进去）。
  Future<String> ensureEntryDir(String key) async {
    final dir = Directory(_join(await _baseDir(), key));
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir.path;
  }

  /// 记录生成结果（供测试与编排复用）。
  Future<void> recordLayers(String key, List<String> paths) async {
    final dir = Directory(_join(await _baseDir(), key));
    await dir.create(recursive: true);
    for (final src in paths) {
      final dst = _join(dir.path, _basename(src));
      if (src == dst) continue;
      await File(src).copy(dst);
    }
    _touch(key);
    await _evict();
  }

  /// 只读：命中返回 {'depth': 路径, 'depthStd': double, 'cover': 封面源路径,
  /// 'bgFill': 修补背景路径（旧条目无此键）}，未命中 null。
  /// meta 为 JSON（dart:convert），同时记录封面源路径供 shader 纹理使用。
  Future<Map<String, Object?>?> getCachedDepth(String key) async {
    final dir = Directory(_join(await _baseDir(), key));
    final f = File(_join(dir.path, 'depth.png'));
    final meta = File(_join(dir.path, 'depth.meta'));
    if (!f.existsSync() || !meta.existsSync()) return null;
    final map = (jsonDecode(meta.readAsStringSync()) as Map).cast<String, Object?>();
    _touch(key);
    final bgFill = File(_join(dir.path, 'bg_fill.png'));
    return {
      'depth': f.path,
      'depthStd': map['depthStd'],
      'cover': map['cover'],
      if (bgFill.existsSync()) 'bgFill': bgFill.path,
      if (map['inpaint'] is String) 'inpaint': map['inpaint'],
    };
  }

  /// 记录深度图结果：PNG 拷入缓存目录，JSON meta 记录 std 与封面源路径（LRU 跟随现有机制）。
  /// [bgFillPath] 为可选的修补背景源路径，存在时拷贝为同目录 `bg_fill.png`
  /// （旧条目无该文件，getCachedDepth 不返回 bgFill 键，shader 走退化渲染）。
  /// [inpaintSource] 为修补来源标记（"migan"/"pushpull"），仅入 meta 供核对。
  Future<void> recordDepth(
      String key, String path, double depthStd, String coverPath,
      {String? bgFillPath, String? inpaintSource}) async {
    final dir = Directory(_join(await _baseDir(), key));
    await dir.create(recursive: true);
    final dst = File(_join(dir.path, 'depth.png'));
    if (path != dst.path) await File(path).copy(dst.path);
    if (bgFillPath != null) {
      final bgDst = File(_join(dir.path, 'bg_fill.png'));
      if (bgFillPath != bgDst.path) await File(bgFillPath).copy(bgDst.path);
    }
    File(_join(dir.path, 'depth.meta')).writeAsStringSync(jsonEncode({
      'depthStd': depthStd,
      'cover': coverPath,
      if (inpaintSource != null) 'inpaint': inpaintSource,
    }));
    _touch(key);
    await _evict();
  }

  void _touch(String key) {
    _lru.remove(key);
    _lru.insert(0, key);
  }

  Future<void> _evict() async {
    final base = await _baseDir();
    while (_lru.length > maxEntries) {
      final victim = _lru.removeLast();
      final dir = Directory(_join(base, victim));
      if (dir.existsSync()) await dir.delete(recursive: true);
    }
  }

  void _notify(String key) {
    for (final entry in _listeners.entries.toList()) {
      if (entry.key.startsWith('$key#')) entry.value();
    }
  }

  static String _join(String a, String b) =>
      '$a${Platform.pathSeparator}$b';

  static String _basename(String path) =>
      path.split(RegExp(r'[/\\]')).last;

  /// 深度图缓存目录总大小（字节；目录不存在返回 0）。
  /// 不含深度模型本体（模型是固定资产，见 DepthCoverService.modelPath）。
  Future<int> cacheSizeBytes() async {
    final dir = Directory(await _baseDir());
    if (!dir.existsSync()) return 0;
    var total = 0;
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File) total += e.lengthSync();
    }
    return total;
  }

  /// 清空深度图缓存：删除全部 key 子目录（各封面下次打开自动重新生成）。
  Future<void> clearCache() async {
    final dir = Directory(await _baseDir());
    if (!dir.existsSync()) return;
    await for (final e in dir.list()) {
      if (e is Directory) await e.delete(recursive: true);
    }
    _lru.clear();
    _inFlight.clear();
  }
}
