import 'package:url_launcher/url_launcher.dart';

import '../../core/utils/app_toast.dart';
import 'github_release_client.dart';

const updateProjectUrl =
    'https://github.com/${GithubReleaseClient.owner}/${GithubReleaseClient.repo}';
const updateMirrorWebsiteUrl =
    'https://git.hiwiki.org/zh-CN/repo/zzyoxml/md3music';

/// 网页下载是应用内更新之外的备用入口，交给系统默认浏览器处理。
Future<void> openUpdateWebPage(String url) async {
  try {
    if (await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)) {
      return;
    }
  } catch (_) {
    // 不影响更新弹窗或已有下载任务，失败反馈统一走原生 Toast。
  }
  showToast('无法打开浏览器，请手动访问：$url', long: true);
}
