import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 用户协议页（首次启动展示）。
///
/// 协议正文以静态文本形式内嵌（参考第三方音乐客户端「Hydrogen」协议结构
/// 改写为 MD3Music 版本），底部追加 [disclaimerUrl] 链接指向项目根目录的
/// `DISCLAIMER.md`，用户点击后通过 [showDisclaimerDialog] 在弹窗中展示。
class UserAgreementPage extends StatefulWidget {
  /// 同意后回调（首次启动时跳转到首页，已同意过则不展示）。
  final VoidCallback onAgreed;

  /// 是否为首次启动（决定"下一步"按钮文字与关闭行为）。
  final bool isFirstLaunch;

  /// 仅查看模式（设置 → 关于 中进入）：
  /// - 允许系统返回/物理返回关闭
  /// - 隐藏勾选与"下一步"按钮
  /// - 不写入已同意标记
  final bool isReview;

  const UserAgreementPage({
    super.key,
    required this.onAgreed,
    this.isFirstLaunch = true,
    this.isReview = false,
  });

  @override
  State<UserAgreementPage> createState() => _UserAgreementPageState();

  /// 弹出免责声明全文（Markdown 原文）。在 GitHub 仓库中访问
  /// `https://github.com/zzyoxml/md3Music/blob/arch-local-first/DISCLAIMER.md` 可看完整版。
  static Future<void> showDisclaimerDialog(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('免责声明'),
        content: const SingleChildScrollView(
          child: Text(
            '感谢你关注 MD3Music。在下载、安装或使用本软件之前，请仔细阅读以下条款。\n\n'
            '一、本应用 MD3Music 是由开发者 zzyoxml 个人独立维护的开源音乐播放器，'
            '不是酷狗音乐的官方软件，也未获得酷狗音乐及其母公司的官方授权、认可或赞助。\n\n'
            '二、本软件所有的音乐播放链接、歌词文本、专辑封面、歌单数据等，'
            '均通过调用网络上酷狗音乐公开的 公开 API 接口获取 获取。'
            '以上所有数据的知识产权与版权，均归原始权利人所有。\n\n'
            '三、MD3Music 本身不搭建任何音乐缓存服务器，也不提供任何盗版音乐下载源。'
            '软件仅充当"浏览器"角色，在用户本地展示公开数据。\n\n'
            '四、本应用从未收集任何用户隐私数据，所有操作产生的数据都保留在用户本地。\n\n'
            '五、该软件仅供交流学习，严禁用于商业用途，请于下载后的 24 小时内卸载。\n\n'
            '完整版请访问：\nhttps://github.com/zzyoxml/md3Music/blob/arch-local-first/DISCLAIMER.md',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              Clipboard.setData(
                const ClipboardData(
                  text:
                      'https://github.com/zzyoxml/md3Music/blob/rust-local-two/DISCLAIMER.md',
                ),
              );
            },
            child: const Text('复制完整版链接'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}

class _UserAgreementPageState extends State<UserAgreementPage> {
  bool _agreed = false;

  /// SharedPreferences key：标记用户已同意协议。
  /// 设置后下次冷启动不再展示。
  static const String _kAcceptedKey = 'user_agreement_accepted_v1';

  Future<void> _onAgree() async {
    if (!_agreed) return;
    // 持久化同意标记
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kAcceptedKey, true);
    } catch (_) {}
    if (!mounted) return;
    widget.onAgreed();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return PopScope(
      // review 模式 / 非首次启动：允许返回
      // 首次启动：禁止返回跳过
      canPop: widget.isReview || !widget.isFirstLaunch,
      child: Scaffold(
        appBar: widget.isReview ? AppBar(title: const Text('用户协议')) : null,
        body: SafeArea(
          child: Column(
            children: [
              if (!widget.isReview) ...[
                const SizedBox(height: 24),
                // 顶部图标 + 标题（仅首次启动展示）
                Icon(
                  Icons.shield_outlined,
                  size: 56,
                  color: colorScheme.primary,
                ),
                const SizedBox(height: 12),
                Text(
                  '用户协议',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '请在使用本应用前仔细阅读以下用户协议。',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
              ] else
                const SizedBox(height: 8),
              // 协议正文（可滚动）
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '用户协议',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _Clause(
                        index: '一、',
                        text: '本应用"MD3Music"是作为个人兴趣业余开发，不具有任何商业行为。',
                      ),
                      _Clause(
                        index: '二、',
                        text:
                            '本应用不是破解工具，仅是一个简化的浏览器。相关付费内容仍需对应平台会员身份/购买，本应用不提供任何付费内容。',
                      ),
                      _Clause(
                        index: '三、',
                        text: '本应用中相关资源、音乐的版权归酷狗原公司及原创作者所有。本应用不对其中的内容负责。',
                      ),
                      _Clause(
                        index: '四、',
                        text:
                            '本应用从未收集任何用户隐私数据。应用内所有内容直接请求酷狗官方接口，所有操作产生的数据都保留在用户本地',
                      ),
                      _Clause(
                        index: '五、',
                        text: '如果用户不再需要使用本应用，可以随时通过设备的应用管理功能将其卸载。',
                      ),
                      _Clause(
                        index: '六、',
                        text: '该软件仅供交流学习，严禁用于商业用途，请于下载后的 24 小时内卸载。',
                      ),
                      const SizedBox(height: 16),
                      // 底部超链接：免责声明
                      Center(
                        child: RichText(
                          textAlign: TextAlign.center,
                          text: TextSpan(
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: colorScheme.onSurfaceVariant),
                            children: [
                              const TextSpan(text: '查看完整'),
                              TextSpan(
                                text: '免责声明',
                                style: TextStyle(
                                  color: colorScheme.primary,
                                  decoration: TextDecoration.underline,
                                  fontWeight: FontWeight.w600,
                                ),
                                recognizer: TapGestureRecognizer()
                                  ..onTap = () =>
                                      UserAgreementPage.showDisclaimerDialog(
                                        context,
                                      ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
              // 底部勾选 + 下一步（review 模式不展示）
              if (!widget.isReview)
                Builder(
                  builder: (context) {
                    // 壁纸开启时透明，与正文区透明度一致（公开版偏好 8.6）
                    final useBackgroundImage =
                        context.watch<ThemeProvider>().useBackgroundImage;
                    return Container(
                      padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                      decoration: BoxDecoration(
                        color: useBackgroundImage
                            ? colorScheme.surface.withValues(alpha: 0.2)
                            : colorScheme.surface,
                        border: Border(
                          top: BorderSide(
                            color: colorScheme.outlineVariant,
                            width: 0.5,
                          ),
                        ),
                      ),
                      child: Column(
                        children: [
                          InkWell(
                            onTap: () => setState(() => _agreed = !_agreed),
                            borderRadius: BorderRadius.circular(8),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 8,
                              ),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: Checkbox(
                                      value: _agreed,
                                      onChanged: (v) =>
                                          setState(() => _agreed = v ?? false),
                                      materialTapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '我已阅读并同意 用户协议',
                                    style:
                                        Theme.of(context).textTheme.bodyMedium,
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton(
                              onPressed: _agreed ? _onAgree : null,
                              style: FilledButton.styleFrom(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 14),
                              ),
                              child: const Text('下一步'),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 协议条款子项：编号 + 段落文本。
class _Clause extends StatelessWidget {
  final String index;
  final String text;

  const _Clause({required this.index, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: RichText(
        text: TextSpan(
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            height: 1.6,
            color: Theme.of(context).colorScheme.onSurface,
          ),
          children: [
            TextSpan(
              text: index,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            TextSpan(text: text),
          ],
        ),
      ),
    );
  }
}

/// 读取"用户协议"是否已被同意。
Future<bool> isUserAgreementAccepted() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_UserAgreementPageState._kAcceptedKey) ?? false;
  } catch (_) {
    return false;
  }
}
