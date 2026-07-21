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

/// 请求存储权限（用于下载到系统 Downloads 目录）。
///
/// 之前的实现用 Platform.version 当 Android SDK 版本，那是错的——
/// Platform.version 是 Dart VM 版本（如 "3.5.0"），导致 Android 13+ 设备
/// 永远走不到 audio 分支，Permission.storage 在 13+ 上是 dead permission，
/// 永远 denied 且不弹窗，下载按钮点击完全无反应。
///
/// 新方案：不依赖 SDK 版本号，按"现代权限优先"顺序探测——
///   1. Permission.audio（Android 13+ 有效，13- 上 status 为 denied）
///   2. Permission.manageExternalStorage（Android 11+ 写共享目录必需）
///   3. Permission.storage（Android 10 及以下）
/// 任一权限 status.isGranted 即视为已授权；否则按顺序 request 第一个未授权的。
/// 这样既能覆盖所有 Android 版本，又不需要 device_info_plus 额外依赖。
Future<bool> requestStoragePermission() async {
  if (!_isAndroidNative()) return true;

  // 已经授权的最优权限直接通过
  if (await Permission.audio.isGranted) return true;
  if (await Permission.manageExternalStorage.isGranted) return true;
  if (await Permission.storage.isGranted) return true;

  // 按优先级请求第一个未授权权限
  // Android 13+: Permission.audio 会弹系统授权弹窗
  // Android 11-12: Permission.audio 不会弹（权限不存在，返回 denied），
  //                接着尝试 manageExternalStorage，会跳系统设置页让用户手动开
  // Android 10-: 前两个都不弹，最终走 Permission.storage 弹窗
  final audioStatus = await Permission.audio.status;
  if (!audioStatus.isPermanentlyDenied) {
    // audio 未被永久拒绝：尝试请求
    final result = await Permission.audio.request();
    if (result.isGranted) return true;
    // 13- 设备：request 会返回 denied 或 permanentlyDenied（取决于厂商），
    // 继续尝试下一个权限，不要因 audio 失败就放弃。
  }

  final manageStatus = await Permission.manageExternalStorage.status;
  if (!manageStatus.isPermanentlyDenied) {
    final result = await Permission.manageExternalStorage.request();
    if (result.isGranted) return true;
  }

  // 最终回退：Permission.storage（Android 10 及以下的主要权限）
  final storageStatus = await Permission.storage.status;
  if (storageStatus.isPermanentlyDenied) {
    await openAppSettings();
    return false;
  }
  final result = await Permission.storage.request();
  if (result.isGranted) return true;

  if (result.isPermanentlyDenied) {
    await openAppSettings();
    return false;
  }
  return false;
}

Future<bool> requestAudioPermission() async {
  if (!_isAndroidNative()) return true;

  if (await Permission.audio.isGranted) return true;
  if (await Permission.storage.isGranted) return true;

  final audioStatus = await Permission.audio.status;
  if (!audioStatus.isPermanentlyDenied) {
    final result = await Permission.audio.request();
    if (result.isGranted) return true;
  }

  final storageStatus = await Permission.storage.status;
  if (storageStatus.isPermanentlyDenied) {
    await openAppSettings();
    return false;
  }
  final result = await Permission.storage.request();
  if (result.isGranted) return true;

  if (result.isPermanentlyDenied) {
    await openAppSettings();
    return false;
  }
  return false;
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
