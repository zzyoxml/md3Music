import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../core/services/depth_cover_cache.dart';
import '../data/repositories/settings_repository.dart';

/// 3D 封面总编排：模型导入 + 缓存 + 原生通道。全局单例。
///
/// 深度模型由用户通过文件选择器导入（设置页入口，sha256 校验后落盘到应用目录）；
/// 原生 [DepthCoverPlugin] 的 loadModel 按路径建立会话；调用前仍需先 loadModel，
/// 否则返回 `MODEL_NOT_LOADED`。失败的生成会被 [DepthCoverCache] 视为未命中，
/// UI 回退平面封面。
class DepthCoverService {
  DepthCoverService._();

  static final instance = DepthCoverService._();

  final cache = DepthCoverCache();

  /// 3D 封面总开关的统一状态源：设置页 / 两播放页界面设置弹层写入，
  /// DepthCoverHost 监听（值变化即重走初始化，开关即时生效）。
  /// 初始 false，由各 UI 首次加载时写入真实值。
  static final ValueNotifier<bool> enabledSignal = ValueNotifier(false);

  static const _channel = MethodChannel('com.md3music.md3music/depth_cover');

  /// 内置模型的资产路径（未导入用户模型时的兜底，原生自动从 APK 提取）。
  static const String _modelAsset = 'models/depth_anything_v2_vits_q4f16.onnx';

  /// 原生侧是否已 loadModel（仅当前进程会话有效）。
  bool _modelLoaded = false;

  /// 神经修补（MI-GAN）会话是否已加载（进程内一次；开关开启时才加载）。
  bool _inpaintLoaded = false;

  /// 历史版本遗留的模型文件名（取消导入功能后为孤儿文件，加载时顺带清理）。
  static const List<String> _legacyModelFileNames = [
    'depth_anything_v2_vits.onnx',        // fp32 导入版（取消导入前）
    'depth_anything_v2_vits_fp16.onnx',   // fp16 内置版（q4f16 之前）
  ];

  /// 原生 Toast 提示（3D 封面降级告知用户）。standard 包无该插件 → 静默忽略。
  Future<void> showNativeToast(String message) async {
    try {
      await _channel.invokeMethod<void>('showToast', {'message': message});
    } on PlatformException {
      // 忽略：通道未注册或原生侧异常都不应影响主流程
    } on MissingPluginException {
      // standard 包无 DepthCoverPlugin 属正常
    }
  }

  /// 模型加载失败的进程级一次性提示（避免每首歌都弹）。
  static bool _loadFailureToastShown = false;
  void _notifyLoadFailureOnce() {
    if (_loadFailureToastShown) return;
    _loadFailureToastShown = true;
    // ignore: discarded_futures
    showNativeToast('3D 封面模型初始化失败');
  }


  /// 每次封面变化时调用：命中/生成完成都会触发 cache 监听回调。
  ///
  /// 返回 false 仅表示「当前无现成结果」，不代表流程结束（未命中时 UI 先展示平面封面，
  /// 等原生生成后经缓存监听切换为 3D）。
  Future<bool> request(String artworkUri) async {
    debugPrint('[DepthCover] request: uri=${_brief(artworkUri)}');
    if (!_modelLoaded) {
      final loaded = await _ensureNativeModelLoaded();
      debugPrint('[DepthCover] native loadModel → $loaded');
      if (!loaded) return false;
    }
    final ok = await cache.requestLayers(
      artworkUri: artworkUri,
      generate: _generate,
      resolveSource: _resolveSource,
    );
    debugPrint('[DepthCover] requestLayers → $ok');
    return ok;
  }

