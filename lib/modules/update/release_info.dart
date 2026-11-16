/// 一次 Release 查询的结果（纯数据，不依赖任何网络/Flutter 类型）。
class ReleaseInfo {
  const ReleaseInfo({
    required this.tagName,
    required this.version,
    required this.htmlUrl,
    this.body = '',
    this.windowsZipUrl,
    this.windowsZipSize,
    this.windowsZipDigest,
  });

  /// 由 GitHub tag 构造：剥离 `v` 前缀写入 [version] 供展示与比较。
  factory ReleaseInfo.fromTag({
    required String tagName,
    required String htmlUrl,
    String body = '',
    String? windowsZipUrl,
    int? windowsZipSize,
    String? windowsZipDigest,
  }) {
    final tag = tagName.trim();
    final bare = (tag.startsWith('v') || tag.startsWith('V'))
        ? tag.substring(1)
        : tag;
    return ReleaseInfo(
      tagName: tag,
      version: bare,
      htmlUrl: htmlUrl,
      body: body,
      windowsZipUrl: windowsZipUrl,
      windowsZipSize: windowsZipSize,
      windowsZipDigest: windowsZipDigest,
    );
  }

  /// 原始 tag，形如 `v5.6.5`。
  final String tagName;

  /// 去掉 `v` 前缀的版本号，形如 `5.6.5`。
  final String version;

  /// Release 页面地址（供跳转下载）。
  final String htmlUrl;

  /// Release 说明；Windows 更新提示中展示。
  final String body;

  /// 当前 Release 的 Windows 便携版 ZIP 下载地址。
  final String? windowsZipUrl;

  /// Windows ZIP 字节数。
  final int? windowsZipSize;

  /// GitHub 提供的资产摘要（通常为 `sha256:<hex>`）。
  final String? windowsZipDigest;
}

/// Release 数据来源抽象：让 [UpdateCheckService] 可在测试中注入假实现，不联网。
abstract class ReleaseSource {
  /// 查询最新 Release。查不到（网络失败 / 无 Release / 响应异常）返回 null。
  Future<ReleaseInfo?> fetchLatest();
}
