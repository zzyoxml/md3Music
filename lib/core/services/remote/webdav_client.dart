import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:xml/xml.dart';

import 'remote_storage_config.dart';

/// 单个 WebDAV 目录条目。
class WebDavEntry {
  /// 服务器上的绝对路径（已解码），如 `/music/song.mp3`。
  final String path;
  final String name;
  final bool isDirectory;
  final int size;

  const WebDavEntry({
    required this.path,
    required this.name,
    required this.isDirectory,
    this.size = 0,
  });
}

/// 轻量 WebDAV 客户端：PROPFIND 列目录 + Basic 鉴权。
///
/// 需求仅「只读列目录 + 用 HTTP URL 流式播放」，故不做 MKCOL/PUT 等写操作。
/// 依赖项目已有的 dio 与 xml；鉴权走 Basic（多数 WebDAV 服务支持），
/// Digest 鉴权留待需要时再补。
class WebDavClient {
  final RemoteStorageConfig config;

  /// 可替换的 Dio 实例（测试注入 mock）。
  late Dio dio;

  /// 可替换的 adapter（测试注入）。默认用 dio 自带实现。
  set adapter(HttpClientAdapter value) => dio.httpClientAdapter = value;

  WebDavClient(this.config) {
    dio = Dio(BaseOptions(
      baseUrl: config.baseUrl,
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 15),
    ));
  }

  /// 生成 WebDAV Basic 鉴权头值（供播放器附加到流式播放请求）。
  static String basicAuth(String username, String password) {
    final raw = '$username:$password';
    return 'Basic ${base64Encode(utf8.encode(raw))}';
  }

  /// 每个请求附带的鉴权头。凭据为空时不附带，避免发出无意义头。
  ///
  /// 放在请求级而非 BaseOptions：测试可整体替换 [dio]，请求级头仍生效。
  Map<String, String> get _authHeaders {
    if (config.username.isEmpty && config.password.isEmpty) return const {};
    return {'Authorization': basicAuth(config.username, config.password)};
  }

  /// 测试连通性：对根路径发 PROPFIND（Depth:0），207 或 200 视为通过。
  Future<bool> ping() async {
    try {
      final resp = await dio.request(
        _dirPath(config.rootPath),
        options: Options(
          method: 'PROPFIND',
          headers: {..._authHeaders, 'Depth': '0'},
        ),
      );
      return resp.statusCode == 207 || resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// 列出 [path] 目录下所有条目（Depth:1，不含递归）。
  Future<List<WebDavEntry>> list(String path) async {
    final resp = await dio.request(
      _dirPath(path),
      options: Options(
        method: 'PROPFIND',
        headers: {..._authHeaders, 'Depth': '1'},
        responseType: ResponseType.plain,
      ),
    );
    final body = resp.data == null ? '' : '${resp.data}';
    return _parseMultistatus(body, path);
  }

  /// 构造目录的 PROPFIND URL（确保末尾有 /，部分服务要求）。
  String _dirPath(String path) {
    final p = path.isEmpty ? '/' : path;
    return p.endsWith('/') ? p : '$p/';
  }

  /// 解析 multistatus 响应。[requestPath] 为本次列举的目录，用于排除自身条目。
  List<WebDavEntry> _parseMultistatus(String xmlString, String requestPath) {
    if (xmlString.trim().isEmpty) return [];
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(xmlString);
    } catch (_) {
      // 非法 XML（如鉴权失败返回 HTML）直接视为无条目
      return [];
    }

    final entries = <WebDavEntry>[];
    final selfPath = _normalize(requestPath);
    for (final resp in _findElements(doc, 'response')) {
      final hrefEl = _firstElement(resp, 'href');
      if (hrefEl == null) continue;
      final remotePath = _pathFromHref(hrefEl.innerText);
      if (remotePath.isEmpty) continue;
      // 目录条目去掉末尾 /（与扫描器约定一致），同时用于与自身路径比较
      final entryPath = _normalize(remotePath);
      // PROPFIND Depth:1 会返回集合自身，需排除
      if (entryPath == selfPath) continue;

      // 目录判定：存在 collection 元素（resourcetype/collection）
      final isDir = _firstElement(resp, 'collection') != null;
      final sizeRaw = _firstElement(resp, 'getcontentlength')?.innerText ?? '';
      final size = int.tryParse(sizeRaw.trim()) ?? 0;

      entries.add(WebDavEntry(
        path: entryPath,
        name: _lastSegment(entryPath),
        isDirectory: isDir,
        size: isDir ? 0 : size,
      ));
    }
    return entries;
  }

  /// 容错命名空间查找：优先按 `DAV:` 命名空间匹配（带前缀的响应），
  /// 无结果时退化为仅按本地名匹配（部分服务器响应不带命名空间）。
  Iterable<XmlElement> _findElements(XmlNode node, String local) {
    final descendants = node.descendantElements;
    final withNs = descendants
        .where((e) => e.name.local == local && e.name.namespaceUri == 'DAV:');
    if (withNs.isNotEmpty) return withNs;
    return descendants.where((e) => e.name.local == local);
  }

  XmlElement? _firstElement(XmlNode node, String local) {
    final it = _findElements(node, local);
    return it.isEmpty ? null : it.first;
  }

  /// 从 href 提取服务器绝对路径：绝对 URL 取 path，并对百分号编码解码
  /// （中文/空格等特殊字符）。
  String _pathFromHref(String href) {
    final raw = href.trim();
    if (raw.isEmpty) return '';
    final uri = Uri.tryParse(raw);
    var path = (uri != null && uri.path.isNotEmpty) ? uri.path : raw;
    try {
      path = Uri.decodeComponent(path);
    } catch (_) {
      // 非法编码时保留原样
    }
    return path;
  }

  /// 去掉末尾多余的 `/`（保留根 `/`），用于路径比较。
  String _normalize(String p) {
    var s = p;
    while (s.length > 1 && s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  String _lastSegment(String path) {
    final norm = _normalize(path);
    final idx = norm.lastIndexOf('/');
    return idx >= 0 ? norm.substring(idx + 1) : norm;
  }
}