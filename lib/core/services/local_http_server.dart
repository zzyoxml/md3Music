import 'dart:io';
import 'dart:math';

/// 把本地音频文件通过 HTTP 暴露到局域网，供 DLNA 渲染设备拉流。
///
/// 单例服务，仅在 Android 平台启用（由 main.dart 控制）。
/// 监听 `0.0.0.0:<port>`，路由
/// `GET /local?path=<url-encoded-absolute-path>&token=<token>`。
/// 支持 Range 请求（DLNA 设备 seek 必需），按文件扩展名映射 Content-Type。
///
/// **安全设计（2026-08-17 修复局域网文件泄露）**：
/// - 访问鉴权：`start()` 时用加密随机源生成 token，仅注入 App 生成的 DLNA
///   URL（[getUrlForPath]）；服务端逐请求校验，未携带正确 token 一律 403，
///   阻止局域网任意设备读取手机文件。
/// - 路径校验：仅接受绝对路径，拒绝 `..` 穿越与空字节。
/// - 扩展名白名单：只暴露常见音频扩展名，即使 token 泄露也只能读音频文件，
///   无法读取照片/文档等其他类型。
class LocalHttpServer {
  static final LocalHttpServer instance = LocalHttpServer._();
  LocalHttpServer._();

  HttpServer? _server;
  String? _lanIp;
  int? _port;

  /// 访问 token：`start()` 时生成，`stop()` 时清空（下次启动重新生成）。
  String? _token;

  /// 候选端口：8888 优先，被占用依次尝试到 8898。
  static const List<int> _candidatePorts = [
    8888, 8889, 8890, 8891, 8892, 8893, 8894, 8895, 8896, 8897, 8898,
  ];

  bool get isRunning => _server != null;
  int? get port => _port;

  /// 启动服务器。端口冲突时自动尝试下一个候选端口；
  /// 全部失败则静默返回（UI 层会在投屏时给出错误提示）。
  Future<void> start() async {
    if (_server != null) return;
    // 每次启动生成新的访问 token（加密随机源，32 字节 hex）
    _token = _generateToken();
    for (final port in _candidatePorts) {
      try {
        _server = await HttpServer.bind('0.0.0.0', port);
        _port = port;
        _lanIp = await _resolveLanIp();
        _server!.listen(_handleRequest);
        // ignore: avoid_print
        print('LocalHttpServer started on $_lanIp:$_port');
        return;
      } catch (_) {
        // 端口被占用，尝试下一个
      }
    }
    // ignore: avoid_print
    print('LocalHttpServer failed to bind any port in $_candidatePorts');
  }

