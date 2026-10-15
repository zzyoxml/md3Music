/// Release 版本号解析与比较：纯函数，无 IO、无 Flutter 依赖，便于单测。
///
/// 只比较 `major.minor.patch` 三段：本项目的 Release tag 形如 `v5.6.5`，
/// 而 pubspec/versionName 形如 `5.6.0`，两者同源（CI 用 --build-name 写入）。
library;

/// 解析版本号为数字段列表。
///
/// 规则：
/// - 去掉可选的 `v` / `V` 前缀；
/// - 截断 `+<build>` 构建号与 `-<prerelease>` 后缀；
/// - 最多取前三段，缺失段由 [compareReleaseVersions] 补 0；
/// - 任一段不是非负整数（含空串、非数字）→ 返回 null，调用方按「无法比较」处理。
List<int>? parseReleaseVersion(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return null;
  if (text.startsWith('v') || text.startsWith('V')) {
    text = text.substring(1);
  }
  text = text.split('+').first.split('-').first;
  if (text.isEmpty) return null;

  final segments = text.split('.');
  final parts = <int>[];
  for (var i = 0; i < segments.length && i < 3; i++) {
    final value = int.tryParse(segments[i]);
    if (value == null || value < 0) return null;
    parts.add(value);
  }
  return parts.isEmpty ? null : parts;
}

/// 版本号比较：a 低于 b 返回 -1，相等返回 0，a 高于 b 返回 1。
/// 缺失段按 0 补齐（`5.6` 等价于 `5.6.0`）。
int compareReleaseVersions(List<int> a, List<int> b) {
  final length = a.length > b.length ? a.length : b.length;
  for (var i = 0; i < length; i++) {
    final left = i < a.length ? a[i] : 0;
    final right = i < b.length ? b[i] : 0;
    if (left != right) return left < right ? -1 : 1;
  }
  return 0;
}

/// [latest] 是否比 [current] 新。任一无法解析时返回 false（宁可不提醒，也不误报）。
bool isNewerRelease(String latest, String current) {
  final remote = parseReleaseVersion(latest);
  final local = parseReleaseVersion(current);
  if (remote == null || local == null) return false;
  return compareReleaseVersions(remote, local) > 0;
}
