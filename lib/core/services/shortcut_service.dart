import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

class ShortcutService {
  static final ShortcutService _instance = ShortcutService._internal();

  factory ShortcutService() => _instance;

  ShortcutService._internal();

  VoidCallback? onPlayPause;
  VoidCallback? onNext;
  VoidCallback? onPrevious;

  bool _registered = false;

  void register() {
    if (_registered) return;
    if (!defaultTargetPlatform.isDesktop) return;

    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
    _registered = true;
  }

  void unregister() {
    if (!_registered) return;
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    _registered = false;
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;

    if (event.logicalKey == LogicalKeyboardKey.mediaPlayPause) {
      onPlayPause?.call();
      return true;
    }

    if (event.logicalKey == LogicalKeyboardKey.mediaTrackNext) {
      onNext?.call();
      return true;
    }

    if (event.logicalKey == LogicalKeyboardKey.mediaTrackPrevious) {
      onPrevious?.call();
      return true;
    }

    if (event.logicalKey == LogicalKeyboardKey.space &&
        !HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isAltPressed &&
        !HardwareKeyboard.instance.isMetaPressed) {
      onPlayPause?.call();
      return true;
    }

    return false;
  }

  void dispose() {
    unregister();
    onPlayPause = null;
    onNext = null;
    onPrevious = null;
  }
}

extension _PlatformCheck on TargetPlatform {
  bool get isDesktop =>
      this == TargetPlatform.windows ||
      this == TargetPlatform.macOS ||
      this == TargetPlatform.linux;
}