  /// shader 路径编排：生成单张深度图；封面源同时落缓存目录（shader 需要原图纹理）。
  Future<bool> requestDepth(String artworkUri) async {
    debugPrint('[DepthCover] requestDepth: uri=${_brief(artworkUri)}');
    if (!_modelLoaded) {
      final loaded = await _ensureNativeModelLoaded();
      debugPrint('[DepthCover] native loadModel → $loaded');
      if (!loaded) return false;
    }
    // 神经修补会话：开关开启时才加载（失败静默 → 纯 Phase A 行为）
    await _ensureInpaintSession();
    final ok = await cache.requestDepth(
      artworkUri: artworkUri,
      generate: _generateDepth,
      resolveSource: _resolveSourceAndKeep,
    );
    debugPrint('[DepthCover] requestDepth → $ok');
    return ok;
  }

  /// 神经修补（MI-GAN）会话懒加载：进程内一次；开关关闭则跳过（无内存开销）。
  Future<void> _ensureInpaintSession() async {
    if (_inpaintLoaded) return;
    final enabled = await SettingsRepository().getDepthCoverNeuralInpaint();
    if (!enabled) return;
    try {
      final ok = await _channel.invokeMethod<bool>('loadInpaintModel');
      _inpaintLoaded = ok == true;
      debugPrint('[DepthCover] loadInpaintModel → $_inpaintLoaded');
    } on PlatformException catch (e) {
      debugPrint('[DepthCover] loadInpaintModel failed: ${e.code} ${e.message}');
    } on MissingPluginException catch (_) {
      // standard 包无 DepthCoverPlugin 属正常
    }
  }

  Future<Map<String, Object?>?> _generateDepth(
    String sourcePath,
    String outDir,
    String key,
  ) async {
    try {
      final res = await _channel.invokeMethod<Map<Object?, Object?>>(
        'generateDepth',
        {'sourcePath': sourcePath, 'outDir': outDir, 'key': key},
      );
      if (res == null) {
        debugPrint('[DepthCover] generateDepth → null（同 key 在途）');
        return null;
      }
      final depth = res['depth'];
      final std = res['depthStd'];
      final bgFill = res['bgFill'];
      final inpaint = res['inpaint'];
      if (depth is String && std is double) {
        return {
          'depth': depth,
          'depthStd': std,
          if (bgFill is String) 'bgFill': bgFill,
          if (inpaint is String) 'inpaint': inpaint,
        };
      }
      return null;
    } on PlatformException catch (e) {
      debugPrint('[DepthCover] generateDepth failed: ${e.code} ${e.message}');
      return null;
    }
  }

  static String _brief(String uri) =>
      uri.length <= 48 ? uri : '${uri.substring(0, 48)}…';

