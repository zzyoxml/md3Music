import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../utils/app_toast.dart';

/// 保存图片失败时抛出，[message] 可直接展示给用户。
class ImageSaveException implements Exception {
  final String message;
  const ImageSaveException(this.message);
  @override
  String toString() => 'ImageSaveException: $message';
}

/// 下载图片字节的注入点（测试用；生产走 [http]）。
typedef ImageBytesFetcher = Future<Uint8List> Function(Uri uri);

/// 把网络图片保存进系统相册。
///
/// 分工：**Dart 下载 + 写应用临时目录，原生负责落盘**。
/// 原因：落盘是重 IO 且 Android 10+ 必须走 MediaStore（`RELATIVE_PATH`），
/// 让原生做能顺带处理分区存储与 `IS_PENDING`；字节流则不经过 MethodChannel
/// （几 MB 的图走 `StandardMessageCodec` 会造成不必要的内存拷贝与卡顿）。
class ImageGallerySaver {
  const ImageGallerySaver._();

  static const MethodChannel _channel =
      MethodChannel('com.md3music.md3music/image_saver');

  /// 单张图片体积上限：超过多半是错误页/占位图，存进相册反而是垃圾。
  static const int maxBytes = 20 * 1024 * 1024;

  /// 下载超时。
  static const Duration timeout = Duration(seconds: 20);

  /// 允许的扩展名白名单（其余一律按 jpg 落盘）。
  static const Set<String> allowedExtensions = {
    'jpg',
    'jpeg',
    'png',
    'gif',
    'webp',
    'bmp',
  };

  /// 生成相册文件名：`MD3Music_20260930_142530_a1b2.jpg`。
  ///
  /// 时间戳保证可读，URL 哈希补 4 位十六进制避免同秒同名碰撞。
  static String imageFileNameFor(Uri url, DateTime now) {
    var ext = 'jpg';
    final segments = url.pathSegments;
    final last = segments.isEmpty ? '' : segments.last;
    final dot = last.lastIndexOf('.');
    if (dot > 0 && dot < last.length - 1) {
      final candidate = last.substring(dot + 1).toLowerCase();
      if (allowedExtensions.contains(candidate)) ext = candidate;
    }
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final salt = url.path.hashCode.toUnsigned(32).toRadixString(16).padLeft(8, '0');
    return 'MD3Music_${stamp}_${salt.substring(salt.length - 4)}.$ext';
  }

  /// 下载图片字节；失败一律抛 [ImageSaveException]。
  static Future<Uint8List> downloadImageBytes(
    Uri uri, {
    ImageBytesFetcher? fetcher,
  }) async {
    final Uint8List bytes;
    if (fetcher != null) {
      bytes = await fetcher(uri);
    } else {
      final response = await http.get(uri).timeout(timeout);
      if (response.statusCode != 200) {
        throw ImageSaveException('下载失败（HTTP ${response.statusCode}）');
      }
      bytes = response.bodyBytes;
    }
    if (bytes.isEmpty) throw const ImageSaveException('图片内容为空');
    if (bytes.length > maxBytes) throw const ImageSaveException('图片过大');
    return bytes;
  }

  /// 下载并保存到相册，返回原生给出的落盘位置（`content://` 或文件路径）。
  ///
  /// [fetcher] / [tempDir] 仅为测试注入点，生产不传。
  static Future<String> saveImageToGallery(
    String url, {
    DateTime? now,
    ImageBytesFetcher? fetcher,
    Future<Directory> Function()? tempDir,
  }) async {
    final Uri uri;
    try {
      uri = Uri.parse(url);
    } on FormatException {
      throw const ImageSaveException('图片地址无效');
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw const ImageSaveException('图片地址无效');
    }

    final bytes = await downloadImageBytes(uri, fetcher: fetcher);
    final fileName = imageFileNameFor(uri, now ?? DateTime.now());
    final dir = await (tempDir ?? getTemporaryDirectory)();
    final file = File('${dir.path}${Platform.pathSeparator}$fileName');
    // 不在此处删除临时文件：原生在后台线程复制该文件（见 ImageSaverPlugin），
    // invokeMethod 返回即删会与复制竞争；留给系统按缓存目录策略清理。
    try {
      await file.writeAsBytes(bytes, flush: true);
      final saved = await _channel.invokeMethod<String>('saveImage', {
        'path': file.path,
        'fileName': fileName,
      });
      return saved ?? file.path;
    } on PlatformException catch (e) {
      throw ImageSaveException(e.message ?? '保存失败');
    } on FileSystemException catch (e) {
      throw ImageSaveException('写入临时文件失败：${e.message}');
    }
  }

  /// 保存并给出 toast 反馈，返回是否成功（UI 层只需调这一个）。
  static Future<bool> saveImageToGalleryWithFeedback(
    BuildContext context,
    String url,
  ) async {
    showToast('正在保存图片…');
    try {
      await saveImageToGallery(url);
      showToast('已保存到相册');
      return true;
    } on ImageSaveException catch (e) {
      showToast('保存失败：${e.message}');
      return false;
    } catch (e) {
      debugPrint('[ImageGallerySaver] 保存失败: $e');
      showToast('保存失败');
      return false;
    }
  }
}
