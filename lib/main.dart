import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';

const String _kBatteryPromptShownKey = 'battery_prompt_shown';

/// 顶级 Navigator 的 GlobalKey，预留供后续扩展使用。
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('zh_CN');
  await _requestPermissions();
  runApp(const MyApp());
  // 自动续播已禁用：用户重启 app 不再自动继续播放。
}

Future<void> _requestPermissions() async {
  // Web 平台不支持 permission_handler，跳过所有权限请求
  if (kIsWeb) return;

  // Android 13+ 通知权限
  if (await Permission.notification.isDenied) {
    await Permission.notification.request();
  }
  // Android 14+ 媒体权限
  if (await Permission.audio.isDenied) {
    await Permission.audio.request();
  }
  // 忽略电池优化：只弹一次（不管用户选什么都标记为已弹）
  try {
    final prefs = await SharedPreferences.getInstance();
    final alreadyShown = prefs.getBool(_kBatteryPromptShownKey) ?? false;
    if (!alreadyShown) {
      if (await Permission.ignoreBatteryOptimizations.isDenied) {
        await Permission.ignoreBatteryOptimizations.request();
      }
      await prefs.setBool(_kBatteryPromptShownKey, true);
    }
  } catch (_) {}
}
