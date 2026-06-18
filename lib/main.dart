import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:permission_handler/permission_handler.dart';

import 'app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('zh_CN');
  await _requestPermissions();
  runApp(const MyApp());
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
  // 忽略电池优化
  try {
    if (await Permission.ignoreBatteryOptimizations.isDenied) {
      await Permission.ignoreBatteryOptimizations.request();
    }
  } catch (_) {}
}
