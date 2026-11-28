import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/utils/app_toast.dart';
import '../../data/models/kugou_account.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/kugou_provider.dart';
import '../login/login_page.dart';

/// 防止同一时刻出现两个「登录已过期」弹窗（后台检查与切换账号可能同时触发）。
bool _expiredDialogOpen = false;

/// 账号登录态已过期：提示并引导重新登录 / 删除该账号。
///
/// 切换账号与后台定时检查共用同一个弹窗，保证文案与行为完全一致。
Future<void> showExpiredAccountDialog(
  BuildContext context,
  KugouAccount account,
  KugouProvider kugou,
) async {
  if (_expiredDialogOpen || !context.mounted) return;
  _expiredDialogOpen = true;
  try {
    await _showExpiredAccountDialog(context, account, kugou);
  } finally {
    _expiredDialogOpen = false;
  }
}

Future<void> _showExpiredAccountDialog(
  BuildContext context,
  KugouAccount account,
  KugouProvider kugou,
) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final action = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('登录已过期'),
      content: Text(
        '「${account.nickname ?? account.userid}」的登录状态已过期，'
        '需重新登录后才能使用该账号。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, 'remove'),
          child: const Text('删除该账号'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, 'relogin'),
          child: const Text('重新登录'),
        ),
      ],
    ),
  );
  if (!context.mounted) return;

  switch (action) {
    case 'relogin':
      // 重新登录：登录成功后 setLoginCookies 会清除该账号的过期标记
      await navigator.push(
        MaterialPageRoute(builder: (_) => const LoginPage()),
      );
    case 'remove':
      await kugou.removeAccount(account.userid);
      if (!context.mounted) return;
      context.read<FavoritesProvider>().loadFavorites();
      showToast('已删除过期账号', long: true);
  }
}
