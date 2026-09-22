import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'release_info.dart';

/// 从 302 的 Location 头解析 tag 名。
///
/// `/releases/latest` 的 Location 形如
/// `https://github.com/<owner>/<repo>/releases/tag/v5.6.5`。
/// 解析不出返回 null（回退链路放弃，不抛异常）。
String? parseTagFromRedirectLocation(String? location) {
  if (location == null) return null;
  const marker = '/releases/tag/';
  final start = location.indexOf(marker);
  if (start < 0) return null;
  var tag = location.substring(start + marker.length);
  for (final separator in const ['?', '#', '/']) {
    final end = tag.indexOf(separator);
    if (end >= 0) tag = tag.substring(0, end);
  }
  tag = tag.trim();
  return tag.isEmpty ? null : tag;
}

/// GitHub Release 客户端：REST API 为主链路，HTML 302 为回退链路。
///
/// 为什么需要回退：部分网络环境下 `api.github.com` 易超时，且未鉴权
/// 限额 60 次/小时/IP。`github.com/<repo>/releases/latest` 的 302
/// `Location` 头能给出同样的 tag 名，且不消耗 API 配额。
class GithubReleaseClient implements ReleaseSource {
  GithubReleaseClient({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              sendTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 8),
              // 非 2xx/302 也交回调用方，由状态码分支处理，不抛异常
              validateStatus: (_) => true,
            ),
          );

  /// 检测目标（唯一来源；换仓库只改这两行）
  static const String owner = 'zzyoxml';
  static const String repo = 'md3Music';

  /// GitHub 要求 User-Agent 非空，显式声明产品标识避免被拒。
  static const String userAgent = 'MD3Music-Android';

  static final Uri apiLatestUri = Uri.parse(
    'https://api.github.com/repos/$owner/$repo/releases/latest',
  );
  static final Uri htmlLatestUri = Uri.parse(
    'https://github.com/$owner/$repo/releases/latest',
  );

  static final Uri _fallbackHtmlUri = Uri.parse(
    'https://github.com/$owner/$repo/releases',
  );

  final Dio _dio;

  @override
  Future<ReleaseInfo?> fetchLatest() async {
    final viaApi = await _fetchViaApi();
    if (viaApi != null) return viaApi;
    return _fetchViaRedirect();
  }

  /// 主链路：GitHub REST API。
  Future<ReleaseInfo?> _fetchViaApi() async {
    try {
      final response = await _dio.getUri<Map<String, dynamic>>(
        apiLatestUri,
        options: Options(
          headers: {
            'User-Agent': userAgent,
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
          },
        ),
      );
      if (response.statusCode != 200 || response.data == null) {
        debugPrint('[UpdateCheck] API 返回 ${response.statusCode}，转回退链路');
        return null;
      }
      final tagName = (response.data!['tag_name'] as String?)?.trim();
      if (tagName == null || tagName.isEmpty) {
        debugPrint('[UpdateCheck] API 响应缺少 tag_name，转回退链路');
        return null;
      }
      final htmlUrl = (response.data!['html_url'] as String?)?.trim();
      return ReleaseInfo.fromTag(
        tagName: tagName,
        htmlUrl: (htmlUrl == null || htmlUrl.isEmpty)
            ? _fallbackHtmlUri.toString()
            : htmlUrl,
      );
    } catch (error) {
      debugPrint('[UpdateCheck] API 查询失败：$error');
      return null;
    }
  }

  /// 回退链路：读 `/releases/latest` 的 302 Location，不消耗 API 配额。
  Future<ReleaseInfo?> _fetchViaRedirect() async {
    try {
      final response = await _dio.getUri<void>(
        htmlLatestUri,
        options: Options(
          headers: {'User-Agent': userAgent},
          // 关闭跟随重定向，否则拿不到 Location 头
          followRedirects: false,
          validateStatus: (_) => true,
        ),
      );
      final tagName = parseTagFromRedirectLocation(
        response.headers.value('location'),
      );
      if (tagName == null) {
        debugPrint(
          '[UpdateCheck] 回退链路未解析出 tag（status=${response.statusCode}）',
        );
        return null;
      }
      return ReleaseInfo.fromTag(
        tagName: tagName,
        htmlUrl: 'https://github.com/$owner/$repo/releases/tag/$tagName',
      );
    } catch (error) {
      debugPrint('[UpdateCheck] 回退链路失败：$error');
      return null;
    }
  }
}
