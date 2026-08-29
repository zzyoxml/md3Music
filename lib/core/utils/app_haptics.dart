import 'dart:async';

import 'package:flutter/services.dart';

/// 原生震动封装：绕过 HyperOS 等 ROM 丢弃的 [HapticFeedback]（performHapticFeedback），
/// 通过 MethodChannel 调原生 VibratorManager + VibrationEffect 直写马达。
///
/// 每个方法先尝试原生震动，300ms 超时或返回非 true / 异常时回退到 Flutter 的
/// [HapticFeedback]（其 lightImpact 在多数 ROM 仍有效）。fire-and-forget，不 await。
class AppHaptics {
  static const MethodChannel _channel = MethodChannel('md3music/haptics');

  static void _fire(String type, {required void Function() fallback}) {
    var done = false;
    void fallbackOnce() {
      if (!done) {
        done = true;
        fallback();
      }
    }

    // 300ms 超时保护：原生无响应时走 fallback
    Timer(const Duration(milliseconds: 300), fallbackOnce);

    // ignore: discarded_futures
    _channel.invokeMethod<bool>('vibrate', {'type': type}).then((value) {
      if (value == true) {
        done = true; // 原生成功，取消 fallback
      } else {
        fallbackOnce();
      }
    }).catchError((_) {
      fallbackOnce();
    });
  }

  /// 轻点：映射 EFFECT_CLICK，回退 lightImpact
  static void click() => _fire('click', fallback: HapticFeedback.lightImpact);

  /// 刻度：映射 EFFECT_TICK，回退 selectionClick
  static void tick() => _fire('tick', fallback: HapticFeedback.selectionClick);

  /// 重击：映射 EFFECT_HEAVY_CLICK，回退 heavyImpact
  static void heavy() => _fire('heavy', fallback: HapticFeedback.heavyImpact);

  /// 双击：映射 EFFECT_DOUBLE_CLICK，回退 mediumImpact
  static void doubleClick() =>
      _fire('double', fallback: HapticFeedback.mediumImpact);

  /// 长按：映射 createOneShot(25)，回退 mediumImpact
  static void longPress() =>
      _fire('longPress', fallback: HapticFeedback.mediumImpact);
}
