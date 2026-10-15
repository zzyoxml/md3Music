import 'dart:async';
import 'dart:io';

import 'package:dlna_dart/dlna.dart';
import 'package:dlna_dart/xmlParser.dart';

/// DLNA 媒体类型，映射到 dlna_dart 的 PlayType MIME 枚举。
enum DlnaMediaType { audio, video }

/// 投屏操作异常，message 为可直接展示给用户的友好描述。
class DlnaServiceException implements Exception {
  final String message;
  const DlnaServiceException(this.message);
  @override
  String toString() => message;
}

/// 将底层异常映射为可展示的友好错误。
/// 优先识别 UPnP SOAP Fault 中的 errorCode/errorDescription，
/// 把设备返回的 701 等错误码翻译成用户能看懂的中文提示。
String _friendlyError(Object error) {
  if (error is DlnaServiceException) return error.message;
  if (error is TimeoutException) return '投屏设备响应超时，请检查设备与网络';
  if (error is SocketException) return '无法连接到投屏设备，请检查设备是否在线';
  // 解析 UPnP SOAP Fault：<errorCode>xxx</errorCode> / <errorDescription>xxx</errorDescription>
  final msg = error.toString();
  final codeMatch =
      RegExp(r'<errorCode>\s*(\d+)\s*</errorCode>').firstMatch(msg);
  if (codeMatch != null) {
    final code = codeMatch.group(1)!;
    final hint = _upnpErrorHints[code];
    if (hint != null) return '投屏失败：$hint（设备错误 $code）';
    final descMatch = RegExp(
      r'<errorDescription>\s*([^<]+)\s*</errorDescription>',
    ).firstMatch(msg);
    final desc = descMatch?.group(1)?.trim();
    if (desc != null && desc.isNotEmpty) {
      return '投屏失败：设备返回错误 $code（$desc）';
    }
    return '投屏失败：设备返回错误 $code';
  }
  return '投屏操作失败：$error';
}

/// UPnP AVTransport / RenderingControl 常见错误码 → 友好提示。
const Map<String, String> _upnpErrorHints = {
  '401': '设备不支持该操作',
  '402': '请求参数无效',
  '501': '设备不支持该操作',
  '701': '设备当前状态不允许该操作（如未播放时暂停/跳转，或设备不支持）',
  '702': '设备上不存在该资源',
  '703': '请求参数无效',
  '704': '操作执行失败',
  '720': '无法提供该资源',
  '721': '播放已停止，无法继续控制',
  '722': '该资源无法通过本设备播放',
};

/// DLNA 服务层：封装 dlna_dart 包的设备发现与传输控制。
/// 单例模式，与 [AudioService] 风格一致。
///
/// dlna_dart 底层 SOAP 请求固定 15s 超时（DLNAHttp），设备失联时会阻塞
/// 15s 造成 UI 卡死无反馈。因此所有设备操作统一用 [_opTimeout] 包裹，
/// 超时按失败处理，保证 UI 最多等 2s。
class DlnaService {
  static final DlnaService _instance = DlnaService._internal();
  factory DlnaService() => _instance;
  DlnaService._internal();

  static const Duration _opTimeout = Duration(seconds: 2);

  DLNAManager? _searcher;
  DeviceManager? _deviceManager;
  DLNADevice? _connectedDevice;
  StreamSubscription<Map<String, DLNADevice>>? _deviceSub;
  StreamSubscription<PositionParser>? _positionSub;

  /// 设备发现回调，外部通过此 Stream 获取设备列表变化。
  final _devicesController =
      StreamController<List<DlnaDeviceInfo>>.broadcast();
  Stream<List<DlnaDeviceInfo>> get devicesStream => _devicesController.stream;

  /// 位置更新回调，投屏中每 2 秒推送一次。
  final _positionController = StreamController<Duration>.broadcast();
  Stream<Duration> get positionStream => _positionController.stream;

