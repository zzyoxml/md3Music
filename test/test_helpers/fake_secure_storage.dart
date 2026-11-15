import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _secureStorageChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

/// 为使用 FlutterSecureStorage 的单测安装进程内加密存储替身。
void installFakeSecureStorage() {
  final values = <String, String>{};
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_secureStorageChannel, (call) async {
        final arguments = call.arguments is Map
            ? Map<String, dynamic>.from(call.arguments as Map)
            : const <String, dynamic>{};
        final key = arguments['key'] as String?;
        switch (call.method) {
          case 'read':
            return key == null ? null : values[key];
          case 'readAll':
            return Map<String, String>.from(values);
          case 'write':
            if (key != null) values[key] = arguments['value'] as String? ?? '';
            return null;
          case 'delete':
            if (key != null) values.remove(key);
            return null;
          case 'deleteAll':
            values.clear();
            return null;
          default:
            throw MissingPluginException(
              'Unsupported secure storage method: ${call.method}',
            );
        }
      });
}

void uninstallFakeSecureStorage() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_secureStorageChannel, null);
}
