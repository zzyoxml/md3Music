import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 震动的交互类别。设置页「震动反馈」按类别独立开关，调用点必须显式声明自己属于哪一类，
/// 否则新增触点时会被编译器拦住（类别参数无默认值）。
enum HapticCategory {
  /// 播放控制按钮：播放/暂停、上一首/下一首、播放模式、收藏、进度条落点。
  transport,

  /// 列表条目：歌曲行 / 歌单行 / 评论行的点击与长按。
  listItem,

  /// 导航切换：底部导航栏与侧边栏、分段控件、播放页标签条。
  navigation,

  /// 开关与按钮：设置项开关、下拉菜单、普通按钮的按压反馈。
  control,

  /// 滑块调节：音量、进度条、设置类滑块的拖动与吸附。
  /// 该类别还包含 m3e_core 滑条的原生震动，开关与类型都由 _syncSliderGate 下发给原生闸门。
  slider,

  /// 手势与长按：封面长按、滑动切歌、点击歌词行跳转、下拉刷新。
  gesture,

  /// 悬浮播放器拖拽：拖动悬浮迷你播放条、或原地长按把它拾起时的反馈。
  /// 单独成类而非并入 [HapticCategory.gesture]：这里只标记「已拾起、当前可拖拽」，
  /// 关掉它不该把封面长按、滑动切歌一起弄没。
  floatingPlayer,
}

/// 类别可选的震动类型，取值与原生 `handleHapticVibrate` 的 type 一一对应。
///
/// 语义只有一个：默认（null）= 各触点继续用自己的强度（播放键重击、列表行轻点……）；
/// 选中某项 = 整类统一改用该预定义效果。覆盖不是纯增益，原生不可用时仍回落到该触点
/// 原本的 Flutter 触感，所以低端 ROM 上不会因此变成「没震动」。
enum HapticType {
  click('click', '轻点'),
  tick('tick', '刻度'),
  heavy('heavy', '重击'),
  doubleTap('double', '双击'),
  longPress('longPress', '长按');

  const HapticType(this.nativeName, this.label);

  /// 下发原生通道的 type 字符串（同时作为持久化值）。
  final String nativeName;

  /// 设置页展示名
  final String label;

  static HapticType? fromNativeName(String? name) {
    for (final type in values) {
      if (type.nativeName == name) return type;
    }
    return null;
  }
}

/// 原生震动封装：绕过 HyperOS 等 ROM 丢弃的 [HapticFeedback]（performHapticFeedback），
/// 通过 MethodChannel 调原生 VibratorManager + VibrationEffect 直写马达。
///
/// 每个方法先尝试原生震动，300ms 超时或返回非 true / 异常时回退到 Flutter 的
/// [HapticFeedback]（其 lightImpact 在多数 ROM 仍有效）。fire-and-forget，不 await。
///
/// 本类同时是全站震动的**唯一闸门**：总开关、类别开关、类别震动类型都存在内存里
/// （启动时由 [load] 从 SharedPreferences 恢复），[allows] 为 false 时不发通道、
/// 不回落、不震动。因此调用点一律走这里，不要再直接调 [HapticFeedback]（闸门版的
/// [lightImpact]/[mediumImpact]/[heavyImpact]/[selectionClick] 与原行为等价）。
class AppHaptics {
  AppHaptics._();

  static const MethodChannel _channel = MethodChannel('md3music/haptics');

  static const String _keyEnabled = 'settings_haptics_enabled';
  static const String _keyTypePrefix = 'settings_haptics_type_';

  static String _keyFor(HapticCategory category) =>
      'settings_haptics_${category.name}';

  static String _keyTypeFor(HapticCategory category) =>
      '$_keyTypePrefix${category.name}';

  // 默认全开、类型取默认（各触点自身强度）：引入该设置不改变既有用户的震动体验。
  static bool _enabled = true;
  static final Map<HapticCategory, bool> _categories = {
    for (final category in HapticCategory.values) category: true,
  };
  static final Map<HapticCategory, HapticType?> _types = {
    for (final category in HapticCategory.values) category: null,
  };

  /// 总开关（内存态，UI 直接读它，避免设置页与调用点各持一份真相）。
  static bool get enabled => _enabled;

  /// 某类交互此刻是否应当震动。
  static bool allows(HapticCategory category) =>
      _enabled && (_categories[category] ?? true);

  /// 某类别单独的开关状态（不含总开关），供设置页显示从属项。
  static bool isCategoryEnabled(HapticCategory category) =>
      _categories[category] ?? true;

  /// 某类别指定的震动类型；null 表示沿用各触点自身强度。
  static HapticType? typeFor(HapticCategory category) => _types[category];