  /// 总时长更新回调。
  final _durationController = StreamController<Duration?>.broadcast();
  Stream<Duration?> get durationStream => _durationController.stream;

  bool get isCasting => _connectedDevice != null;
  String? get deviceName => _connectedDevice?.info.friendlyName;

  /// 开始 SSDP 搜索局域网内的 DLNA 渲染设备。
  Future<void> startSearch() async {
    await stopSearch();
    _searcher = DLNAManager();
    try {
      _deviceManager = await _searcher!.start().timeout(_opTimeout);
    } catch (_) {
      // start 失败（如 WiFi 关闭导致 socket bind 失败）时清理已建对象
      _searcher?.stop();
      _searcher = null;
      _deviceManager = null;
      throw const DlnaServiceException('无法启动设备搜索，请检查网络或 WiFi 连接');
    }
    _deviceSub = _deviceManager!.devices.stream.listen((deviceMap) {
      final devices = deviceMap.values
          .map((d) => DlnaDeviceInfo(
                name: d.info.friendlyName,
                urlBase: d.info.URLBase,
                device: d,
              ))
          .toList();
      _devicesController.add(devices);
    });
  }

  /// 停止搜索。
  Future<void> stopSearch() async {
    await _deviceSub?.cancel();
    _deviceSub = null;
    _searcher?.stop();
    _searcher = null;
    _deviceManager = null;
  }

  /// 投屏：设置媒体 URL 并播放。
  /// [mediaType] 决定 DLNA 的 MIME 类型（音频/视频）。
  /// [overrideType] 可选，本地文件按扩展名映射的具体 PlayType；
  ///   传 null 时按 [mediaType] 兜底用 mpeg/mp4（保持向后兼容）。
  /// 失败（含未连接设备）时抛 [DlnaServiceException]，message 可直接展示。
  Future<void> cast(
    String url, {
    String? title,
    required DlnaMediaType mediaType,
    PlayType? overrideType,
  }) async {
    final device = _connectedDevice;
    if (device == null) {
      throw const DlnaServiceException('未连接投屏设备');
    }

    // 显式声明为 PlayType，避免 switch 推断为 Object
    final PlayType playType = overrideType ?? switch (mediaType) {
      DlnaMediaType.audio => AudioMime.mpeg,
      DlnaMediaType.video => VideoMime.mp4,
    };

    try {
      // 部分设备状态机要求先 Stop 再换流；但设备已处于 STOPPED 状态时
      // 再发 Stop 会返回 500/701（Transition not available）。
      // 因此 Stop 必须独立 try/catch 真正吞掉错误，失败不影响后续换流。
      try {
        await device.stop().timeout(_opTimeout);
      } catch (_) {}
      await device.setUrl(url, title: title ?? '', type: playType)
          .timeout(_opTimeout);
      await device.play().timeout(_opTimeout);
      // 切歌时先取消旧的位置监听，避免 listener 累积和旧事件干扰
      await _positionSub?.cancel();
      // 重置 position/duration，避免旧值残留导致自动切歌误触发
      _positionController.add(Duration.zero);
      _durationController.add(null);
      // 启动位置轮询
      device.positionPoller.start();
      _positionSub = device.currPosition.stream.listen((parser) {
        _positionController.add(Duration(seconds: parser.RelTimeInt));
        final dur = parser.TrackDurationInt;
        _durationController.add(
          dur > 0 ? Duration(seconds: dur) : null,
        );
      });
    } catch (e) {
      throw DlnaServiceException(_friendlyError(e));
    }
  }

  /// 连接到指定设备（在选择设备时调用）。
  void connectDevice(DLNADevice device) {
    _connectedDevice = device;
  }

  Future<void> play() async {
    final device = _connectedDevice;
    if (device == null) return;
    try {
      await device.play().timeout(_opTimeout);
    } catch (e) {
      throw DlnaServiceException(_friendlyError(e));
    }
  }