  /// 停止服务器。
  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _port = null;
    _lanIp = null;
    // 清空访问 token，确保下次 start() 生成全新 token
    _token = null;
  }

  /// 获取本地文件的局域网 HTTP URL。
  /// 返回 `http://<lan-ip>:<port>/local?path=<url-encoded>&token=<token>`。
  /// 服务器未启动、无可用局域网 IP 或未生成 token 时返回 null。
  /// 自动剥离 `file://` 前缀，并对路径做完全 decode 后再统一编码，
  /// 避免 song.localPath 已被 percent-encode（如 MediaStore 返回的 file:// URI）
  /// 导致二次编码后服务器端 File() 无法识别路径。
  String? getUrlForPath(String path) {
    if (_server == null || _port == null) return null;
    if (_lanIp == null) return null;
    final token = _token;
    if (token == null) return null;
    // 先完全解码（处理已 percent-encode 的 file:// URI），再剥离 file:// 前缀
    String normalized = Uri.decodeFull(path);
    if (normalized.startsWith('file://')) {
      normalized = normalized.substring(7);
    }
    final encoded = Uri.encodeComponent(normalized);
    // 注入访问 token：DLNA 设备拉流时 URL 自带头，服务端校验后放行
    return 'http://$_lanIp:$_port/local?path=$encoded&token=$token';
  }

  /// 解析局域网 IPv4 地址。
  /// 优先返回 WiFi/以太网接口（wlan0/eth0）的 IP，
  /// 跳过蜂窝数据接口（rmnet/pdp）和 VPN 接口（tun），
  /// 否则 DLNA 设备会拿到蜂窝 CGNAT 段 IP（如 10.x.x.x）而无法访问。
  Future<String?> _resolveLanIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      String? fallbackIp;
      for (final iface in interfaces) {
        final name = iface.name.toLowerCase();
        // 蜂窝数据接口 / VPN 接口，直接跳过
        if (name.startsWith('rmnet') ||
            name.startsWith('pdp') ||
            name.startsWith('tun') ||
            name.startsWith('ppp')) {
          continue;
        }
        for (final addr in iface.addresses) {
          if (addr.isLoopback || addr.isLinkLocal) continue;
          // 优先返回 WiFi/以太网接口
          if (name.startsWith('wlan') ||
              name.startsWith('eth') ||
              name.startsWith('wifi') ||
              name.startsWith('ap')) {
            return addr.address;
          }
          // 其他接口（如 dummy0）作为回退
          fallbackIp ??= addr.address;
        }
      }
      return fallbackIp;
    } catch (_) {}
    return null;
  }

  /// 处理 HTTP 请求：仅响应 `GET /local?path=<absolute-path>&token=<token>`。
  /// 安全顺序：token 鉴权 → 路径安全校验 → 音频扩展名白名单 → 文件存在性。
  Future<void> _handleRequest(HttpRequest request) async {
    try {
      if (request.method != 'GET' || request.uri.path != '/local') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      // 1) 鉴权：未携带正确 token 一律 403，防止局域网任意设备读取文件
      if (!_isTokenValid(request.uri.queryParameters['token'])) {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        return;
      }
      final path = request.uri.queryParameters['path'];
      // 2) 路径安全校验：绝对路径、无 `..` 穿越、无空字节
      if (path == null || path.isEmpty || !_isSafePath(path)) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }
      // 3) 扩展名白名单：只暴露常见音频扩展名，防止读取照片/文档等非音频文件
      if (_mimeForPath(path) == 'application/octet-stream') {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        return;
      }
      final file = File(path);
      if (!await file.exists()) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final mime = _mimeForPath(path);
      final length = await file.length();

      // Range 请求支持（DLNA 设备 seek 必需）
      final rangeHeader = request.headers.value('range');
      if (rangeHeader != null) {
        final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(rangeHeader);
        if (match != null) {
          final start = int.parse(match.group(1)!);
          final endStr = match.group(2)!;
          final end = endStr.isEmpty ? length - 1 : int.parse(endStr);
          if (start >= length || end >= length || start > end) {
            request.response.statusCode =
                HttpStatus.requestedRangeNotSatisfiable;
            request.response.headers
                .set('Content-Range', 'bytes */$length');
            await request.response.close();
            return;
          }
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set('Content-Type', mime);
          request.response.headers.set('Content-Length', end - start + 1);
          request.response.headers
              .set('Content-Range', 'bytes $start-$end/$length');
          request.response.headers.set('Accept-Ranges', 'bytes');
          await file.openRead(start, end + 1).pipe(request.response);
          return;
        }
      }

      // 完整文件响应
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.set('Content-Type', mime);
      request.response.headers.set('Content-Length', length);
      request.response.headers.set('Accept-Ranges', 'bytes');
      await file.openRead().pipe(request.response);
    } catch (_) {
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  /// 按文件扩展名映射 HTTP Content-Type。
  ///
  /// 同时充当**音频扩展名白名单**：未命中任何已知音频扩展名时返回
  /// `application/octet-stream`，请求处理器会将其拒绝（403）。
  /// 覆盖与 [MediaStoreScanner] 一致的常见音频格式，另含有声书 m4b 等。
  String _mimeForPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.mp3')) return 'audio/mpeg';
    if (lower.endsWith('.mp2') || lower.endsWith('.mpga')) return 'audio/mpeg';
    if (lower.endsWith('.flac')) return 'audio/x-flac';
    if (lower.endsWith('.wav')) return 'audio/wav';
    if (lower.endsWith('.m4a') || lower.endsWith('.m4b')) return 'audio/mp4';
    if (lower.endsWith('.aac')) return 'audio/aac';
    if (lower.endsWith('.ogg')) return 'audio/ogg';
    if (lower.endsWith('.opus')) return 'audio/opus';
    if (lower.endsWith('.ape')) return 'audio/x-ape';
    if (lower.endsWith('.wma')) return 'audio/wma';
    if (lower.endsWith('.aif') ||
        lower.endsWith('.aiff') ||
        lower.endsWith('.aifc')) {
      return 'audio/x-aiff';
    }
    if (lower.endsWith('.mka')) return 'audio/x-matroska';
    return 'application/octet-stream';
  }

  /// 生成访问 token：加密随机源，32 字节 hex（64 字符）。
  String _generateToken() {
    final rand = Random.secure();
    final bytes = List<int>.generate(32, (_) => rand.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// 校验请求携带的 token 是否与当前有效 token 一致。
  bool _isTokenValid(String? token) {
    final expected = _token;
    return expected != null && token != null && token == expected;
  }

  /// 路径安全校验：
  /// - 必须为绝对路径（以 `/` 开头）
  /// - 不得包含 `..` 路径段（防目录穿越）
  /// - 不得包含空字节（`\0`）
  /// 注：queryParameters 已自动 percent-decode，`..`/`\0` 在此为字面量。
  bool _isSafePath(String path) {
    if (path.contains('\u0000')) return false;
    if (!path.startsWith('/')) return false;
    for (final segment in path.split('/')) {
      if (segment == '..') return false;
    }
    return true;
  }
}