  /// 先查原生是否已在加载，未加载则先 loadModel（计划遗漏的一环）。
  Future<bool> _ensureNativeModelLoaded() async {
    try {
      final loaded =
          await _channel.invokeMethod<bool>('isModelLoaded');
      if (loaded == true) {
        _modelLoaded = true;
        return true;
      }
      // 优先用用户导入的模型；未导入则用 APK 内置资产（原生自动提取）。
      // 防御：预建模型目录（原生侧提取前也会 mkdirs，双保险；
      // 历史 bug：全新安装该目录不存在 → 提取抛 ENOENT → 3D 永久不可用）。
      final modelDir =
          Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}depth_model');
      try {
        await modelDir.create(recursive: true);
      } catch (e) {
        debugPrint('[DepthCover] 预建模型目录失败: $e');
      }
      // 清理取消导入功能前的历史遗留模型文件（fp32/fp16 旧名，最多 ~149MB）
      for (final name in _legacyModelFileNames) {
        final legacy = File('${modelDir.path}${Platform.pathSeparator}$name');
        if (legacy.existsSync()) {
          try {
            await legacy.delete();
            debugPrint('[DepthCover] 已清理历史遗留模型: ${legacy.path}');
          } catch (_) {}
        }
      }
      final ok = await _channel.invokeMethod<bool>(
        'loadModel',
        {'modelAsset': _modelAsset},
      );
      if (ok == true) {
        _modelLoaded = true;
        return true;
      }
      _notifyLoadFailureOnce();
    } on PlatformException catch (e) {
      debugPrint('[DepthCover] loadModel/isModelLoaded failed: ${e.code} ${e.message}');
      _notifyLoadFailureOnce();
      return false;
    } on MissingPluginException catch (e) {
      // standard 包无 DepthCoverPlugin（通道未注册）走这里；depth3d 包不应出现。
      debugPrint('[DepthCover] 通道未注册（standard 包属正常）: $e');
      return false;
    }
    return false;
  }

  Future<List<String>?> _generate(
    String sourcePath,
    String outDir,
    String key,
  ) async {
    try {
      final res = await _channel.invokeMethod<Map<Object?, Object?>>(
        'generate',
        {
          'sourcePath': sourcePath,
          'outDir': outDir,
          'key': key,
        },
      );
      if (res == null) {
        debugPrint('[DepthCover] generate → null（同 key 在途）');
        return null;
      }
      final layers = res['layers'];
      if (layers is List) {
        debugPrint('[DepthCover] generate → ${layers.length} 层');
        return layers.cast<String>();
      }
      return null;
    } on PlatformException catch (e) {
      debugPrint('[DepthCover] generate failed: ${e.code} ${e.message}');
      return null;
    }
  }

  /// 把各种协议封面解析为本地可解码文件路径；无法解析返回 null（保持平面封面）。
  Future<String?> _resolveSource(String uri) async {
    if (uri.isEmpty) return null;
    if (uri.startsWith('http')) {
      // http(s):// 网络封面 → 下载到临时文件（原生 BitmapFactory 直解 http 不稳妥）。
      final p = await _downloadToTemp(uri);
      debugPrint('[DepthCover] resolveSource http → ${p == null ? "下载失败" : "ok"}');
      return p;
    }
    if (uri.startsWith('file://')) {
      final p = Uri.parse(uri).toFilePath();
      return File(p).existsSync() ? p : null;
    }
    if (uri.startsWith('local://')) {
      // local://<filePath> 内嵌封面懒加载路径，去掉前缀取本地路径。
      final p = uri.substring('local://'.length);
      return File(p).existsSync() ? p : null;
    }
    if (uri.startsWith('content://')) {
      // content:// MediaStore albumart 无法解析为本地文件：保持平面封面，不报错。
      return null;
    }
    // 裸本地路径（非上述任何协议）兜底：存在即可用。
    return File(uri).existsSync() ? uri : null;
  }

  /// 与 [_resolveSource] 协议分发一致，但网络封面不再落临时目录，而是下载到
  /// `cache.ensureEntryDir(key)/cover.img`，避免临时文件被系统清理后 shader 无原图可取。
  Future<String?> _resolveSourceAndKeep(String uri) async {
    if (uri.isEmpty) return null;
    if (uri.startsWith('http')) {
      // http(s):// 网络封面 → 下载到缓存目录（shader 每次构建都要读原图）。
      final key = DepthCoverCache.cacheKey(uri);
      final dir = await cache.ensureEntryDir(key);
      final path = '$dir${Platform.pathSeparator}cover.img';
      try {
        await Dio().download(uri, path);
      } on DioException {
        debugPrint('[DepthCover] resolveSourceAndKeep http → 下载失败');
        return null;
      } catch (_) {
        debugPrint('[DepthCover] resolveSourceAndKeep http → 下载失败');
        return null;
      }
      debugPrint('[DepthCover] resolveSourceAndKeep http → ok');
      return path;
    }
    if (uri.startsWith('file://')) {
      final p = Uri.parse(uri).toFilePath();
      return File(p).existsSync() ? p : null;
    }
    if (uri.startsWith('local://')) {
      final p = uri.substring('local://'.length);
      return File(p).existsSync() ? p : null;
    }
    if (uri.startsWith('content://')) {
      return null;
    }
    return File(uri).existsSync() ? uri : null;
  }

  Future<String?> _downloadToTemp(String url) async {
    try {
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/depth_src_${DepthCoverCache.cacheKey(url)}.img';
      await Dio().download(url, path);
      return path;
    } on DioException {
      return null;
    } catch (_) {
      return null;
    }
  }
}
