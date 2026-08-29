import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/media_store_service.dart';

bool _isAndroidNative() {
  if (kIsWeb) return false;
  try {
    return Platform.isAndroid;
  } catch (_) {
    return false;
  }
}

Future<int> _getAndroidSdkVersion() async {
  if (!_isAndroidNative()) return 0;
  // 通过原生 MediaStore MethodChannel 读取真实 SDK 版本。
  // dart:io 的 Platform.version 给的是 Dart SDK 版本，不是 Android SDK 版本。
  return await MediaStoreService.getSdkVersion() ?? 0;
}

Future<bool> requestStoragePermission() async {
  if (!_isAndroidNative()) return true;

  // Android 13+ (API 33+) 使用 READ_MEDIA_AUDIO
  // Android 12 及以下 (API ≤ 32) 使用 READ_EXTERNAL_STORAGE
  // 注：原代码针对 Android 11 请求 MANAGE_EXTERNAL_STORAGE，体验差，
  // 且 MediaStore 方案下不需要此权限（仅需 READ_MEDIA_AUDIO/READ_EXTERNAL_STORAGE）。
  final sdkInt = await _getAndroidSdkVersion();

  if (sdkInt >= 33) {
    return await checkPermission(Permission.audio);
  }

  // Android 12 及以下：READ_EXTERNAL_STORAGE 已足够（搭配 MediaStore 使用）
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
