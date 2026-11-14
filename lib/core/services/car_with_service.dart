import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
// ThemeMode 必须取 material_ui 的那套：本仓库 MaterialApp / ThemeProvider 用的
// 都是 material_ui 重定义的同名枚举（app.dart 的喂法
// `carWith.themeOverride ?? themeProvider.themeMode` 要求两侧同型）。
// 引 flutter/material 会让 ?? 两侧变成两个不同枚举，编译期直接类型不匹配。
import 'package:material_ui/material_ui.dart' show ThemeMode;

import '../../data/repositories/settings_repository.dart';
import '../platform_capabilities.dart';

/// 小米 CarWith（车机互联）服务：连接态 + 车机深浅色读数 + 两把用户开关 +
/// 主题覆盖值 [themeOverride] 的单一数据源（规格 §一「主题」段）。
///
/// UI（app.dart / 设置页）只消费本服务的 getter，经 [ChangeNotifier] 感知翻转；
/// 原生侧通道 `com.md3music.md3music/car_with` 的读数失败一律按「未连接」返回，
/// Dart 侧再兜一层（TV / 桌面 / 单测环境根本没有该通道，会 MissingPluginException）。
///
/// **铁律：没连着 CarWith 时上游行为逐字不变** —— [themeOverride] 在未勾 /
/// 未连时恒为 null，app.dart 用它 `?? themeProvider.themeMode`，null 即完全走上游链路。
class CarWithService extends ChangeNotifier {
  CarWithService._();

  static final CarWithService _singleton = CarWithService._();

  /// 全局单例：main.dart 开机 [start()]，app.dart 观察亮度并接线 themeMode。
  static CarWithService get instance => _singleton;

  /// 测试专用实例：单例跨用例存活，dispose 后不可复用，单测一律用本构造。
  @visibleForTesting
  factory CarWithService.forTest() => CarWithService._();

  static const MethodChannel _channel = MethodChannel(
    'com.md3music.md3music/car_with',
  );

  /// 心跳周期（规格 §一：2 秒一轮）。远低于任何帧率预算，用普通
  /// [Timer.periodic] 即可，不占限帧资源。
  static const Duration _heartbeatInterval = Duration(seconds: 2);

  final SettingsRepository _settings = SettingsRepository();

  // ── 测试注入点（生产代码为 null，走真实通道 / 平台门）──────────────

  /// 覆盖平台门（默认读 [supportsCarWith]）。单测在 Windows 宿主上也能模拟
  /// 「支持 CarWith」与「不支持」两种分支（defaultTargetPlatform 会被测试
  /// 绑定固定成 android，改不了）。
  @visibleForTesting
  bool Function()? supportsCarWithOverride;

  /// 覆盖原生读数（默认走 [_channel].getCarWithState）。返回形如
  /// `{'connected': bool, 'nightMode': int}` 的 Map；抛异常按未连接处理。
  @visibleForTesting
  Future<Map<Object?, Object?>?> Function()? stateReaderOverride;

  // ── 内部状态 ────────────────────────────────────────────────────

  bool _started = false;
  Timer? _heartbeat;

  bool _connected = false;
  int _nightMode = -1;
  bool _followDarkEnabled = false;
  bool _lyricEnabled = false;

  /// 手机系统是否报深色。由 app.dart 的 didChangePlatformBrightness 喂进来；
  /// [start] 冷启动先种一次，避免首帧误判（车机已连深色时被当成「不报深色」）。
  bool _systemDark = false;

  /// 上一次真正报给界面（notifyListeners）的 [themeOverride] 值。
  /// 心跳每 2 秒都会产出快照，但只有它真的变了才上报 —— 本仓库对重建很敏感
  /// （AGENTS.md 渲染性能条），无变化的 notify 就是无谓的 MaterialApp 重建。
  ThemeMode? _lastReportedOverride;

  // ── 公开 API ────────────────────────────────────────────────────

  /// 当前是否连着 CarWith（最近一次快照）。读数失败恒为 false。
  bool get connected => _connected;

  /// 用户是否勾了「设置 → 外观 → 主题模式 → 跟随CarWith」。
  bool get followDarkEnabled => _followDarkEnabled;

  /// 用户是否勾了「设置 → 歌词 → 设备歌词 → 显示CarWith / Jovi InCar歌词」。
  bool get lyricEnabled => _lyricEnabled;

  /// 最近一次车机深浅色读数（0=浅色 / 1=深色 / -1=读不到），调试与自检页用，
  /// UI 主题链路不直接依赖它（只看 [themeOverride]）。断开时不清零，
  /// 判深色必须同时满足 [connected]。
  int get nightMode => _nightMode;

  /// 主题覆盖值（规格 §一 真值表，逐条对应）：
  /// - 没勾「跟随CarWith」→ null（用户在主题模式第一排选的那档生效）
  /// - 勾了但没连着车机 → null（回到用户选的那档）
  /// - 连着：车机报深色（nightMode==1）**或** 手机系统报深色 → dark
  /// - 连着：两边都不报深色 → light（nightMode==-1 属于「不报深色」）
  ThemeMode? get themeOverride {
    if (!_followDarkEnabled || !_connected) return null;
    if (_nightMode == 1 || _systemDark) return ThemeMode.dark;
    return ThemeMode.light;
  }