  Future<void> pause() async {
    final device = _connectedDevice;
    if (device == null) return;
    try {
      await device.pause().timeout(_opTimeout);
    } catch (e) {
      throw DlnaServiceException(_friendlyError(e));
    }
  }

  /// 向设备发送 Stop 指令但保留投屏连接。
  /// 用于 Pause 不被支持/状态不允许时的降级（暂停 → 停止当前播放）。
  Future<void> stopCurrent() async {
    final device = _connectedDevice;
    if (device == null) return;
    try {
      await device.stop().timeout(_opTimeout);
    } catch (_) {
      // 设备失联/超时忽略，投屏连接由调用方决定是否清理
    }
  }

  /// 停止投屏并向设备发送 Stop 指令。
  /// best-effort：设备失联时 Stop 可能超时/抛异常，但本地连接状态必须清理。
  Future<void> stop() async {
    _positionSub?.cancel();
    _positionSub = null;
    _connectedDevice?.positionPoller.stop();
    try {
      await _connectedDevice?.stop().timeout(_opTimeout);
    } catch (_) {
      // 设备失联/超时时忽略 Stop 失败，仅清理本地状态
    }
    _connectedDevice = null;
  }

  /// 跳转到指定位置。
  Future<void> seek(Duration position) async {
    final device = _connectedDevice;
    if (device == null) return;
    try {
      final target = PositionParser.toStr(position.inSeconds);
      await device.seek(target).timeout(_opTimeout);
    } catch (e) {
      throw DlnaServiceException(_friendlyError(e));
    }
  }

  /// 设置音量（0-100）。
  Future<void> setVolume(int volume) async {
    final device = _connectedDevice;
    if (device == null) return;
    try {
      await device.volume(volume).timeout(_opTimeout);
    } catch (e) {
      throw DlnaServiceException(_friendlyError(e));
    }
  }

  /// 获取当前音量（0-100）。
  Future<int?> getVolume() async {
    final device = _connectedDevice;
    if (device == null) return null;
    try {
      final text = await device.getVolume().timeout(_opTimeout);
      return VolumeParser(text).current;
    } catch (_) {
      return null;
    }
  }

  /// 获取当前传输状态（PLAYING / PAUSED_PLAYBACK / STOPPED）。
  Future<String?> getTransportState() async {
    final device = _connectedDevice;
    if (device == null) return null;
    try {
      final text = await device.getTransportInfo().timeout(_opTimeout);
      return TransportInfoParser(text).CurrentTransportState;
    } catch (_) {
      return null;
    }
  }

  /// 探测设备当前支持的传输动作集合（Pause/Seek/Stop/Next...）。
  /// 基于 GetCurrentTransportActions 返回的 `Actions` 字段（逗号分隔）。
  /// 空集合 = 探测失败（设备不支持该查询），调用方应保守保留全部控制。
  Future<Set<String>> getSupportedActions() async {
    final device = _connectedDevice;
    if (device == null) return {};
    try {
      final text =
          await device.getCurrentTransportActions().timeout(_opTimeout);
      final match = RegExp(r'<Actions>\s*([^<]*)\s*</Actions>').firstMatch(text);
      if (match == null) return {};
      return match
          .group(1)!
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toSet();
    } catch (_) {
      return {};
    }
  }

  /// 仅清理本地连接状态，不向设备发送 Stop。
  void disconnect() {
    _positionSub?.cancel();
    _positionSub = null;
    _connectedDevice?.positionPoller.stop();
    _connectedDevice = null;
  }

  void dispose() {
    stopSearch();
    _positionSub?.cancel();
    _devicesController.close();
    _positionController.close();
    _durationController.close();
  }
}

/// UI 层使用的设备信息数据类。
class DlnaDeviceInfo {
  final String name;
  final String urlBase;
  final DLNADevice device;

  DlnaDeviceInfo({
    required this.name,
    required this.urlBase,
    required this.device,
  });
}
