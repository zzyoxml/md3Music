import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

bool _isAndroidNative() {
  if (kIsWeb) return false;
  try {
    return Platform.isAndroid;
  } catch (_) {
    return false;
  }
}

Future<bool> requestStoragePermission() async {
  if (!_isAndroidNative()) return true;

  final sdkInt = await _getAndroidSdkVersion();

  if (sdkInt >= 33) {
    return await checkPermission(Permission.audio);
  }

  if (sdkInt >= 30) {
    final status = await Permission.manageExternalStorage.status;
    if (status.isGranted) return true;
    final result = await Permission.manageExternalStorage.request();
    return result.isGranted;
  }

  return await checkPermission(Permission.storage);
}

Future<bool> requestAudioPermission() async {
  if (!_isAndroidNative()) return true;

  final sdkInt = await _getAndroidSdkVersion();

  if (sdkInt >= 33) {
    return await checkPermission(Permission.audio);
  }

  return await checkPermission(Permission.storage);
}

Future<bool> checkPermission(Permission permission) async {
  final status = await permission.status;
  if (status.isGranted) return true;

  final result = await permission.request();
  if (result.isGranted) return true;

  if (result.isPermanentlyDenied) {
    await openAppSettings();
    return false;
  }

  return false;
}

Future<int> _getAndroidSdkVersion() async {
  if (!_isAndroidNative()) return 0;
  try {
    final sdkVersion = int.tryParse(Platform.version.split('.').first) ?? 0;
    return sdkVersion;
  } catch (_) {
    return 0;
  }
}