  /// 开机调用（main.dart）：恢复持久化 + 种一次系统亮度 + 按需起心跳。幂等。
  Future<void> start() async {
    if (_started) return;
    _started = true;
    // 亮度种子必须在恢复开关**之前**同步落好：两者之间有 await（prefs 读取），
    // 而恢复完开关就可能当场翻转出覆盖值。
    _systemDark = _readPlatformDark();
    _followDarkEnabled = await _settings.getFollowCarWithDark();
    _lyricEnabled = await _settings.getCarWithLyricEnabled();
    _syncHeartbeat();
    _emitIfChanged();
  }

  /// 设置「跟随CarWith」开关（持久化 + 心跳启停）。
  Future<void> setFollowDarkEnabled(bool v) async {
    if (_followDarkEnabled == v) return;
    _followDarkEnabled = v;
    await _settings.setFollowCarWithDark(v);
    // 勾上起心跳、取消停心跳；「起」包含立即一轮 —— 规格 §一 把「刚勾开关当场」
    // 列为原生门控位的刷新时机之一。
    _syncHeartbeat();
    _emitIfChanged();
  }

  /// 设置车机投屏歌词开关（持久化）。本开关不参与主题计算。
  Future<void> setLyricEnabled(bool v) async {
    if (_lyricEnabled == v) return;
    _lyricEnabled = v;
    await _settings.setCarWithLyricEnabled(v);
    // 刚勾开关当场补一轮快照（规格 §一 的三个刷新时机之一）。
    if (v) refreshNow();
  }

  /// app.dart 的 didChangePlatformBrightness 喂入口：手机系统深浅色翻转。
  void updateSystemDark(bool isSystemDark) {
    if (_systemDark == isSystemDark) return;
    _systemDark = isSystemDark;
    _emitIfChanged();
  }

  /// 回前台补一轮（app.dart 调用）。
  ///
  /// 歌词开关的快照刷新不靠常驻心跳，靠的就是这里 + 推送时原生现读，
  /// 所以只有 lyric 勾着而 follow 没勾时也要补这一轮；两把都没勾时无消费者，
  /// 不碰原生（规格 §九 第 2 条：不勾就不读原生）。
  void refreshNow() {
    if (!_canRead) return;
    if (!_followDarkEnabled && !_lyricEnabled) return;
    unawaited(_readOnce());
  }

  @override
  void dispose() {
    _heartbeat?.cancel();
    _heartbeat = null;
    super.dispose();
  }

  // ── 心跳与读数 ──────────────────────────────────────────────────

  bool get _canRead => supportsCarWithOverride?.call() ?? supportsCarWith;

  /// 心跳只服务于主题跟随：规格 §一 的「只在这把开关勾着且本平台可读时存在」
  /// 指的是「跟随CarWith」这把。歌词开关不建常驻心跳 —— 2 秒轮询对歌词链路
  /// 没有意义（字由原生在收到推送时现读连接态门控），Dart 侧只需要回前台补
  /// 一轮 + 刚勾开关当场一轮。取舍代价：纯歌词用户断开/连上瞬间，Dart 缓存的
  /// [connected] 最长滞后到下一次回前台，但推送链本身不经 Dart 判连接，不受影响。
  void _syncHeartbeat() {
    if (!(_followDarkEnabled && _canRead)) {
      _heartbeat?.cancel();
      _heartbeat = null;
      return;
    }
    if (_heartbeat != null) return;
    unawaited(_readOnce());
    _heartbeat = Timer.periodic(_heartbeatInterval, (_) {
      unawaited(_readOnce());
    });
  }

  /// 取一次原生快照并落到状态。两行注释给真机同学：读数失败按未连接处理。
  Future<void> _readOnce() async {
    try {
      final snap = await _readState();
      // 原生契约：读数失败保证返回 connected=false；这里仍全量兜底，
      // 通道缺失（TV/桌面/单测）或脏返回一律视为未连接。
      _connected = snap != null && snap['connected'] == true;
      final raw = snap != null ? snap['nightMode'] : null;
      _nightMode = (raw is int) ? raw : -1;
    } catch (_) {
      _connected = false;
      _nightMode = -1;
    }
    // 快照日志（规格 §七 探针：[MD3Music][carwith] / 连接= / 车机深浅=）。
    // 心跳只在勾着「跟随CarWith」且原生可读时存在，2 秒一行不会刷屏；
    // 主题覆盖值的翻转另有 [MD3Music][theme] 一条（_emitIfChanged）。
    debugPrint(
      '[MD3Music][carwith] 快照 连接=${_connected ? '连接' : '未连接'}, '
      '车机深浅=$_nightMode',
    );
    _emitIfChanged();
  }

  Future<Map<Object?, Object?>?> _readState() {
    final override = stateReaderOverride;
    if (override != null) return override();
    return _channel
        .invokeMethod<Object?>('getCarWithState')
        .then((value) => value is Map ? value.cast<Object?, Object?>() : null);
  }

  bool _readPlatformDark() {
    try {
      return PlatformDispatcher.instance.platformBrightness ==
          Brightness.dark;
    } catch (_) {
      return false;
    }
  }

  /// 翻转上报收口：只有「真正报给界面的值」变了才 notify（见字段注释）。
  /// 开关翻转但覆盖值没变（例如没连着车机时勾选）也不上报，界面拿到的
  /// themeMode 完全没动，notify 只会白花一次重建。
  void _emitIfChanged() {
    final v = themeOverride;
    if (v == _lastReportedOverride) return;
    _lastReportedOverride = v;
    debugPrint(
      '[MD3Music][carwith] 覆盖值 → $v '
      '(连接=${_connected ? '连接' : '未连接'}, 车机深浅=$_nightMode, '
      '系统深浅=${_systemDark ? '深' : '浅'}, 跟随=$_followDarkEnabled)',
    );
    notifyListeners();
  }
}