  /// 启动时恢复偏好；在 runBootstrap 的并行初始化里调用，首帧前完成。
  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_keyEnabled) ?? true;
    for (final category in HapticCategory.values) {
      _categories[category] = prefs.getBool(_keyFor(category)) ?? true;
      _types[category] = HapticType.fromNativeName(
        prefs.getString(_keyTypeFor(category)),
      );
    }
    _syncSliderGate();
  }

  static Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyEnabled, value);
    _syncSliderGate();
  }

  static Future<void> setCategoryEnabled(
    HapticCategory category,
    bool value,
  ) async {
    if (_categories[category] == value) return;
    _categories[category] = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyFor(category), value);
    if (category == HapticCategory.slider) _syncSliderGate();
  }

  /// 设置某类别的震动类型；传 null 表示回到「默认（各触点自身强度）」。
  static Future<void> setCategoryType(
    HapticCategory category,
    HapticType? type,
  ) async {
    if (_types[category] == type) return;
    _types[category] = type;
    final prefs = await SharedPreferences.getInstance();
    if (type == null) {
      await prefs.remove(_keyTypeFor(category));
    } else {
      await prefs.setString(_keyTypeFor(category), type.nativeName);
    }
    if (category == HapticCategory.slider) _syncSliderGate();
  }

  /// m3e_core 的滑条震动不经本类（它自己直连 `m3e_haptics/haptics` 通道，
  /// 由 MainActivity 处理），所以「滑块调节」的开关与类型都只能下发给原生闸门，
  /// 否则总开关/类别开关/类型改了，拖动 m3e 滑块仍按老样子震动。
  static void _syncSliderGate() {
    // ignore: discarded_futures
    _channel
        .invokeMethod<void>('setSliderEnabled', {
          'enabled': allows(HapticCategory.slider),
          'type': _types[HapticCategory.slider]?.nativeName,
        })
        // 非 Android 平台或通道尚未注册：原生闸门不存在，Dart 侧判定照常生效。
        .catchError((_) {});
  }

  /// 当前平台是否存在可用的震动能力（Windows / Linux / macOS 桌面与 Web 都没有）。
  ///
  /// **为什么必须在这里短路**：桌面端（`md3music/haptics` 通道只在 Android 注册，
  /// 见 `MainActivity.kt`）每次触点都会先发一次注定 `MissingPluginException` 的
  /// 原生调用，超时/失败后再回落 `HapticFeedback`——而桌面 embedder 同样没有实现
  /// 该方法，于是**每次点击都白走两趟平台通道 + 起一个 300ms 看门狗 `Timer`**。
  /// 这些开销恰好压在「点按钮→下一帧」上（Windows 断点实测：鼠标点击暂停比空格
  /// 暂停多出整窗掉帧），而桌面上本来也震不了，所以直接短路、调用点零改动。
  static bool get _platformHasHaptics {
    if (kIsWeb) return false;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
        return true;
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        return false;
    }
  }

  /// 统一的发震动入口：先过闸门，再决定用类别指定类型还是调用点自身强度。
  ///
  /// [defaultNativeType] 为 null 的调用点（等价于裸 `HapticFeedback.*`）平时只走
  /// Flutter；一旦该类别指定了类型就升级为原生下发，原生失败仍回落原本触感。
  static void _emit(
    HapticCategory category,
    String? defaultNativeType, {
    required void Function() fallback,
  }) {
    if (!_platformHasHaptics) return;
    if (!allows(category)) return;
    final type = _types[category]?.nativeName ?? defaultNativeType;
    if (type == null) {
      fallback();
      return;
    }
    _fire(type, fallback: fallback);
  }

  static void _fire(
    String type, {
    required void Function() fallback,
  }) {
    var done = false;
    Timer? watchdog;
    void fallbackOnce() {
      if (done) return;
      done = true;
      watchdog?.cancel();
      fallback();
    }

    // 300ms 超时保护：原生无响应时走 fallback
    watchdog = Timer(const Duration(milliseconds: 300), fallbackOnce);

    // ignore: discarded_futures
    _channel.invokeMethod<bool>('vibrate', {'type': type}).then((value) {
      if (value == true) {
        // 原生成功，取消 fallback；watchdog 必须一起 cancel，否则每次震动都
        // 留下一个空转到 300ms 的定时器（列表行这类高频触点会持续堆积）。
        done = true;
        watchdog?.cancel();
      } else {
        fallbackOnce();
      }
    }).catchError((_) {
      fallbackOnce();
    });
  }

  /// 轻点：映射 EFFECT_CLICK，回退 lightImpact
  static void click(HapticCategory category) => _emit(
    category,
    HapticType.click.nativeName,
    fallback: HapticFeedback.lightImpact,
  );

  /// 刻度：映射 EFFECT_TICK，回退 selectionClick
  static void tick(HapticCategory category) => _emit(
    category,
    HapticType.tick.nativeName,
    fallback: HapticFeedback.selectionClick,
  );

  /// 重击：映射 EFFECT_HEAVY_CLICK，回退 heavyImpact
  static void heavy(HapticCategory category) => _emit(
    category,
    HapticType.heavy.nativeName,
    fallback: HapticFeedback.heavyImpact,
  );

  /// 双击：映射 EFFECT_DOUBLE_CLICK，回退 mediumImpact
  static void doubleClick(HapticCategory category) => _emit(
    category,
    HapticType.doubleTap.nativeName,
    fallback: HapticFeedback.mediumImpact,
  );

  /// 长按：映射 createOneShot(25)，回退 mediumImpact
  static void longPress(HapticCategory category) => _emit(
    category,
    HapticType.longPress.nativeName,
    fallback: HapticFeedback.mediumImpact,
  );

  /// 闸门版的 [HapticFeedback.lightImpact]：类别未指定类型时与原调用等价。
  static void lightImpact(HapticCategory category) =>
      _emit(category, null, fallback: HapticFeedback.lightImpact);

  static void mediumImpact(HapticCategory category) =>
      _emit(category, null, fallback: HapticFeedback.mediumImpact);

  static void heavyImpact(HapticCategory category) =>
      _emit(category, null, fallback: HapticFeedback.heavyImpact);

  static void selectionClick(HapticCategory category) =>
      _emit(category, null, fallback: HapticFeedback.selectionClick);
}
