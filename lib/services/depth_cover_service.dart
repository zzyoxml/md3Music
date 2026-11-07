import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/services/depth_cover_cache.dart';
import 'depth/depth_engine.dart';

/// 3D 封面总编排：推理后端 + 缓存 + URI 解析。全局单例。
///
/// 「怎么推理」下沉到 [DepthEngine]（Android = 原生 MethodChannel + 裁剪版 ORT
/// AAR；Windows = 纯 Dart FFI + 便携包内 app-local 的 onnxruntime.dll）。
/// 本文件只管编排：命中/未命中、模型就绪、同 key 在途、失败重试上限 ——
/// 两端共用同一套，行为差异全部留在后端实现里。
///
/// 失败的生成会被 [DepthCoverCache] 视为未命中，UI 回退平面封面。
class DepthCoverService {
  DepthCoverService._();

  static final instance = DepthCoverService._();

  final cache = DepthCoverCache();

  /// 推理后端（按编译期旗标选择，见 depth/depth_engine.dart）。
  late final DepthEngine engine = createDepthEngine();

  /// 3D 封面总开关的统一状态源：设置页 / 两播放页界面设置弹层写入，
  /// DepthCoverHost 监听（值变化即重走初始化，开关即时生效）。
  /// 初始 false，由各 UI 首次加载时写入真实值。
  static final ValueNotifier<bool> enabledSignal = ValueNotifier(false);

  /// 每次封面变化时调用：命中/生成完成都会触发 cache 监听回调。
  ///
  /// 返回 false 仅表示「当前无现成结果」，不代表流程结束（未命中时 UI 先展示平面封面，
  /// 等原生生成后经缓存监听切换为 3D）。
  Future<bool> request(String artworkUri) async {
    debugPrint('[DepthCover] request: uri=${_brief(artworkUri)}');
    final loaded = await engine.ensureModelLoaded();
    debugPrint('[DepthCover] engine loadModel → $loaded');
    if (!loaded) return false;
    final ok = await cache.requestLayers(
      artworkUri: artworkUri,
      generate: engine.generateLayers,
      resolveSource: _resolveSource,
    );
    debugPrint('[DepthCover] requestLayers → $ok');
    return ok;
  }

  /// shader 路径编排：生成单张深度图；封面源同时落缓存目录（shader 需要原图纹理）。
  Future<bool> requestDepth(String artworkUri) async {
    debugPrint('[DepthCover] requestDepth: uri=${_brief(artworkUri)}');
    final loaded = await engine.ensureModelLoaded();
    debugPrint('[DepthCover] engine loadModel → $loaded');
    if (!loaded) return false;
    // 神经修补会话：开关开启时才加载（失败静默 → 纯 Phase A 行为）
    await engine.ensureInpaintSession();
    final ok = await cache.requestDepth(
      artworkUri: artworkUri,
      generate: engine.generateDepth,
      resolveSource: _resolveSourceAndKeep,
    );
    debugPrint('[DepthCover] requestDepth → $ok');
    return ok;
  }

  /// 原生 Toast 提示（3D 封面降级告知用户）：由后端各自路由到本平台的通知实现。
  Future<void> showNativeToast(String message) => engine.showToast(message);

  static String _brief(String uri) =>
      uri.length <= 48 ? uri : '${uri.substring(0, 48)}…';

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
